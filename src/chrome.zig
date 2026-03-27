const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");

// ============================================================================
// Chrome Process Management
// Reference: agent-browser/cli/src/native/cdp/chrome.rs
//            agent-browser/cli/src/native/cdp/discovery.rs
// ============================================================================

/// Chrome launch configuration.
pub const LaunchOptions = struct {
    headless: bool = true,
    executable_path: ?[]const u8 = null,
    port: u16 = 0, // 0 = OS assigns a free port
    user_data_dir: ?[]const u8 = null,
    window_size: struct { width: u16 = 1280, height: u16 = 720 } = .{},
    extra_args: []const []const u8 = &.{},
};

/// Result of Chrome discovery — the WebSocket URL to connect to.
pub const DiscoveryResult = struct {
    ws_url: []const u8,
    allocator: Allocator,

    pub fn deinit(self: DiscoveryResult) void {
        self.allocator.free(self.ws_url);
    }
};

// ============================================================================
// Chrome Discovery
// ============================================================================

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

/// Parse /json/version response to extract webSocketDebuggerUrl.
pub fn parseJsonVersion(allocator: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const val = parsed.value.object.get("webSocketDebuggerUrl") orelse return null;
    return switch (val) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

/// Parse /json/list response to extract first target's webSocketDebuggerUrl.
pub fn parseJsonList(allocator: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .array) return null;
    const items = parsed.value.array.items;

    // Prefer "browser" type target
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        if (obj.get("type")) |t| {
            if (t == .string and std.mem.eql(u8, t.string, "browser")) {
                if (obj.get("webSocketDebuggerUrl")) |ws| {
                    if (ws == .string) return allocator.dupe(u8, ws.string) catch null;
                }
            }
        }
    }

    // Fallback: first target with a ws URL
    for (items) |item| {
        if (item != .object) continue;
        if (item.object.get("webSocketDebuggerUrl")) |ws| {
            if (ws == .string) return allocator.dupe(u8, ws.string) catch null;
        }
    }

    return null;
}

/// Rewrite host and port in a WebSocket URL.
/// Chrome's /json/version always returns ws://127.0.0.1:<local-port>/...
/// which is unreachable when behind port-forward or on remote machine.
pub fn rewriteWsHost(allocator: Allocator, ws_url: []const u8, host: []const u8, port: u16) ![]u8 {
    // Parse: ws://HOST:PORT/path
    const prefix = if (std.mem.startsWith(u8, ws_url, "wss://")) @as(usize, 6) else if (std.mem.startsWith(u8, ws_url, "ws://")) @as(usize, 5) else return allocator.dupe(u8, ws_url);

    const scheme = ws_url[0..prefix];
    const rest = ws_url[prefix..];

    // Find path start
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

// ============================================================================
// Chrome Path Discovery
// ============================================================================

/// Find Chrome executable on the system.
pub fn findChrome() ?[]const u8 {
    if (builtin.os.tag == .macos) {
        const candidates = [_][]const u8{
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        };
        for (candidates) |path| {
            if (fileExists(path)) return path;
        }
    }

    if (builtin.os.tag == .linux) {
        const candidates = [_][]const u8{
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium-browser",
            "/usr/bin/chromium",
            "/usr/bin/brave-browser",
        };
        for (candidates) |path| {
            if (fileExists(path)) return path;
        }
    }

    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ============================================================================
// Chrome Launch Arguments
// ============================================================================

/// Build Chrome command-line arguments for automation.
pub fn buildChromeArgs(allocator: Allocator, options: LaunchOptions) ![]const []const u8 {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    // Core flags for automation
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
        try args.append(allocator, flag);
    }

    // Remote debugging port
    const port_arg = try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{options.port});
    try args.append(allocator, port_arg);

    if (options.headless) {
        try args.append(allocator, "--headless=new");
        try args.append(allocator, "--enable-unsafe-swiftshader");
    }

    // Window size
    const size_arg = try std.fmt.allocPrint(allocator, "--window-size={d},{d}", .{ options.window_size.width, options.window_size.height });
    try args.append(allocator, size_arg);

    // User data dir
    if (options.user_data_dir) |dir| {
        const dir_arg = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{dir});
        try args.append(allocator, dir_arg);
    }

    // Extra args from caller
    for (options.extra_args) |arg| {
        try args.append(allocator, arg);
    }

    return args.toOwnedSlice(allocator);
}

/// Free args returned by buildChromeArgs (frees allocated strings).
pub fn freeChromeArgs(allocator: Allocator, args: []const []const u8) void {
    for (args) |arg| {
        // Only free args we allocated (those starting with --)
        if (std.mem.startsWith(u8, arg, "--remote-debugging-port=") or
            std.mem.startsWith(u8, arg, "--window-size=") or
            std.mem.startsWith(u8, arg, "--user-data-dir="))
        {
            allocator.free(arg);
        }
    }
    allocator.free(args);
}

// ============================================================================
// Tests: DevToolsActivePort parsing
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

// ============================================================================
// Tests: /json/version parsing
// ============================================================================

test "parseJsonVersion: normal response" {
    const body =
        \\{"Browser":"Chrome/136","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/abc"}
    ;
    const url = parseJsonVersion(testing.allocator, body).?;
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/abc", url);
}

test "parseJsonVersion: missing field" {
    const body =
        \\{"Browser":"Chrome/136"}
    ;
    try testing.expect(parseJsonVersion(testing.allocator, body) == null);
}

test "parseJsonVersion: invalid JSON" {
    try testing.expect(parseJsonVersion(testing.allocator, "not json") == null);
}

test "parseJsonVersion: non-object" {
    try testing.expect(parseJsonVersion(testing.allocator, "[1,2]") == null);
}

test "parseJsonVersion: field is not string" {
    const body =
        \\{"webSocketDebuggerUrl":123}
    ;
    try testing.expect(parseJsonVersion(testing.allocator, body) == null);
}

// ============================================================================
// Tests: /json/list parsing
// ============================================================================

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
    const body =
        \\[{"type":"page","title":"Test"}]
    ;
    try testing.expect(parseJsonList(testing.allocator, body) == null);
}

test "parseJsonList: invalid JSON" {
    try testing.expect(parseJsonList(testing.allocator, "invalid") == null);
}

test "parseJsonList: not an array" {
    try testing.expect(parseJsonList(testing.allocator, "{}") == null);
}

// ============================================================================
// Tests: WebSocket URL rewriting
// ============================================================================

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

// ============================================================================
// Tests: stderr parsing
// ============================================================================

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

// ============================================================================
// Tests: Chrome path discovery
// ============================================================================

test "findChrome: returns a path or null (platform-dependent)" {
    // On CI or machines without Chrome, this returns null — that's OK
    const result = findChrome();
    if (result) |path| {
        try testing.expect(path.len > 0);
    }
}

// ============================================================================
// Tests: Chrome launch arguments
// ============================================================================

test "buildChromeArgs: default options" {
    const args = try buildChromeArgs(testing.allocator, .{});
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(args.len > 0);

    // Must contain required flags
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

    // Count occurrences of --no-first-run
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-first-run")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

fn containsArg(args: []const []const u8, target: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, target)) return true;
    }
    return false;
}
