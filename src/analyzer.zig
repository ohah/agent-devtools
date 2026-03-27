const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const cdp = @import("cdp.zig");
const network_mod = @import("network.zig");

// ============================================================================
// API Endpoint Analyzer
// Analyzes network traffic to discover API endpoints and generate schema.
// ============================================================================

pub const Endpoint = struct {
    method: []const u8,
    path_pattern: []const u8, // e.g. "/api/users/{id}"
    example_url: []const u8,
    status: ?i64,
    mime_type: []const u8,
    count: usize,
};

pub const AnalysisResult = struct {
    endpoints: []Endpoint,
    base_url: []const u8,
    total_requests: usize,
    api_requests: usize,
    allocator: Allocator,

    pub fn deinit(self: *AnalysisResult) void {
        for (self.endpoints) |ep| {
            self.allocator.free(ep.path_pattern);
            self.allocator.free(ep.example_url);
            self.allocator.free(ep.method);
            self.allocator.free(ep.mime_type);
        }
        self.allocator.free(self.endpoints);
        self.allocator.free(self.base_url);
    }
};

/// Check if a request is likely an API call (not a static resource).
pub fn isApiRequest(url: []const u8, resource_type: []const u8, mime_type: []const u8) bool {
    // Filter by resource type
    if (std.mem.eql(u8, resource_type, "XHR") or
        std.mem.eql(u8, resource_type, "Fetch"))
    {
        return true;
    }

    // Filter by mime type
    if (std.mem.indexOf(u8, mime_type, "application/json") != null or
        std.mem.indexOf(u8, mime_type, "application/xml") != null or
        std.mem.indexOf(u8, mime_type, "text/json") != null or
        std.mem.indexOf(u8, mime_type, "application/graphql") != null)
    {
        return true;
    }

    // Filter by URL pattern (common API paths)
    if (std.mem.indexOf(u8, url, "/api/") != null or
        std.mem.indexOf(u8, url, "/graphql") != null or
        std.mem.indexOf(u8, url, "/v1/") != null or
        std.mem.indexOf(u8, url, "/v2/") != null or
        std.mem.indexOf(u8, url, "/v3/") != null or
        std.mem.indexOf(u8, url, "/rest/") != null)
    {
        return true;
    }

    // Exclude known static types
    const static_exts = [_][]const u8{
        ".js", ".css", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico",
        ".woff", ".woff2", ".ttf", ".eot", ".map", ".webp", ".avif",
    };
    for (static_exts) |ext| {
        if (std.mem.endsWith(u8, url, ext)) return false;
        // Also check with query string: .js?v=123
        if (std.mem.indexOf(u8, url, ext)) |pos| {
            if (pos + ext.len < url.len and url[pos + ext.len] == '?') return false;
        }
    }

    return false;
}

/// Extract the path from a URL (strip scheme, host, query, fragment).
pub fn extractPath(url: []const u8) []const u8 {
    // Find path start after scheme://host
    var start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        start = scheme_end + 3;
        // Skip host
        start = std.mem.indexOfScalarPos(u8, url, start, '/') orelse return "/";
    }

    // Strip query string and fragment
    var end = url.len;
    if (std.mem.indexOfScalarPos(u8, url, start, '?')) |q| end = q;
    if (std.mem.indexOfScalarPos(u8, url, start, '#')) |h| end = @min(end, h);

    return url[start..end];
}

/// Extract base URL (scheme + host) from a URL.
pub fn extractBaseUrl(allocator: Allocator, url: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const host_start = scheme_end + 3;
        const host_end = std.mem.indexOfScalarPos(u8, url, host_start, '/') orelse url.len;
        return allocator.dupe(u8, url[0..host_end]);
    }
    return allocator.dupe(u8, url);
}

/// Detect if a path segment looks like a dynamic ID.
/// e.g. "123", "abc-def-123", UUID, hex hash
pub fn isLikelyId(segment: []const u8) bool {
    if (segment.len == 0) return false;

    // Pure numeric
    var all_digits = true;
    for (segment) |c| {
        if (c < '0' or c > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits and segment.len > 0) return true;

    // UUID pattern (32 hex + 4 dashes = 36 chars, or 32 hex without dashes)
    if (segment.len == 36 or segment.len == 32) {
        var hex_count: usize = 0;
        var dash_count: usize = 0;
        for (segment) |c| {
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                hex_count += 1;
            } else if (c == '-') {
                dash_count += 1;
            } else {
                break;
            }
        }
        if (hex_count == 32 and (dash_count == 0 or dash_count == 4)) return true;
    }

    // Long hex string (hash, token)
    if (segment.len >= 16) {
        var all_hex = true;
        for (segment) |c| {
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                all_hex = false;
                break;
            }
        }
        if (all_hex) return true;
    }

    // Mixed alphanumeric with digits (e.g. "user123", "item42")
    var has_digit = false;
    var has_alpha = false;
    for (segment) |c| {
        if (c >= '0' and c <= '9') has_digit = true;
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) has_alpha = true;
    }
    // Short mixed segments are usually IDs (but not too short like "v2")
    if (has_digit and has_alpha and segment.len >= 4) return true;

    return false;
}

/// Convert a concrete path to a parameterized pattern.
/// e.g. "/api/users/123/posts/456" → "/api/users/{id}/posts/{id}"
pub fn pathToPattern(allocator: Allocator, path: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var iter = std.mem.splitScalar(u8, path, '/');
    var first = true;

    while (iter.next()) |segment| {
        if (!first) try result.append(allocator, '/');
        first = false;

        if (segment.len == 0) continue;

        if (isLikelyId(segment)) {
            try result.appendSlice(allocator, "{id}");
        } else {
            try result.appendSlice(allocator, segment);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Analyze collected network requests and extract API endpoints.
pub fn analyzeRequests(allocator: Allocator, collector: *const network_mod.Collector) !AnalysisResult {
    var endpoints_map = std.StringArrayHashMap(EndpointAccum).init(allocator);
    defer {
        var it = endpoints_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.pattern);
        }
        endpoints_map.deinit();
    }

    var base_url: ?[]u8 = null;
    var api_count: usize = 0;
    const total = collector.count();

    var req_it = collector.requests.iterator();
    while (req_it.next()) |entry| {
        const info = entry.value_ptr.info;

        if (!isApiRequest(info.url, info.resource_type, info.mime_type)) continue;
        api_count += 1;

        // Extract base URL from first API request
        if (base_url == null) {
            base_url = extractBaseUrl(allocator, info.url) catch null;
        }

        const path = extractPath(info.url);
        const pattern = pathToPattern(allocator, path) catch continue;

        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ info.method, pattern }) catch {
            allocator.free(pattern);
            continue;
        };

        if (endpoints_map.getPtr(key)) |accum| {
            accum.count += 1;
            if (info.status) |s| accum.last_status = s;
            allocator.free(pattern); // Already have this pattern
        } else {
            const owned_key = allocator.dupe(u8, key) catch {
                allocator.free(pattern);
                continue;
            };
            endpoints_map.put(owned_key, .{
                .method = info.method,
                .pattern = pattern, // Transfer ownership to map
                .example_url = info.url,
                .last_status = info.status,
                .mime_type = info.mime_type,
                .count = 1,
            }) catch {
                allocator.free(owned_key);
                allocator.free(pattern);
            };
        }
    }

    // Convert to Endpoint slice
    var endpoints: std.ArrayList(Endpoint) = .empty;
    defer endpoints.deinit(allocator);

    var ep_it = endpoints_map.iterator();
    while (ep_it.next()) |entry| {
        const accum = entry.value_ptr;
        endpoints.append(allocator, .{
            .method = allocator.dupe(u8, accum.method) catch continue,
            .path_pattern = allocator.dupe(u8, accum.pattern) catch continue,
            .example_url = allocator.dupe(u8, accum.example_url) catch continue,
            .status = accum.last_status,
            .mime_type = allocator.dupe(u8, accum.mime_type) catch continue,
            .count = accum.count,
        }) catch {};
    }

    return .{
        .endpoints = endpoints.toOwnedSlice(allocator) catch &.{},
        .base_url = base_url orelse allocator.dupe(u8, "") catch "",
        .total_requests = total,
        .api_requests = api_count,
        .allocator = allocator,
    };
}

const EndpointAccum = struct {
    method: []const u8, // borrowed from RequestInfo
    pattern: []const u8, // borrowed from key
    example_url: []const u8, // borrowed from RequestInfo
    last_status: ?i64,
    mime_type: []const u8,
    count: usize,
};

/// Serialize analysis result to JSON.
pub fn serializeResult(allocator: Allocator, result: *const AnalysisResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"baseUrl\":");
    try cdp.writeJsonString(writer, result.base_url);
    try writer.writeAll(",\"totalRequests\":");
    try std.fmt.format(writer, "{d}", .{result.total_requests});
    try writer.writeAll(",\"apiRequests\":");
    try std.fmt.format(writer, "{d}", .{result.api_requests});
    try writer.writeAll(",\"endpoints\":[");

    for (result.endpoints, 0..) |ep, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"method\":");
        try cdp.writeJsonString(writer, ep.method);
        try writer.writeAll(",\"path\":");
        try cdp.writeJsonString(writer, ep.path_pattern);
        try writer.writeAll(",\"exampleUrl\":");
        try cdp.writeJsonString(writer, ep.example_url);
        try writer.writeAll(",\"status\":");
        if (ep.status) |s| {
            try std.fmt.format(writer, "{d}", .{s});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"mimeType\":");
        try cdp.writeJsonString(writer, ep.mime_type);
        try writer.writeAll(",\"count\":");
        try std.fmt.format(writer, "{d}", .{ep.count});
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "isApiRequest: XHR type" {
    try testing.expect(isApiRequest("https://api.test.com/data", "XHR", ""));
}

test "isApiRequest: Fetch type" {
    try testing.expect(isApiRequest("https://api.test.com/data", "Fetch", ""));
}

test "isApiRequest: JSON mime type" {
    try testing.expect(isApiRequest("https://test.com/data", "Document", "application/json"));
}

test "isApiRequest: API path pattern" {
    try testing.expect(isApiRequest("https://test.com/api/users", "Document", "text/html"));
    try testing.expect(isApiRequest("https://test.com/v1/users", "Document", "text/html"));
    try testing.expect(isApiRequest("https://test.com/graphql", "Document", "text/html"));
}

test "isApiRequest: rejects static resources" {
    try testing.expect(!isApiRequest("https://cdn.test.com/app.js", "Script", "application/javascript"));
    try testing.expect(!isApiRequest("https://cdn.test.com/style.css", "Stylesheet", "text/css"));
    try testing.expect(!isApiRequest("https://cdn.test.com/logo.png", "Image", "image/png"));
    try testing.expect(!isApiRequest("https://cdn.test.com/font.woff2", "Font", "font/woff2"));
}

test "isApiRequest: js with query string" {
    try testing.expect(!isApiRequest("https://cdn.test.com/app.js?v=123", "Script", "application/javascript"));
}

test "extractPath: full URL" {
    try testing.expectEqualStrings("/api/users/123", extractPath("https://api.test.com/api/users/123"));
}

test "extractPath: with query string" {
    try testing.expectEqualStrings("/api/users", extractPath("https://api.test.com/api/users?page=1&limit=10"));
}

test "extractPath: with fragment" {
    try testing.expectEqualStrings("/api/data", extractPath("https://test.com/api/data#section"));
}

test "extractPath: root" {
    try testing.expectEqualStrings("/", extractPath("https://test.com/"));
}

test "extractPath: no path" {
    try testing.expectEqualStrings("/", extractPath("https://test.com"));
}

test "extractBaseUrl: normal" {
    const base = try extractBaseUrl(testing.allocator, "https://api.test.com/api/users/123?q=1");
    defer testing.allocator.free(base);
    try testing.expectEqualStrings("https://api.test.com", base);
}

test "extractBaseUrl: with port" {
    const base = try extractBaseUrl(testing.allocator, "http://localhost:3000/api/data");
    defer testing.allocator.free(base);
    try testing.expectEqualStrings("http://localhost:3000", base);
}

test "isLikelyId: numeric" {
    try testing.expect(isLikelyId("123"));
    try testing.expect(isLikelyId("42"));
    try testing.expect(isLikelyId("0"));
}

test "isLikelyId: UUID" {
    try testing.expect(isLikelyId("550e8400-e29b-41d4-a716-446655440000"));
    try testing.expect(isLikelyId("550e8400e29b41d4a716446655440000"));
}

test "isLikelyId: hex hash" {
    try testing.expect(isLikelyId("abc123def456abc0"));
    try testing.expect(isLikelyId("1234567890abcdef1234567890abcdef"));
}

test "isLikelyId: mixed alphanumeric" {
    try testing.expect(isLikelyId("user123"));
    try testing.expect(isLikelyId("item42abc"));
}

test "isLikelyId: not an ID" {
    try testing.expect(!isLikelyId("users"));
    try testing.expect(!isLikelyId("api"));
    try testing.expect(!isLikelyId("v2")); // too short
    try testing.expect(!isLikelyId(""));
    try testing.expect(!isLikelyId("posts"));
}

test "pathToPattern: no IDs" {
    const pattern = try pathToPattern(testing.allocator, "/api/users");
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("/api/users", pattern);
}

test "pathToPattern: numeric ID" {
    const pattern = try pathToPattern(testing.allocator, "/api/users/123");
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("/api/users/{id}", pattern);
}

test "pathToPattern: UUID" {
    const pattern = try pathToPattern(testing.allocator, "/api/users/550e8400-e29b-41d4-a716-446655440000/posts");
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("/api/users/{id}/posts", pattern);
}

test "pathToPattern: multiple IDs" {
    const pattern = try pathToPattern(testing.allocator, "/api/users/123/posts/456");
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("/api/users/{id}/posts/{id}", pattern);
}

test "pathToPattern: version prefix preserved" {
    const pattern = try pathToPattern(testing.allocator, "/v2/users/123");
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("/v2/users/{id}", pattern);
}

test "pathToPattern: root" {
    const pattern = try pathToPattern(testing.allocator, "/");
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("/", pattern);
}

test "serializeResult: empty" {
    var result = AnalysisResult{
        .endpoints = &.{},
        .base_url = "",
        .total_requests = 0,
        .api_requests = 0,
        .allocator = testing.allocator,
    };

    const json = try serializeResult(testing.allocator, &result);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"totalRequests\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"endpoints\":[]") != null);
    // Verify valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);

    _ = &result;
}
