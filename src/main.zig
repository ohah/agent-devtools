const std = @import("std");
const agent = @import("agent_devtools");
const chrome = agent.chrome;
const cdp = agent.cdp;
const websocket = agent.websocket;
const network = agent.network;
const daemon = agent.daemon;

const Allocator = std.mem.Allocator;
const version = "0.1.0";

pub fn main() void {
    if (std.posix.getenv("AGENT_DEVTOOLS_DAEMON")) |_| {
        runDaemon();
        return;
    }

    var args_iter = std.process.args();
    _ = args_iter.next();

    // Parse --session flag (can appear before command)
    var session: []const u8 = "default";
    var command: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--session=")) {
            session = arg["--session=".len..];
        } else if (command == null) {
            command = arg;
            break;
        }
    }

    const cmd = command orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        write("agent-devtools {s}\n", .{version});
    } else if (std.mem.eql(u8, cmd, "find-chrome")) {
        if (chrome.findChrome()) |path| {
            write("{s}\n", .{path});
        } else {
            write("Chrome not found.\n", .{});
        }
    } else if (std.mem.eql(u8, cmd, "open")) {
        const url = args_iter.next() orelse {
            writeErr("Usage: agent-devtools open <url>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "open", url, null);
    } else if (std.mem.eql(u8, cmd, "network")) {
        const subcmd = args_iter.next() orelse "list";
        if (std.mem.eql(u8, subcmd, "list")) {
            const pattern = args_iter.next();
            sendAction(session, "network_list", null, pattern);
        } else if (std.mem.eql(u8, subcmd, "help")) {
            write(
                \\Usage: agent-devtools network <subcommand>
                \\
                \\Subcommands:
                \\  list [pattern]    List captured network requests (optional URL filter)
                \\  help              Show this help
                \\
            , .{});
        } else {
            writeErr("Unknown network subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "close")) {
        sendAction(session, "close", null, null);
    } else if (isPlannedCommand(cmd)) {
        writeErr("{s}: not yet implemented\n", .{cmd});
        std.process.exit(1);
    } else {
        writeErr("Unknown command: {s}\nRun 'agent-devtools --help' for usage.\n", .{cmd});
        std.process.exit(1);
    }
}

// ============================================================================
// CLI → Daemon Communication
// ============================================================================

fn sendAction(session: []const u8, action: []const u8, url: ?[]const u8, pattern: ?[]const u8) void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    // Ensure daemon is running
    const started = daemon.ensureDaemon(allocator, session) catch |err| {
        writeErr("Failed to start daemon: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (started) {
        writeErr("Started daemon (session: {s})\n", .{session});
    }

    // Connect and send command
    var client = daemon.SocketClient.connect(session) catch |err| {
        writeErr("Failed to connect to daemon: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.close();

    const req = daemon.serializeRequest(allocator, .{
        .id = "1",
        .action = action,
        .url = url,
        .pattern = pattern,
    }) catch {
        writeErr("Failed to serialize request\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(req);

    client.send(req) catch |err| {
        writeErr("Failed to send command: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Read response
    var recv_buf: [65536]u8 = undefined;
    const response_line = client.recvLine(&recv_buf) catch |err| {
        writeErr("Failed to read response: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const resp = daemon.parseResponse(allocator, response_line) catch {
        // Raw output if not valid JSON
        write("{s}\n", .{response_line});
        return;
    };
    defer daemon.freeResponse(allocator, resp);

    if (resp.success) {
        if (resp.data) |data| {
            write("{s}\n", .{data});
        } else {
            write("OK\n", .{});
        }
    } else {
        writeErr("Error: {s}\n", .{resp.@"error" orelse "unknown error"});
        std.process.exit(1);
    }
}

// ============================================================================
// Daemon Mode
// ============================================================================

fn runDaemon() void {
    const session = std.posix.getenv("AGENT_DEVTOOLS_SESSION") orelse "default";

    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    // Launch Chrome
    var chrome_proc = chrome.ChromeProcess.launch(allocator, .{}) catch |err| {
        std.debug.print("Daemon: Chrome launch failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer chrome_proc.deinit();

    // Connect to Chrome via WebSocket
    var ws = websocket.Client.connect(allocator, chrome_proc.ws_url) catch |err| {
        std.debug.print("Daemon: WebSocket failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer ws.close();

    // Create page target and attach
    var cmd_id = cdp.CommandId.init();
    const create_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Target.createTarget",
        \\{"url":"about:blank"}
    , null) catch return;
    ws.sendText(create_cmd) catch return;
    allocator.free(create_cmd);

    ws.setReadTimeout(5000);

    var session_id: ?[]u8 = null;
    defer if (session_id) |s| allocator.free(s);

    for (0..20) |_| {
        const msg = ws.recvMessage() catch break;
        defer allocator.free(msg);
        const parsed = cdp.parseMessage(allocator, msg) catch continue;
        defer parsed.parsed.deinit();

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |result| {
                if (cdp.getString(result, "targetId")) |tid| {
                    const attach = cdp.targetAttachToTarget(allocator, cmd_id.next(), tid, true) catch continue;
                    ws.sendText(attach) catch {};
                    allocator.free(attach);
                } else if (cdp.getString(result, "sessionId")) |sid| {
                    session_id = allocator.dupe(u8, sid) catch null;
                    break;
                }
            }
        }
    }

    if (session_id == null) {
        std.debug.print("Daemon: Failed to attach to page target\n", .{});
        return;
    }

    const net_enable = cdp.networkEnable(allocator, cmd_id.next(), session_id) catch return;
    ws.sendText(net_enable) catch return;
    allocator.free(net_enable);

    const page_enable = cdp.pageEnable(allocator, cmd_id.next(), session_id) catch return;
    ws.sendText(page_enable) catch return;
    allocator.free(page_enable);

    // Drain enable responses
    for (0..10) |_| {
        const msg = ws.recvMessage() catch break;
        allocator.free(msg);
    }

    // Start network collector
    var collector = network.Collector.init(allocator);
    defer collector.deinit();

    // Listen on Unix socket for CLI commands
    var server = daemon.SocketServer.listen(session) catch |err| {
        std.debug.print("Daemon: Socket listen failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer server.close();

    // Set read timeout on WebSocket so we can poll for socket clients
    ws.setReadTimeout(100);

    // Set accept timeout once (100ms)
    const timeval = std.posix.timeval{ .sec = 0, .usec = 100_000 };
    std.posix.setsockopt(server.fd, std.posix.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

    var running = true;
    var cdp_fail_count: usize = 0;

    while (running) {
        const drained = drainCdpEvents(&ws, allocator, &collector);
        if (drained == 0) {
            cdp_fail_count += 1;
        } else {
            cdp_fail_count = 0;
        }

        // Chrome crash detection: 30 consecutive failures (~3 seconds)
        if (cdp_fail_count > 30) {
            std.debug.print("Daemon: Chrome connection lost, shutting down\n", .{});
            break;
        }

        if (server.accept()) |client_fd| {
            defer std.posix.close(client_fd);

            var req_buf: [4096]u8 = undefined;
            var req_len: usize = 0;
            while (req_len < req_buf.len) {
                const n = std.posix.read(client_fd, req_buf[req_len..]) catch break;
                if (n == 0) break;
                req_len += n;
                if (std.mem.indexOfScalar(u8, req_buf[0..req_len], '\n') != null) break;
            }

            if (req_len > 0) {
                const resp = handleCommand(allocator, req_buf[0..req_len], &ws, &collector, &cmd_id, session_id, &running);
                defer allocator.free(resp);
                _ = std.posix.write(client_fd, resp) catch {};
            }
        } else |_| {}
    }
}

/// Drain pending CDP events. Returns number of messages processed.
fn drainCdpEvents(ws: *websocket.Client, allocator: Allocator, collector: *network.Collector) usize {
    var count: usize = 0;
    for (0..50) |_| {
        const msg = ws.recvMessage() catch return count;
        defer allocator.free(msg);
        count += 1;

        const parsed = cdp.parseMessage(allocator, msg) catch continue;
        defer parsed.parsed.deinit();

        if (parsed.message.isEvent()) {
            if (parsed.message.method) |method| {
                if (parsed.message.params) |params| {
                    _ = collector.processEvent(method, params) catch {};
                }
            }
        }
    }
    return count;
}

const error_fallback = "{\"success\":false,\"error\":\"internal error\"}\n";

fn respondOk(allocator: Allocator) []u8 {
    return daemon.serializeResponse(allocator, .{ .success = true }) catch
        allocator.dupe(u8, "{\"success\":true}\n") catch @constCast(error_fallback);
}

fn respondErr(allocator: Allocator, msg: []const u8) []u8 {
    return daemon.serializeResponse(allocator, .{ .success = false, .@"error" = msg }) catch
        allocator.dupe(u8, error_fallback) catch @constCast(error_fallback);
}

fn handleCommand(
    allocator: Allocator,
    line: []const u8,
    ws: *websocket.Client,
    collector: *network.Collector,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    running: *bool,
) []u8 {
    const req = daemon.parseRequest(allocator, line) catch {
        return respondErr(allocator, "Invalid request");
    };
    defer daemon.freeRequest(allocator, req);

    if (std.mem.eql(u8, req.action, "open")) {
        return handleOpen(allocator, ws, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "network_list")) {
        return handleNetworkList(allocator, collector, req.pattern);
    } else if (std.mem.eql(u8, req.action, "close")) {
        running.* = false;
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "ping")) {
        return respondOk(allocator);
    } else {
        return respondErr(allocator, "Unknown action");
    }
}

fn handleOpen(allocator: Allocator, ws: *websocket.Client, cmd_id: *cdp.CommandId, session_id: ?[]const u8, url: ?[]const u8) []u8 {
    const target_url = url orelse return respondErr(allocator, "url required");

    const nav_cmd = cdp.pageNavigate(allocator, cmd_id.next(), target_url, session_id) catch
        return respondErr(allocator, "Failed to build navigate command");
    defer allocator.free(nav_cmd);

    ws.sendText(nav_cmd) catch return respondErr(allocator, "Failed to send navigate");

    return respondOk(allocator);
}

fn handleNetworkList(allocator: Allocator, collector: *network.Collector, pattern: ?[]const u8) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    writer.writeByte('[') catch return respondErr(allocator, "write error");
    var it = collector.requests.iterator();
    var first = true;
    while (it.next()) |entry| {
        const info = entry.value_ptr.info;

        if (pattern) |p| {
            if (std.mem.indexOf(u8, info.url, p) == null) continue;
        }

        if (!first) writer.writeByte(',') catch {};
        first = false;

        // Use proper JSON escaping for all string values
        writer.writeAll("{\"url\":") catch {};
        cdp.writeJsonString(writer, info.url) catch {};
        writer.writeAll(",\"method\":") catch {};
        cdp.writeJsonString(writer, info.method) catch {};
        writer.writeAll(",\"status\":") catch {};
        if (info.status) |s| {
            std.fmt.format(writer, "{d}", .{s}) catch {};
        } else {
            writer.writeAll("null") catch {};
        }
        writer.writeAll(",\"state\":") catch {};
        cdp.writeJsonString(writer, @tagName(info.state)) catch {};
        writer.writeByte('}') catch {};
    }
    writer.writeByte(']') catch {};

    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

// ============================================================================
// Helpers
// ============================================================================

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
        \\Usage: agent-devtools [--session=NAME] <command> [options]
        \\
        \\Commands:
        \\  open <url>              Navigate to URL (starts daemon if needed)
        \\  network list [pattern]  List captured network requests
        \\  close                   Close browser and stop daemon
        \\  find-chrome             Find Chrome executable on the system
        \\
        \\  (Coming soon)
        \\  analyze <url>           Reverse-engineer web app API schema
        \\  intercept               Intercept and modify network requests
        \\  record <name>           Record a browsing flow
        \\  replay <name>           Replay and compare a recorded flow
        \\  diff <baseline>         Compare against baseline
        \\
        \\Options:
        \\  --session=NAME          Session name (default: "default")
        \\  -h, --help              Show this help
        \\  -v, --version           Show version
        \\
    , .{});
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
}

test "isPlannedCommand: recognizes planned commands" {
    try std.testing.expect(isPlannedCommand("analyze"));
    try std.testing.expect(isPlannedCommand("intercept"));
}

test "isPlannedCommand: rejects implemented commands" {
    try std.testing.expect(!isPlannedCommand("open"));
    try std.testing.expect(!isPlannedCommand("network"));
    try std.testing.expect(!isPlannedCommand("close"));
}
