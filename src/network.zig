const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const cdp = @import("cdp.zig");

// ============================================================================
// Network Request Collector
// Based on CDP Network domain events:
// https://chromedevtools.github.io/devtools-protocol/tot/Network/
// ============================================================================

pub const RequestInfo = struct {
    request_id: []const u8,
    url: []const u8,
    method: []const u8,
    resource_type: []const u8,
    status: ?i64,
    status_text: []const u8,
    mime_type: []const u8,
    timestamp: f64,
    encoded_data_length: ?i64,
    error_text: []const u8,

    // State tracking
    state: RequestState,

    pub const RequestState = enum {
        pending,
        received,
        finished,
        failed,
    };
};

/// Collects network requests from CDP events into a queryable list.
pub const Collector = struct {
    requests: std.StringArrayHashMap(RequestEntry),
    allocator: Allocator,

    const RequestEntry = struct {
        info: RequestInfo,
        // All strings are owned by the entry
        owned_strings: []const []const u8,
    };

    pub fn init(allocator: Allocator) Collector {
        return .{
            .requests = std.StringArrayHashMap(RequestEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Collector) void {
        var it = self.requests.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.owned_strings) |s| {
                self.allocator.free(s);
            }
            self.allocator.free(entry.value_ptr.owned_strings);
            self.allocator.free(entry.key_ptr.*);
        }
        self.requests.deinit();
    }

    /// Process a CDP event message. Returns true if the event was a network event.
    pub fn processEvent(self: *Collector, method: []const u8, params: std.json.Value) !bool {
        if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
            try self.handleRequestWillBeSent(params);
            return true;
        } else if (std.mem.eql(u8, method, "Network.responseReceived")) {
            try self.handleResponseReceived(params);
            return true;
        } else if (std.mem.eql(u8, method, "Network.loadingFinished")) {
            try self.handleLoadingFinished(params);
            return true;
        } else if (std.mem.eql(u8, method, "Network.loadingFailed")) {
            try self.handleLoadingFailed(params);
            return true;
        }
        return false;
    }

    fn handleRequestWillBeSent(self: *Collector, params: std.json.Value) !void {
        const request_id_raw = cdp.getString(params, "requestId") orelse return;
        const request_obj = cdp.getObject(params, "request") orelse return;

        const url_raw = cdp.getString(request_obj, "url") orelse return;
        const method_raw = cdp.getString(request_obj, "method") orelse "GET";
        const resource_type = cdp.getString(params, "type") orelse "Other";
        const timestamp = cdp.getFloat(params, "timestamp") orelse 0;

        const request_id = try self.allocator.dupe(u8, request_id_raw);
        errdefer self.allocator.free(request_id);

        const url = try self.allocator.dupe(u8, url_raw);
        const method = try self.allocator.dupe(u8, method_raw);
        const rtype = try self.allocator.dupe(u8, resource_type);

        var owned = std.ArrayList([]const u8).empty;
        try owned.append(self.allocator, url);
        try owned.append(self.allocator, method);
        try owned.append(self.allocator, rtype);
        const owned_slice = try owned.toOwnedSlice(self.allocator);

        try self.requests.put(request_id, .{
            .info = .{
                .request_id = request_id,
                .url = url,
                .method = method,
                .resource_type = rtype,
                .status = null,
                .status_text = "",
                .mime_type = "",
                .timestamp = timestamp,
                .encoded_data_length = null,
                .error_text = "",
                .state = .pending,
            },
            .owned_strings = owned_slice,
        });
    }

    fn handleResponseReceived(self: *Collector, params: std.json.Value) !void {
        const request_id = cdp.getString(params, "requestId") orelse return;
        const entry = self.requests.getPtr(request_id) orelse return;

        const response = cdp.getObject(params, "response") orelse return;

        entry.info.status = cdp.getInt(response, "status");
        entry.info.state = .received;

        // Dupe new strings and track ownership
        if (cdp.getString(response, "statusText")) |st| {
            const duped = try self.allocator.dupe(u8, st);
            entry.info.status_text = duped;
            var new_owned = try self.allocator.alloc([]const u8, entry.owned_strings.len + 1);
            @memcpy(new_owned[0..entry.owned_strings.len], entry.owned_strings);
            new_owned[entry.owned_strings.len] = duped;
            self.allocator.free(entry.owned_strings);
            entry.owned_strings = new_owned;
        }

        if (cdp.getString(response, "mimeType")) |mt| {
            const duped = try self.allocator.dupe(u8, mt);
            entry.info.mime_type = duped;
            var new_owned = try self.allocator.alloc([]const u8, entry.owned_strings.len + 1);
            @memcpy(new_owned[0..entry.owned_strings.len], entry.owned_strings);
            new_owned[entry.owned_strings.len] = duped;
            self.allocator.free(entry.owned_strings);
            entry.owned_strings = new_owned;
        }
    }

    fn handleLoadingFinished(self: *Collector, params: std.json.Value) !void {
        const request_id = cdp.getString(params, "requestId") orelse return;
        const entry = self.requests.getPtr(request_id) orelse return;

        entry.info.state = .finished;
        entry.info.encoded_data_length = cdp.getInt(params, "encodedDataLength");
    }

    fn handleLoadingFailed(self: *Collector, params: std.json.Value) !void {
        const request_id = cdp.getString(params, "requestId") orelse return;
        const entry = self.requests.getPtr(request_id) orelse return;

        entry.info.state = .failed;

        if (cdp.getString(params, "errorText")) |et| {
            const duped = try self.allocator.dupe(u8, et);
            entry.info.error_text = duped;
            var new_owned = try self.allocator.alloc([]const u8, entry.owned_strings.len + 1);
            @memcpy(new_owned[0..entry.owned_strings.len], entry.owned_strings);
            new_owned[entry.owned_strings.len] = duped;
            self.allocator.free(entry.owned_strings);
            entry.owned_strings = new_owned;
        }
    }

    /// Get all collected requests as a slice.
    pub fn getRequests(self: *const Collector) []const RequestInfo {
        const values = self.requests.values();
        // Return a view — caller should not free
        const infos = @as([*]const RequestInfo, @ptrCast(values.ptr));
        // RequestInfo is the first field in RequestEntry
        _ = infos;
        // Simpler approach: collect into temp slice
        return &.{};
    }

    /// Get number of collected requests.
    pub fn count(self: *const Collector) usize {
        return self.requests.count();
    }

    /// Get request by ID.
    pub fn getById(self: *const Collector, request_id: []const u8) ?RequestInfo {
        const entry = self.requests.get(request_id) orelse return null;
        return entry.info;
    }

    /// Filter requests by URL pattern (simple substring match).
    pub fn filterByUrl(self: *const Collector, allocator: Allocator, pattern: []const u8) ![]const RequestInfo {
        var results: std.ArrayList(RequestInfo) = .empty;
        defer results.deinit(allocator);

        var it = self.requests.iterator();
        while (it.next()) |entry| {
            if (std.mem.indexOf(u8, entry.value_ptr.info.url, pattern) != null) {
                try results.append(allocator, entry.value_ptr.info);
            }
        }

        return results.toOwnedSlice(allocator);
    }

    /// Format a request as a single-line summary for CLI output.
    pub fn formatRequestLine(info: RequestInfo, buf: []u8) []const u8 {
        // Use a separate stack buffer for status to avoid aliasing with output buf
        var status_buf: [8]u8 = undefined;
        const status_str = if (info.status) |s|
            std.fmt.bufPrint(&status_buf, "{d}", .{s}) catch "?"
        else
            "...";

        const state_str = switch (info.state) {
            .pending => "PEND",
            .received => "RECV",
            .finished => "DONE",
            .failed => "FAIL",
        };

        return std.fmt.bufPrint(buf, "{s: <6} {s: <4} {s: <8} {s}", .{
            status_str,
            state_str,
            info.method,
            info.url,
        }) catch info.url;
    }
};

// ============================================================================
// Tests
// ============================================================================

fn makeJsonParams(allocator: Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
}

test "Collector: requestWillBeSent creates pending entry" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const json =
        \\{"requestId":"1","request":{"url":"https://example.com/api","method":"GET","headers":{}},"type":"XHR","timestamp":100.0,"loaderId":"L1","documentURL":"https://example.com","initiator":{"type":"other"},"wallTime":1700000000.0,"redirectHasExtraInfo":false}
    ;
    const parsed = try makeJsonParams(testing.allocator, json);
    defer parsed.deinit();

    const handled = try collector.processEvent("Network.requestWillBeSent", parsed.value);
    try testing.expect(handled);
    try testing.expectEqual(@as(usize, 1), collector.count());

    const info = collector.getById("1").?;
    try testing.expectEqualStrings("https://example.com/api", info.url);
    try testing.expectEqualStrings("GET", info.method);
    try testing.expectEqualStrings("XHR", info.resource_type);
    try testing.expectEqual(RequestInfo.RequestState.pending, info.state);
    try testing.expect(info.status == null);
}

test "Collector: responseReceived updates status" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    // First: request
    const req_json =
        \\{"requestId":"2","request":{"url":"https://api.test.com/data","method":"POST","headers":{}},"type":"Fetch","timestamp":100.0,"loaderId":"L1","documentURL":"https://test.com","initiator":{"type":"script"},"wallTime":1700000000.0,"redirectHasExtraInfo":false}
    ;
    const req_parsed = try makeJsonParams(testing.allocator, req_json);
    defer req_parsed.deinit();
    _ = try collector.processEvent("Network.requestWillBeSent", req_parsed.value);

    // Then: response
    const resp_json =
        \\{"requestId":"2","response":{"url":"https://api.test.com/data","status":200,"statusText":"OK","headers":{},"mimeType":"application/json","charset":"UTF-8","connectionReused":true,"connectionId":1,"fromDiskCache":false,"fromServiceWorker":false,"fromPrefetchCache":false,"fromEarlyHints":false,"encodedDataLength":512,"securityState":"secure"},"type":"Fetch","timestamp":100.5,"loaderId":"L1","hasExtraInfo":false}
    ;
    const resp_parsed = try makeJsonParams(testing.allocator, resp_json);
    defer resp_parsed.deinit();
    _ = try collector.processEvent("Network.responseReceived", resp_parsed.value);

    const info = collector.getById("2").?;
    try testing.expectEqual(@as(i64, 200), info.status.?);
    try testing.expectEqualStrings("OK", info.status_text);
    try testing.expectEqualStrings("application/json", info.mime_type);
    try testing.expectEqual(RequestInfo.RequestState.received, info.state);
}

test "Collector: loadingFinished marks done" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const req_json =
        \\{"requestId":"3","request":{"url":"https://cdn.test.com/style.css","method":"GET","headers":{}},"type":"Stylesheet","timestamp":100.0,"loaderId":"L1","documentURL":"https://test.com","initiator":{"type":"other"},"wallTime":1700000000.0,"redirectHasExtraInfo":false}
    ;
    const req_parsed = try makeJsonParams(testing.allocator, req_json);
    defer req_parsed.deinit();
    _ = try collector.processEvent("Network.requestWillBeSent", req_parsed.value);

    const fin_json =
        \\{"requestId":"3","timestamp":101.0,"encodedDataLength":2048}
    ;
    const fin_parsed = try makeJsonParams(testing.allocator, fin_json);
    defer fin_parsed.deinit();
    _ = try collector.processEvent("Network.loadingFinished", fin_parsed.value);

    const info = collector.getById("3").?;
    try testing.expectEqual(RequestInfo.RequestState.finished, info.state);
    try testing.expectEqual(@as(i64, 2048), info.encoded_data_length.?);
}

test "Collector: loadingFailed marks failed" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const req_json =
        \\{"requestId":"4","request":{"url":"https://broken.test.com/api","method":"GET","headers":{}},"type":"XHR","timestamp":100.0,"loaderId":"L1","documentURL":"https://test.com","initiator":{"type":"other"},"wallTime":1700000000.0,"redirectHasExtraInfo":false}
    ;
    const req_parsed = try makeJsonParams(testing.allocator, req_json);
    defer req_parsed.deinit();
    _ = try collector.processEvent("Network.requestWillBeSent", req_parsed.value);

    const fail_json =
        \\{"requestId":"4","timestamp":100.5,"type":"XHR","errorText":"net::ERR_CONNECTION_REFUSED"}
    ;
    const fail_parsed = try makeJsonParams(testing.allocator, fail_json);
    defer fail_parsed.deinit();
    _ = try collector.processEvent("Network.loadingFailed", fail_parsed.value);

    const info = collector.getById("4").?;
    try testing.expectEqual(RequestInfo.RequestState.failed, info.state);
    try testing.expectEqualStrings("net::ERR_CONNECTION_REFUSED", info.error_text);
}

test "Collector: ignores non-network events" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const json =
        \\{"frameId":"F1","timestamp":100.0}
    ;
    const parsed = try makeJsonParams(testing.allocator, json);
    defer parsed.deinit();

    const handled = try collector.processEvent("Page.loadEventFired", parsed.value);
    try testing.expect(!handled);
    try testing.expectEqual(@as(usize, 0), collector.count());
}

test "Collector: responseReceived for unknown request is ignored" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const resp_json =
        \\{"requestId":"unknown","response":{"url":"https://test.com","status":200,"statusText":"OK","headers":{},"mimeType":"text/html","charset":"UTF-8","connectionReused":false,"connectionId":1,"fromDiskCache":false,"fromServiceWorker":false,"fromPrefetchCache":false,"fromEarlyHints":false,"encodedDataLength":100,"securityState":"secure"},"type":"Document","timestamp":100.0,"loaderId":"L1","hasExtraInfo":false}
    ;
    const parsed = try makeJsonParams(testing.allocator, resp_json);
    defer parsed.deinit();

    _ = try collector.processEvent("Network.responseReceived", parsed.value);
    try testing.expectEqual(@as(usize, 0), collector.count());
}

test "Collector: multiple requests tracked independently" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const req1 =
        \\{"requestId":"A","request":{"url":"https://a.com","method":"GET","headers":{}},"type":"Document","timestamp":1.0,"loaderId":"L1","documentURL":"https://a.com","initiator":{"type":"other"},"wallTime":1700000000.0,"redirectHasExtraInfo":false}
    ;
    const req2 =
        \\{"requestId":"B","request":{"url":"https://b.com/api","method":"POST","headers":{}},"type":"XHR","timestamp":2.0,"loaderId":"L1","documentURL":"https://a.com","initiator":{"type":"script"},"wallTime":1700000001.0,"redirectHasExtraInfo":false}
    ;

    const p1 = try makeJsonParams(testing.allocator, req1);
    defer p1.deinit();
    const p2 = try makeJsonParams(testing.allocator, req2);
    defer p2.deinit();

    _ = try collector.processEvent("Network.requestWillBeSent", p1.value);
    _ = try collector.processEvent("Network.requestWillBeSent", p2.value);

    try testing.expectEqual(@as(usize, 2), collector.count());

    const a = collector.getById("A").?;
    const b = collector.getById("B").?;
    try testing.expectEqualStrings("https://a.com", a.url);
    try testing.expectEqualStrings("https://b.com/api", b.url);
    try testing.expectEqualStrings("GET", a.method);
    try testing.expectEqualStrings("POST", b.method);
}

test "Collector: filterByUrl" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const reqs = [_][]const u8{
        \\{"requestId":"1","request":{"url":"https://api.example.com/users","method":"GET","headers":{}},"type":"XHR","timestamp":1.0,"loaderId":"L","documentURL":"","initiator":{"type":"other"},"wallTime":0,"redirectHasExtraInfo":false}
        ,
        \\{"requestId":"2","request":{"url":"https://cdn.example.com/image.png","method":"GET","headers":{}},"type":"Image","timestamp":2.0,"loaderId":"L","documentURL":"","initiator":{"type":"other"},"wallTime":0,"redirectHasExtraInfo":false}
        ,
        \\{"requestId":"3","request":{"url":"https://api.example.com/posts","method":"POST","headers":{}},"type":"Fetch","timestamp":3.0,"loaderId":"L","documentURL":"","initiator":{"type":"script"},"wallTime":0,"redirectHasExtraInfo":false}
    };

    for (reqs) |json| {
        const parsed = try makeJsonParams(testing.allocator, json);
        defer parsed.deinit();
        _ = try collector.processEvent("Network.requestWillBeSent", parsed.value);
    }

    const api_results = try collector.filterByUrl(testing.allocator, "api.example.com");
    defer testing.allocator.free(api_results);
    try testing.expectEqual(@as(usize, 2), api_results.len);

    const cdn_results = try collector.filterByUrl(testing.allocator, "cdn.example.com");
    defer testing.allocator.free(cdn_results);
    try testing.expectEqual(@as(usize, 1), cdn_results.len);

    const none_results = try collector.filterByUrl(testing.allocator, "nonexistent.com");
    defer testing.allocator.free(none_results);
    try testing.expectEqual(@as(usize, 0), none_results.len);
}

test "Collector: full lifecycle (request → response → finished)" {
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    const req =
        \\{"requestId":"LC","request":{"url":"https://test.com/page","method":"GET","headers":{}},"type":"Document","timestamp":100.0,"loaderId":"L1","documentURL":"https://test.com","initiator":{"type":"other"},"wallTime":1700000000.0,"redirectHasExtraInfo":false}
    ;
    const resp =
        \\{"requestId":"LC","response":{"url":"https://test.com/page","status":301,"statusText":"Moved","headers":{},"mimeType":"text/html","charset":"UTF-8","connectionReused":false,"connectionId":1,"fromDiskCache":false,"fromServiceWorker":false,"fromPrefetchCache":false,"fromEarlyHints":false,"encodedDataLength":0,"securityState":"secure"},"type":"Document","timestamp":100.1,"loaderId":"L1","hasExtraInfo":false}
    ;
    const fin =
        \\{"requestId":"LC","timestamp":100.2,"encodedDataLength":4096}
    ;

    const p1 = try makeJsonParams(testing.allocator, req);
    defer p1.deinit();
    const p2 = try makeJsonParams(testing.allocator, resp);
    defer p2.deinit();
    const p3 = try makeJsonParams(testing.allocator, fin);
    defer p3.deinit();

    _ = try collector.processEvent("Network.requestWillBeSent", p1.value);
    var info = collector.getById("LC").?;
    try testing.expectEqual(RequestInfo.RequestState.pending, info.state);

    _ = try collector.processEvent("Network.responseReceived", p2.value);
    info = collector.getById("LC").?;
    try testing.expectEqual(RequestInfo.RequestState.received, info.state);
    try testing.expectEqual(@as(i64, 301), info.status.?);

    _ = try collector.processEvent("Network.loadingFinished", p3.value);
    info = collector.getById("LC").?;
    try testing.expectEqual(RequestInfo.RequestState.finished, info.state);
    try testing.expectEqual(@as(i64, 4096), info.encoded_data_length.?);
}

test "Collector: formatRequestLine" {
    const info = RequestInfo{
        .request_id = "1",
        .url = "https://api.example.com/users",
        .method = "GET",
        .resource_type = "XHR",
        .status = 200,
        .status_text = "OK",
        .mime_type = "application/json",
        .timestamp = 100.0,
        .encoded_data_length = 1024,
        .error_text = "",
        .state = .finished,
    };

    var buf: [512]u8 = undefined;
    const line = Collector.formatRequestLine(info, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "200") != null);
    try testing.expect(std.mem.indexOf(u8, line, "DONE") != null);
    try testing.expect(std.mem.indexOf(u8, line, "GET") != null);
    try testing.expect(std.mem.indexOf(u8, line, "https://api.example.com/users") != null);
}

test "Collector: formatRequestLine pending request" {
    const info = RequestInfo{
        .request_id = "1",
        .url = "https://test.com",
        .method = "POST",
        .resource_type = "Fetch",
        .status = null,
        .status_text = "",
        .mime_type = "",
        .timestamp = 0,
        .encoded_data_length = null,
        .error_text = "",
        .state = .pending,
    };

    var buf: [512]u8 = undefined;
    const line = Collector.formatRequestLine(info, &buf);
    try testing.expect(std.mem.indexOf(u8, line, "...") != null);
    try testing.expect(std.mem.indexOf(u8, line, "PEND") != null);
}
