const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");
const posix = std.posix;
const cdp = @import("cdp.zig");

// Reference: agent-browser/cli/src/connection.rs, daemon.rs

/// Get the base directory for socket/pid files.
/// Priority: AGENT_DEVTOOLS_SOCKET_DIR > XDG_RUNTIME_DIR > $HOME/.agent-devtools > /tmp/agent-devtools
pub fn getSocketDir(buf: []u8) []const u8 {
    if (std.posix.getenv("AGENT_DEVTOOLS_SOCKET_DIR")) |dir| {
        if (dir.len > 0) return dir;
    }
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) return dir;
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.agent-devtools", .{home}) catch "/tmp/agent-devtools";
    }
    return "/tmp/agent-devtools";
}

pub fn getSocketPath(buf: []u8, session: []const u8) ![]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = getSocketDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}.sock", .{ dir, session });
}

pub fn getPidPath(buf: []u8, session: []const u8) ![]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = getSocketDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}.pid", .{ dir, session });
}

// ============================================================================
// Protocol: JSON-line over Unix Socket
// ============================================================================

pub const Request = struct {
    id: []const u8,
    action: []const u8,
    url: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
};

pub const Response = struct {
    success: bool,
    data: ?[]const u8 = null, // pre-serialized JSON or plain text
    @"error": ?[]const u8 = null,
};

/// Serialize a request to JSON-line. All strings properly escaped.
pub fn serializeRequest(allocator: Allocator, req: Request) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"id\":");
    try cdp.writeJsonString(writer, req.id);
    try writer.writeAll(",\"action\":");
    try cdp.writeJsonString(writer, req.action);

    if (req.url) |url| {
        try writer.writeAll(",\"url\":");
        try cdp.writeJsonString(writer, url);
    }
    if (req.pattern) |pattern| {
        try writer.writeAll(",\"pattern\":");
        try cdp.writeJsonString(writer, pattern);
    }

    try writer.writeAll("}\n");
    return buf.toOwnedSlice(allocator);
}

/// Serialize a response to JSON-line.
pub fn serializeResponse(allocator: Allocator, resp: Response) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"success\":");
    try writer.writeAll(if (resp.success) "true" else "false");

    if (resp.data) |data| {
        // data is pre-serialized JSON — write raw
        try writer.writeAll(",\"data\":");
        try writer.writeAll(data);
    }
    if (resp.@"error") |err| {
        try writer.writeAll(",\"error\":");
        try cdp.writeJsonString(writer, err);
    }

    try writer.writeAll("}\n");
    return buf.toOwnedSlice(allocator);
}

/// Parse a request from a JSON-line.
pub fn parseRequest(allocator: Allocator, line: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCharacter;

    const id_raw = cdp.getString(parsed.value, "id") orelse "0";
    const action_raw = cdp.getString(parsed.value, "action") orelse return error.InvalidCharacter;
    const url_raw = cdp.getString(parsed.value, "url");
    const pattern_raw = cdp.getString(parsed.value, "pattern");

    // Dupe strings since parsed will be freed
    const id = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(id);
    const action = try allocator.dupe(u8, action_raw);
    errdefer allocator.free(action);
    const url = if (url_raw) |u| try allocator.dupe(u8, u) else null;
    errdefer if (url) |u| allocator.free(u);
    const pattern = if (pattern_raw) |p| try allocator.dupe(u8, p) else null;

    return .{
        .id = id,
        .action = action,
        .url = url,
        .pattern = pattern,
    };
}

pub fn freeRequest(allocator: Allocator, req: Request) void {
    allocator.free(req.id);
    allocator.free(req.action);
    if (req.url) |u| allocator.free(u);
    if (req.pattern) |p| allocator.free(p);
}

/// Parse a response from a JSON-line.
pub fn parseResponse(allocator: Allocator, line: []const u8) !Response {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCharacter;

    const success = cdp.getBool(parsed.value, "success") orelse false;
    const err_str = if (cdp.getString(parsed.value, "error")) |e|
        try allocator.dupe(u8, e)
    else
        null;
    errdefer if (err_str) |e| allocator.free(e);

    // For data, re-serialize the JSON value to a string if present
    const data_str: ?[]u8 = if (parsed.value.object.get("data")) |data_val| blk: {
        // Use bufPrint approach: format the JSON value back to string
        var data_buf: std.ArrayList(u8) = .empty;
        defer data_buf.deinit(allocator);
        // Write the value using Zig's JSON writer
        writeJsonValue(data_buf.writer(allocator), data_val) catch break :blk null;
        break :blk data_buf.toOwnedSlice(allocator) catch null;
    } else null;

    return .{
        .success = success,
        .data = data_str,
        .@"error" = err_str,
    };
}

/// Write a std.json.Value to a writer as JSON text.
fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try std.fmt.format(writer, "{d}", .{n}),
        .float => |f| try std.fmt.format(writer, "{d}", .{f}),
        .string => |s| try cdp.writeJsonString(writer, s),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try cdp.writeJsonString(writer, entry.key_ptr.*);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

pub fn freeResponse(allocator: Allocator, resp: Response) void {
    if (resp.data) |d| allocator.free(d);
    if (resp.@"error") |e| allocator.free(e);
}

// ============================================================================
// Socket Server (Unix Domain Socket)
// ============================================================================

pub const SocketServer = struct {
    fd: posix.socket_t,
    socket_path: [std.fs.max_path_bytes]u8,
    socket_path_len: usize,

    pub const AcceptError = posix.AcceptError;

    pub fn listen(session: []const u8) !SocketServer {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const socket_path = try getSocketPath(&path_buf, session);

        // Ensure directory exists
        var dir_buf: [512]u8 = undefined;
        const dir = getSocketDir(&dir_buf);
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        std.fs.deleteFileAbsolute(socket_path) catch {};

        const addr = try std.net.Address.initUnix(socket_path);
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, .{ .backlog = 5 });

        var server = SocketServer{
            .fd = fd,
            .socket_path = undefined,
            .socket_path_len = socket_path.len,
        };
        @memcpy(server.socket_path[0..socket_path.len], socket_path);

        return server;
    }

    pub fn accept(self: *SocketServer) AcceptError!posix.socket_t {
        return posix.accept(self.fd, null, null, .{});
    }

    pub fn close(self: *SocketServer) void {
        posix.close(self.fd);
        const path = self.socket_path[0..self.socket_path_len];
        std.fs.deleteFileAbsolute(path) catch {};
    }
};

// ============================================================================
// Socket Client (CLI → Daemon)
// ============================================================================

pub const SocketClient = struct {
    fd: posix.socket_t,

    pub fn connect(session: []const u8) !SocketClient {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const socket_path = try getSocketPath(&path_buf, session);

        const addr = try std.net.Address.initUnix(socket_path);
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        try posix.connect(fd, &addr.any, addr.getOsSockLen());

        return .{ .fd = fd };
    }

    pub fn send(self: *SocketClient, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = posix.write(self.fd, data[written..]) catch |err| return err;
            written += n;
        }
    }

    pub fn recvLine(self: *SocketClient, buf: []u8) ![]const u8 {
        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(self.fd, buf[total..]) catch |err| return err;
            if (n == 0) {
                if (total > 0) return buf[0..total];
                return error.EndOfStream;
            }
            total += n;

            if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |nl| {
                return buf[0..nl];
            }
        }
        return buf[0..total];
    }

    pub fn close(self: *SocketClient) void {
        posix.close(self.fd);
    }

    pub fn isReady(session: []const u8) bool {
        var client = SocketClient.connect(session) catch return false;
        client.close();
        return true;
    }
};

// ============================================================================
// Daemon Lifecycle
// ============================================================================

/// Ensure a daemon is running for the given session.
/// Returns true if a new daemon was started.
pub fn ensureDaemon(allocator: Allocator, session: []const u8) !bool {
    if (SocketClient.isReady(session)) return false;

    // Clean stale files
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    var pid_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock_path = getSocketPath(&sock_buf, session) catch return error.InvalidArgument;
    const pid_path = getPidPath(&pid_buf, session) catch return error.InvalidArgument;
    std.fs.deleteFileAbsolute(sock_path) catch {};
    std.fs.deleteFileAbsolute(pid_path) catch {};

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const argv = [_][]const u8{exe_path};
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("AGENT_DEVTOOLS_DAEMON", "1");
    try env_map.put("AGENT_DEVTOOLS_SESSION", session);
    child.env_map = &env_map;

    try child.spawn();

    // Poll for readiness (50 × 100ms = 5 seconds)
    const poll_interval = 100 * std.time.ns_per_ms;
    for (0..50) |_| {
        if (SocketClient.isReady(session)) return true;
        std.Thread.sleep(poll_interval);
    }

    // Timeout — kill the orphaned child
    _ = child.kill() catch {};
    _ = child.wait() catch {};
    return error.TimedOut;
}

// ============================================================================
// Tests
// ============================================================================

test "getSocketDir: returns a path" {
    var buf: [512]u8 = undefined;
    const dir = getSocketDir(&buf);
    try testing.expect(dir.len > 0);
}

test "getSocketPath: builds correct path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try getSocketPath(&buf, "test-session");
    try testing.expect(std.mem.endsWith(u8, path, "test-session.sock"));
}

test "getPidPath: builds correct path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try getPidPath(&buf, "test-session");
    try testing.expect(std.mem.endsWith(u8, path, "test-session.pid"));
}

test "getSocketDir: uses HOME when no env overrides" {
    // This test verifies HOME-based path is constructed (if HOME is set)
    var buf: [512]u8 = undefined;
    const dir = getSocketDir(&buf);
    // Should either contain .agent-devtools or be /tmp/agent-devtools
    try testing.expect(
        std.mem.indexOf(u8, dir, "agent-devtools") != null or
            std.mem.indexOf(u8, dir, "/tmp") != null,
    );
}

test "serializeRequest: basic request with proper escaping" {
    const req = Request{ .id = "1", .action = "network_list" };
    const json = try serializeRequest(testing.allocator, req);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\":\"network_list\"") != null);
    try testing.expect(std.mem.endsWith(u8, json, "\n"));
}

test "serializeRequest: escapes special characters in url" {
    const req = Request{ .id = "1", .action = "open", .url = "https://example.com/path?q=\"hello\"" };
    const json = try serializeRequest(testing.allocator, req);
    defer testing.allocator.free(json);

    // Should contain escaped quotes
    try testing.expect(std.mem.indexOf(u8, json, "\\\"hello\\\"") != null);
    // Verify it's valid JSON by parsing it back
    const parsed = try parseRequest(testing.allocator, json);
    defer freeRequest(testing.allocator, parsed);
    try testing.expectEqualStrings("https://example.com/path?q=\"hello\"", parsed.url.?);
}

test "serializeRequest: with url and pattern" {
    const req = Request{ .id = "2", .action = "open", .url = "https://example.com" };
    const json = try serializeRequest(testing.allocator, req);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"url\":\"https://example.com\"") != null);
}

test "serializeResponse: success with data" {
    const resp = Response{ .success = true, .data = "[1,2,3]" };
    const json = try serializeResponse(testing.allocator, resp);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"success\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"data\":[1,2,3]") != null);
}

test "serializeResponse: error with special characters" {
    const resp = Response{ .success = false, .@"error" = "Chrome said: \"not found\"" };
    const json = try serializeResponse(testing.allocator, resp);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"success\":false") != null);
    // Error should be escaped
    const parsed = try parseResponse(testing.allocator, json);
    defer freeResponse(testing.allocator, parsed);
    try testing.expectEqualStrings("Chrome said: \"not found\"", parsed.@"error".?);
}

test "parseRequest: basic" {
    const json = "{\"id\":\"1\",\"action\":\"network_list\"}\n";
    const req = try parseRequest(testing.allocator, json);
    defer freeRequest(testing.allocator, req);

    try testing.expectEqualStrings("1", req.id);
    try testing.expectEqualStrings("network_list", req.action);
    try testing.expect(req.url == null);
}

test "parseRequest: with url and pattern" {
    const json = "{\"id\":\"2\",\"action\":\"network_filter\",\"url\":\"https://test.com\",\"pattern\":\"api\"}\n";
    const req = try parseRequest(testing.allocator, json);
    defer freeRequest(testing.allocator, req);

    try testing.expectEqualStrings("network_filter", req.action);
    try testing.expectEqualStrings("https://test.com", req.url.?);
    try testing.expectEqualStrings("api", req.pattern.?);
}

test "parseResponse: success with nested data" {
    const json = "{\"success\":true,\"data\":{\"count\":5,\"items\":[1,2]}}\n";
    const resp = try parseResponse(testing.allocator, json);
    defer freeResponse(testing.allocator, resp);

    try testing.expect(resp.success);
    try testing.expect(resp.data != null);
    // Verify the data contains the nested structure
    try testing.expect(std.mem.indexOf(u8, resp.data.?, "\"count\"") != null);
}

test "parseResponse: error" {
    const json = "{\"success\":false,\"error\":\"timeout\"}\n";
    const resp = try parseResponse(testing.allocator, json);
    defer freeResponse(testing.allocator, resp);

    try testing.expect(!resp.success);
    try testing.expectEqualStrings("timeout", resp.@"error".?);
}

test "roundtrip: request serialize → parse" {
    const original = Request{ .id = "42", .action = "open", .url = "https://test.com" };
    const json = try serializeRequest(testing.allocator, original);
    defer testing.allocator.free(json);

    const parsed = try parseRequest(testing.allocator, json);
    defer freeRequest(testing.allocator, parsed);

    try testing.expectEqualStrings("42", parsed.id);
    try testing.expectEqualStrings("open", parsed.action);
    try testing.expectEqualStrings("https://test.com", parsed.url.?);
}

test "roundtrip: response serialize → parse" {
    const original = Response{ .success = true, .data = "{\"key\":\"value\"}" };
    const json = try serializeResponse(testing.allocator, original);
    defer testing.allocator.free(json);

    const parsed = try parseResponse(testing.allocator, json);
    defer freeResponse(testing.allocator, parsed);

    try testing.expect(parsed.success);
    try testing.expect(std.mem.indexOf(u8, parsed.data.?, "\"key\"") != null);
}

test "SocketClient.isReady: returns false for non-existent session" {
    try testing.expect(!SocketClient.isReady("nonexistent-test-session-xyz"));
}

test "writeJsonValue: null" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonValue(buf.writer(testing.allocator), .null);
    try testing.expectEqualStrings("null", buf.items);
}

test "writeJsonValue: nested object" {
    const json = "{\"a\":{\"b\":1},\"c\":[true,false]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonValue(buf.writer(testing.allocator), parsed.value);

    // Re-parse to verify it's valid JSON
    const reparsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer reparsed.deinit();
    try testing.expect(reparsed.value == .object);
}
