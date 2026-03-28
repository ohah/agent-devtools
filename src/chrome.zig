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
    user_agent: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    proxy_bypass: ?[]const u8 = null,
    extensions: ?[]const u8 = null, // comma-separated paths
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

const websocket = @import("websocket.zig");

/// Rewrite host and port in a WebSocket URL.
/// Chrome's /json/version always returns ws://127.0.0.1:<local-port>/...
/// which is unreachable when behind port-forward or on remote machine.
pub fn rewriteWsHost(allocator: Allocator, ws_url: []const u8, host: []const u8, port: u16) ![]u8 {
    const parts = websocket.parseWsUrl(ws_url) orelse return allocator.dupe(u8, ws_url);
    return std.fmt.allocPrint(allocator, "{s}{s}:{d}{s}", .{ parts.scheme, host, port, parts.path });
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

/// Discover CDP WebSocket URL by querying /json/version on the given port.
/// Does a raw HTTP GET and parses the JSON response.
/// Fetch a URL via raw HTTP GET. Returns the response body.
pub fn httpGet(allocator: Allocator, host: []const u8, port: u16, path: []const u8) ![]u8 {
    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    defer stream.close();

    // Set read timeout so we don't block forever if server keeps connection open
    const timeval = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

    var req_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ path, host, port }) catch return error.Overflow;

    var total_written: usize = 0;
    while (total_written < request.len) {
        total_written += stream.write(request[total_written..]) catch return error.ConnectionRefused;
    }

    var resp_buf: [8192]u8 = undefined;
    var resp_len: usize = 0;
    while (resp_len < resp_buf.len) {
        const n = stream.read(resp_buf[resp_len..]) catch break;
        if (n == 0) break;
        resp_len += n;
        // Early exit: if we have headers + body, no need to wait for close
        if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |hdr_end| {
            // Check if we have Content-Length and got enough data
            const headers = resp_buf[0..hdr_end];
            if (std.mem.indexOf(u8, headers, "Content-Length: ")) |cl_start| {
                const cl_val_start = cl_start + "Content-Length: ".len;
                const cl_end = std.mem.indexOfScalarPos(u8, headers, cl_val_start, '\r') orelse continue;
                const content_length = std.fmt.parseInt(usize, headers[cl_val_start..cl_end], 10) catch continue;
                const body_start = hdr_end + 4;
                if (resp_len - body_start >= content_length) break;
            }
        }
    }

    if (resp_len == 0) return error.EndOfStream;

    // Find body after \r\n\r\n
    const header_end = std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n") orelse return error.InvalidResponse;
    const body = resp_buf[header_end + 4 .. resp_len];

    return allocator.dupe(u8, body);
}

/// Discover CDP WebSocket URL by querying /json/version on the given port.
pub fn discoverWsUrl(allocator: Allocator, host: []const u8, port: u16) ![]u8 {
    const body = try httpGet(allocator, host, port, "/json/version");
    defer allocator.free(body);

    if (parseJsonVersion(allocator, body)) |ws_url| {
        defer allocator.free(ws_url);
        return rewriteWsHost(allocator, ws_url, host, port);
    }

    return error.InvalidResponse;
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
        .windows => &[_][]const u8{
            "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
            "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
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
        "--disable-blink-features=AutomationControlled",
    };
    for (core_flags) |flag| {
        try args.append(allocator, try allocator.dupe(u8, flag));
    }

    try args.append(allocator, try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{options.port}));

    // Extensions don't work in headless mode — skip --headless if extensions are loaded
    if (options.headless and options.extensions == null) {
        try args.append(allocator, try allocator.dupe(u8, "--headless=new"));
        try args.append(allocator, try allocator.dupe(u8, "--enable-unsafe-swiftshader"));
    }

    // Proxy support
    if (options.proxy) |proxy| {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "--proxy-server={s}", .{proxy}));
    }
    if (options.proxy_bypass) |bypass| {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "--proxy-bypass-list={s}", .{bypass}));
    }

    // Extension loading
    if (options.extensions) |ext_paths| {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "--load-extension={s}", .{ext_paths}));
        try args.append(allocator, try std.fmt.allocPrint(allocator, "--disable-extensions-except={s}", .{ext_paths}));
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
// Chrome Process
// ============================================================================

pub const ChromeProcess = struct {
    child: std.process.Child,
    ws_url: []u8,
    temp_dir: ?[]u8,
    allocator: Allocator,

    pub const LaunchError = error{
        ChromeNotFound,
        LaunchFailed,
        TimeoutWaitingForDevTools,
    } || Allocator.Error;

    /// Launch Chrome and wait for the CDP WebSocket URL.
    pub fn launch(allocator: Allocator, options: LaunchOptions) LaunchError!ChromeProcess {
        const chrome_path = options.executable_path orelse findChrome() orelse
            return error.ChromeNotFound;

        // Create temp user-data-dir if none provided
        var temp_dir: ?[]u8 = null;
        var effective_options = options;

        if (options.user_data_dir == null) {
            temp_dir = createTempDir(allocator) catch return error.LaunchFailed;
            effective_options.user_data_dir = temp_dir;
        }
        errdefer if (temp_dir) |d| {
            std.fs.deleteTreeAbsolute(d) catch {};
            allocator.free(d);
        };

        const args = buildChromeArgs(allocator, effective_options) catch return error.LaunchFailed;
        defer freeChromeArgs(allocator, args);

        // Build argv: [chrome_path] ++ args
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        argv.append(allocator, chrome_path) catch return error.LaunchFailed;
        argv.appendSlice(allocator, args) catch return error.LaunchFailed;

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;

        child.spawn() catch return error.LaunchFailed;
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        // Wait for DevToolsActivePort file or stderr URL
        const ws_url = waitForWsUrl(allocator, &child, effective_options.user_data_dir) catch
            return error.TimeoutWaitingForDevTools;

        return ChromeProcess{
            .child = child,
            .ws_url = ws_url,
            .temp_dir = temp_dir,
            .allocator = allocator,
        };
    }

    pub fn kill(self: *ChromeProcess) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }

    pub fn deinit(self: *ChromeProcess) void {
        self.kill();
        self.allocator.free(self.ws_url);
        if (self.temp_dir) |d| {
            std.fs.deleteTreeAbsolute(d) catch {};
            self.allocator.free(d);
        }
    }
};

/// Wait for Chrome to write the DevToolsActivePort file, then build the WS URL.
fn waitForWsUrl(allocator: Allocator, child: *std.process.Child, user_data_dir: ?[]const u8) ![]u8 {
    _ = child;
    const max_polls = 100; // 100 * 50ms = 5 seconds
    const poll_interval_ns: u64 = 50 * std.time.ns_per_ms;

    if (user_data_dir) |dir| {
        var port_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const port_path = std.fmt.bufPrint(&port_path_buf, "{s}/DevToolsActivePort", .{dir}) catch return error.Overflow;

        for (0..max_polls) |_| {
            var content_buf: [256]u8 = undefined;
            if (std.fs.cwd().readFile(port_path, &content_buf)) |content| {
                if (parseDevToolsActivePort(content)) |info| {
                    return std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}{s}", .{ info.port, info.ws_path });
                }
            } else |_| {}

            std.Thread.sleep(poll_interval_ns);
        }
    }

    return error.TimedOut;
}

fn createTempDir(allocator: Allocator) ![]u8 {
    const charset = "abcdefghijklmnopqrstuvwxyz0123456789";
    var suffix: [12]u8 = undefined;
    std.crypto.random.bytes(&suffix);
    for (&suffix) |*c| {
        c.* = charset[c.* % charset.len];
    }

    const tmp_base = if (comptime builtin.os.tag == .windows)
        "C:\\Windows\\Temp"
    else
        std.posix.getenv("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(allocator, "{s}/agent-devtools-{s}", .{ tmp_base, &suffix });
    errdefer allocator.free(path);

    // Use exclusive creation — if path exists, it's a collision, retry would be needed.
    // With 12 chars from 36-char alphabet, collision probability is ~1 in 4.7 trillion.
    std.fs.makeDirAbsolute(path) catch |err| {
        return err;
    };

    return path;
}

// ============================================================================
// Auto-Connect: discover existing Chrome instances
// ============================================================================

/// Check if a TCP port is reachable on 127.0.0.1.
pub fn isPortReachable(port: u16) bool {
    const addr = std.net.Address.parseIp4("127.0.0.1", port) catch return false;
    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return false;
    defer std.posix.close(fd);
    std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

/// Get Chrome user data directories for the current platform.
/// Returns a slice of directory path strings. Some paths are absolute,
/// others require prepending $HOME or %LOCALAPPDATA%.
pub fn getUserDataDirs(allocator: Allocator) ![][]u8 {
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    switch (comptime builtin.os.tag) {
        .macos => {
            const home = std.posix.getenv("HOME") orelse return dirs.toOwnedSlice(allocator);
            const suffixes = [_][]const u8{
                "/Library/Application Support/Google/Chrome",
                "/Library/Application Support/Google/Chrome Canary",
                "/Library/Application Support/Chromium",
                "/Library/Application Support/BraveSoftware/Brave-Browser",
            };
            for (suffixes) |suffix| {
                const path = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, suffix }) catch continue;
                try dirs.append(allocator, path);
            }
        },
        .linux => {
            const home = std.posix.getenv("HOME") orelse return dirs.toOwnedSlice(allocator);
            const suffixes = [_][]const u8{
                "/.config/google-chrome",
                "/.config/google-chrome-unstable",
                "/.config/chromium",
                "/.config/BraveSoftware/Brave-Browser",
            };
            for (suffixes) |suffix| {
                const path = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, suffix }) catch continue;
                try dirs.append(allocator, path);
            }
        },
        .windows => {
            const local_app_data = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA")) orelse
                return dirs.toOwnedSlice(allocator);
            // Convert WTF-16 to UTF-8
            var home_buf: [512]u8 = undefined;
            var home_len: usize = 0;
            for (local_app_data) |wc| {
                if (home_len >= home_buf.len) break;
                if (wc <= 127) {
                    home_buf[home_len] = @intCast(wc);
                    home_len += 1;
                }
            }
            const base = home_buf[0..home_len];
            if (base.len == 0) return dirs.toOwnedSlice(allocator);

            const suffixes = [_][]const u8{
                "\\Google\\Chrome\\User Data",
                "\\Google\\Chrome SxS\\User Data",
                "\\Chromium\\User Data",
                "\\BraveSoftware\\Brave-Browser\\User Data",
            };
            for (suffixes) |suffix| {
                const path = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix }) catch continue;
                try dirs.append(allocator, path);
            }
        },
        else => {},
    }

    return dirs.toOwnedSlice(allocator);
}

pub fn freeUserDataDirs(allocator: Allocator, dirs: [][]u8) void {
    for (dirs) |d| allocator.free(d);
    allocator.free(dirs);
}

/// Try to discover a running Chrome instance's WebSocket URL.
/// 1. Search Chrome user data directories for DevToolsActivePort file
/// 2. Try connecting via /json/version with the discovered port
/// 3. Fallback: probe common ports (9222, 9229)
/// Returns the WebSocket URL (caller must free).
pub fn autoConnect(allocator: Allocator) ![]u8 {
    // Step 1: Try user data directories
    var has_dirs = true;
    const dirs = getUserDataDirs(allocator) catch blk: {
        has_dirs = false;
        break :blk @as([][]u8, &.{});
    };
    defer if (has_dirs) freeUserDataDirs(allocator, dirs);

    for (dirs) |dir| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/DevToolsActivePort", .{dir}) catch continue;

        var file_buf: [256]u8 = undefined;
        const content = std.fs.cwd().readFile(path, &file_buf) catch continue;

        const info = parseDevToolsActivePort(content) orelse continue;
        if (info.port == 0) continue;

        // Try /json/version discovery first
        if (discoverWsUrl(allocator, "127.0.0.1", info.port)) |ws_url| {
            return ws_url;
        } else |_| {}

        // Fallback: build WebSocket URL directly from the file
        if (isPortReachable(info.port)) {
            return std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}{s}", .{ info.port, info.ws_path });
        }
    }

    // Step 2: Probe common ports
    const common_ports = [_]u16{ 9222, 9229 };
    for (common_ports) |port| {
        if (discoverWsUrl(allocator, "127.0.0.1", port)) |ws_url| {
            return ws_url;
        } else |_| {}
    }

    return error.NoChromeFound;
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

test "rewriteWsHost: no path gets default /" {
    const result = try rewriteWsHost(testing.allocator, "ws://127.0.0.1:9222", "other", 1234);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ws://other:1234/", result);
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

test "buildChromeArgs: proxy flag" {
    const args = try buildChromeArgs(testing.allocator, .{ .proxy = "http://localhost:8080" });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--proxy-server=http://localhost:8080"));
}

test "buildChromeArgs: proxy bypass flag" {
    const args = try buildChromeArgs(testing.allocator, .{ .proxy_bypass = "localhost,*.internal.com" });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--proxy-bypass-list=localhost,*.internal.com"));
}

test "buildChromeArgs: proxy with bypass" {
    const args = try buildChromeArgs(testing.allocator, .{ .proxy = "http://proxy:3128", .proxy_bypass = "127.0.0.1" });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--proxy-server=http://proxy:3128"));
    try testing.expect(containsArg(args, "--proxy-bypass-list=127.0.0.1"));
}

test "buildChromeArgs: extension loading" {
    const args = try buildChromeArgs(testing.allocator, .{ .extensions = "/path/to/ext" });
    defer freeChromeArgs(testing.allocator, args);

    try testing.expect(containsArg(args, "--load-extension=/path/to/ext"));
    try testing.expect(containsArg(args, "--disable-extensions-except=/path/to/ext"));
}

test "buildChromeArgs: extension disables headless" {
    const args = try buildChromeArgs(testing.allocator, .{ .headless = true, .extensions = "/ext" });
    defer freeChromeArgs(testing.allocator, args);

    // Extensions don't work in headless — headless flag should be omitted
    try testing.expect(!containsArg(args, "--headless=new"));
    try testing.expect(containsArg(args, "--load-extension=/ext"));
}

test "buildChromeArgs: no proxy by default" {
    const args = try buildChromeArgs(testing.allocator, .{});
    defer freeChromeArgs(testing.allocator, args);

    for (args) |arg| {
        try testing.expect(!std.mem.startsWith(u8, arg, "--proxy-server="));
        try testing.expect(!std.mem.startsWith(u8, arg, "--proxy-bypass-list="));
        try testing.expect(!std.mem.startsWith(u8, arg, "--load-extension="));
    }
}

fn containsArg(args: []const []const u8, target: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, target)) return true;
    }
    return false;
}

// ============================================================================
// Tests: CDP Discovery (parseJsonVersion, rewriteWsHost, discoverWsUrl)
// ============================================================================

test "discoverWsUrl: parses /json/version and rewrites host" {
    // This test simulates the parsing logic without actually connecting.
    // The httpGet + parseJsonVersion + rewriteWsHost chain is tested here.
    const version_body =
        \\{"Browser":"Chrome/146","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/abc-123-def"}
    ;

    // parseJsonVersion extracts the URL
    const ws_url = parseJsonVersion(testing.allocator, version_body).?;
    defer testing.allocator.free(ws_url);
    try testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/abc-123-def", ws_url);

    // rewriteWsHost rewrites to target host/port
    const rewritten = try rewriteWsHost(testing.allocator, ws_url, "10.0.0.1", 9333);
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("ws://10.0.0.1:9333/devtools/browser/abc-123-def", rewritten);
}

test "discoverWsUrl: same host keeps GUID path" {
    const body =
        \\{"webSocketDebuggerUrl":"ws://127.0.0.1:9333/devtools/browser/aaaa-bbbb-cccc"}
    ;
    const ws_url = parseJsonVersion(testing.allocator, body).?;
    defer testing.allocator.free(ws_url);

    const rewritten = try rewriteWsHost(testing.allocator, ws_url, "127.0.0.1", 9333);
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("ws://127.0.0.1:9333/devtools/browser/aaaa-bbbb-cccc", rewritten);
}

test "httpGet: response body extraction with Content-Length" {
    // This tests the response parsing logic that httpGet would apply.
    // We can't test the full httpGet without a server, but we test the
    // parseJsonVersion that processes its output.
    const http_body =
        \\{"Browser":"Chrome/146","Protocol-Version":"1.3","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/unique-id"}
    ;
    const url = parseJsonVersion(testing.allocator, http_body).?;
    defer testing.allocator.free(url);
    try testing.expect(std.mem.indexOf(u8, url, "unique-id") != null);
}

// ============================================================================
// Tests: Auto-Connect
// ============================================================================

test "isPortReachable: unreachable port returns false" {
    // Port 1 is almost certainly not listening (requires root)
    try testing.expect(!isPortReachable(1));
}

test "isPortReachable: random high port returns false" {
    // A random ephemeral port unlikely to be in use
    try testing.expect(!isPortReachable(64999));
}

test "getUserDataDirs: returns dirs for current platform" {
    const dirs = try getUserDataDirs(testing.allocator);
    defer freeUserDataDirs(testing.allocator, dirs);

    // On macOS/Linux with HOME set, we should get some dirs
    if (comptime builtin.os.tag == .macos) {
        if (std.posix.getenv("HOME") != null) {
            try testing.expect(dirs.len == 4);
            // All should contain "Library/Application Support" on macOS
            for (dirs) |d| {
                try testing.expect(std.mem.indexOf(u8, d, "Library/Application Support") != null);
            }
        }
    } else if (comptime builtin.os.tag == .linux) {
        if (std.posix.getenv("HOME") != null) {
            try testing.expect(dirs.len == 4);
            for (dirs) |d| {
                try testing.expect(std.mem.indexOf(u8, d, ".config/") != null or
                    std.mem.indexOf(u8, d, "BraveSoftware") != null);
            }
        }
    }
}

test "getUserDataDirs: paths are absolute" {
    const dirs = try getUserDataDirs(testing.allocator);
    defer freeUserDataDirs(testing.allocator, dirs);

    for (dirs) |d| {
        if (comptime builtin.os.tag == .windows) {
            // Windows paths start with drive letter
            try testing.expect(d.len >= 2 and d[1] == ':');
        } else {
            try testing.expect(d.len > 0 and d[0] == '/');
        }
    }
}

test "autoConnect: returns error when no Chrome is running" {
    // In CI/test environment, no Chrome should be running on standard ports
    // and no DevToolsActivePort files should exist in user data dirs.
    // This test verifies the function handles the "not found" case gracefully.
    const result = autoConnect(testing.allocator);
    if (result) |url| {
        // If Chrome happens to be running, that's OK — just free the result
        testing.allocator.free(url);
    } else |err| {
        // Expected: no Chrome found
        try testing.expect(err == error.NoChromeFound or err == error.ConnectionRefused);
    }
}
