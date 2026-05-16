const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// ============================================================================
// CDP Message Types
// (Based on Chrome DevTools Protocol spec:
//  https://chromedevtools.github.io/devtools-protocol/)
//
// CDP uses JSON-RPC-like messaging over WebSocket:
//   Command:  { "id": N, "method": "Domain.method", "params": {...}, "sessionId"?: "..." }
//   Response: { "id": N, "result": {...} }
//   Error:    { "id": N, "error": { "code": N, "message": "...", "data"?: "..." } }
//   Event:    { "method": "Domain.event", "params": {...}, "sessionId"?: "..." }
// ============================================================================

/// Standard JSON-RPC error codes used by CDP.
/// Reference: https://www.jsonrpc.org/specification#error_object
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    /// Chrome-specific: server error range -32000 to -32099
    server_error = -32000,
    _,
};

/// Represents a parsed CDP message.
/// A message is exactly one of: response, error_response, or event.
pub const Message = struct {
    /// Present in responses and error responses. Absent in events.
    id: ?u64,
    /// Present in events and commands. Absent in responses.
    method: ?[]const u8,
    /// Present in successful responses.
    result: ?std.json.Value,
    /// Present in error responses.
    @"error": ?CdpError,
    /// Present when targeting a specific session.
    session_id: ?[]const u8,
    /// Present in events.
    params: ?std.json.Value,

    pub fn isResponse(self: Message) bool {
        return self.id != null and self.result != null;
    }

    pub fn isErrorResponse(self: Message) bool {
        return self.id != null and self.@"error" != null;
    }

    pub fn isEvent(self: Message) bool {
        return self.id == null and self.method != null;
    }
};

/// CDP error object.
/// `code` is optional — JSON-RPC spec requires it, but defensive parsing
/// handles cases where Chrome omits it (agent-browser uses Option<i64>).
pub const CdpError = struct {
    code: ?i64,
    message: []const u8,
    data: ?[]const u8,

    pub fn errorCode(self: CdpError) ?ErrorCode {
        const c = self.code orelse return null;
        const c32 = std.math.cast(i32, c) orelse return null;
        return @enumFromInt(c32);
    }
};

// ============================================================================
// Parsing
// ============================================================================

pub const ParseError = error{
    InvalidJson,
    InvalidMessageFormat,
} || Allocator.Error;

/// Parse a CDP JSON message into a Message struct.
/// The returned Message borrows from the parsed tree — caller must keep
/// `parsed` alive while using the Message.
pub fn parseMessage(allocator: Allocator, json_bytes: []const u8) ParseError!struct { message: Message, parsed: std.json.Parsed(std.json.Value) } {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_bytes,
        .{},
    ) catch return error.InvalidJson;
    errdefer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidMessageFormat;

    // id needs special handling: accepts integer or integer-valued float
    const id: ?u64 = if (root.object.get("id")) |v| switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else null,
        else => null,
    } else null;

    const method = getString(root, "method");
    const result = root.object.get("result");
    const session_id = getString(root, "sessionId");
    const params = root.object.get("params");

    const cdp_error: ?CdpError = if (getObject(root, "error")) |err_val| blk: {
        const message = getString(err_val, "message") orelse break :blk null;
        break :blk CdpError{
            .code = getInt(err_val, "code"),
            .message = message,
            .data = getString(err_val, "data"),
        };
    } else null;

    return .{
        .message = .{
            .id = id,
            .method = method,
            .result = result,
            .@"error" = cdp_error,
            .session_id = session_id,
            .params = params,
        },
        .parsed = parsed,
    };
}

// ============================================================================
// Command Serialization
// ============================================================================

/// Tracks command IDs for a CDP session.
pub const CommandId = struct {
    next_id: std.atomic.Value(u64),

    pub fn init() CommandId {
        return .{ .next_id = std.atomic.Value(u64).init(1) };
    }

    pub fn next(self: *CommandId) u64 {
        return self.next_id.fetchAdd(1, .monotonic);
    }
};

/// Serialize a CDP command to JSON bytes.
/// `params_json` is a pre-serialized JSON string for the params field (or null).
pub fn serializeCommand(
    allocator: Allocator,
    id: u64,
    method: []const u8,
    params_json: ?[]const u8,
    session_id: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"id\":");
    try std.fmt.format(writer, "{d}", .{id});
    try writer.writeAll(",\"method\":\"");
    try writer.writeAll(method);
    try writer.writeByte('"');

    if (params_json) |p| {
        try writer.writeAll(",\"params\":");
        try writer.writeAll(p);
    }

    if (session_id) |sid| {
        try writer.writeAll(",\"sessionId\":\"");
        try writer.writeAll(sid);
        try writer.writeByte('"');
    }

    try writer.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// Convenience: Common CDP Commands
// ============================================================================

pub fn networkEnable(allocator: Allocator, id: u64, session_id: ?[]const u8) ![]u8 {
    return serializeCommand(allocator, id, "Network.enable", null, session_id);
}

pub fn networkDisable(allocator: Allocator, id: u64, session_id: ?[]const u8) ![]u8 {
    return serializeCommand(allocator, id, "Network.disable", null, session_id);
}

pub fn networkGetResponseBody(allocator: Allocator, id: u64, request_id: []const u8, session_id: ?[]const u8) ![]u8 {
    const params = try jsonObject1(allocator, "requestId", request_id);
    defer allocator.free(params);
    return serializeCommand(allocator, id, "Network.getResponseBody", params, session_id);
}

pub fn pageNavigate(allocator: Allocator, id: u64, url: []const u8, session_id: ?[]const u8) ![]u8 {
    const params = try jsonObject1(allocator, "url", url);
    defer allocator.free(params);
    return serializeCommand(allocator, id, "Page.navigate", params, session_id);
}

pub fn pageEnable(allocator: Allocator, id: u64, session_id: ?[]const u8) ![]u8 {
    return serializeCommand(allocator, id, "Page.enable", null, session_id);
}

pub fn runtimeEvaluate(allocator: Allocator, id: u64, expression: []const u8, session_id: ?[]const u8) ![]u8 {
    // JSON-escape the expression string
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    try writeJsonString(escaped.writer(allocator), expression);

    const params = try std.fmt.allocPrint(allocator, "{{\"expression\":{s}}}", .{escaped.items});
    defer allocator.free(params);
    return serializeCommand(allocator, id, "Runtime.evaluate", params, session_id);
}

/// Build a JSON object with a single string key-value pair, properly escaped.
pub fn jsonObject1(allocator: Allocator, key: []const u8, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"");
    try writer.writeAll(key);
    try writer.writeAll("\":");
    try writeJsonString(writer, value);
    try writer.writeByte('}');

    return buf.toOwnedSlice(allocator);
}

/// Write a JSON-escaped string (with quotes) to a writer.
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"), // backspace
            0x0C => try writer.writeAll("\\f"), // form feed
            else => if (c < 0x20) {
                try std.fmt.format(writer, "\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

pub fn fetchEnable(allocator: Allocator, id: u64, patterns_json: ?[]const u8, session_id: ?[]const u8) ![]u8 {
    if (patterns_json) |p| {
        const params = try std.fmt.allocPrint(allocator, "{{\"patterns\":{s}}}", .{p});
        defer allocator.free(params);
        return serializeCommand(allocator, id, "Fetch.enable", params, session_id);
    }
    return serializeCommand(allocator, id, "Fetch.enable", null, session_id);
}

pub fn fetchDisable(allocator: Allocator, id: u64, session_id: ?[]const u8) ![]u8 {
    return serializeCommand(allocator, id, "Fetch.disable", null, session_id);
}

pub fn fetchFulfillRequest(
    allocator: Allocator,
    id: u64,
    request_id: []const u8,
    response_code: u16,
    body: ?[]const u8,
    session_id: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"requestId\":");
    try writeJsonString(writer, request_id);
    try writer.writeAll(",\"responseCode\":");
    try std.fmt.format(writer, "{d}", .{response_code});

    if (body) |b| {
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(b.len));
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, b);

        try writer.writeAll(",\"body\":\"");
        try writer.writeAll(encoded);
        try writer.writeByte('"');
    }

    try writer.writeByte('}');

    const params = try buf.toOwnedSlice(allocator);
    defer allocator.free(params);

    return serializeCommand(allocator, id, "Fetch.fulfillRequest", params, session_id);
}

pub fn fetchFailRequest(allocator: Allocator, id: u64, request_id: []const u8, error_reason: []const u8, session_id: ?[]const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"requestId\":");
    try writeJsonString(writer, request_id);
    try writer.writeAll(",\"errorReason\":");
    try writeJsonString(writer, error_reason);
    try writer.writeByte('}');

    const params = try buf.toOwnedSlice(allocator);
    defer allocator.free(params);

    return serializeCommand(allocator, id, "Fetch.failRequest", params, session_id);
}

pub fn fetchContinueRequest(
    allocator: Allocator,
    id: u64,
    request_id: []const u8,
    url: ?[]const u8,
    method_override: ?[]const u8,
    session_id: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"requestId\":");
    try writeJsonString(writer, request_id);

    if (url) |u| {
        try writer.writeAll(",\"url\":");
        try writeJsonString(writer, u);
    }

    if (method_override) |m| {
        try writer.writeAll(",\"method\":");
        try writeJsonString(writer, m);
    }

    try writer.writeByte('}');

    const params = try buf.toOwnedSlice(allocator);
    defer allocator.free(params);

    return serializeCommand(allocator, id, "Fetch.continueRequest", params, session_id);
}

// ============================================================================
// Convenience: Target Domain (connection management)
// Based on: https://chromedevtools.github.io/devtools-protocol/tot/Target/
// ============================================================================

pub fn targetGetTargets(allocator: Allocator, id: u64) ![]u8 {
    return serializeCommand(allocator, id, "Target.getTargets", null, null);
}

pub fn targetAttachToTarget(allocator: Allocator, id: u64, target_id: []const u8, flatten: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\"targetId\":");
    try writeJsonString(writer, target_id);
    try writer.writeAll(",\"flatten\":");
    try writer.writeAll(if (flatten) "true" else "false");
    try writer.writeByte('}');

    const params = try buf.toOwnedSlice(allocator);
    defer allocator.free(params);
    return serializeCommand(allocator, id, "Target.attachToTarget", params, null);
}

pub fn targetSetDiscoverTargets(allocator: Allocator, id: u64, discover: bool) ![]u8 {
    const params = try std.fmt.allocPrint(allocator, "{{\"discover\":{s}}}", .{
        if (discover) "true" else "false",
    });
    defer allocator.free(params);
    return serializeCommand(allocator, id, "Target.setDiscoverTargets", params, null);
}

// ============================================================================
// Helper: Extract values from CDP params
// ============================================================================

/// Extract a string field from a JSON object Value.
pub fn getString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract an integer field from a JSON object Value.
pub fn getInt(obj: std.json.Value, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .integer => |n| n,
        else => null,
    };
}

/// Extract a float field from a JSON object Value.
pub fn getFloat(obj: std.json.Value, key: []const u8) ?f64 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

/// Extract a bool field from a JSON object Value.
pub fn getBool(obj: std.json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// Extract a nested object field from a JSON object Value.
pub fn getObject(obj: std.json.Value, key: []const u8) ?std.json.Value {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return if (val == .object) val else null;
}

// ============================================================================
// Tests: Message Parsing
// ============================================================================

test "parse: successful response" {
    // CDP spec: { "id": N, "result": {...} }
    const json =
        \\{"id":1,"result":{"frameId":"ABC123"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const msg = result.message;

    try testing.expect(msg.isResponse());
    try testing.expect(!msg.isErrorResponse());
    try testing.expect(!msg.isEvent());
    try testing.expectEqual(@as(u64, 1), msg.id.?);
    try testing.expect(msg.result != null);
    try testing.expect(msg.@"error" == null);
    try testing.expect(msg.method == null);
}

test "parse: response with nested result" {
    const json =
        \\{"id":5,"result":{"body":"<html></html>","base64Encoded":false}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const msg = result.message;

    try testing.expectEqual(@as(u64, 5), msg.id.?);
    try testing.expect(msg.isResponse());

    // Verify nested fields
    const body = getString(msg.result.?, "body");
    try testing.expectEqualStrings("<html></html>", body.?);
    try testing.expectEqual(false, getBool(msg.result.?, "base64Encoded").?);
}

test "parse: empty result response" {
    // Network.enable returns empty result
    const json =
        \\{"id":2,"result":{}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isResponse());
    try testing.expectEqual(@as(u64, 2), result.message.id.?);
}

test "parse: error response - method not found" {
    // JSON-RPC error code -32601: Method not found
    const json =
        \\{"id":3,"error":{"code":-32601,"message":"'Network.bogus' wasn't found"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const msg = result.message;

    try testing.expect(msg.isErrorResponse());
    try testing.expect(!msg.isResponse());
    try testing.expectEqual(@as(u64, 3), msg.id.?);

    const err = msg.@"error".?;
    try testing.expectEqual(@as(i64, -32601), err.code.?);
    try testing.expectEqual(ErrorCode.method_not_found, err.errorCode().?);
    try testing.expectEqualStrings("'Network.bogus' wasn't found", err.message);
    try testing.expect(err.data == null);
}

test "parse: error response - invalid params" {
    // JSON-RPC error code -32602: Invalid params
    const json =
        \\{"id":4,"error":{"code":-32602,"message":"Invalid parameters","data":"requestId is required"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const err = result.message.@"error".?;

    try testing.expectEqual(ErrorCode.invalid_params, err.errorCode().?);
    try testing.expectEqualStrings("requestId is required", err.data.?);
}

test "parse: error response - parse error" {
    const json =
        \\{"id":0,"error":{"code":-32700,"message":"Parse error"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(ErrorCode.parse_error, result.message.@"error".?.errorCode().?);
}

test "parse: error response - server error" {
    const json =
        \\{"id":10,"error":{"code":-32000,"message":"Server error"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(ErrorCode.server_error, result.message.@"error".?.errorCode().?);
}

test "parse: error response without code (defensive)" {
    // agent-browser treats code as optional — handle gracefully
    const json =
        \\{"id":11,"error":{"message":"Something went wrong"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isErrorResponse());
    const err = result.message.@"error".?;
    try testing.expect(err.code == null);
    try testing.expect(err.errorCode() == null);
    try testing.expectEqualStrings("Something went wrong", err.message);
}

test "parse: event - Network.requestWillBeSent" {
    // Based on CDP spec: https://chromedevtools.github.io/devtools-protocol/tot/Network/#event-requestWillBeSent
    const json =
        \\{"method":"Network.requestWillBeSent","params":{"requestId":"1.1","loaderId":"L1","documentURL":"https://example.com","request":{"url":"https://example.com/api/users","method":"GET","headers":{"Accept":"application/json"}},"timestamp":1234.567,"wallTime":1700000000.123,"initiator":{"type":"script"},"type":"XHR","frameId":"F1","hasUserGesture":false}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const msg = result.message;

    try testing.expect(msg.isEvent());
    try testing.expect(!msg.isResponse());
    try testing.expect(msg.id == null);
    try testing.expectEqualStrings("Network.requestWillBeSent", msg.method.?);

    // Verify params fields per CDP spec
    const params = msg.params.?;
    try testing.expectEqualStrings("1.1", getString(params, "requestId").?);
    try testing.expectEqualStrings("L1", getString(params, "loaderId").?);
    try testing.expectEqualStrings("https://example.com", getString(params, "documentURL").?);
    try testing.expectEqualStrings("XHR", getString(params, "type").?);
    try testing.expectEqualStrings("F1", getString(params, "frameId").?);
    try testing.expectEqual(false, getBool(params, "hasUserGesture").?);

    // Verify nested Request object per CDP spec
    const request = getObject(params, "request").?;
    try testing.expectEqualStrings("https://example.com/api/users", getString(request, "url").?);
    try testing.expectEqualStrings("GET", getString(request, "method").?);

    // Verify nested headers
    const headers = getObject(request, "headers").?;
    try testing.expectEqualStrings("application/json", getString(headers, "Accept").?);
}

test "parse: event - Network.responseReceived" {
    // Based on CDP spec: https://chromedevtools.github.io/devtools-protocol/tot/Network/#event-responseReceived
    const json =
        \\{"method":"Network.responseReceived","params":{"requestId":"1.1","loaderId":"L1","timestamp":1234.890,"type":"XHR","response":{"url":"https://example.com/api/users","status":200,"statusText":"OK","headers":{"Content-Type":"application/json"},"mimeType":"application/json","connectionReused":true,"connectionId":42,"fromDiskCache":false,"fromServiceWorker":false,"fromPrefetchCache":false,"fromEarlyHints":false,"encodedDataLength":1024,"securityState":"secure"},"frameId":"F1"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const msg = result.message;

    try testing.expect(msg.isEvent());
    try testing.expectEqualStrings("Network.responseReceived", msg.method.?);

    // Verify Response object per CDP spec
    const params = msg.params.?;
    const response = getObject(params, "response").?;
    try testing.expectEqualStrings("https://example.com/api/users", getString(response, "url").?);
    try testing.expectEqual(@as(i64, 200), getInt(response, "status").?);
    try testing.expectEqualStrings("OK", getString(response, "statusText").?);
    try testing.expectEqualStrings("application/json", getString(response, "mimeType").?);
    try testing.expectEqual(true, getBool(response, "connectionReused").?);
    try testing.expectEqual(@as(i64, 42), getInt(response, "connectionId").?);
    try testing.expectEqual(false, getBool(response, "fromDiskCache").?);
    try testing.expectEqual(@as(i64, 1024), getInt(response, "encodedDataLength").?);
}

test "parse: event - Network.loadingFinished" {
    const json =
        \\{"method":"Network.loadingFinished","params":{"requestId":"1.1","timestamp":1235.000,"encodedDataLength":2048}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isEvent());
    try testing.expectEqualStrings("Network.loadingFinished", result.message.method.?);
    try testing.expectEqual(@as(i64, 2048), getInt(result.message.params.?, "encodedDataLength").?);
}

test "parse: event - Fetch.requestPaused" {
    // Based on CDP spec: https://chromedevtools.github.io/devtools-protocol/tot/Fetch/#event-requestPaused
    const json =
        \\{"method":"Fetch.requestPaused","params":{"requestId":"interception-1","request":{"url":"https://api.example.com/data","method":"POST","headers":{"Content-Type":"application/json"}},"frameId":"F1","resourceType":"XHR"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const msg = result.message;

    try testing.expect(msg.isEvent());
    try testing.expectEqualStrings("Fetch.requestPaused", msg.method.?);

    const params = msg.params.?;
    try testing.expectEqualStrings("interception-1", getString(params, "requestId").?);
    try testing.expectEqualStrings("XHR", getString(params, "resourceType").?);

    const request = getObject(params, "request").?;
    try testing.expectEqualStrings("POST", getString(request, "method").?);
}

test "parse: event with sessionId" {
    const json =
        \\{"method":"Page.loadEventFired","params":{"timestamp":1234.0},"sessionId":"session-abc-123"}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isEvent());
    try testing.expectEqualStrings("session-abc-123", result.message.session_id.?);
}

test "parse: response with sessionId" {
    const json =
        \\{"id":7,"result":{},"sessionId":"sess-42"}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isResponse());
    try testing.expectEqualStrings("sess-42", result.message.session_id.?);
}

// ============================================================================
// Tests: Parse Errors
// ============================================================================

test "parse error: invalid JSON" {
    try testing.expectError(error.InvalidJson, parseMessage(testing.allocator, "not json"));
}

test "parse error: empty string" {
    try testing.expectError(error.InvalidJson, parseMessage(testing.allocator, ""));
}

test "parse error: JSON array instead of object" {
    try testing.expectError(error.InvalidMessageFormat, parseMessage(testing.allocator, "[1,2,3]"));
}

test "parse error: JSON string instead of object" {
    try testing.expectError(error.InvalidMessageFormat, parseMessage(testing.allocator, "\"hello\""));
}

test "parse error: JSON number instead of object" {
    try testing.expectError(error.InvalidMessageFormat, parseMessage(testing.allocator, "42"));
}

// ============================================================================
// Tests: Command Serialization
// ============================================================================

test "serialize: command without params" {
    const json = try serializeCommand(testing.allocator, 1, "Network.enable", null, null);
    defer testing.allocator.free(json);

    // Verify by parsing back
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(@as(u64, 1), result.message.id.?);
    try testing.expectEqualStrings("Network.enable", result.message.method.?);
}

test "serialize: command with params" {
    const json = try serializeCommand(testing.allocator, 2, "Page.navigate",
        \\{"url":"https://example.com"}
    , null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(@as(u64, 2), result.message.id.?);
    try testing.expectEqualStrings("Page.navigate", result.message.method.?);
    try testing.expectEqualStrings("https://example.com", getString(result.message.params.?, "url").?);
}

test "serialize: command with sessionId" {
    const json = try serializeCommand(testing.allocator, 3, "Network.enable", null, "session-xyz");
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("session-xyz", result.message.session_id.?);
}

test "serialize: command with params and sessionId" {
    const json = try serializeCommand(testing.allocator, 4, "Fetch.failRequest",
        \\{"requestId":"req-1","errorReason":"AccessDenied"}
    , "sess-1");
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(@as(u64, 4), result.message.id.?);
    try testing.expectEqualStrings("Fetch.failRequest", result.message.method.?);
    try testing.expectEqualStrings("sess-1", result.message.session_id.?);
    try testing.expectEqualStrings("req-1", getString(result.message.params.?, "requestId").?);
}

// ============================================================================
// Tests: Convenience Commands (roundtrip: serialize → parse)
// ============================================================================

test "networkEnable: serializes correctly" {
    const json = try networkEnable(testing.allocator, 1, null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Network.enable", result.message.method.?);
    try testing.expect(result.message.params == null);
}

test "networkDisable: serializes correctly" {
    const json = try networkDisable(testing.allocator, 2, null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Network.disable", result.message.method.?);
}

test "networkGetResponseBody: serializes correctly" {
    const json = try networkGetResponseBody(testing.allocator, 3, "req-123", null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Network.getResponseBody", result.message.method.?);
    try testing.expectEqualStrings("req-123", getString(result.message.params.?, "requestId").?);
}

test "pageNavigate: serializes correctly" {
    const json = try pageNavigate(testing.allocator, 4, "https://example.com", null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Page.navigate", result.message.method.?);
    try testing.expectEqualStrings("https://example.com", getString(result.message.params.?, "url").?);
}

test "pageEnable: serializes correctly" {
    const json = try pageEnable(testing.allocator, 5, null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Page.enable", result.message.method.?);
}

test "runtimeEvaluate: serializes correctly" {
    const json = try runtimeEvaluate(testing.allocator, 6, "document.title", null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Runtime.evaluate", result.message.method.?);
    try testing.expectEqualStrings("document.title", getString(result.message.params.?, "expression").?);
}

test "runtimeEvaluate: escapes special characters" {
    const json = try runtimeEvaluate(testing.allocator, 7, "console.log(\"hello\\nworld\")", null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("console.log(\"hello\\nworld\")", getString(result.message.params.?, "expression").?);
}

test "fetchEnable: without patterns" {
    const json = try fetchEnable(testing.allocator, 8, null, null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Fetch.enable", result.message.method.?);
}

test "fetchEnable: with patterns" {
    const json = try fetchEnable(testing.allocator, 9,
        \\[{"urlPattern":"*","requestStage":"Response"}]
    , null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Fetch.enable", result.message.method.?);
    try testing.expect(result.message.params != null);
}

test "fetchFulfillRequest: with body" {
    const json = try fetchFulfillRequest(testing.allocator, 10, "req-1", 200, "{\"ok\":true}", null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Fetch.fulfillRequest", result.message.method.?);
    try testing.expectEqualStrings("req-1", getString(result.message.params.?, "requestId").?);
    try testing.expectEqual(@as(i64, 200), getInt(result.message.params.?, "responseCode").?);
    // body should be base64 encoded
    try testing.expect(getString(result.message.params.?, "body") != null);
}

test "fetchFulfillRequest: without body" {
    const json = try fetchFulfillRequest(testing.allocator, 11, "req-2", 204, null, null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(@as(i64, 204), getInt(result.message.params.?, "responseCode").?);
}

test "fetchFailRequest: serializes correctly" {
    const json = try fetchFailRequest(testing.allocator, 12, "req-3", "ConnectionRefused", null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Fetch.failRequest", result.message.method.?);
    try testing.expectEqualStrings("req-3", getString(result.message.params.?, "requestId").?);
    try testing.expectEqualStrings("ConnectionRefused", getString(result.message.params.?, "errorReason").?);
}

test "fetchContinueRequest: with url and method override" {
    const json = try fetchContinueRequest(testing.allocator, 13, "req-4", "https://other.com", "POST", null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Fetch.continueRequest", result.message.method.?);
    try testing.expectEqualStrings("req-4", getString(result.message.params.?, "requestId").?);
    try testing.expectEqualStrings("https://other.com", getString(result.message.params.?, "url").?);
    try testing.expectEqualStrings("POST", getString(result.message.params.?, "method").?);
}

test "fetchContinueRequest: minimal (requestId only)" {
    const json = try fetchContinueRequest(testing.allocator, 14, "req-5", null, null, null);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("req-5", getString(result.message.params.?, "requestId").?);
    try testing.expect(getString(result.message.params.?, "url") == null);
    try testing.expect(getString(result.message.params.?, "method") == null);
}

// ============================================================================
// Tests: CommandId
// ============================================================================

test "CommandId: sequential IDs" {
    var cmd_id = CommandId.init();
    try testing.expectEqual(@as(u64, 1), cmd_id.next());
    try testing.expectEqual(@as(u64, 2), cmd_id.next());
    try testing.expectEqual(@as(u64, 3), cmd_id.next());
}

test "CommandId: starts at 1" {
    const cmd_id = CommandId.init();
    try testing.expectEqual(@as(u64, 1), cmd_id.next_id.load(.monotonic));
}

// ============================================================================
// Tests: Helper Functions
// ============================================================================

test "getString: extracts string field" {
    const json =
        \\{"name":"hello","count":42}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("hello", getString(parsed.value, "name").?);
    try testing.expect(getString(parsed.value, "count") == null); // not a string
    try testing.expect(getString(parsed.value, "missing") == null);
}

test "getInt: extracts integer field" {
    const json =
        \\{"status":200,"name":"ok"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 200), getInt(parsed.value, "status").?);
    try testing.expect(getInt(parsed.value, "name") == null);
    try testing.expect(getInt(parsed.value, "missing") == null);
}

test "getBool: extracts boolean field" {
    const json =
        \\{"fromCache":true,"status":200}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqual(true, getBool(parsed.value, "fromCache").?);
    try testing.expect(getBool(parsed.value, "status") == null);
}

test "getFloat: extracts float and integer as float" {
    const json =
        \\{"timestamp":1234.567,"count":42}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectApproxEqAbs(@as(f64, 1234.567), getFloat(parsed.value, "timestamp").?, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 42.0), getFloat(parsed.value, "count").?, 0.001);
}

test "getObject: extracts nested object" {
    const json =
        \\{"request":{"url":"https://example.com"},"name":"test"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const obj = getObject(parsed.value, "request");
    try testing.expect(obj != null);
    try testing.expectEqualStrings("https://example.com", getString(obj.?, "url").?);
    try testing.expect(getObject(parsed.value, "name") == null); // not an object
}

test "helpers: work on non-object value" {
    const json =
        \\[1,2,3]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(getString(parsed.value, "any") == null);
    try testing.expect(getInt(parsed.value, "any") == null);
    try testing.expect(getBool(parsed.value, "any") == null);
    try testing.expect(getFloat(parsed.value, "any") == null);
    try testing.expect(getObject(parsed.value, "any") == null);
}

// ============================================================================
// Tests: Parsing Edge Cases
// ============================================================================

test "parse: response with id=0 (valid)" {
    const json =
        \\{"id":0,"result":{}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isResponse());
    try testing.expectEqual(@as(u64, 0), result.message.id.?);
}

test "parse: response with large id" {
    const json =
        \\{"id":999999999,"result":{}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(@as(u64, 999999999), result.message.id.?);
}

test "parse: event without params (some events have no params)" {
    const json =
        \\{"method":"Inspector.detached"}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isEvent());
    try testing.expectEqualStrings("Inspector.detached", result.message.method.?);
    try testing.expect(result.message.params == null);
}

test "parse: result is null (distinct from empty object)" {
    const json =
        \\{"id":1,"result":null}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    // result field exists but is null — id is present so it's a response
    try testing.expectEqual(@as(u64, 1), result.message.id.?);
    try testing.expect(result.message.result != null); // json null is a valid Value
}

test "parse: negative id is ignored (treated as no id)" {
    const json =
        \\{"id":-1,"method":"some.event","params":{}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    // Negative id → id=null → treated as event
    try testing.expect(result.message.id == null);
    try testing.expect(result.message.isEvent());
}

test "parse: id as float (Chrome sometimes sends float ids)" {
    const json =
        \\{"id":5.0,"result":{}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(@as(u64, 5), result.message.id.?);
}

test "parse: id as non-integer float is ignored" {
    const json =
        \\{"id":5.5,"result":{}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    // 5.5 is not a valid integer id
    try testing.expect(result.message.id == null);
}

test "parse: error with data as object (not just string)" {
    // Some CDP errors return data as an object
    const json =
        \\{"id":1,"error":{"code":-32000,"message":"Error","data":"extra info"}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isErrorResponse());
    try testing.expectEqualStrings("extra info", result.message.@"error".?.data.?);
}

test "parse: message with unknown extra fields (forward compatible)" {
    // CDP may add new fields — parser should not reject them
    const json =
        \\{"id":1,"result":{},"unknown_field":"whatever","another":42}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expect(result.message.isResponse());
    try testing.expectEqual(@as(u64, 1), result.message.id.?);
}

test "parse: empty object (no id, no method)" {
    const json =
        \\{}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    // Not a response, not an error, not an event
    try testing.expect(!result.message.isResponse());
    try testing.expect(!result.message.isErrorResponse());
    try testing.expect(!result.message.isEvent());
}

// ============================================================================
// Tests: Target Domain Commands
// ============================================================================

test "targetGetTargets: serializes correctly" {
    const json = try targetGetTargets(testing.allocator, 1);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Target.getTargets", result.message.method.?);
}

test "targetAttachToTarget: with flatten=true" {
    const json = try targetAttachToTarget(testing.allocator, 2, "ABCDEF123", true);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Target.attachToTarget", result.message.method.?);
    try testing.expectEqualStrings("ABCDEF123", getString(result.message.params.?, "targetId").?);
    try testing.expectEqual(true, getBool(result.message.params.?, "flatten").?);
}

test "targetAttachToTarget: with flatten=false" {
    const json = try targetAttachToTarget(testing.allocator, 3, "TARGET1", false);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqual(false, getBool(result.message.params.?, "flatten").?);
}

test "targetSetDiscoverTargets: discover=true" {
    const json = try targetSetDiscoverTargets(testing.allocator, 4, true);
    defer testing.allocator.free(json);

    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();

    try testing.expectEqualStrings("Target.setDiscoverTargets", result.message.method.?);
    try testing.expectEqual(true, getBool(result.message.params.?, "discover").?);
}

// ============================================================================
// Tests: writeJsonString edge cases
// ============================================================================

test "writeJsonString: simple string" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(buf.writer(testing.allocator), "hello");
    try testing.expectEqualStrings("\"hello\"", buf.items);
}

test "writeJsonString: escapes quotes and backslash" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(buf.writer(testing.allocator), "say \"hi\" and \\go");
    try testing.expectEqualStrings("\"say \\\"hi\\\" and \\\\go\"", buf.items);
}

test "writeJsonString: escapes control characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(buf.writer(testing.allocator), "line1\nline2\ttab\r");
    try testing.expectEqualStrings("\"line1\\nline2\\ttab\\r\"", buf.items);
}

test "writeJsonString: escapes null and low control chars" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(buf.writer(testing.allocator), &[_]u8{ 0x00, 0x01, 0x1F });

    // Should produce \u0000, \u0001, \u001f
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u0000") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u0001") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u001f") != null);
}

test "writeJsonString: empty string" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(buf.writer(testing.allocator), "");
    try testing.expectEqualStrings("\"\"", buf.items);
}

test "writeJsonString: backspace and form feed" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(buf.writer(testing.allocator), &[_]u8{ 0x08, 0x0C });
    try testing.expectEqualStrings("\"\\b\\f\"", buf.items);
}

// ============================================================================
// Tests: Roundtrip with CDP spec field validation
// (Fields verified against reference/cdp-protocol/json/browser_protocol.json)
// ============================================================================

test "parse: Network.requestWillBeSent - all required fields per spec" {
    // CDP spec says these fields are required:
    // requestId, loaderId, documentURL, request, timestamp, wallTime,
    // initiator, redirectHasExtraInfo
    const json =
        \\{"method":"Network.requestWillBeSent","params":{"requestId":"R1","loaderId":"L1","documentURL":"https://test.com","request":{"url":"https://test.com/api","method":"POST","headers":{},"initialPriority":"High","referrerPolicy":"no-referrer"},"timestamp":100.0,"wallTime":1700000000.0,"initiator":{"type":"other"},"redirectHasExtraInfo":false}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const params = result.message.params.?;

    // Verify all required fields exist
    try testing.expect(getString(params, "requestId") != null);
    try testing.expect(getString(params, "loaderId") != null);
    try testing.expect(getString(params, "documentURL") != null);
    try testing.expect(getObject(params, "request") != null);
    try testing.expect(getFloat(params, "timestamp") != null);
    try testing.expect(getFloat(params, "wallTime") != null);
    try testing.expect(getObject(params, "initiator") != null);
    try testing.expect(getBool(params, "redirectHasExtraInfo") != null);

    // Verify nested Request required fields per spec
    const request = getObject(params, "request").?;
    try testing.expect(getString(request, "url") != null);
    try testing.expect(getString(request, "method") != null);
    try testing.expect(getObject(request, "headers") != null);
}

test "parse: Network.responseReceived - all required fields per spec" {
    // CDP spec required: requestId, loaderId, timestamp, type, response, hasExtraInfo
    const json =
        \\{"method":"Network.responseReceived","params":{"requestId":"R1","loaderId":"L1","timestamp":101.0,"type":"Document","response":{"url":"https://test.com","status":200,"statusText":"OK","headers":{},"mimeType":"text/html","connectionReused":false,"connectionId":1,"fromDiskCache":false,"fromServiceWorker":false,"fromPrefetchCache":false,"fromEarlyHints":false,"encodedDataLength":500,"securityState":"secure"},"hasExtraInfo":true}}
    ;
    const result = try parseMessage(testing.allocator, json);
    defer result.parsed.deinit();
    const params = result.message.params.?;

    try testing.expect(getString(params, "requestId") != null);
    try testing.expect(getString(params, "loaderId") != null);
    try testing.expect(getFloat(params, "timestamp") != null);
    try testing.expect(getString(params, "type") != null);
    try testing.expect(getObject(params, "response") != null);
    try testing.expect(getBool(params, "hasExtraInfo") != null);

    // Verify Response required fields per spec
    const response = getObject(params, "response").?;
    try testing.expect(getString(response, "url") != null);
    try testing.expect(getInt(response, "status") != null);
    try testing.expect(getString(response, "statusText") != null);
    try testing.expect(getObject(response, "headers") != null);
    try testing.expect(getString(response, "mimeType") != null);
    try testing.expect(getBool(response, "connectionReused") != null);
    try testing.expect(getInt(response, "connectionId") != null);
    try testing.expect(getBool(response, "fromDiskCache") != null);
    try testing.expect(getBool(response, "fromServiceWorker") != null);
    try testing.expect(getBool(response, "fromPrefetchCache") != null);
    try testing.expect(getBool(response, "fromEarlyHints") != null);
    try testing.expect(getInt(response, "encodedDataLength") != null);
    try testing.expect(getString(response, "securityState") != null);
}
