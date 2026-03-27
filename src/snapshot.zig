const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const cdp = @import("cdp.zig");

// ============================================================================
// AX Tree Snapshot + @ref System
// Reference: agent-browser/cli/src/native/snapshot.rs
//            agent-browser/cli/src/native/element.rs
// CDP: Accessibility.getFullAXTree, DOM.getBoxModel, Input.dispatch*
// ============================================================================

const INTERACTIVE_ROLES = [_][]const u8{
    "button",     "link",       "textbox",          "checkbox",
    "radio",      "combobox",   "listbox",          "menuitem",
    "menuitemcheckbox", "menuitemradio", "option",  "searchbox",
    "slider",     "spinbutton", "switch",           "tab",
    "treeitem",
};

const CONTENT_ROLES = [_][]const u8{
    "heading", "cell", "gridcell", "columnheader", "rowheader",
    "listitem", "article", "region", "main", "navigation",
};

pub const RefEntry = struct {
    ref_id: []u8,
    backend_node_id: ?i64,
    role: []u8,
    name: []u8,
};

pub const RefMap = struct {
    entries: std.StringArrayHashMap(RefEntry),
    next_ref: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) RefMap {
        return .{
            .entries = std.StringArrayHashMap(RefEntry).init(allocator),
            .next_ref = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RefMap) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            // ref_id shares allocation with key — only free role, name, and key
            self.allocator.free(entry.value_ptr.role);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn addRef(self: *RefMap, backend_node_id: ?i64, role: []const u8, name: []const u8) ![]const u8 {
        var ref_buf: [16]u8 = undefined;
        const ref_id = std.fmt.bufPrint(&ref_buf, "e{d}", .{self.next_ref}) catch return error.Overflow;
        self.next_ref += 1;

        const owned_key = try self.allocator.dupe(u8, ref_id);
        errdefer self.allocator.free(owned_key);
        const owned_role = try self.allocator.dupe(u8, role);
        errdefer self.allocator.free(owned_role);
        const owned_name = try self.allocator.dupe(u8, name);

        try self.entries.put(owned_key, .{
            .ref_id = owned_key, // Share key allocation — no separate ref_id
            .backend_node_id = backend_node_id,
            .role = owned_role,
            .name = owned_name,
        });

        return owned_key;
    }

    pub fn getByRef(self: *const RefMap, ref_id: []const u8) ?RefEntry {
        // Strip @ prefix if present
        const clean_ref = if (std.mem.startsWith(u8, ref_id, "@")) ref_id[1..] else ref_id;
        return self.entries.get(clean_ref);
    }

    pub fn count(self: *const RefMap) usize {
        return self.entries.count();
    }
};

/// Check if a role is interactive (should get a @ref).
pub fn isInteractiveRole(role: []const u8) bool {
    for (INTERACTIVE_ROLES) |r| {
        if (std.mem.eql(u8, role, r)) return true;
    }
    return false;
}

/// Check if a role is content (gets @ref only if it has a name).
pub fn isContentRole(role: []const u8) bool {
    for (CONTENT_ROLES) |r| {
        if (std.mem.eql(u8, role, r)) return true;
    }
    return false;
}

/// Parse the AX tree response and build a text snapshot with @refs.
/// Preserves tree structure using parentId for depth-based indentation.
pub fn buildSnapshot(
    allocator: Allocator,
    ax_tree_json: std.json.Value,
    ref_map: *RefMap,
    interactive_only: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    if (ax_tree_json != .object) return error.InvalidCharacter;
    const nodes_val = ax_tree_json.object.get("nodes") orelse return error.InvalidCharacter;
    if (nodes_val != .array) return error.InvalidCharacter;

    const nodes = nodes_val.array.items;

    // Build node-id → depth map using parentId
    var depth_map = std.StringArrayHashMap(usize).init(allocator);
    defer depth_map.deinit();

    for (nodes) |node| {
        if (node != .object) continue;
        const node_id = cdp.getString(node, "nodeId") orelse continue;
        const parent_id = cdp.getString(node, "parentId");

        const depth: usize = if (parent_id) |pid| blk: {
            break :blk (depth_map.get(pid) orelse 0) + 1;
        } else 0;

        const key = allocator.dupe(u8, node_id) catch continue;
        depth_map.put(key, depth) catch allocator.free(key);
    }
    defer {
        var it = depth_map.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    }

    for (nodes) |node| {
        if (node != .object) continue;

        if (cdp.getBool(node, "ignored")) |ignored| {
            if (ignored) continue;
        }

        const role = extractAxValue(node, "role") orelse continue;
        const name = extractAxValue(node, "name") orelse "";
        const backend_node_id = cdp.getInt(node, "backendDOMNodeId");

        // Get depth for indentation
        const node_id = cdp.getString(node, "nodeId") orelse "";
        const depth = depth_map.get(node_id) orelse 0;

        const should_ref = isInteractiveRole(role) or
            (isContentRole(role) and name.len > 0);

        if (should_ref) {
            const ref_id = ref_map.addRef(backend_node_id, role, name) catch continue;

            // Indent by depth
            for (0..depth) |_| try writer.writeAll("  ");
            try writer.writeAll("@");
            try writer.writeAll(ref_id);
            try writer.writeAll(" [");
            try writer.writeAll(role);
            try writer.writeAll("] ");
            if (name.len > 0) {
                try writer.writeByte('"');
                try writer.writeAll(name);
                try writer.writeByte('"');
            }
            try writer.writeByte('\n');
        } else if (!interactive_only and name.len > 0) {
            for (0..depth) |_| try writer.writeAll("  ");
            try writer.writeAll(role);
            try writer.writeAll(" \"");
            try writer.writeAll(name);
            try writer.writeByte('"');
            try writer.writeByte('\n');
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Extract value from an AXValue object: {"type":"...","value":"the actual value"}
fn extractAxValue(node: std.json.Value, field: []const u8) ?[]const u8 {
    if (node != .object) return null;
    const ax_val = node.object.get(field) orelse return null;
    if (ax_val != .object) return null;
    return cdp.getString(ax_val, "value");
}

/// Build a CDP command that takes a single backendNodeId parameter.
pub fn buildBackendNodeCmd(allocator: Allocator, id: u64, method: []const u8, backend_node_id: i64, session_id: ?[]const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"backendNodeId\":{d}}}", .{backend_node_id}) catch
        return error.Overflow;
    return cdp.serializeCommand(allocator, id, method, params, session_id);
}

pub fn buildGetBoxModelCmd(allocator: Allocator, id: u64, backend_node_id: i64, session_id: ?[]const u8) ![]u8 {
    return buildBackendNodeCmd(allocator, id, "DOM.getBoxModel", backend_node_id, session_id);
}

pub fn buildFocusCmd(allocator: Allocator, id: u64, backend_node_id: i64, session_id: ?[]const u8) ![]u8 {
    return buildBackendNodeCmd(allocator, id, "DOM.focus", backend_node_id, session_id);
}

/// Build CDP command to dispatch a mouse click at coordinates.
pub fn buildClickCmd(allocator: Allocator, id: u64, x: f64, y: f64, click_type: []const u8, session_id: ?[]const u8) ![]u8 {
    var buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ click_type, x, y }) catch
        return error.Overflow;
    return cdp.serializeCommand(allocator, id, "Input.dispatchMouseEvent", params, session_id);
}

/// Build CDP command to insert text.
pub fn buildInsertTextCmd(allocator: Allocator, id: u64, text: []const u8, session_id: ?[]const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"text\":");
    try cdp.writeJsonString(writer, text);
    try writer.writeByte('}');

    const params = try buf.toOwnedSlice(allocator);
    defer allocator.free(params);

    return cdp.serializeCommand(allocator, id, "Input.insertText", params, session_id);
}

/// Extract center coordinates from a DOM.getBoxModel response.
pub fn extractBoxCenter(result: std.json.Value) ?struct { x: f64, y: f64 } {
    const model = cdp.getObject(result, "model") orelse return null;
    if (model != .object) return null;

    // content quad: [x1,y1, x2,y2, x3,y3, x4,y4]
    const content = model.object.get("content") orelse return null;
    if (content != .array) return null;
    const items = content.array.items;
    if (items.len < 4) return null;

    const x1 = jsonToF64(items[0]) orelse return null;
    const y1 = jsonToF64(items[1]) orelse return null;
    const x3 = jsonToF64(items[4]) orelse return null;
    const y3 = jsonToF64(items[5]) orelse return null;

    return .{
        .x = (x1 + x3) / 2.0,
        .y = (y1 + y3) / 2.0,
    };
}

fn jsonToF64(val: std.json.Value) ?f64 {
    return switch (val) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "isInteractiveRole: known roles" {
    try testing.expect(isInteractiveRole("button"));
    try testing.expect(isInteractiveRole("link"));
    try testing.expect(isInteractiveRole("textbox"));
    try testing.expect(isInteractiveRole("checkbox"));
    try testing.expect(isInteractiveRole("combobox"));
    try testing.expect(!isInteractiveRole("generic"));
    try testing.expect(!isInteractiveRole("heading"));
    try testing.expect(!isInteractiveRole(""));
}

test "isContentRole: known roles" {
    try testing.expect(isContentRole("heading"));
    try testing.expect(isContentRole("cell"));
    try testing.expect(isContentRole("listitem"));
    try testing.expect(!isContentRole("button"));
    try testing.expect(!isContentRole("generic"));
}

test "RefMap: add and get" {
    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const ref = try ref_map.addRef(42, "button", "Submit");
    try testing.expectEqualStrings("e1", ref);
    try testing.expectEqual(@as(usize, 1), ref_map.count());

    const entry = ref_map.getByRef("e1").?;
    try testing.expectEqual(@as(i64, 42), entry.backend_node_id.?);
    try testing.expectEqualStrings("button", entry.role);
    try testing.expectEqualStrings("Submit", entry.name);
}

test "RefMap: @ prefix stripped" {
    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    _ = try ref_map.addRef(1, "link", "Home");
    const entry = ref_map.getByRef("@e1").?;
    try testing.expectEqualStrings("link", entry.role);
}

test "RefMap: sequential IDs" {
    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const r1 = try ref_map.addRef(1, "button", "A");
    const r2 = try ref_map.addRef(2, "link", "B");
    const r3 = try ref_map.addRef(3, "textbox", "C");

    try testing.expectEqualStrings("e1", r1);
    try testing.expectEqualStrings("e2", r2);
    try testing.expectEqualStrings("e3", r3);
}

test "RefMap: not found" {
    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    try testing.expect(ref_map.getByRef("e99") == null);
    try testing.expect(ref_map.getByRef("@e99") == null);
}

test "buildSnapshot: simple AX tree" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Submit"},"backendDOMNodeId":42},{"nodeId":"2","ignored":false,"role":{"type":"role","value":"heading"},"name":{"type":"computedString","value":"Welcome"}},{"nodeId":"3","ignored":true,"role":{"type":"role","value":"generic"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snapshot = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false);
    defer testing.allocator.free(snapshot);

    try testing.expect(std.mem.indexOf(u8, snapshot, "@e1 [button] \"Submit\"") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "@e2 [heading] \"Welcome\"") != null);
    try testing.expectEqual(@as(usize, 2), ref_map.count());
}

test "buildSnapshot: interactive only" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Click"}},{"nodeId":"2","ignored":false,"role":{"type":"role","value":"heading"},"name":{"type":"computedString","value":"Title"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snapshot = try buildSnapshot(testing.allocator, parsed.value, &ref_map, true);
    defer testing.allocator.free(snapshot);

    // Button gets ref, heading gets ref (content with name)
    try testing.expect(std.mem.indexOf(u8, snapshot, "@e1 [button]") != null);
    // Heading has name so it gets ref too
    try testing.expect(std.mem.indexOf(u8, snapshot, "@e2 [heading]") != null);
}

test "extractBoxCenter: normal quad" {
    const json =
        \\{"model":{"content":[10,20,100,20,100,80,10,80],"width":90,"height":60}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const center = extractBoxCenter(parsed.value).?;
    try testing.expectApproxEqAbs(@as(f64, 55.0), center.x, 0.1);
    try testing.expectApproxEqAbs(@as(f64, 50.0), center.y, 0.1);
}

test "extractAxValue: normal AXValue" {
    const json =
        \\{"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Submit"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("button", extractAxValue(parsed.value, "role").?);
    try testing.expectEqualStrings("Submit", extractAxValue(parsed.value, "name").?);
}

test "buildBackendNodeCmd: produces valid CDP command" {
    const cmd = try buildBackendNodeCmd(testing.allocator, 1, "DOM.getBoxModel", 42, null);
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "DOM.getBoxModel") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "42") != null);
}

test "buildClickCmd: produces mouse event" {
    const cmd = try buildClickCmd(testing.allocator, 1, 100.5, 200.5, "mousePressed", null);
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "mousePressed") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "Input.dispatchMouseEvent") != null);
}

test "buildInsertTextCmd: escapes text" {
    const cmd = try buildInsertTextCmd(testing.allocator, 1, "hello \"world\"", null);
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "Input.insertText") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "hello") != null);
}

test "buildSnapshot: tree depth preserved" {
    // Node with parentId should be indented deeper
    const json =
        \\{"nodes":[{"nodeId":"root","ignored":false,"role":{"type":"role","value":"RootWebArea"},"name":{"type":"computedString","value":"Page"}},{"nodeId":"child","parentId":"root","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Click"},"backendDOMNodeId":1}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, true);
    defer testing.allocator.free(snap);

    // Child button should have indentation (depth 1 = 2 spaces)
    try testing.expect(std.mem.indexOf(u8, snap, "  @e1 [button]") != null);
}

test "extractBoxCenter: missing content returns null" {
    const json =
        \\{"model":{"width":90,"height":60}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(extractBoxCenter(parsed.value) == null);
}

test "extractBoxCenter: insufficient items returns null" {
    const json =
        \\{"model":{"content":[10,20],"width":90,"height":60}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(extractBoxCenter(parsed.value) == null);
}

test "RefMap: deinit cleans up all memory" {
    var ref_map = RefMap.init(testing.allocator);
    _ = try ref_map.addRef(1, "button", "A");
    _ = try ref_map.addRef(2, "link", "B");
    _ = try ref_map.addRef(3, "textbox", "C");
    ref_map.deinit();
    // testing.allocator detects leaks automatically
}
