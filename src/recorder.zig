const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const cdp = @import("cdp.zig");
const network_mod = @import("network.zig");

// ============================================================================
// Flow Recorder
// Records network state to JSON files for later comparison.
// Enables regression detection without LLM — pure mechanical diffing.
// ============================================================================

pub const RequestSnapshot = struct {
    request_id: []const u8,
    url: []const u8,
    method: []const u8,
    status: ?i64,
    mime_type: []const u8,
    state: []const u8,
};

pub const Recording = struct {
    name: []const u8,
    timestamp: i64,
    requests: []RequestSnapshot,
    console_count: usize,
};

pub const DiffEntry = struct {
    change_type: ChangeType,
    url: []const u8,
    method: []const u8,
    detail: []const u8,
};

pub const ChangeType = enum {
    added, // Request in current but not in baseline
    removed, // Request in baseline but not in current
    changed, // Same URL+method but different status/state
};

pub const DiffResult = struct {
    added: usize,
    removed: usize,
    changed: usize,
    unchanged: usize,
    entries: []DiffEntry,
    allocator: Allocator,

    pub fn deinit(self: *DiffResult) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.method);
            self.allocator.free(entry.detail);
        }
        self.allocator.free(self.entries);
    }

    pub fn totalChanges(self: *const DiffResult) usize {
        return self.added + self.removed + self.changed;
    }
};

/// Save current network state to a JSON string.
pub fn saveRecording(allocator: Allocator, name: []const u8, collector: *const network_mod.Collector, console_count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"name\":");
    try cdp.writeJsonString(writer, name);
    try std.fmt.format(writer, ",\"timestamp\":{d}", .{std.time.timestamp()});
    try std.fmt.format(writer, ",\"consoleCount\":{d}", .{console_count});
    try writer.writeAll(",\"requests\":[");

    var it = collector.requests.iterator();
    var first = true;
    while (it.next()) |entry| {
        const info = entry.value_ptr.info;
        if (!first) try writer.writeByte(',');
        first = false;

        try writer.writeAll("{\"requestId\":");
        try cdp.writeJsonString(writer, info.request_id);
        try writer.writeAll(",\"url\":");
        try cdp.writeJsonString(writer, info.url);
        try writer.writeAll(",\"method\":");
        try cdp.writeJsonString(writer, info.method);
        try writer.writeAll(",\"status\":");
        if (info.status) |s| {
            try std.fmt.format(writer, "{d}", .{s});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"mimeType\":");
        try cdp.writeJsonString(writer, info.mime_type);
        try writer.writeAll(",\"state\":");
        try cdp.writeJsonString(writer, @tagName(info.state));
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

/// Load a recording from JSON string.
pub fn loadRecording(allocator: Allocator, json: []const u8) !Recording {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCharacter;

    const name = cdp.getString(parsed.value, "name") orelse "unknown";
    const timestamp = cdp.getInt(parsed.value, "timestamp") orelse 0;
    const console_count: usize = @intCast(cdp.getInt(parsed.value, "consoleCount") orelse 0);

    var requests: std.ArrayList(RequestSnapshot) = .empty;
    errdefer {
        for (requests.items) |r| {
            allocator.free(r.request_id);
            allocator.free(r.url);
            allocator.free(r.method);
            allocator.free(r.mime_type);
            allocator.free(r.state);
        }
        requests.deinit(allocator);
    }

    if (parsed.value.object.get("requests")) |reqs_val| {
        if (reqs_val == .array) {
            for (reqs_val.array.items) |item| {
                const rid = cdp.getString(item, "requestId") orelse continue;
                const url = cdp.getString(item, "url") orelse continue;
                const method = cdp.getString(item, "method") orelse continue;
                const mime = cdp.getString(item, "mimeType") orelse "";
                const state = cdp.getString(item, "state") orelse "unknown";
                const status = cdp.getInt(item, "status");

                try requests.append(allocator, .{
                    .request_id = try allocator.dupe(u8, rid),
                    .url = try allocator.dupe(u8, url),
                    .method = try allocator.dupe(u8, method),
                    .status = status,
                    .mime_type = try allocator.dupe(u8, mime),
                    .state = try allocator.dupe(u8, state),
                });
            }
        }
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .timestamp = timestamp,
        .requests = try requests.toOwnedSlice(allocator),
        .console_count = console_count,
    };
}

pub fn freeRecording(allocator: Allocator, rec: *Recording) void {
    for (rec.requests) |r| {
        allocator.free(r.request_id);
        allocator.free(r.url);
        allocator.free(r.method);
        allocator.free(r.mime_type);
        allocator.free(r.state);
    }
    allocator.free(rec.requests);
    allocator.free(rec.name);
}

/// Compare two sets of requests and produce a diff.
pub fn diffRequests(
    allocator: Allocator,
    baseline: []const RequestSnapshot,
    current_collector: *const network_mod.Collector,
) !DiffResult {
    var entries: std.ArrayList(DiffEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.url);
            allocator.free(e.method);
            allocator.free(e.detail);
        }
        entries.deinit(allocator);
    }

    var added: usize = 0;
    var removed: usize = 0;
    var changed: usize = 0;
    var unchanged: usize = 0;

    // Build a map of current requests by "METHOD URL" key
    var current_map = std.StringArrayHashMap(network_mod.RequestInfo).init(allocator);
    defer current_map.deinit();

    var cur_it = current_collector.requests.iterator();
    while (cur_it.next()) |entry| {
        const info = entry.value_ptr.info;
        var key_buf: [1024]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ info.method, info.url }) catch continue;
        const owned_key = allocator.dupe(u8, key) catch continue;
        current_map.put(owned_key, info) catch allocator.free(owned_key);
    }
    defer {
        var km = current_map.iterator();
        while (km.next()) |e| allocator.free(e.key_ptr.*);
    }

    // Check baseline against current
    for (baseline) |base_req| {
        var key_buf: [1024]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ base_req.method, base_req.url }) catch continue;

        if (current_map.get(key)) |cur_info| {
            // Exists in both — check for changes
            if (base_req.status != cur_info.status) {
                var detail_buf: [128]u8 = undefined;
                const detail = std.fmt.bufPrint(&detail_buf, "status: {?d} -> {?d}", .{ base_req.status, cur_info.status }) catch "status changed";
                try entries.append(allocator, .{
                    .change_type = .changed,
                    .url = try allocator.dupe(u8, base_req.url),
                    .method = try allocator.dupe(u8, base_req.method),
                    .detail = try allocator.dupe(u8, detail),
                });
                changed += 1;
            } else {
                unchanged += 1;
            }
        } else {
            try entries.append(allocator, .{
                .change_type = .removed,
                .url = try allocator.dupe(u8, base_req.url),
                .method = try allocator.dupe(u8, base_req.method),
                .detail = try allocator.dupe(u8, "not in current"),
            });
            removed += 1;
        }
    }

    // Check current against baseline for new requests
    var cur_check = current_collector.requests.iterator();
    while (cur_check.next()) |entry| {
        const info = entry.value_ptr.info;
        var found = false;
        for (baseline) |base_req| {
            if (std.mem.eql(u8, base_req.method, info.method) and std.mem.eql(u8, base_req.url, info.url)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try entries.append(allocator, .{
                .change_type = .added,
                .url = try allocator.dupe(u8, info.url),
                .method = try allocator.dupe(u8, info.method),
                .detail = try allocator.dupe(u8, "new request"),
            });
            added += 1;
        }
    }

    return .{
        .added = added,
        .removed = removed,
        .changed = changed,
        .unchanged = unchanged,
        .entries = try entries.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Serialize a diff result to JSON.
pub fn serializeDiff(allocator: Allocator, diff: *const DiffResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try std.fmt.format(writer, "{{\"added\":{d},\"removed\":{d},\"changed\":{d},\"unchanged\":{d}", .{
        diff.added, diff.removed, diff.changed, diff.unchanged,
    });
    try writer.writeAll(",\"entries\":[");

    for (diff.entries, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"type\":");
        try cdp.writeJsonString(writer, @tagName(entry.change_type));
        try writer.writeAll(",\"method\":");
        try cdp.writeJsonString(writer, entry.method);
        try writer.writeAll(",\"url\":");
        try cdp.writeJsonString(writer, entry.url);
        try writer.writeAll(",\"detail\":");
        try cdp.writeJsonString(writer, entry.detail);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "saveRecording: produces valid JSON" {
    var collector = network_mod.Collector.init(testing.allocator);
    defer collector.deinit();

    const json = try saveRecording(testing.allocator, "test-flow", &collector, 0);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expectEqualStrings("test-flow", cdp.getString(parsed.value, "name").?);
}

test "loadRecording: roundtrip" {
    const json =
        \\{"name":"login-flow","timestamp":1700000000,"consoleCount":3,"requests":[{"requestId":"1","url":"https://api.test.com/login","method":"POST","status":200,"mimeType":"application/json","state":"finished"}]}
    ;
    var rec = try loadRecording(testing.allocator, json);
    defer freeRecording(testing.allocator, &rec);

    try testing.expectEqualStrings("login-flow", rec.name);
    try testing.expectEqual(@as(usize, 1), rec.requests.len);
    try testing.expectEqualStrings("POST", rec.requests[0].method);
    try testing.expectEqualStrings("https://api.test.com/login", rec.requests[0].url);
    try testing.expectEqual(@as(i64, 200), rec.requests[0].status.?);
}

test "loadRecording: invalid JSON" {
    try testing.expectError(error.SyntaxError, loadRecording(testing.allocator, "not json"));
}

test "diffRequests: no changes" {
    var collector = network_mod.Collector.init(testing.allocator);
    defer collector.deinit();

    // Add a request to collector
    const req_json =
        \\{"requestId":"1","request":{"url":"https://api.test.com/data","method":"GET","headers":{}},"type":"XHR","timestamp":1.0,"loaderId":"L","documentURL":"","initiator":{"type":"other"},"wallTime":0,"redirectHasExtraInfo":false}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, req_json, .{});
    defer parsed.deinit();
    _ = try collector.processEvent("Network.requestWillBeSent", parsed.value);

    // Create baseline matching the collector
    const baseline = [_]RequestSnapshot{.{
        .request_id = "1",
        .url = "https://api.test.com/data",
        .method = "GET",
        .status = null,
        .mime_type = "",
        .state = "pending",
    }};

    var diff = try diffRequests(testing.allocator, &baseline, &collector);
    defer diff.deinit();

    try testing.expectEqual(@as(usize, 0), diff.totalChanges());
    try testing.expectEqual(@as(usize, 1), diff.unchanged);
}

test "diffRequests: added request" {
    var collector = network_mod.Collector.init(testing.allocator);
    defer collector.deinit();

    const req_json =
        \\{"requestId":"1","request":{"url":"https://api.test.com/new","method":"GET","headers":{}},"type":"XHR","timestamp":1.0,"loaderId":"L","documentURL":"","initiator":{"type":"other"},"wallTime":0,"redirectHasExtraInfo":false}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, req_json, .{});
    defer parsed.deinit();
    _ = try collector.processEvent("Network.requestWillBeSent", parsed.value);

    // Empty baseline
    var diff = try diffRequests(testing.allocator, &.{}, &collector);
    defer diff.deinit();

    try testing.expectEqual(@as(usize, 1), diff.added);
    try testing.expectEqual(@as(usize, 0), diff.removed);
}

test "diffRequests: removed request" {
    var collector = network_mod.Collector.init(testing.allocator);
    defer collector.deinit();

    const baseline = [_]RequestSnapshot{.{
        .request_id = "1",
        .url = "https://api.test.com/old",
        .method = "GET",
        .status = 200,
        .mime_type = "",
        .state = "finished",
    }};

    var diff = try diffRequests(testing.allocator, &baseline, &collector);
    defer diff.deinit();

    try testing.expectEqual(@as(usize, 0), diff.added);
    try testing.expectEqual(@as(usize, 1), diff.removed);
}

test "serializeDiff: produces valid JSON" {
    var diff = DiffResult{
        .added = 1,
        .removed = 0,
        .changed = 0,
        .unchanged = 2,
        .entries = &.{},
        .allocator = testing.allocator,
    };

    const json = try serializeDiff(testing.allocator, &diff);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expectEqual(@as(i64, 1), cdp.getInt(parsed.value, "added").?);
}
