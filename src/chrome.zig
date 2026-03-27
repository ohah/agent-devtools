const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");
const cdp = @import("cdp.zig");

// Reference: agent-browser/cli/src/native/cdp/chrome.rs
//            agent-browser/cli/src/native/cdp/discovery.rs

pub const LaunchOptions = struct {
    headless: bool = true,
    executable_path: ?[]const u8 = null,
    port: u16 = 0, // 0 = OS assigns a free port
    user_data_dir: ?[]const u8 = null,
    window_size: struct { width: u16 = 1280, height: u16 = 720 } = .{},
    extra_args: []const []const u8 = &.{},
};

/// Parse DevToolsActivePort file written by Chrome into user-data-dir.
/// Format: line 1 = port, line 2 = WebSocket path
pub fn parseDevToolsActivePort(content: []const u8) ?struct { port: u16, ws_path: []const u8 } {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    const port_str = std.mem.trim(u8, line_iter.next() orelse return null, &std.ascii.whitespace);
    if (port_str.len == 0) return null;

    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    const ws_path = if (line_iter.next()) |line|
        std.mem.trim(u8, line, &std.ascii.whitespace)
    else
        "/devtools/browser";

    if (ws_path.len == 0) return .{ .port = port, .ws_path = "/devtools/browser" };

    return .{ .port = port, .ws_path = ws_path };
}

/// Extract webSocketDebuggerUrl from a parsed JSON object, duping the string.
fn extractWsUrl(allocator: Allocator, obj: std.json.Value) ?[]const u8 {
    const url = cdp.getString(obj, "webSocketDebuggerUrl") orelse return null;
    return allocator.dupe(u8, url) catch null;
}

/// Parse /json/version response to extract webSocketDebuggerUrl.
pub fn parseJsonVersion(allocator: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    return extractWsUrl(allocator, parsed.value);
}

/// Parse /json/list response to extract first target's webSocketDebuggerUrl.
/// Prefers targets with type "browser".
pub fn parseJsonList(allocator: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .array) return null;
    const items = parsed.value.array.items;

    for (items) |item| {
        const type_str = cdp.getString(item, "type") orelse continue;
        if (std.mem.eql(u8, type_str, "browser")) {
            if (extractWsUrl(allocator, item)) |url| return url;
        }
    }

    for (items) |item| {
        if (extractWsUrl(allocator, item)) |url| return url;
    }

    return null;
}

/// Rewrite host and port in a WebSocket URL.
/// Chrome's /json/version always returns ws://127.0.0.1:<local-port>/...
/// which is unreachable when behind port-forward or on remote machine.
pub fn rewriteWsHost(allocator: Allocator, ws_url: []const u8, host: []const u8, port: u16) ![]u8 {
    const prefix: usize = if (std.mem.startsWith(u8, ws_url, "wss://"))
        6
    else if (std.mem.startsWith(u8, ws_url, "ws://"))
        5
    else
        return allocator.dupe(u8, ws_url);

    const scheme = ws_url[0..prefix];
    const rest = ws_url[prefix..];
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const path = rest[path_start..];

    return std.fmt.allocPrint(allocator, "{s}{s}:{d}{s}", .{ scheme, host, port, path });
}

/// Extract WebSocket debugger URL from stderr line.
/// Chrome prints "DevTools listening on ws://..." to stderr.
pub fn parseStderrForWsUrl(line: []const u8) ?[]const u8 {
    const prefix = "DevTools listening on ";
    if (std.mem.startsWith(u8, line, prefix)) {
        return std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace);
    }
    return null;
}

/// Find Chrome executable on the system.
pub fn findChrome() ?[]const u8 {
    const candidates = switch (builtin.os.tag) {
        .macos => &[_][]const u8{
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        },
        .linux => &[_][]const u8{
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium-browser",
            "/usr/bin/chromium",
            "/usr/bin/brave-browser",
        },
        else => return null,
    };

    for (candidates) |path| {
        std.fs.cwd().access(path, .{}) catch continue;
        return path;
    }
    return null;
}

/// Build Chrome command-line arguments for automation.
/// All returned strings are allocator-owned — free with `freeChromeArgs`.
pub fn buildChromeArgs(allocator: Allocator, options: LaunchOptions) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    const core_flags = [_][]const u8{
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-backgrounding-occluded-windows",
        "--disable-component-update",
        "--disable-default-apps",
        "--disable-hang-monitor",
        "--disable-popup-blocking",
        "--disable-prompt-on-repost",
        "--disable-sync",
        "--disable-features=Translate",
        "--enable-features=NetworkService,NetworkServiceInProcess",
        "--metrics-recording-only",
        "--password-store=basic",
        "--use-mock-keychain",
    };
    for (core_flags) |flag| {
        try args.append(allocator, try allocator.dupe(u8, flag));
    }

    try args.append(allocator, try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{options.port}));

    if (options.headless) {
        try args.append(allocator, try allocator.dupe(u8, "--headless=new"));
        try args.append(allocator, try allocator.dupe(u8, "--enable-unsafe-swiftshader"));
    }

    try args.append(allocator, try std.fmt.allocPrint(allocator, "--window-size={d},{d}", .{ options.window_size.width, options.window_size.height }));

    if (options.user_data_dir) |dir| {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{dir}));
    }

    for (options.extra_args) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    return args.toOwnedSlice(allocator);
}

/// Free args returned by buildChromeArgs. All strings are uniformly owned.
pub fn freeChromeArgs(allocator: Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

// ============================================================================
// Tests
// ============================================================================

test "parseDevToolsActivePort: normal format" {
    const content = "9222\n/devtools/browser/abc-123\n";
    const result = parseDevToolsActivePort(content).?;
    try testing.expectEqual(@as(u16, 9222), result.port);
    try testing.expectEqualStrings("/devtools/browser/abc-123", result.ws_path);
}

test "parseDevToolsActivePort: port only (no ws path)" {
    const content = "9222\n";
    const result = parseDevToolsActivePort(content).?;
    try testing.expectEqual(@as(u16, 9222), result.port);
    try testing.expectEqualStrings("/devtools/browser", result.ws_path);
}

test "parseDevToolsActivePort: port only no newline" {
    const content = "9222";
    const result = parseDevToolsActivePort(content).?;
    try testing.expectEqual(@as(u16, 9222), result.port);
}

test "parseDevToolsActivePort: with whitespace" {
    const content = "  9222  \n  /devtools/browser/xyz  \n";
    const result = parseDevToolsActivePort(content).?;
    try testing.expectEqual(@as(u16, 9222), result.port);
    try testing.expectEqualStrings("/devtools/browser/xyz", result.ws_path);
}

test "parseDevToolsActivePort: empty ws path line falls back" {
    const content = "9222\n\n";
    const result = parseDevToolsActivePort(content).?;
    try testing.expectEqualStrings("/devtools/browser", result.ws_path);
}

test "parseDevToolsActivePort: empty content" {
    try testing.expect(parseDevToolsActivePort("") == null);
}

test "parseDevToolsActivePort: non-numeric port" {
    try testing.expect(parseDevToolsActivePort("abc\n/devtools") == null);
}

test "parseDevToolsActivePort: port 0" {
    const result = parseDevToolsActivePort("0\n/path").?;
    try testing.expectEqual(@as(u16, 0), result.port);
}

test "parseDevToolsActivePort: port overflow" {
    try testing.expect(parseDevToolsActivePort("99999\n/path") == null);
}

test "parseJsonVersion: normal response" {
    const body =
        \\{"Browser":"Chrome/136","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/abc"}
    ;
    const url = parseJsonVersion(testing.allocator, body).?;
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/abc", url);
}

test "parseJsonVersion: missing field" {
    try testing.expect(parseJsonVersion(testing.allocator,
        \\{"Browser":"Chrome/136"}
    ) == null);
}

test "parseJsonVersion: invalid JSON" {
    try testing.expect(parseJsonVersion(testing.allocator, "not json") == null);
}

test "parseJsonVersion: non-object" {
    try testing.expect(parseJsonVersion(testing.allocator, "[1,2]") == null);
}

test "parseJsonVersion: field is not string" {
    try testing.expect(parseJsonVersion(testing.allocator,
        \\{"webSocketDebuggerUrl":123}
    ) == null);
}

test "parseJsonList: prefers browser type target" {
    const body =
        \\[{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/1"},{"type":"browser","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/abc"}]
    ;
    const url = parseJsonList(testing.allocator, body).?;
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/abc", url);
}

test "parseJsonList: falls back to first target" {
    const body =
        \\[{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/1"}]
    ;
    const url = parseJsonList(testing.allocator, body).?;
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/1", url);
}

test "parseJsonList: empty array" {
    try testing.expect(parseJsonList(testing.allocator, "[]") == null);
}

test "parseJsonList: no ws URL in targets" {
    try testing.expect(parseJsonList(testing.allocator,
        \\[{"type":"page","title":"Test"}]
    ) == null);
}

test "parseJsonList: invalid JSON" {
    try testing.expect(parseJsonList(testing.allocator, "invalid") == null);
}

test "parseJsonList: not an array" {
    try testing.expect(parseJsonList(testing.allocator, "{}") == null);
}

test "rewriteWsHost: replaces host and port" {
    const result = try rewriteWsHost(testing.allocator, "ws://127.0.0.1:9222/devtools/browser/abc", "10.0.0.1", 9333);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ws://10.0.0.1:9333/devtools/browser/abc", result);
}

test "rewriteWsHost: preserves wss scheme" {
    const result = try rewriteWsHost(testing.allocator, "wss://localhost:443/devtools/browser/abc", "remote.host", 8443);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("wss://remote.host:8443/devtools/browser/abc", result);
}

test "rewriteWsHost: no path" {
    const result = try rewriteWsHost(testing.allocator, "ws://127.0.0.1:9222", "other", 1234);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ws://other:1234", result);
}

test "rewriteWsHost: non-ws URL returned as-is" {
    const result = try rewriteWsHost(testing.allocator, "http://example.com", "host", 80);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("http://example.com", result);
}

test "rewriteWsHost: root path" {
    const result = try rewriteWsHost(testing.allocator, "ws://127.0.0.1:9222/", "host", 80);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ws://host:80/", result);
}

test "parseStderrForWsUrl: valid line" {
    const url = parseStderrForWsUrl("DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc");
    try testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/abc", url.?);
}

test "parseStderrForWsUrl: with trailing whitespace" {
    const url = parseStderrForWsUrl("DevTools listening on ws://127.0.0.1:9222/path  \n");
    try testing.expectEqualStrings("ws://127.0.0.1:9222/path", url.?);
}

test "parseStderrForWsUrl: unrelated line" {
    try testing.expect(parseStderrForWsUrl("[0101/000000:ERROR] something") == null);
}

test "parseStderrForWsUrl: empty" {
    try testing.expect(parseStderrForWsUrl("") == null);
}

test "findChrome: returns a path or null (platform-dependent)" {
    const result = findChrome();
    if (result) |path| {
        try testing.expect(path.len > 0);
    }
}

test "buildChromeArgs: default options" {
    const args = try buildChromeArgs(testing.allocator, .{});
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(args.len > 0);
    try testing.expect(containsArg(args, "--no-first-run"));
    try testing.expect(containsArg(args, "--headless=new"));
    try testing.expect(containsArg(args, "--remote-debugging-port=0"));
    try testing.expect(containsArg(args, "--window-size=1280,720"));
}

test "buildChromeArgs: headed mode" {
    const args = try buildChromeArgs(testing.allocator, .{ .headless = false });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(!containsArg(args, "--headless=new"));
    try testing.expect(!containsArg(args, "--enable-unsafe-swiftshader"));
}

test "buildChromeArgs: custom port" {
    const args = try buildChromeArgs(testing.allocator, .{ .port = 9222 });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--remote-debugging-port=9222"));
}

test "buildChromeArgs: custom user data dir" {
    const args = try buildChromeArgs(testing.allocator, .{ .user_data_dir = "/tmp/test-profile" });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--user-data-dir=/tmp/test-profile"));
}

test "buildChromeArgs: custom window size" {
    const args = try buildChromeArgs(testing.allocator, .{ .window_size = .{ .width = 800, .height = 600 } });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--window-size=800,600"));
}

test "buildChromeArgs: extra args appended" {
    const extra = [_][]const u8{ "--no-sandbox", "--disable-gpu" };
    const args = try buildChromeArgs(testing.allocator, .{ .extra_args = &extra });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--no-sandbox"));
    try testing.expect(containsArg(args, "--disable-gpu"));
}

test "buildChromeArgs: no duplicate flags" {
    const args = try buildChromeArgs(testing.allocator, .{});
    defer freeChromeArgs(testing.allocator, args);

    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-first-run")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "buildChromeArgs: extra args with same prefix as core args are safe" {
    // Regression test: extra_args with matching prefixes must not cause double-free
    const extra = [_][]const u8{ "--remote-debugging-port=9222", "--window-size=800,600" };
    const args = try buildChromeArgs(testing.allocator, .{ .extra_args = &extra });
    defer freeChromeArgs(testing.allocator, args);

    // Both the core and extra versions exist (duped independently)
    try testing.expect(containsArg(args, "--remote-debugging-port=0"));
    try testing.expect(containsArg(args, "--remote-debugging-port=9222"));
}

fn containsArg(args: []const []const u8, target: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, target)) return true;
    }
    return false;
}
