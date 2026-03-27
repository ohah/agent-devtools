const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");
const posix = std.posix;

// Reference: agent-browser/cli/src/connection.rs
//            agent-browser/cli/src/native/daemon.rs

// ============================================================================
// Socket Directory
// ============================================================================

/// Get the base directory for socket/pid files.
/// Priority: AGENT_DEVTOOLS_SOCKET_DIR > XDG_RUNTIME_DIR > ~/.agent-devtools > /tmp
pub fn getSocketDir() []const u8 {
    if (std.posix.getenv("AGENT_DEVTOOLS_SOCKET_DIR")) |dir| {
        if (dir.len > 0) return dir;
    }
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) return dir;
    }
    if (std.posix.getenv("HOME")) |home| {
        _ = home;
        // Can't allocate here to join paths, return a known fallback
    }
    return "/tmp/agent-devtools";
}

/// Build the socket path for a session.
pub fn getSocketPath(buf: []u8, session: []const u8) ![]const u8 {
    const dir = getSocketDir();
    return std.fmt.bufPrint(buf, "{s}/{s}.sock", .{ dir, session });
}

/// Build the PID file path for a session.
pub fn getPidPath(buf: []u8, session: []const u8) ![]const u8 {
    const dir = getSocketDir();
    return std.fmt.bufPrint(buf, "{s}/{s}.pid", .{ dir, session });
}

// ============================================================================
// Daemon Protocol: JSON-line over Unix Socket
// ============================================================================

pub const Request = struct {
    id: []const u8,
    action: []const u8,
    url: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

pub const Response = struct {
    success: bool,
    data: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Serialize a request to JSON-line format.
pub fn serializeRequest(allocator: Allocator, req: Request) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"id\":\"");
    try writer.writeAll(req.id);
    try writer.writeAll("\",\"action\":\"");
    try writer.writeAll(req.action);
    try writer.writeByte('"');

    if (req.url) |url| {
        try writer.writeAll(",\"url\":\"");
        try writer.writeAll(url);
        try writer.writeByte('"');
    }
    if (req.pattern) |pattern| {
        try writer.writeAll(",\"pattern\":\"");
        try writer.writeAll(pattern);
        try writer.writeByte('"');
    }

    try writer.writeAll("}\n");
    return buf.toOwnedSlice(allocator);
}

/// Serialize a response to JSON-line format.
pub fn serializeResponse(allocator: Allocator, resp: Response) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"success\":");
    try writer.writeAll(if (resp.success) "true" else "false");

    if (resp.data) |data| {
        try writer.writeAll(",\"data\":");
        try writer.writeAll(data);
    }
    if (resp.@"error") |err| {
        try writer.writeAll(",\"error\":\"");
        try writer.writeAll(err);
        try writer.writeByte('"');
    }

    try writer.writeAll("}\n");
    return buf.toOwnedSlice(allocator);
}

/// Parse a request from a JSON-line.
pub fn parseRequest(allocator: Allocator, line: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCharacter;

    const obj = parsed.value.object;
    const id = if (obj.get("id")) |v| switch (v) {
        .string => |s| s,
        else => "0",
    } else "0";
    const action = if (obj.get("action")) |v| switch (v) {
        .string => |s| s,
        else => return error.InvalidCharacter,
    } else return error.InvalidCharacter;

    const url = if (obj.get("url")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    const pattern = if (obj.get("pattern")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    // Dupe strings since parsed will be freed
    return .{
        .id = try allocator.dupe(u8, id),
        .action = try allocator.dupe(u8, action),
        .url = if (url) |u| try allocator.dupe(u8, u) else null,
        .pattern = if (pattern) |p| try allocator.dupe(u8, p) else null,
    };
}

/// Free a request's owned strings.
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

    const obj = parsed.value.object;
    const success = if (obj.get("success")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;

    // For data, find the raw JSON substring from the input
    // This avoids re-serialization issues with Zig 0.15's JSON API
    const data_str: ?[]u8 = if (obj.get("data")) |_| blk: {
        // Find "data": in the line and extract the value
        const data_key = "\"data\":";
        const start = std.mem.indexOf(u8, line, data_key) orelse break :blk null;
        const val_start = start + data_key.len;
        // Find the end — either the last } before \n, or end of line
        // Simple approach: everything from val_start to the closing }
        var depth: i32 = 0;
        var i: usize = val_start;
        var found_end: usize = line.len;
        while (i < line.len) : (i += 1) {
            switch (line[i]) {
                '{', '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    if (depth < 0) {
                        found_end = i;
                        break;
                    }
                },
                ',' => if (depth == 0) {
                    found_end = i;
                    break;
                },
                else => {},
            }
        }
        if (found_end > val_start) {
            const raw = std.mem.trim(u8, line[val_start..found_end], &std.ascii.whitespace);
            break :blk try allocator.dupe(u8, raw);
        }
        break :blk null;
    } else null;

    const err_str = if (obj.get("error")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    return .{
        .success = success,
        .data = data_str,
        .@"error" = err_str,
    };
}

pub fn freeResponse(allocator: Allocator, resp: Response) void {
    if (resp.data) |d| allocator.free(d);
    if (resp.@"error") |e| allocator.free(e);
}

// ============================================================================
// Daemon Socket Server (Unix Domain Socket)
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
        const dir = getSocketDir();
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Remove stale socket
        std.fs.deleteFileAbsolute(socket_path) catch {};

        // Create and bind Unix socket
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
        const result = posix.accept(self.fd, null, null, .{});
        return result;
    }

    pub fn close(self: *SocketServer) void {
        posix.close(self.fd);
        // Clean up socket file
        const path = self.socket_path[0..self.socket_path_len];
        std.fs.deleteFileAbsolute(path) catch {};
    }
};

// ============================================================================
// Client Connection (CLI → Daemon)
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

            // Check for newline
            if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |nl| {
                return buf[0..nl];
            }
        }
        return buf[0..total];
    }

    pub fn close(self: *SocketClient) void {
        posix.close(self.fd);
    }

    /// Check if daemon is reachable.
    pub fn isReady(session: []const u8) bool {
        var client = SocketClient.connect(session) catch return false;
        client.close();
        return true;
    }
};

// ============================================================================
// Daemon Lifecycle: ensure_daemon
// ============================================================================

/// Ensure a daemon is running for the given session.
/// If not running, spawns the current executable as a daemon process.
/// Returns true if a new daemon was started, false if already running.
pub fn ensureDaemon(allocator: Allocator, session: []const u8) !bool {
    if (SocketClient.isReady(session)) return false;

    // Clean up stale files
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    var pid_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock_path = getSocketPath(&sock_buf, session) catch return error.InvalidArgument;
    const pid_path = getPidPath(&pid_buf, session) catch return error.InvalidArgument;
    std.fs.deleteFileAbsolute(sock_path) catch {};
    std.fs.deleteFileAbsolute(pid_path) catch {};

    // Spawn self as daemon
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const argv = [_][]const u8{exe_path};
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    // Set daemon environment
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

    return error.TimedOut;
}

// ============================================================================
// Tests
// ============================================================================

test "getSocketDir: returns a path" {
    const dir = getSocketDir();
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

test "serializeRequest: basic request" {
    const req = Request{ .id = "1", .action = "network_list" };
    const json = try serializeRequest(testing.allocator, req);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\":\"network_list\"") != null);
    try testing.expect(std.mem.endsWith(u8, json, "\n"));
}

test "serializeRequest: with url" {
    const req = Request{ .id = "2", .action = "open", .url = "https://example.com" };
    const json = try serializeRequest(testing.allocator, req);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"url\":\"https://example.com\"") != null);
}

test "serializeResponse: success" {
    const resp = Response{ .success = true, .data = "[1,2,3]" };
    const json = try serializeResponse(testing.allocator, resp);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"success\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"data\":[1,2,3]") != null);
}

test "serializeResponse: error" {
    const resp = Response{ .success = false, .@"error" = "Chrome not found" };
    const json = try serializeResponse(testing.allocator, resp);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"success\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error\":\"Chrome not found\"") != null);
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

test "parseResponse: success with data" {
    const json = "{\"success\":true,\"data\":{\"count\":5}}\n";
    const resp = try parseResponse(testing.allocator, json);
    defer freeResponse(testing.allocator, resp);

    try testing.expect(resp.success);
    try testing.expect(resp.data != null);
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

test "SocketClient.isReady: returns false for non-existent session" {
    try testing.expect(!SocketClient.isReady("nonexistent-test-session-xyz"));
}
