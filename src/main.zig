const std = @import("std");
const agent = @import("agent_devtools");
const chrome = agent.chrome;
const cdp = agent.cdp;
const websocket = agent.websocket;
const network = agent.network;

const version = "0.1.0";

pub fn main() void {
    var args_iter = std.process.args();
    _ = args_iter.next();

    const command = args_iter.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        write("agent-devtools {s}\n", .{version});
    } else if (std.mem.eql(u8, command, "find-chrome")) {
        if (chrome.findChrome()) |path| {
            write("{s}\n", .{path});
        } else {
            write("Chrome not found.\n", .{});
        }
    } else if (std.mem.eql(u8, command, "chrome-args")) {
        runChromeArgs();
    } else if (std.mem.eql(u8, command, "network")) {
        const subcmd = args_iter.next() orelse "list";
        const url = args_iter.next();
        runNetwork(subcmd, url);
    } else if (isPlannedCommand(command)) {
        writeErr("{s}: not yet implemented\n", .{command});
        std.process.exit(1);
    } else {
        writeErr("Unknown command: {s}\nRun 'agent-devtools --help' for usage.\n", .{command});
        std.process.exit(1);
    }
}

fn runChromeArgs() void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    const args = chrome.buildChromeArgs(allocator, .{}) catch {
        writeErr("Failed to build Chrome args\n", .{});
        std.process.exit(1);
    };
    defer chrome.freeChromeArgs(allocator, args);

    for (args) |arg| write("{s}\n", .{arg});
}

fn runNetwork(subcmd: []const u8, url: ?[]const u8) void {
    if (std.mem.eql(u8, subcmd, "list")) {
        runNetworkList(url);
    } else if (std.mem.eql(u8, subcmd, "help")) {
        write(
            \\Usage: agent-devtools network <subcommand> [url]
            \\
            \\Subcommands:
            \\  list [url]    Navigate to URL and list all network requests
            \\  help          Show this help
            \\
        , .{});
    } else {
        writeErr("Unknown network subcommand: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

fn runNetworkList(url_opt: ?[]const u8) void {
    const target_url = url_opt orelse {
        writeErr("Usage: agent-devtools network list <url>\n", .{});
        std.process.exit(1);
    };

    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    writeErr("Launching Chrome...\n", .{});

    var chrome_proc = chrome.ChromeProcess.launch(allocator, .{}) catch |err| {
        writeErr("Failed to launch Chrome: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer chrome_proc.deinit();

    writeErr("Connecting to CDP...\n", .{});

    var ws = websocket.Client.connect(allocator, chrome_proc.ws_url) catch |err| {
        writeErr("WebSocket connection failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ws.close();

    // Set 3-second read timeout so we don't block forever
    ws.setReadTimeout(3000);

    var cmd_id = cdp.CommandId.init();

    // Create a new page target and attach to it
    // Browser-level WS only delivers events if we attach to a page session
    const create_target_cmd = cdp.serializeCommand(
        allocator,
        cmd_id.next(),
        "Target.createTarget",
        \\{"url":"about:blank"}
    ,
        null,
    ) catch return;
    sendCdpCommand(&ws, allocator, create_target_cmd);

    // Read response to get targetId
    ws.setReadTimeout(5000);
    var session_id: ?[]const u8 = null;
    defer if (session_id) |s| allocator.free(s);

    // Process responses to get targetId and attach
    var target_id: ?[]const u8 = null;
    defer if (target_id) |t| allocator.free(t);

    for (0..20) |_| {
        const msg_data = ws.recvMessage() catch break;
        defer allocator.free(msg_data);

        const parsed = cdp.parseMessage(allocator, msg_data) catch continue;
        defer parsed.parsed.deinit();

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |result| {
                // Target.createTarget response: {"targetId":"..."}
                if (cdp.getString(result, "targetId")) |tid| {
                    target_id = allocator.dupe(u8, tid) catch null;
                    break;
                }
                // Target.attachToTarget response: {"sessionId":"..."}
                if (cdp.getString(result, "sessionId")) |sid| {
                    session_id = allocator.dupe(u8, sid) catch null;
                    break;
                }
            }
        }
    }

    // Attach to the target with flatten mode
    if (target_id) |tid| {
        const attach_cmd = cdp.targetAttachToTarget(allocator, cmd_id.next(), tid, true) catch return;
        sendCdpCommand(&ws, allocator, attach_cmd);

        for (0..20) |_| {
            const msg_data = ws.recvMessage() catch break;
            defer allocator.free(msg_data);

            const parsed = cdp.parseMessage(allocator, msg_data) catch continue;
            defer parsed.parsed.deinit();

            if (parsed.message.isResponse()) {
                if (parsed.message.result) |result| {
                    if (cdp.getString(result, "sessionId")) |sid| {
                        session_id = allocator.dupe(u8, sid) catch null;
                        break;
                    }
                }
            }
        }
    }

    // Enable Network + Page on the page session, wait for acks, then navigate
    sendCdpCommand(&ws, allocator, cdp.networkEnable(allocator, cmd_id.next(), session_id) catch return);
    sendCdpCommand(&ws, allocator, cdp.pageEnable(allocator, cmd_id.next(), session_id) catch return);

    // Wait for enable responses before navigating
    for (0..10) |_| {
        const msg_data = ws.recvMessage() catch break;
        allocator.free(msg_data);
    }

    writeErr("Navigating to {s}...\n", .{target_url});
    sendCdpCommand(&ws, allocator, cdp.pageNavigate(allocator, cmd_id.next(), target_url, session_id) catch return);

    var collector = network.Collector.init(allocator);
    defer collector.deinit();

    ws.setReadTimeout(3000);

    var page_loaded = false;
    const max_messages = 1000;
    var msg_count: usize = 0;

    while (msg_count < max_messages) : (msg_count += 1) {
        const msg_data = ws.recvMessage() catch break;
        defer allocator.free(msg_data);

        const parsed = cdp.parseMessage(allocator, msg_data) catch continue;
        defer parsed.parsed.deinit();

        if (parsed.message.isEvent()) {
            if (parsed.message.method) |method| {
                if (parsed.message.params) |params| {
                    _ = collector.processEvent(method, params) catch {};
                }
                if (std.mem.eql(u8, method, "Page.loadEventFired")) {
                    page_loaded = true;
                    ws.setReadTimeout(1000);
                }
            }
        }
    }

    // Output results to stdout
    write("{d} requests captured:\n\n", .{collector.count()});

    var it = collector.requests.iterator();
    while (it.next()) |entry| {
        var line_buf: [1024]u8 = undefined;
        const line = network.Collector.formatRequestLine(entry.value_ptr.info, &line_buf);
        write("{s}\n", .{line});
    }
}

fn sendCdpCommand(ws: *websocket.Client, allocator: std.mem.Allocator, cmd: []u8) void {
    defer allocator.free(cmd);
    ws.sendText(cmd) catch {};
}

fn isPlannedCommand(cmd: []const u8) bool {
    const planned = [_][]const u8{ "analyze", "intercept", "record", "replay", "diff" };
    for (planned) |p| {
        if (std.mem.eql(u8, cmd, p)) return true;
    }
    return false;
}

fn write(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = stdout.write(msg) catch {};
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn printUsage() void {
    write(
        \\agent-devtools - Browser DevTools CLI for AI agents
        \\
        \\Usage: agent-devtools <command> [options]
        \\
        \\Commands:
        \\  find-chrome           Find Chrome executable on the system
        \\  chrome-args           Print Chrome launch arguments
        \\  network list <url>    Navigate to URL and list network requests
        \\  network help          Show network subcommand help
        \\
        \\  (Coming soon)
        \\  analyze <url>         Reverse-engineer web app API schema
        \\  intercept             Intercept and modify network requests
        \\  record <name>         Record a browsing flow
        \\  replay <name>         Replay and compare a recorded flow
        \\  diff <baseline>       Compare against baseline
        \\
        \\Options:
        \\  -h, --help            Show this help
        \\  -v, --version         Show version
        \\
    , .{});
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, version, ".") != null);
}

test "isPlannedCommand: recognizes planned commands" {
    try std.testing.expect(isPlannedCommand("analyze"));
    try std.testing.expect(isPlannedCommand("intercept"));
    try std.testing.expect(isPlannedCommand("record"));
    try std.testing.expect(isPlannedCommand("replay"));
    try std.testing.expect(isPlannedCommand("diff"));
}

test "isPlannedCommand: rejects unknown and implemented commands" {
    try std.testing.expect(!isPlannedCommand("bogus"));
    try std.testing.expect(!isPlannedCommand(""));
    try std.testing.expect(!isPlannedCommand("--help"));
    try std.testing.expect(!isPlannedCommand("network")); // now implemented
}
