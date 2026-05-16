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
    "button",           "link",      "textbox",          "checkbox",
    "radio",            "combobox",  "listbox",          "menuitem",
    "menuitemcheckbox", "menuitemradio", "option",       "searchbox",
    "slider",           "spinbutton", "switch",          "tab",
    "treeitem",         "Iframe",
};

const CONTENT_ROLES = [_][]const u8{
    "heading", "cell", "gridcell", "columnheader", "rowheader",
    "listitem", "article", "region", "main", "navigation",
};

/// Zero-width and invisible characters to strip from names.
const INVISIBLE_CHARS = [_]u21{
    0xFEFF, // BOM / Zero Width No-Break Space
    0x200B, // Zero Width Space
    0x200C, // Zero Width Non-Joiner
    0x200D, // Zero Width Joiner
    0x2060, // Word Joiner
};

/// Info about a cursor-interactive element detected via JS/CSS heuristics.
/// These are non-ARIA elements (e.g. div with onclick, cursor:pointer, tabindex, contenteditable)
/// that should also get @refs in the snapshot.
pub const CursorElementInfo = struct {
    kind: []const u8, // "clickable", "focusable", "editable"
    hints: []const u8, // "cursor:pointer, onclick" etc
    text: []const u8, // textContent fallback
};

/// Map of backendNodeId → CursorElementInfo for cursor-interactive elements.
pub const CursorElementMap = std.AutoHashMap(i64, CursorElementInfo);

/// ARIA properties extracted from AX node.
const NodeProperties = struct {
    level: ?i64 = null,
    checked: ?[]const u8 = null, // "true", "false", "mixed"
    expanded: ?bool = null,
    selected: ?bool = null,
    disabled: ?bool = null,
    required: ?bool = null,
    value_text: ?[]const u8 = null,
};

/// Intermediate tree node for building the snapshot.
const TreeNode = struct {
    role: []const u8,
    name: []const u8,
    backend_node_id: ?i64,
    properties: NodeProperties,
    children: std.ArrayList(usize),
    parent_idx: ?usize,
    has_ref: bool,
    ref_id: ?[]const u8,
    depth: usize,
    cleared: bool,
    cursor_info: ?CursorElementInfo,

    fn initEmpty() TreeNode {
        return .{
            .role = "",
            .name = "",
            .backend_node_id = null,
            .properties = .{},
            .children = std.ArrayList(usize).empty,
            .parent_idx = null,
            .has_ref = false,
            .ref_id = null,
            .depth = 0,
            .cleared = true,
            .cursor_info = null,
        };
    }

    fn deinit(self: *TreeNode, allocator: Allocator) void {
        self.children.deinit(allocator);
    }

    fn clear(self: *TreeNode) void {
        self.role = "";
        self.name = "";
        self.backend_node_id = null;
        self.properties = .{};
        self.has_ref = false;
        self.ref_id = null;
        self.cleared = true;
        self.cursor_info = null;
    }
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

/// Strip invisible characters (zero-width spaces, BOM, etc.) from a name.
fn stripInvisibleChars(allocator: Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
            try buf.append(allocator, input[i]);
            i += 1;
            continue;
        };
        if (i + len > input.len) {
            try buf.append(allocator, input[i]);
            i += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(input[i..][0..len]) catch {
            try buf.append(allocator, input[i]);
            i += 1;
            continue;
        };

        var is_invisible = false;
        for (INVISIBLE_CHARS) |ic| {
            if (codepoint == ic) {
                is_invisible = true;
                break;
            }
        }
        if (!is_invisible) {
            try buf.appendSlice(allocator, input[i .. i + len]);
        }
        i += len;
    }

    return buf.toOwnedSlice(allocator);
}

/// Parse the AX tree response and build a text snapshot with @refs.
/// Uses a TreeNode intermediate representation matching agent-browser's model.
pub fn buildSnapshot(
    allocator: Allocator,
    ax_tree_json: std.json.Value,
    ref_map: *RefMap,
    interactive_only: bool,
    cursor_elements: ?*const CursorElementMap,
    link_urls: ?*const std.AutoHashMap(i64, []const u8),
) ![]u8 {
    if (ax_tree_json != .object) return error.InvalidCharacter;
    const nodes_val = ax_tree_json.object.get("nodes") orelse return error.InvalidCharacter;
    if (nodes_val != .array) return error.InvalidCharacter;

    const nodes = nodes_val.array.items;

    // Phase 1: Build TreeNode array and id→index map
    var tree_nodes = std.ArrayList(TreeNode).empty;
    defer {
        for (tree_nodes.items) |*tn| tn.deinit(allocator);
        tree_nodes.deinit(allocator);
    }

    var id_to_idx = std.StringArrayHashMap(usize).init(allocator);
    defer id_to_idx.deinit();

    // Track allocated numeric value strings for cleanup
    var numeric_values: std.ArrayList([]u8) = .empty;
    defer {
        for (numeric_values.items) |v| allocator.free(v);
        numeric_values.deinit(allocator);
    }

    for (nodes, 0..) |node, i| {
        if (node != .object) {
            const empty = TreeNode.initEmpty();
            try tree_nodes.append(allocator, empty);
            _ = i;
            continue;
        }

        const role = extractAxValue(node, "role") orelse "";
        const name = extractAxValue(node, "name") orelse "";
        const backend_node_id = cdp.getInt(node, "backendDOMNodeId");
        const node_id = cdp.getString(node, "nodeId") orelse "";

        const ignored = cdp.getBool(node, "ignored") orelse false;

        // Skip InlineTextBox and ignored nodes (but not RootWebArea)
        if ((ignored and !std.mem.eql(u8, role, "RootWebArea")) or std.mem.eql(u8, role, "InlineTextBox")) {
            const empty = TreeNode.initEmpty();
            try tree_nodes.append(allocator, empty);
            if (node_id.len > 0) try id_to_idx.put(node_id, tree_nodes.items.len - 1);
            continue;
        }

        // Extract properties
        const props = extractProperties(node);
        var value_num_buf: [32]u8 = undefined;
        const value_text: ?[]const u8 = blk: {
            // Try string first (borrows from JSON — no alloc needed)
            if (extractAxValue(node, "value")) |s| break :blk s;
            // Try numeric (needs owned copy since buffer is on stack)
            if (extractAxValueNumeric(node, "value", &value_num_buf)) |num_str| {
                const owned = allocator.dupe(u8, num_str) catch break :blk null;
                numeric_values.append(allocator, owned) catch {
                    allocator.free(owned);
                    break :blk null;
                };
                break :blk owned;
            }
            break :blk null;
        };

        // Look up cursor-interactive element info
        const ci = if (cursor_elements) |ce| blk: {
            if (backend_node_id) |bid| {
                break :blk ce.get(bid);
            }
            break :blk null;
        } else null;

        var tn = TreeNode{
            .role = role,
            .name = name,
            .backend_node_id = backend_node_id,
            .properties = .{
                .level = props.level,
                .checked = props.checked,
                .expanded = props.expanded,
                .selected = props.selected,
                .disabled = props.disabled,
                .required = props.required,
                .value_text = value_text,
            },
            .children = std.ArrayList(usize).empty,
            .parent_idx = null,
            .has_ref = false,
            .ref_id = null,
            .depth = 0,
            .cleared = false,
            .cursor_info = ci,
        };
        try tree_nodes.append(allocator, tn);
        _ = &tn;

        if (node_id.len > 0) try id_to_idx.put(node_id, tree_nodes.items.len - 1);
    }

    // Phase 2: Build parent-child relationships using childIds (primary) and parentId (fallback)
    for (nodes, 0..) |node, i| {
        if (node != .object) continue;

        // Use childIds if available
        if (node.object.get("childIds")) |child_ids_val| {
            if (child_ids_val == .array) {
                for (child_ids_val.array.items) |cid_val| {
                    if (cid_val == .string) {
                        if (id_to_idx.get(cid_val.string)) |child_idx| {
                            try tree_nodes.items[i].children.append(allocator, child_idx);
                            tree_nodes.items[child_idx].parent_idx = i;
                        }
                    }
                }
            }
        }
    }

    // Fallback: use parentId for nodes that don't have a parent yet
    for (nodes, 0..) |node, i| {
        if (node != .object) continue;
        if (tree_nodes.items[i].parent_idx != null) continue; // already set

        const parent_id = cdp.getString(node, "parentId") orelse continue;
        if (id_to_idx.get(parent_id)) |parent_idx| {
            // Check if this child is already in the parent's children list
            var already_child = false;
            for (tree_nodes.items[parent_idx].children.items) |existing| {
                if (existing == i) {
                    already_child = true;
                    break;
                }
            }
            if (!already_child) {
                try tree_nodes.items[parent_idx].children.append(allocator, i);
            }
            tree_nodes.items[i].parent_idx = parent_idx;
        }
    }

    // Track aggregated names that need freeing
    var agg_names = std.ArrayList([]u8).empty;
    defer {
        for (agg_names.items) |n| allocator.free(n);
        agg_names.deinit(allocator);
    }

    // Phase 3: StaticText aggregation
    for (tree_nodes.items) |*tn| {
        if (tn.cleared or tn.children.items.len == 0) continue;

        const children = tn.children.items;

        // Merge consecutive StaticText children
        var start: usize = 0;
        while (start < children.len) {
            if (tree_nodes.items[children[start]].cleared or
                !std.mem.eql(u8, tree_nodes.items[children[start]].role, "StaticText"))
            {
                start += 1;
                continue;
            }

            var end = start + 1;
            while (end < children.len and
                !tree_nodes.items[children[end]].cleared and
                std.mem.eql(u8, tree_nodes.items[children[end]].role, "StaticText"))
            {
                end += 1;
            }

            // If we have 2+ consecutive StaticText, aggregate names into first
            if (end > start + 1) {
                // Build aggregated name
                var agg: std.ArrayList(u8) = .empty;
                defer agg.deinit(allocator);
                for (start..end) |idx| {
                    const child_name = tree_nodes.items[children[idx]].name;
                    agg.appendSlice(allocator, child_name) catch {};
                }
                // Store aggregated name (borrows from agg, but we allocate owned copy)
                const owned = agg.toOwnedSlice(allocator) catch {
                    start = end;
                    continue;
                };
                // We need to keep this alive — store it and free later
                // Since names borrow from the JSON, we'll use a separate allocated name
                // and store it in a temp list. For simplicity, just set the name pointer
                // to the first child's original name + extras (won't work).
                // Actually: the aggregated name needs to persist. We'll allocate and track.
                // For now, store in the first child. Since we only read names during render,
                // and the allocator manages lifetime, let's use a different approach:
                // We'll just keep the first child's name as-is if aggregation isn't critical
                // for the first pass. But let's do it properly.
                tree_nodes.items[children[start]].name = owned;
                agg_names.append(allocator, owned) catch {};

                // Clear the rest
                for ((start + 1)..end) |j| {
                    tree_nodes.items[children[j]].clear();
                }
            }
            start = end;
        }

        // Deduplicate: single StaticText child with same name as parent
        if (children.len == 1 and
            !tree_nodes.items[children[0]].cleared and
            std.mem.eql(u8, tree_nodes.items[children[0]].role, "StaticText") and
            std.mem.eql(u8, tn.name, tree_nodes.items[children[0]].name))
        {
            tree_nodes.items[children[0]].clear();
        }
    }

    // Phase 4: Compute depths and find roots
    var root_indices = std.ArrayList(usize).empty;
    defer root_indices.deinit(allocator);

    for (tree_nodes.items, 0..) |tn, i| {
        if (tn.parent_idx == null and !tn.cleared) {
            try root_indices.append(allocator, i);
        }
    }

    // Set depths recursively
    for (root_indices.items) |root_idx| {
        setDepth(&tree_nodes, root_idx, 0);
    }

    // Phase 5: Assign refs
    for (tree_nodes.items) |*tn| {
        if (tn.cleared) continue;
        const should_ref = isInteractiveRole(tn.role) or
            (isContentRole(tn.role) and tn.name.len > 0) or
            tn.cursor_info != null;

        if (should_ref) {
            const ref_id = ref_map.addRef(tn.backend_node_id, tn.role, tn.name) catch continue;
            tn.has_ref = true;
            tn.ref_id = ref_id;
        }
    }

    // Phase 6: Render
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Track allocated names for cleanup
    var owned_names = std.ArrayList([]u8).empty;
    defer {
        for (owned_names.items) |n| allocator.free(n);
        owned_names.deinit(allocator);
    }

    for (root_indices.items) |root_idx| {
        try renderTree(allocator, tree_nodes.items, root_idx, 0, writer, interactive_only, &owned_names, link_urls);
    }

    const result = try buf.toOwnedSlice(allocator);

    // If interactive only and empty, return sentinel
    if (interactive_only and result.len == 0) {
        allocator.free(result);
        return allocator.dupe(u8, "(no interactive elements)");
    }

    return result;
}

fn setDepth(tree_nodes: *std.ArrayList(TreeNode), idx: usize, depth: usize) void {
    tree_nodes.items[idx].depth = depth;
    // Copy children slice to avoid aliasing issues
    const children = tree_nodes.items[idx].children.items;
    for (children) |child_idx| {
        setDepth(tree_nodes, child_idx, depth + 1);
    }
}

fn renderTree(
    allocator: Allocator,
    nodes: []const TreeNode,
    idx: usize,
    indent: usize,
    writer: anytype,
    interactive_only: bool,
    owned_names: *std.ArrayList([]u8),
    link_urls: ?*const std.AutoHashMap(i64, []const u8),
) !void {
    const node = &nodes[idx];

    // Skip cleared/empty nodes but render children
    if (node.cleared or node.role.len == 0) {
        for (node.children.items) |child_idx| {
            try renderTree(allocator, nodes, child_idx, indent, writer, interactive_only, owned_names, link_urls);
        }
        return;
    }

    // Skip generic nodes with <=1 child and no ref (reduce noise)
    if (std.mem.eql(u8, node.role, "generic") and !node.has_ref and node.children.items.len <= 1) {
        for (node.children.items) |child_idx| {
            try renderTree(allocator, nodes, child_idx, indent, writer, interactive_only, owned_names, link_urls);
        }
        return;
    }

    // Skip RootWebArea / WebArea — structural containers
    if (std.mem.eql(u8, node.role, "RootWebArea") or std.mem.eql(u8, node.role, "WebArea")) {
        for (node.children.items) |child_idx| {
            try renderTree(allocator, nodes, child_idx, indent, writer, interactive_only, owned_names, link_urls);
        }
        return;
    }

    // Skip StaticText with empty/invisible-only name
    if (std.mem.eql(u8, node.role, "StaticText")) {
        const cleaned = stripInvisibleChars(allocator, node.name) catch node.name;
        const did_alloc = cleaned.ptr != node.name.ptr;
        defer if (did_alloc) allocator.free(cleaned);
        if (cleaned.len == 0) {
            for (node.children.items) |child_idx| {
                try renderTree(allocator, nodes, child_idx, indent, writer, interactive_only, owned_names, link_urls);
            }
            return;
        }
    }

    // Interactive-only mode: skip non-ref nodes, but recurse children
    if (interactive_only and !node.has_ref) {
        for (node.children.items) |child_idx| {
            try renderTree(allocator, nodes, child_idx, indent, writer, interactive_only, owned_names, link_urls);
        }
        return;
    }

    // Render this node
    // Indent
    for (0..indent) |_| try writer.writeAll("  ");
    try writer.writeAll("- ");
    try writer.writeAll(node.role);

    // Name (strip invisible chars) — stripInvisibleChars always allocates
    const display_name = stripInvisibleChars(allocator, node.name) catch "";
    if (display_name.len > 0) {
        try owned_names.append(allocator, @constCast(display_name));
    } else if (display_name.ptr != node.name.ptr) {
        // Allocated but empty — free immediately
        allocator.free(@constCast(display_name));
    }

    if (display_name.len > 0) {
        try writer.writeAll(" \"");
        try writer.writeAll(display_name);
        try writer.writeByte('"');
    }

    // Properties in brackets — properties first, ref=eN last
    var attrs_buf: std.ArrayList(u8) = .empty;
    defer attrs_buf.deinit(allocator);
    const attrs_writer = attrs_buf.writer(allocator);

    if (node.properties.level) |level| {
        if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
        try attrs_writer.print("level={d}", .{level});
    }

    if (node.properties.checked) |checked| {
        if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
        try attrs_writer.writeAll("checked=");
        try attrs_writer.writeAll(checked);
    }

    if (node.properties.expanded) |expanded| {
        if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
        if (expanded) {
            try attrs_writer.writeAll("expanded=true");
        } else {
            try attrs_writer.writeAll("expanded=false");
        }
    }

    if (node.properties.selected) |selected| {
        if (selected) {
            if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
            try attrs_writer.writeAll("selected");
        }
    }

    if (node.properties.disabled) |disabled| {
        if (disabled) {
            if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
            try attrs_writer.writeAll("disabled");
        }
    }

    if (node.properties.required) |required| {
        if (required) {
            if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
            try attrs_writer.writeAll("required");
        }
    }

    if (link_urls) |urls| url_attr: {
        const bid = node.backend_node_id orelse break :url_attr;
        const href = urls.get(bid) orelse break :url_attr;
        if (href.len == 0) break :url_attr;
        if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
        try attrs_writer.writeAll("url=");
        try attrs_writer.writeAll(href);
    }

    if (node.ref_id) |ref_id| {
        if (attrs_buf.items.len > 0) try attrs_writer.writeAll(", ");
        try attrs_writer.writeAll("ref=");
        try attrs_writer.writeAll(ref_id);
    }

    if (attrs_buf.items.len > 0) {
        try writer.writeAll(" [");
        try writer.writeAll(attrs_buf.items);
        try writer.writeByte(']');
    }

    // Cursor-interactive element hints
    if (node.cursor_info) |ci| {
        try writer.writeByte(' ');
        try writer.writeAll(ci.kind);
        if (ci.hints.len > 0) {
            try writer.writeAll(" [");
            try writer.writeAll(ci.hints);
            try writer.writeByte(']');
        }
    }

    // Value (if different from name)
    if (node.properties.value_text) |val| {
        if (val.len > 0 and !std.mem.eql(u8, val, node.name)) {
            try writer.writeAll(": ");
            try writer.writeAll(val);
        }
    }

    try writer.writeByte('\n');

    // Render children
    for (node.children.items) |child_idx| {
        try renderTree(allocator, nodes, child_idx, indent + 1, writer, interactive_only, owned_names, link_urls);
    }
}

/// Extract ARIA properties from the node's "properties" array.
fn extractProperties(node: std.json.Value) struct {
    level: ?i64,
    checked: ?[]const u8,
    expanded: ?bool,
    selected: ?bool,
    disabled: ?bool,
    required: ?bool,
} {
    var result: @TypeOf(extractProperties(undefined)) = .{
        .level = null,
        .checked = null,
        .expanded = null,
        .selected = null,
        .disabled = null,
        .required = null,
    };

    if (node != .object) return result;
    const props_val = node.object.get("properties") orelse return result;
    if (props_val != .array) return result;

    for (props_val.array.items) |prop| {
        if (prop != .object) continue;
        const prop_name = cdp.getString(prop, "name") orelse continue;
        const value_obj = prop.object.get("value") orelse continue;
        if (value_obj != .object) continue;

        if (std.mem.eql(u8, prop_name, "level")) {
            result.level = cdp.getInt(value_obj, "value");
        } else if (std.mem.eql(u8, prop_name, "checked")) {
            // Can be string ("true","false","mixed") or bool
            if (cdp.getString(value_obj, "value")) |s| {
                result.checked = s;
            } else if (cdp.getBool(value_obj, "value")) |b| {
                result.checked = if (b) "true" else "false";
            }
        } else if (std.mem.eql(u8, prop_name, "expanded")) {
            result.expanded = cdp.getBool(value_obj, "value");
        } else if (std.mem.eql(u8, prop_name, "selected")) {
            result.selected = cdp.getBool(value_obj, "value");
        } else if (std.mem.eql(u8, prop_name, "disabled")) {
            result.disabled = cdp.getBool(value_obj, "value");
        } else if (std.mem.eql(u8, prop_name, "required")) {
            result.required = cdp.getBool(value_obj, "value");
        }
    }

    return result;
}

/// Extract value from an AXValue object: {"type":"...","value":"the actual value"}
fn extractAxValue(node: std.json.Value, field: []const u8) ?[]const u8 {
    if (node != .object) return null;
    const ax_val = node.object.get(field) orelse return null;
    if (ax_val != .object) return null;
    return cdp.getString(ax_val, "value");
}

/// Extract AX value that might be numeric (e.g. spinbutton value: 0)
fn extractAxValueNumeric(node: std.json.Value, field: []const u8, buf: []u8) ?[]const u8 {
    if (node != .object) return null;
    const ax_val = node.object.get(field) orelse return null;
    if (ax_val != .object) return null;
    // Try string first
    if (cdp.getString(ax_val, "value")) |s| return s;
    // Try integer
    if (cdp.getInt(ax_val, "value")) |n| {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch null;
    }
    // Try float
    if (cdp.getFloat(ax_val, "value")) |f| {
        // Check if it's a whole number to avoid ".0" suffix
        const int_val: i64 = @intFromFloat(f);
        if (@as(f64, @floatFromInt(int_val)) == f) {
            return std.fmt.bufPrint(buf, "{d}", .{int_val}) catch null;
        }
        return std.fmt.bufPrint(buf, "{d:.1}", .{f}) catch null;
    }
    return null;
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
    try testing.expect(isInteractiveRole("Iframe"));
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

    const snapshot = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snapshot);

    // New format: - role "name" [ref=eN]
    try testing.expect(std.mem.indexOf(u8, snapshot, "- button \"Submit\" [ref=e1]") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "- heading \"Welcome\" [ref=e2]") != null);
    try testing.expectEqual(@as(usize, 2), ref_map.count());
}

test "buildSnapshot: link_urls renders url= attr for matching backend id" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"Home"},"backendDOMNodeId":7}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    var urls = std.AutoHashMap(i64, []const u8).init(testing.allocator);
    defer urls.deinit();
    try urls.put(7, "https://example.com/home");

    const snapshot = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, &urls);
    defer testing.allocator.free(snapshot);

    try testing.expect(std.mem.indexOf(u8, snapshot, "url=https://example.com/home") != null);
    // url= must precede ref= within the bracket group
    const u = std.mem.indexOf(u8, snapshot, "url=").?;
    const r = std.mem.indexOf(u8, snapshot, "ref=").?;
    try testing.expect(u < r);
}

test "buildSnapshot: link_urls null leaves no url= attr" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"Home"},"backendDOMNodeId":7}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snapshot = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snapshot);

    try testing.expect(std.mem.indexOf(u8, snapshot, "url=") == null);
}

test "buildSnapshot: interactive only" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Click"}},{"nodeId":"2","ignored":false,"role":{"type":"role","value":"heading"},"name":{"type":"computedString","value":"Title"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snapshot = try buildSnapshot(testing.allocator, parsed.value, &ref_map, true, null, null);
    defer testing.allocator.free(snapshot);

    // Button gets ref, heading gets ref (content with name)
    try testing.expect(std.mem.indexOf(u8, snapshot, "- button \"Click\" [ref=e1]") != null);
    // Heading has name so it gets ref too
    try testing.expect(std.mem.indexOf(u8, snapshot, "- heading \"Title\" [ref=e2]") != null);
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
    // RootWebArea is skipped in rendering, so child button renders at depth 0
    const json =
        \\{"nodes":[{"nodeId":"root","ignored":false,"role":{"type":"role","value":"RootWebArea"},"name":{"type":"computedString","value":"Page"},"childIds":["child"]},{"nodeId":"child","parentId":"root","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Click"},"backendDOMNodeId":1}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, true, null, null);
    defer testing.allocator.free(snap);

    // RootWebArea is skipped, so button is at depth 0
    try testing.expect(std.mem.indexOf(u8, snap, "- button \"Click\" [ref=e1]") != null);
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

// ============================================================================
// New tests for agent-browser parity
// ============================================================================

test "buildSnapshot: InlineTextBox filtered" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"heading"},"name":{"type":"computedString","value":"Title"}},{"nodeId":"2","parentId":"1","ignored":false,"role":{"type":"role","value":"InlineTextBox"},"name":{"type":"computedString","value":"Title"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    // InlineTextBox should not appear
    try testing.expect(std.mem.indexOf(u8, snap, "InlineTextBox") == null);
    try testing.expect(std.mem.indexOf(u8, snap, "heading") != null);
}

test "buildSnapshot: StaticText deduplication" {
    // Single StaticText child with same name as parent should be removed
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"link"},"name":{"type":"computedString","value":"Home"},"backendDOMNodeId":10,"childIds":["2"]},{"nodeId":"2","parentId":"1","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"Home"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    // StaticText "Home" should be deduplicated (not rendered)
    try testing.expect(std.mem.indexOf(u8, snap, "StaticText") == null);
    try testing.expect(std.mem.indexOf(u8, snap, "- link \"Home\" [ref=e1]") != null);
}

test "buildSnapshot: RootWebArea skipped" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"RootWebArea"},"name":{"type":"computedString","value":"Page"},"childIds":["2"]},{"nodeId":"2","parentId":"1","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"OK"},"backendDOMNodeId":5}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    // RootWebArea should not appear in output
    try testing.expect(std.mem.indexOf(u8, snap, "RootWebArea") == null);
    try testing.expect(std.mem.indexOf(u8, snap, "- button \"OK\" [ref=e1]") != null);
}

test "buildSnapshot: ARIA properties rendered" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"heading"},"name":{"type":"computedString","value":"Title"},"properties":[{"name":"level","value":{"type":"integer","value":2}}]}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "level=2, ref=e1") != null);
}

test "buildSnapshot: checkbox checked property" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"checkbox"},"name":{"type":"computedString","value":"Agree"},"backendDOMNodeId":10,"properties":[{"name":"checked","value":{"type":"tristate","value":"true"}}]}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "checked=true") != null);
}

test "buildSnapshot: value displayed when different from name" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"slider"},"name":{"type":"computedString","value":"Volume"},"backendDOMNodeId":10,"value":{"type":"number","value":"75"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, ": 75") != null);
}

test "buildSnapshot: interactive only returns sentinel when empty" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"generic"},"name":{"type":"computedString","value":""}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, true, null, null);
    defer testing.allocator.free(snap);

    try testing.expectEqualStrings("(no interactive elements)", snap);
}

test "buildSnapshot: Iframe gets ref" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"Iframe"},"name":{"type":"computedString","value":"ad"},"backendDOMNodeId":20}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "[ref=e1]") != null);
    try testing.expectEqual(@as(usize, 1), ref_map.count());
}

test "stripInvisibleChars: removes zero-width spaces" {
    const input = "hello\xE2\x80\x8Bworld"; // hello + U+200B + world
    const result = try stripInvisibleChars(testing.allocator, input);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("helloworld", result);
}

test "stripInvisibleChars: preserves normal text" {
    const input = "normal text";
    const result = try stripInvisibleChars(testing.allocator, input);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("normal text", result);
}

test "buildSnapshot: StaticText consecutive aggregation" {
    // Two consecutive StaticText children should be merged
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"paragraph"},"name":{"type":"computedString","value":""},"childIds":["2","3"]},{"nodeId":"2","parentId":"1","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"Hello "}},{"nodeId":"3","parentId":"1","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"World"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    // Should show aggregated "Hello World" in a single StaticText
    try testing.expect(std.mem.indexOf(u8, snap, "Hello World") != null);
    // Should not have two separate StaticText lines
    const first = std.mem.indexOf(u8, snap, "StaticText") orelse 0;
    const second = std.mem.indexOf(u8, snap[first + 1 ..], "StaticText");
    try testing.expect(second == null);
}

test "extractProperties: level extraction" {
    const json =
        \\{"properties":[{"name":"level","value":{"type":"integer","value":3}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const props = extractProperties(parsed.value);
    try testing.expectEqual(@as(i64, 3), props.level.?);
}

test "extractProperties: multiple properties" {
    const json =
        \\{"properties":[{"name":"disabled","value":{"type":"boolean","value":true}},{"name":"required","value":{"type":"boolean","value":true}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const props = extractProperties(parsed.value);
    try testing.expect(props.disabled.? == true);
    try testing.expect(props.required.? == true);
}

// ============================================================================
// Cursor-interactive element tests
// ============================================================================

test "buildSnapshot: cursor-interactive element gets ref" {
    // A generic div (normally no ref) should get a ref if in cursor_elements map
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"generic"},"name":{"type":"computedString","value":"Menu"},"backendDOMNodeId":99,"childIds":["2"]},{"nodeId":"2","parentId":"1","ignored":false,"role":{"type":"role","value":"StaticText"},"name":{"type":"computedString","value":"Click me"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var cursor_map = CursorElementMap.init(testing.allocator);
    defer cursor_map.deinit();
    try cursor_map.put(99, .{
        .kind = "clickable",
        .hints = "cursor:pointer, onclick",
        .text = "Click me",
    });

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, &cursor_map, null);
    defer testing.allocator.free(snap);

    // generic "Menu" should now have a ref and cursor info
    try testing.expect(std.mem.indexOf(u8, snap, "generic \"Menu\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "ref=e1") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "clickable") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "cursor:pointer, onclick") != null);
    try testing.expectEqual(@as(usize, 1), ref_map.count());
}

test "buildSnapshot: cursor editable element" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"generic"},"name":{"type":"computedString","value":"Editor"},"backendDOMNodeId":50}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var cursor_map = CursorElementMap.init(testing.allocator);
    defer cursor_map.deinit();
    try cursor_map.put(50, .{
        .kind = "editable",
        .hints = "contenteditable",
        .text = "Edit here",
    });

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, &cursor_map, null);
    defer testing.allocator.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "editable") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "contenteditable") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "ref=e1") != null);
}

test "buildSnapshot: cursor focusable element" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"generic"},"name":{"type":"computedString","value":"Nav"},"backendDOMNodeId":77}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var cursor_map = CursorElementMap.init(testing.allocator);
    defer cursor_map.deinit();
    try cursor_map.put(77, .{
        .kind = "focusable",
        .hints = "tabindex",
        .text = "",
    });

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, &cursor_map, null);
    defer testing.allocator.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "focusable") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "tabindex") != null);
}

test "buildSnapshot: cursor element without backendNodeId ignored" {
    // Node without backendDOMNodeId should not match cursor_elements
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"generic"},"name":{"type":"computedString","value":"NoId"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var cursor_map = CursorElementMap.init(testing.allocator);
    defer cursor_map.deinit();
    try cursor_map.put(999, .{
        .kind = "clickable",
        .hints = "onclick",
        .text = "",
    });

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, &cursor_map, null);
    defer testing.allocator.free(snap);

    // No ref should be assigned (generic with no cursor match)
    try testing.expectEqual(@as(usize, 0), ref_map.count());
}

test "buildSnapshot: cursor element in interactive-only mode" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"generic"},"name":{"type":"computedString","value":"Div"},"backendDOMNodeId":33,"childIds":["2"]},{"nodeId":"2","parentId":"1","ignored":false,"role":{"type":"role","value":"heading"},"name":{"type":"computedString","value":"Title"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var cursor_map = CursorElementMap.init(testing.allocator);
    defer cursor_map.deinit();
    try cursor_map.put(33, .{
        .kind = "clickable",
        .hints = "cursor:pointer",
        .text = "",
    });

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, true, &cursor_map, null);
    defer testing.allocator.free(snap);

    // Both cursor-interactive generic and content heading should appear
    try testing.expect(std.mem.indexOf(u8, snap, "generic \"Div\"") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "clickable") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "heading \"Title\"") != null);
}

test "buildSnapshot: null cursor_elements works (backward compat)" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"OK"},"backendDOMNodeId":1}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, null, null);
    defer testing.allocator.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "- button \"OK\" [ref=e1]") != null);
}

test "buildSnapshot: cursor element empty hints" {
    const json =
        \\{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"generic"},"name":{"type":"computedString","value":"Box"},"backendDOMNodeId":88}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var cursor_map = CursorElementMap.init(testing.allocator);
    defer cursor_map.deinit();
    try cursor_map.put(88, .{
        .kind = "clickable",
        .hints = "",
        .text = "",
    });

    var ref_map = RefMap.init(testing.allocator);
    defer ref_map.deinit();

    const snap = try buildSnapshot(testing.allocator, parsed.value, &ref_map, false, &cursor_map, null);
    defer testing.allocator.free(snap);

    // Should show "clickable" but no hints brackets
    try testing.expect(std.mem.indexOf(u8, snap, "clickable") != null);
    // Should not have empty brackets after clickable
    try testing.expect(std.mem.indexOf(u8, snap, "clickable []") == null);
}
