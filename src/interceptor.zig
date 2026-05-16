const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const cdp = @import("cdp.zig");

// ============================================================================
// Network Request Interceptor
// Based on CDP Fetch domain:
// https://chromedevtools.github.io/devtools-protocol/tot/Fetch/
// ============================================================================

pub const Action = enum {
    mock, // Return a custom response (Fetch.fulfillRequest)
    fail, // Block the request (Fetch.failRequest)
    delay, // Delay then continue (sleep + Fetch.continueRequest)
    pass, // Continue without modification (Fetch.continueRequest)
};

pub const Rule = struct {
    url_pattern: []u8,
    action: Action,
    mock_body: ?[]u8, // For mock action
    mock_status: u16, // For mock action (default 200)
    mock_content_type: []u8, // For mock action (default "application/json")
    delay_ms: u32, // For delay action
    error_reason: []u8, // For fail action (default "BlockedByClient")
    resource_types: ?[]u8 = null, // CSV of CDP resourceType; null = match all
};

/// 요청의 resourceType이 룰의 resource_types 필터에 부합하는지.
/// 필터가 없으면(null) 모든 타입 허용. 비교는 대소문자 무시.
pub fn matchesResourceType(rule: *const Rule, resource_type: []const u8) bool {
    const csv = rule.resource_types orelse return true;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, resource_type)) return true;
    }
    return false;
}

pub const InterceptorState = struct {
    rules: std.ArrayList(Rule),
    allocator: Allocator,
    enabled: bool,

    pub fn init(allocator: Allocator) InterceptorState {
        return .{
            .rules = std.ArrayList(Rule).empty,
            .allocator = allocator,
            .enabled = false,
        };
    }

    fn freeRule(allocator: Allocator, rule: Rule) void {
        allocator.free(rule.url_pattern);
        if (rule.mock_body) |b| allocator.free(b);
        allocator.free(rule.mock_content_type);
        allocator.free(rule.error_reason);
        if (rule.resource_types) |rt| allocator.free(rt);
    }

    pub fn deinit(self: *InterceptorState) void {
        for (self.rules.items) |rule| freeRule(self.allocator, rule);
        self.rules.deinit(self.allocator);
    }

    /// Add a new intercept rule.
    pub fn addRule(self: *InterceptorState, rule: Rule) !void {
        try self.rules.append(self.allocator, rule);
        self.enabled = true;
    }

    /// Remove rules matching a URL pattern.
    pub fn removeRule(self: *InterceptorState, url_pattern: []const u8) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.rules.items.len) {
            if (std.mem.eql(u8, self.rules.items[i].url_pattern, url_pattern)) {
                const rule = self.rules.orderedRemove(i);
                freeRule(self.allocator, rule);
                removed += 1;
            } else {
                i += 1;
            }
        }
        if (self.rules.items.len == 0) self.enabled = false;
        return removed;
    }

    /// Find the first rule matching both the URL pattern and resource-type filter.
    pub fn findMatch(self: *const InterceptorState, url: []const u8, resource_type: []const u8) ?*const Rule {
        for (self.rules.items) |*rule| {
            if (matchPattern(rule.url_pattern, url) and matchesResourceType(rule, resource_type)) return rule;
        }
        return null;
    }

    /// Get the number of active rules.
    pub fn ruleCount(self: *const InterceptorState) usize {
        return self.rules.items.len;
    }

    /// Build the CDP Fetch.enable patterns array from active rules.
    pub fn buildFetchPatterns(self: *const InterceptorState, allocator: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeByte('[');
        for (self.rules.items, 0..) |rule, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"urlPattern\":");
            try cdp.writeJsonString(writer, rule.url_pattern);
            try writer.writeAll(",\"requestStage\":\"Request\"}");
        }
        try writer.writeByte(']');

        return buf.toOwnedSlice(allocator);
    }
};

/// Match a URL against a pattern.
/// Supports '*' as wildcard (matches any substring).
/// e.g. "*api*" matches "https://example.com/api/users"
pub fn matchPattern(pattern: []const u8, url: []const u8) bool {
    if (pattern.len == 0) return url.len == 0;
    if (std.mem.eql(u8, pattern, "*")) return true;

    // Split pattern by '*' and check each part exists in order
    var pattern_iter = std.mem.splitScalar(u8, pattern, '*');
    var search_start: usize = 0;
    var first = true;

    while (pattern_iter.next()) |part| {
        if (part.len == 0) {
            first = false;
            continue;
        }

        if (first) {
            // First segment must match at start (if pattern doesn't start with *)
            if (!std.mem.startsWith(u8, url[search_start..], part)) return false;
            search_start += part.len;
        } else {
            // Subsequent segments: find anywhere after current position
            if (std.mem.indexOfPos(u8, url, search_start, part)) |pos| {
                search_start = pos + part.len;
            } else {
                return false;
            }
        }
        first = false;
    }

    // If pattern doesn't end with *, remaining URL must be consumed
    if (!std.mem.endsWith(u8, pattern, "*") and search_start < url.len) return false;

    return true;
}

/// Build a Fetch.fulfillRequest command for a mock response.
pub fn buildFulfillCommand(allocator: Allocator, id: u64, request_id: []const u8, rule: *const Rule, session_id: ?[]const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"requestId\":");
    try cdp.writeJsonString(writer, request_id);
    try std.fmt.format(writer, ",\"responseCode\":{d}", .{rule.mock_status});

    // Headers
    try writer.writeAll(",\"responseHeaders\":[{\"name\":\"Content-Type\",\"value\":");
    try cdp.writeJsonString(writer, rule.mock_content_type);
    try writer.writeAll("},{\"name\":\"Access-Control-Allow-Origin\",\"value\":\"*\"}]");

    // Body (base64 encoded)
    if (rule.mock_body) |body| {
        const encoded_len = std.base64.standard.Encoder.calcSize(body.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, body);

        try writer.writeAll(",\"body\":");
        try cdp.writeJsonString(writer, encoded);
    }

    try writer.writeByte('}');

    const params = try buf.toOwnedSlice(allocator);
    defer allocator.free(params);

    return cdp.serializeCommand(allocator, id, "Fetch.fulfillRequest", params, session_id);
}

/// Build a Fetch.failRequest command.
pub fn buildFailCommand(allocator: Allocator, id: u64, request_id: []const u8, error_reason: []const u8, session_id: ?[]const u8) ![]u8 {
    return cdp.fetchFailRequest(allocator, id, request_id, error_reason, session_id);
}

/// Build a Fetch.continueRequest command.
pub fn buildContinueCommand(allocator: Allocator, id: u64, request_id: []const u8, session_id: ?[]const u8) ![]u8 {
    return cdp.fetchContinueRequest(allocator, id, request_id, null, null, session_id);
}

// ============================================================================
// Tests
// ============================================================================

test "matchPattern: exact match" {
    try testing.expect(matchPattern("https://api.test.com/data", "https://api.test.com/data"));
    try testing.expect(!matchPattern("https://api.test.com/data", "https://api.test.com/other"));
}

test "matchPattern: wildcard all" {
    try testing.expect(matchPattern("*", "https://anything.com/whatever"));
    try testing.expect(matchPattern("*", ""));
}

test "matchPattern: wildcard prefix" {
    try testing.expect(matchPattern("*api*", "https://example.com/api/users"));
    try testing.expect(matchPattern("*api*", "https://api.test.com/data"));
    try testing.expect(!matchPattern("*api*", "https://example.com/data"));
}

test "matchPattern: wildcard suffix" {
    try testing.expect(matchPattern("https://api.test.com/*", "https://api.test.com/users"));
    try testing.expect(matchPattern("https://api.test.com/*", "https://api.test.com/"));
    try testing.expect(!matchPattern("https://api.test.com/*", "https://other.com/users"));
}

test "matchPattern: wildcard middle" {
    try testing.expect(matchPattern("https://*/api/*", "https://example.com/api/users"));
    try testing.expect(!matchPattern("https://*/api/*", "https://example.com/other/data"));
}

test "matchPattern: no wildcard prefix must match start" {
    try testing.expect(matchPattern("https://api*", "https://api.test.com"));
    try testing.expect(!matchPattern("https://api*", "http://api.test.com"));
}

test "matchPattern: no wildcard suffix must match end" {
    try testing.expect(matchPattern("*.json", "https://example.com/data.json"));
    try testing.expect(!matchPattern("*.json", "https://example.com/data.json.bak"));
}

test "matchPattern: empty pattern" {
    try testing.expect(matchPattern("", ""));
    try testing.expect(!matchPattern("", "something"));
}

test "matchesResourceType: null filter matches any type" {
    const rule = Rule{
        .url_pattern = @constCast("*"),
        .action = .fail,
        .mock_body = null,
        .mock_status = 200,
        .mock_content_type = @constCast(""),
        .delay_ms = 0,
        .error_reason = @constCast(""),
        .resource_types = null,
    };
    try testing.expect(matchesResourceType(&rule, "Document"));
    try testing.expect(matchesResourceType(&rule, "XHR"));
    try testing.expect(matchesResourceType(&rule, ""));
}

test "matchesResourceType: CSV filter, case-insensitive, trimmed" {
    const rule = Rule{
        .url_pattern = @constCast("*"),
        .action = .fail,
        .mock_body = null,
        .mock_status = 200,
        .mock_content_type = @constCast(""),
        .delay_ms = 0,
        .error_reason = @constCast(""),
        .resource_types = @constCast("Script, XHR ,fetch"),
    };
    try testing.expect(matchesResourceType(&rule, "script")); // case-insensitive
    try testing.expect(matchesResourceType(&rule, "XHR")); // trimmed
    try testing.expect(matchesResourceType(&rule, "Fetch"));
    try testing.expect(!matchesResourceType(&rule, "Document"));
    try testing.expect(!matchesResourceType(&rule, "Image"));
}

test "InterceptorState: findMatch honors resource-type filter" {
    var state = InterceptorState.init(testing.allocator);
    defer state.deinit();

    try state.addRule(.{
        .url_pattern = try testing.allocator.dupe(u8, "*api*"),
        .action = .fail,
        .mock_body = null,
        .mock_status = 200,
        .mock_content_type = try testing.allocator.dupe(u8, ""),
        .delay_ms = 0,
        .error_reason = try testing.allocator.dupe(u8, "BlockedByClient"),
        .resource_types = try testing.allocator.dupe(u8, "Script,XHR"),
    });

    try testing.expect(state.findMatch("https://x.com/api/v1", "XHR") != null);
    try testing.expect(state.findMatch("https://x.com/api/v1", "Document") == null); // type filtered out
    try testing.expect(state.findMatch("https://x.com/page", "XHR") == null); // url filtered out
}

test "InterceptorState: add and find rule" {
    var state = InterceptorState.init(testing.allocator);
    defer state.deinit();

    try state.addRule(.{
        .url_pattern = try testing.allocator.dupe(u8, "*api*"),
        .action = .mock,
        .mock_body = try testing.allocator.dupe(u8, "{\"ok\":true}"),
        .mock_status = 200,
        .mock_content_type = try testing.allocator.dupe(u8, "application/json"),
        .delay_ms = 0,
        .error_reason = try testing.allocator.dupe(u8, ""),
    });

    try testing.expect(state.enabled);
    try testing.expectEqual(@as(usize, 1), state.ruleCount());

    const match = state.findMatch("https://example.com/api/data", "");
    try testing.expect(match != null);
    try testing.expectEqual(Action.mock, match.?.action);

    const no_match = state.findMatch("https://example.com/page", "");
    try testing.expect(no_match == null);
}

test "InterceptorState: remove rule" {
    var state = InterceptorState.init(testing.allocator);
    defer state.deinit();

    try state.addRule(.{
        .url_pattern = try testing.allocator.dupe(u8, "*api*"),
        .action = .fail,
        .mock_body = null,
        .mock_status = 0,
        .mock_content_type = try testing.allocator.dupe(u8, ""),
        .delay_ms = 0,
        .error_reason = try testing.allocator.dupe(u8, "BlockedByClient"),
    });

    try testing.expectEqual(@as(usize, 1), state.ruleCount());
    const removed = state.removeRule("*api*");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(usize, 0), state.ruleCount());
    try testing.expect(!state.enabled);
}

test "InterceptorState: multiple rules, first match wins" {
    var state = InterceptorState.init(testing.allocator);
    defer state.deinit();

    try state.addRule(.{
        .url_pattern = try testing.allocator.dupe(u8, "*specific-api*"),
        .action = .mock,
        .mock_body = try testing.allocator.dupe(u8, "specific"),
        .mock_status = 200,
        .mock_content_type = try testing.allocator.dupe(u8, "text/plain"),
        .delay_ms = 0,
        .error_reason = try testing.allocator.dupe(u8, ""),
    });
    try state.addRule(.{
        .url_pattern = try testing.allocator.dupe(u8, "*api*"),
        .action = .fail,
        .mock_body = null,
        .mock_status = 0,
        .mock_content_type = try testing.allocator.dupe(u8, ""),
        .delay_ms = 0,
        .error_reason = try testing.allocator.dupe(u8, "BlockedByClient"),
    });

    // specific-api matches the first rule
    const m1 = state.findMatch("https://example.com/specific-api/data", "");
    try testing.expect(m1 != null);
    try testing.expectEqual(Action.mock, m1.?.action);

    // generic api matches the second rule
    const m2 = state.findMatch("https://example.com/api/other", "");
    try testing.expect(m2 != null);
    try testing.expectEqual(Action.fail, m2.?.action);
}

test "buildFetchPatterns: generates correct JSON" {
    var state = InterceptorState.init(testing.allocator);
    defer state.deinit();

    try state.addRule(.{
        .url_pattern = try testing.allocator.dupe(u8, "*api*"),
        .action = .mock,
        .mock_body = null,
        .mock_status = 200,
        .mock_content_type = try testing.allocator.dupe(u8, ""),
        .delay_ms = 0,
        .error_reason = try testing.allocator.dupe(u8, ""),
    });

    const patterns = try state.buildFetchPatterns(testing.allocator);
    defer testing.allocator.free(patterns);

    try testing.expect(std.mem.indexOf(u8, patterns, "\"urlPattern\":\"*api*\"") != null);
    try testing.expect(std.mem.indexOf(u8, patterns, "\"requestStage\":\"Request\"") != null);
}

test "matchPattern: multiple wildcards" {
    try testing.expect(matchPattern("https://*.example.com/*/data", "https://api.example.com/v1/data"));
    try testing.expect(!matchPattern("https://*.example.com/*/data", "https://api.other.com/v1/data"));
}

test "matchPattern: consecutive wildcards" {
    try testing.expect(matchPattern("**api**", "https://api.test.com/data"));
}

test "buildFulfillCommand: produces valid CDP" {
    const rule = Rule{
        .url_pattern = @constCast("*"),
        .action = .mock,
        .mock_body = @constCast("{\"ok\":true}"),
        .mock_status = 200,
        .mock_content_type = @constCast("application/json"),
        .delay_ms = 0,
        .error_reason = @constCast(""),
    };
    const cmd = try buildFulfillCommand(testing.allocator, 1, "req-1", &rule, null);
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "Fetch.fulfillRequest") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "responseCode") != null);
}

test "buildFailCommand: produces valid CDP" {
    const cmd = try buildFailCommand(testing.allocator, 1, "req-1", "BlockedByClient", null);
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "Fetch.failRequest") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "BlockedByClient") != null);
}

test "buildContinueCommand: produces valid CDP" {
    const cmd = try buildContinueCommand(testing.allocator, 1, "req-1", null);
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "Fetch.continueRequest") != null);
}
