const std = @import("std");
const agent = @import("agent_devtools");
const chrome = agent.chrome;
const cdp = agent.cdp;
const websocket = agent.websocket;
const network = agent.network;
const daemon = agent.daemon;
const analyzer = agent.analyzer;
const interceptor = agent.interceptor;
const recorder = agent.recorder;

const Allocator = std.mem.Allocator;
const version = "0.1.0";

const ConsoleEntry = struct {
    log_type: []u8, // "log", "warn", "error", "info", "debug"
    text: []u8,
    timestamp: f64,
};

pub fn main() void {
    if (std.posix.getenv("AGENT_DEVTOOLS_DAEMON")) |_| {
        runDaemon();
        return;
    }

    var args_iter = std.process.args();
    _ = args_iter.next();

    // Parse --session flag (can appear before command)
    var session: []const u8 = "default";
    var headed = false;
    var cdp_port: ?[]const u8 = null;
    var command: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--session=")) {
            session = arg["--session=".len..];
        } else if (std.mem.eql(u8, arg, "--headed")) {
            headed = true;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            cdp_port = arg["--port=".len..];
        } else if (command == null) {
            command = arg;
            break;
        }
    }

    const cmd = command orelse {
        printUsage();
        return;
    };

    const daemon_opts = daemon.DaemonOptions{
        .headed = headed,
        .cdp_port = cdp_port,
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
        sendAction(session, "open", url, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "network")) {
        const subcmd = args_iter.next() orelse "list";
        if (std.mem.eql(u8, subcmd, "list")) {
            sendAction(session, "network_list", null, args_iter.next(), daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "get")) {
            const req_id = args_iter.next() orelse {
                writeErr("Usage: agent-devtools network get <requestId>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "network_get", req_id, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "clear")) {
            sendAction(session, "network_clear", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "help")) {
            write(
                \\Usage: agent-devtools network <subcommand>
                \\
                \\Subcommands:
                \\  list [pattern]    List network requests (optional URL filter)
                \\  get <requestId>   Get request details (headers, body)
                \\  clear             Clear collected requests
                \\  help              Show this help
                \\
            , .{});
        } else {
            writeErr("Unknown network subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "console")) {
        const subcmd = args_iter.next() orelse "list";
        if (std.mem.eql(u8, subcmd, "list")) {
            sendAction(session, "console_list", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "clear")) {
            sendAction(session, "console_clear", null, null, daemon_opts);
        } else {
            writeErr("Unknown console subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "intercept")) {
        const subcmd = args_iter.next() orelse {
            write(
                \\Usage: agent-devtools intercept <subcommand> <pattern> [options]
                \\
                \\Subcommands:
                \\  mock <pattern> <json>     Return mock response for matching URLs
                \\  fail <pattern>            Block matching requests
                \\  delay <pattern> <ms>      Delay matching requests
                \\  remove <pattern>          Remove intercept rule
                \\  list                      List active rules
                \\  clear                     Remove all rules
                \\
                \\Examples:
                \\  agent-devtools intercept mock "*api/users*" '{{"users":[]}}'
                \\  agent-devtools intercept fail "*analytics*"
                \\  agent-devtools intercept delay "*api*" 2000
                \\
            , .{});
            return;
        };

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "clear")) {
            sendAction(session, if (std.mem.eql(u8, subcmd, "list")) "intercept_list" else "intercept_clear", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "remove")) {
            const pattern = args_iter.next() orelse {
                writeErr("Usage: agent-devtools intercept remove <pattern>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "intercept_remove", pattern, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "mock")) {
            const pattern = args_iter.next() orelse {
                writeErr("Usage: agent-devtools intercept mock <pattern> <json>\n", .{});
                std.process.exit(1);
            };
            const body = args_iter.next() orelse "{}";
            sendAction(session, "intercept_mock", pattern, body, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "fail")) {
            const pattern = args_iter.next() orelse {
                writeErr("Usage: agent-devtools intercept fail <pattern>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "intercept_fail", pattern, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "delay")) {
            const pattern = args_iter.next() orelse {
                writeErr("Usage: agent-devtools intercept delay <pattern> <ms>\n", .{});
                std.process.exit(1);
            };
            const ms = args_iter.next() orelse "1000";
            sendAction(session, "intercept_delay", pattern, ms, daemon_opts);
        } else {
            writeErr("Unknown intercept subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "analyze")) {
        sendAction(session, "analyze", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "status")) {
        sendAction(session, "status", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "close")) {
        sendAction(session, "close", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "record")) {
        const name = args_iter.next() orelse {
            writeErr("Usage: agent-devtools record <name>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "record", name, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "diff")) {
        const name = args_iter.next() orelse {
            writeErr("Usage: agent-devtools diff <recording-name>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "diff", name, null, daemon_opts);
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

fn sendAction(session: []const u8, action: []const u8, url: ?[]const u8, pattern: ?[]const u8, daemon_opts: daemon.DaemonOptions) void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    const started = daemon.ensureDaemon(allocator, session, daemon_opts) catch |err| {
        writeErr("Failed to start daemon: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (started) {
        writeErr("Started daemon (session: {s})\n", .{session});
    } else if (daemon_opts.headed or daemon_opts.cdp_port != null) {
        writeErr("Daemon already running — --headed/--port options ignored. Use 'close' first.\n", .{});
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
    const is_headed = std.posix.getenv("AGENT_DEVTOOLS_HEADED") != null;
    const ext_port = std.posix.getenv("AGENT_DEVTOOLS_PORT");

    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    // Connect to existing Chrome or launch new one
    var chrome_proc: ?chrome.ChromeProcess = null;
    defer if (chrome_proc) |*cp| cp.deinit();

    var discovered_url: ?[]u8 = null;
    defer if (discovered_url) |u| allocator.free(u);

    const ws_url: []const u8 = if (ext_port) |port_str| blk: {
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            std.debug.print("Daemon: Invalid port: {s}\n", .{port_str});
            return;
        };
        // Discover the correct WebSocket URL via /json/version
        discovered_url = chrome.discoverWsUrl(allocator, "127.0.0.1", port) catch |err| {
            std.debug.print("Daemon: Failed to discover CDP URL on port {d}: {s}\n", .{ port, @errorName(err) });
            return;
        };
        break :blk discovered_url.?;
    } else blk: {
        chrome_proc = chrome.ChromeProcess.launch(allocator, .{ .headless = !is_headed }) catch |err| {
            std.debug.print("Daemon: Chrome launch failed: {s}\n", .{@errorName(err)});
            return;
        };
        break :blk chrome_proc.?.ws_url;
    };

    var ws = websocket.Client.connect(allocator, ws_url) catch |err| {
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

    // Enable Runtime for console events
    const runtime_enable = cdp.serializeCommand(allocator, cmd_id.next(), "Runtime.enable", null, session_id) catch return;
    ws.sendText(runtime_enable) catch return;
    allocator.free(runtime_enable);

    // Drain enable responses
    for (0..10) |_| {
        const msg = ws.recvMessage() catch break;
        allocator.free(msg);
    }

    var collector = network.Collector.init(allocator);
    defer collector.deinit();

    var intercept_state = interceptor.InterceptorState.init(allocator);
    defer intercept_state.deinit();

    var console_messages: std.ArrayList(ConsoleEntry) = .empty;
    defer {
        for (console_messages.items) |entry| {
            allocator.free(entry.log_type);
            allocator.free(entry.text);
        }
        console_messages.deinit(allocator);
    }

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

    // Idle timeout: 10 minutes without CLI commands → auto-shutdown
    const idle_timeout_ns: i128 = 10 * 60 * std.time.ns_per_s;
    var last_command_time = std.time.nanoTimestamp();
    var running = true;
    var cdp_fail_count: usize = 0;

    while (running) {
        const drained = drainCdpEvents(&ws, allocator, &collector, &console_messages, &intercept_state, &cmd_id, session_id);
        if (drained == 0) {
            cdp_fail_count += 1;
        } else {
            cdp_fail_count = 0;
        }

        if (cdp_fail_count > 30) {
            std.debug.print("Daemon: Chrome connection lost, shutting down\n", .{});
            break;
        }

        // Idle timeout check
        if (std.time.nanoTimestamp() - last_command_time > idle_timeout_ns) {
            std.debug.print("Daemon: Idle timeout (10 min), shutting down\n", .{});
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
                last_command_time = std.time.nanoTimestamp();
                const resp = handleCommand(allocator, req_buf[0..req_len], &ws, &collector, &console_messages, &intercept_state, &cmd_id, session_id, &running);
                defer allocator.free(resp);
                _ = std.posix.write(client_fd, resp) catch {};
            }
        } else |_| {}
    }
}

fn drainCdpEvents(
    ws: *websocket.Client,
    allocator: Allocator,
    collector: *network.Collector,
    console_msgs: *std.ArrayList(ConsoleEntry),
    intercept_state: *interceptor.InterceptorState,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
) usize {
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

                    if (std.mem.eql(u8, method, "Runtime.consoleAPICalled")) {
                        collectConsoleEvent(allocator, params, console_msgs);
                    }

                    // Handle intercepted requests
                    if (std.mem.eql(u8, method, "Fetch.requestPaused")) {
                        handleRequestPaused(allocator, ws, intercept_state, cmd_id, session_id, params);
                    }
                }
            }
        }
    }
    return count;
}

fn handleRequestPaused(
    allocator: Allocator,
    ws: *websocket.Client,
    intercept_state: *const interceptor.InterceptorState,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    params: std.json.Value,
) void {
    const request_id = cdp.getString(params, "requestId") orelse return;
    const request = cdp.getObject(params, "request") orelse return;
    const url = cdp.getString(request, "url") orelse return;

    if (intercept_state.findMatch(url)) |rule| {
        switch (rule.action) {
            .mock => {
                const cmd = interceptor.buildFulfillCommand(allocator, cmd_id.next(), request_id, rule, session_id) catch return;
                defer allocator.free(cmd);
                ws.sendText(cmd) catch {};
            },
            .fail => {
                const cmd = interceptor.buildFailCommand(allocator, cmd_id.next(), request_id, rule.error_reason, session_id) catch return;
                defer allocator.free(cmd);
                ws.sendText(cmd) catch {};
            },
            .delay => {
                std.Thread.sleep(@as(u64, rule.delay_ms) * std.time.ns_per_ms);
                const cmd = interceptor.buildContinueCommand(allocator, cmd_id.next(), request_id, session_id) catch return;
                defer allocator.free(cmd);
                ws.sendText(cmd) catch {};
            },
            .pass => {
                const cmd = interceptor.buildContinueCommand(allocator, cmd_id.next(), request_id, session_id) catch return;
                defer allocator.free(cmd);
                ws.sendText(cmd) catch {};
            },
        }
    } else {
        // No matching rule — continue the request
        const cmd = interceptor.buildContinueCommand(allocator, cmd_id.next(), request_id, session_id) catch return;
        defer allocator.free(cmd);
        ws.sendText(cmd) catch {};
    }
}

fn collectConsoleEvent(allocator: Allocator, params: std.json.Value, console_msgs: *std.ArrayList(ConsoleEntry)) void {
    const log_type_raw = cdp.getString(params, "type") orelse "log";
    const timestamp = cdp.getFloat(params, "timestamp") orelse 0;

    // Extract text from args array
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);

    if (params == .object) {
        if (params.object.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items, 0..) |arg, i| {
                    if (i > 0) text_buf.append(allocator, ' ') catch {};
                    appendRemoteObjectText(allocator, arg, &text_buf);
                }
            }
        }
    }

    const text = text_buf.toOwnedSlice(allocator) catch return;
    const log_type = allocator.dupe(u8, log_type_raw) catch {
        allocator.free(text);
        return;
    };
    console_msgs.append(allocator, .{
        .log_type = log_type,
        .text = text,
        .timestamp = timestamp,
    }) catch {
        allocator.free(text);
        allocator.free(log_type);
    };
}

/// Convert a CDP RemoteObject to a readable text representation.
/// Handles all types: string, number, boolean, null, undefined, object, function, symbol, bigint.
/// Reference: js_protocol.json RemoteObject type
fn appendRemoteObjectText(allocator: Allocator, obj: std.json.Value, buf: *std.ArrayList(u8)) void {
    if (obj != .object) return;
    const map = obj.object;

    const obj_type = cdp.getString(obj, "type") orelse "unknown";

    // For strings, use the value directly (not description which adds quotes)
    if (std.mem.eql(u8, obj_type, "string")) {
        if (cdp.getString(obj, "value")) |v| {
            buf.appendSlice(allocator, v) catch {};
            return;
        }
    }

    // For numbers, booleans: value field contains the actual value
    if (std.mem.eql(u8, obj_type, "number") or std.mem.eql(u8, obj_type, "boolean") or std.mem.eql(u8, obj_type, "bigint")) {
        // Check unserializableValue first (-0, NaN, Infinity, bigint literals)
        if (cdp.getString(obj, "unserializableValue")) |u| {
            buf.appendSlice(allocator, u) catch {};
            return;
        }
        if (map.get("value")) |val| switch (val) {
            .integer => |n| {
                var num_buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch return;
                buf.appendSlice(allocator, s) catch {};
                return;
            },
            .float => |f| {
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch return;
                buf.appendSlice(allocator, s) catch {};
                return;
            },
            .bool => |b| {
                buf.appendSlice(allocator, if (b) "true" else "false") catch {};
                return;
            },
            .string => |s| {
                buf.appendSlice(allocator, s) catch {};
                return;
            },
            else => {},
        };
    }

    // For undefined
    if (std.mem.eql(u8, obj_type, "undefined")) {
        buf.appendSlice(allocator, "undefined") catch {};
        return;
    }

    // Check subtype first (null, array, error, etc.)
    if (cdp.getString(obj, "subtype")) |subtype| {
        if (std.mem.eql(u8, subtype, "null")) {
            buf.appendSlice(allocator, "null") catch {};
            return;
        }
    }

    // For objects: use description (Array(3), Error: msg, Uint8Array(3), etc.)
    if (cdp.getString(obj, "description")) |d| {
        buf.appendSlice(allocator, d) catch {};
        return;
    }

    // Last resort: className or type
    if (cdp.getString(obj, "className")) |c| {
        buf.appendSlice(allocator, c) catch {};
    } else {
        buf.appendSlice(allocator, obj_type) catch {};
    }
}

fn respondOk(allocator: Allocator) []u8 {
    return daemon.serializeResponse(allocator, .{ .success = true }) catch
        allocator.dupe(u8, "{\"success\":true}\n") catch "";
}

fn respondErr(allocator: Allocator, msg: []const u8) []u8 {
    return daemon.serializeResponse(allocator, .{ .success = false, .@"error" = msg }) catch
        allocator.dupe(u8, "{\"success\":false,\"error\":\"internal error\"}\n") catch "";
}

fn handleCommand(
    allocator: Allocator,
    line: []const u8,
    ws: *websocket.Client,
    collector: *network.Collector,
    console_msgs: *std.ArrayList(ConsoleEntry),
    intercept_state: *interceptor.InterceptorState,
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
    } else if (std.mem.eql(u8, req.action, "network_get")) {
        return handleNetworkGet(allocator, ws, cmd_id, session_id, collector, req.url);
    } else if (std.mem.eql(u8, req.action, "network_clear")) {
        collector.deinit();
        collector.* = network.Collector.init(allocator);
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "console_list")) {
        return handleConsoleList(allocator, console_msgs);
    } else if (std.mem.eql(u8, req.action, "console_clear")) {
        for (console_msgs.items) |entry| {
            allocator.free(entry.log_type);
            allocator.free(entry.text);
        }
        console_msgs.clearRetainingCapacity();
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "analyze")) {
        return handleAnalyze(allocator, ws, cmd_id, session_id, collector);
    } else if (std.mem.eql(u8, req.action, "record")) {
        return handleRecord(allocator, collector, console_msgs, req.url);
    } else if (std.mem.eql(u8, req.action, "diff")) {
        return handleDiff(allocator, collector, req.url);
    } else if (std.mem.eql(u8, req.action, "intercept_mock")) {
        return handleInterceptAdd(allocator, ws, cmd_id, session_id, intercept_state, req.url, .mock, req.pattern);
    } else if (std.mem.eql(u8, req.action, "intercept_fail")) {
        return handleInterceptAdd(allocator, ws, cmd_id, session_id, intercept_state, req.url, .fail, null);
    } else if (std.mem.eql(u8, req.action, "intercept_delay")) {
        return handleInterceptAdd(allocator, ws, cmd_id, session_id, intercept_state, req.url, .delay, req.pattern);
    } else if (std.mem.eql(u8, req.action, "intercept_remove")) {
        return handleInterceptRemove(allocator, ws, cmd_id, session_id, intercept_state, req.url);
    } else if (std.mem.eql(u8, req.action, "intercept_list")) {
        return handleInterceptList(allocator, intercept_state);
    } else if (std.mem.eql(u8, req.action, "intercept_clear")) {
        intercept_state.deinit();
        intercept_state.* = interceptor.InterceptorState.init(allocator);
        // Disable Fetch
        const disable = cdp.fetchDisable(allocator, cmd_id.next(), session_id) catch return respondOk(allocator);
        defer allocator.free(disable);
        ws.sendText(disable) catch {};
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "status")) {
        return handleStatus(allocator, collector, console_msgs);
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
        writer.writeAll("{\"requestId\":") catch {};
        cdp.writeJsonString(writer, info.request_id) catch {};
        writer.writeAll(",\"url\":") catch {};
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

fn handleNetworkGet(
    allocator: Allocator,
    ws: *websocket.Client,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    collector: *network.Collector,
    request_id_opt: ?[]const u8,
) []u8 {
    const request_id = request_id_opt orelse return respondErr(allocator, "requestId required (pass as url param)");

    const info = collector.getById(request_id) orelse return respondErr(allocator, "request not found");

    // Fetch response body via CDP
    const get_body_cmd = cdp.networkGetResponseBody(allocator, cmd_id.next(), request_id, session_id) catch
        return respondErr(allocator, "failed to build getResponseBody");
    defer allocator.free(get_body_cmd);

    ws.sendText(get_body_cmd) catch return respondErr(allocator, "failed to send getResponseBody");

    // Wait for response (up to 5 seconds)
    ws.setReadTimeout(5000);
    defer ws.setReadTimeout(100);

    var body_owned: ?[]u8 = null;
    defer if (body_owned) |b| allocator.free(b);
    var base64_encoded = false;

    // Process messages while waiting for getResponseBody response.
    // Events are forwarded to collector to avoid data loss.
    for (0..30) |_| {
        const msg = ws.recvMessage() catch break;
        defer allocator.free(msg);

        const parsed = cdp.parseMessage(allocator, msg) catch continue;
        defer parsed.parsed.deinit();

        if (parsed.message.isEvent()) {
            if (parsed.message.method) |method| {
                if (parsed.message.params) |params| {
                    _ = collector.processEvent(method, params) catch {};
                }
            }
            continue;
        }

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |result| {
                if (cdp.getString(result, "body")) |b| {
                    body_owned = allocator.dupe(u8, b) catch null;
                    base64_encoded = cdp.getBool(result, "base64Encoded") orelse false;
                    break;
                }
            }
            if (parsed.message.isErrorResponse()) break;
        }
    }

    const body_str = body_owned orelse "";

    // Build response JSON
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    writer.writeAll("{\"requestId\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(writer, info.request_id) catch {};
    writer.writeAll(",\"url\":") catch {};
    cdp.writeJsonString(writer, info.url) catch {};
    writer.writeAll(",\"method\":") catch {};
    cdp.writeJsonString(writer, info.method) catch {};
    writer.writeAll(",\"status\":") catch {};
    if (info.status) |s| {
        std.fmt.format(writer, "{d}", .{s}) catch {};
    } else {
        writer.writeAll("null") catch {};
    }
    writer.writeAll(",\"mimeType\":") catch {};
    cdp.writeJsonString(writer, info.mime_type) catch {};
    writer.writeAll(",\"state\":") catch {};
    cdp.writeJsonString(writer, @tagName(info.state)) catch {};
    writer.writeAll(",\"body\":") catch {};
    cdp.writeJsonString(writer, body_str) catch {};
    writer.writeAll(",\"base64Encoded\":") catch {};
    writer.writeAll(if (base64_encoded) "true" else "false") catch {};
    if (info.encoded_data_length) |len| {
        writer.writeAll(",\"encodedDataLength\":") catch {};
        std.fmt.format(writer, "{d}", .{len}) catch {};
    }
    if (info.error_text.len > 0) {
        writer.writeAll(",\"errorText\":") catch {};
        cdp.writeJsonString(writer, info.error_text) catch {};
    }
    writer.writeByte('}') catch {};

    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

fn handleConsoleList(allocator: Allocator, console_msgs: *const std.ArrayList(ConsoleEntry)) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    writer.writeByte('[') catch return respondErr(allocator, "write error");
    for (console_msgs.items, 0..) |entry, i| {
        if (i > 0) writer.writeByte(',') catch {};
        writer.writeAll("{\"type\":") catch {};
        cdp.writeJsonString(writer, entry.log_type) catch {};
        writer.writeAll(",\"text\":") catch {};
        cdp.writeJsonString(writer, entry.text) catch {};
        writer.writeByte('}') catch {};
    }
    writer.writeByte(']') catch {};

    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

fn handleRecord(allocator: Allocator, collector: *const network.Collector, console_msgs: *const std.ArrayList(ConsoleEntry), name: ?[]const u8) []u8 {
    const rec_name = name orelse return respondErr(allocator, "recording name required");

    const json = recorder.saveRecording(allocator, rec_name, collector, console_msgs.items.len) catch
        return respondErr(allocator, "failed to save recording");
    defer allocator.free(json);

    // Save to ~/.agent-devtools/recordings/<name>.json
    var dir_buf: [512]u8 = undefined;
    const socket_dir = daemon.getSocketDir(&dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rec_dir = std.fmt.bufPrint(&path_buf, "{s}/recordings", .{socket_dir}) catch
        return respondErr(allocator, "path error");

    std.fs.makeDirAbsolute(rec_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return respondErr(allocator, "failed to create recordings dir"),
    };

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}.json", .{ rec_dir, rec_name }) catch
        return respondErr(allocator, "path error");

    const file = std.fs.createFileAbsolute(file_path, .{}) catch
        return respondErr(allocator, "failed to create file");
    defer file.close();
    _ = file.write(json) catch return respondErr(allocator, "failed to write file");

    // Return success with file path
    var resp_buf: [512]u8 = undefined;
    const data = std.fmt.bufPrint(&resp_buf, "{{\"file\":\"{s}\",\"requests\":{d}}}", .{
        file_path,
        collector.count(),
    }) catch return respondOk(allocator);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
}

fn handleDiff(allocator: Allocator, collector: *const network.Collector, name: ?[]const u8) []u8 {
    const rec_name = name orelse return respondErr(allocator, "recording name required");

    // Load recording from file
    var dir_buf: [512]u8 = undefined;
    const socket_dir = daemon.getSocketDir(&dir_buf);
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/recordings/{s}.json", .{ socket_dir, rec_name }) catch
        return respondErr(allocator, "path error");

    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch
        return respondErr(allocator, "recording not found");
    defer allocator.free(file_content);

    var rec = recorder.loadRecording(allocator, file_content) catch
        return respondErr(allocator, "invalid recording format");
    defer recorder.freeRecording(allocator, &rec);

    var diff = recorder.diffRequests(allocator, rec.requests, collector) catch
        return respondErr(allocator, "diff failed");
    defer diff.deinit();

    const data = recorder.serializeDiff(allocator, &diff) catch
        return respondErr(allocator, "serialize failed");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "response failed");
}

fn handleInterceptAdd(
    allocator: Allocator,
    ws: *websocket.Client,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    intercept_state: *interceptor.InterceptorState,
    url_pattern: ?[]const u8,
    action: interceptor.Action,
    extra: ?[]const u8, // mock body or delay ms
) []u8 {
    const pattern = url_pattern orelse return respondErr(allocator, "URL pattern required");

    var rule = interceptor.Rule{
        .url_pattern = allocator.dupe(u8, pattern) catch return respondErr(allocator, "alloc error"),
        .action = action,
        .mock_body = null,
        .mock_status = 200,
        .mock_content_type = allocator.dupe(u8, "application/json") catch return respondErr(allocator, "alloc error"),
        .delay_ms = 0,
        .error_reason = allocator.dupe(u8, "BlockedByClient") catch return respondErr(allocator, "alloc error"),
    };

    switch (action) {
        .mock => {
            if (extra) |body| {
                rule.mock_body = allocator.dupe(u8, body) catch null;
            }
        },
        .delay => {
            if (extra) |ms_str| {
                rule.delay_ms = std.fmt.parseInt(u32, ms_str, 10) catch 1000;
            }
        },
        else => {},
    }

    intercept_state.addRule(rule) catch return respondErr(allocator, "failed to add rule");

    // Enable Fetch with updated patterns
    const patterns = intercept_state.buildFetchPatterns(allocator) catch return respondErr(allocator, "pattern error");
    defer allocator.free(patterns);

    const enable_cmd = cdp.fetchEnable(allocator, cmd_id.next(), patterns, session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(enable_cmd);
    ws.sendText(enable_cmd) catch {};

    return respondOk(allocator);
}

fn handleInterceptRemove(
    allocator: Allocator,
    ws: *websocket.Client,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    intercept_state: *interceptor.InterceptorState,
    url_pattern: ?[]const u8,
) []u8 {
    const pattern = url_pattern orelse return respondErr(allocator, "URL pattern required");
    const removed = intercept_state.removeRule(pattern);
    _ = removed;

    if (intercept_state.ruleCount() == 0) {
        const disable = cdp.fetchDisable(allocator, cmd_id.next(), session_id) catch return respondOk(allocator);
        defer allocator.free(disable);
        ws.sendText(disable) catch {};
    } else {
        const patterns = intercept_state.buildFetchPatterns(allocator) catch return respondOk(allocator);
        defer allocator.free(patterns);
        const enable_cmd = cdp.fetchEnable(allocator, cmd_id.next(), patterns, session_id) catch return respondOk(allocator);
        defer allocator.free(enable_cmd);
        ws.sendText(enable_cmd) catch {};
    }

    return respondOk(allocator);
}

fn handleInterceptList(allocator: Allocator, intercept_state: *const interceptor.InterceptorState) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    writer.writeByte('[') catch return respondErr(allocator, "write error");
    for (intercept_state.rules.items, 0..) |rule, i| {
        if (i > 0) writer.writeByte(',') catch {};
        writer.writeAll("{\"pattern\":") catch {};
        cdp.writeJsonString(writer, rule.url_pattern) catch {};
        writer.writeAll(",\"action\":") catch {};
        cdp.writeJsonString(writer, @tagName(rule.action)) catch {};
        if (rule.action == .mock and rule.mock_body != null) {
            writer.writeAll(",\"body\":") catch {};
            cdp.writeJsonString(writer, rule.mock_body.?) catch {};
        }
        if (rule.action == .delay) {
            std.fmt.format(writer, ",\"delayMs\":{d}", .{rule.delay_ms}) catch {};
        }
        writer.writeByte('}') catch {};
    }
    writer.writeByte(']') catch {};

    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

fn handleAnalyze(allocator: Allocator, ws: *websocket.Client, cmd_id: *cdp.CommandId, session_id: ?[]const u8, collector: *network.Collector) []u8 {
    var result = analyzer.analyzeRequests(allocator, collector) catch
        return respondErr(allocator, "analysis failed");
    defer result.deinit();

    // Enrich endpoints with response body schema
    for (result.endpoints) |*ep| {
        if (!std.mem.startsWith(u8, ep.mime_type, "application/json")) continue;

        // Find the requestId for this endpoint's example URL
        var req_it = collector.requests.iterator();
        while (req_it.next()) |entry| {
            const info = entry.value_ptr.info;
            if (std.mem.eql(u8, info.url, ep.example_url)) {
                // Fetch response body
                if (fetchResponseBody(allocator, ws, cmd_id, session_id, info.request_id, collector)) |body| {
                    defer allocator.free(body);
                    ep.response_schema = analyzer.inferJsonSchema(allocator, body);
                }
                break;
            }
        }
    }

    const data = analyzer.serializeResult(allocator, &result) catch
        return respondErr(allocator, "serialize failed");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "response failed");
}

/// Fetch response body for a request via CDP. Returns owned slice or null.
fn fetchResponseBody(allocator: Allocator, ws: *websocket.Client, cmd_id: *cdp.CommandId, session_id: ?[]const u8, request_id: []const u8, collector: *network.Collector) ?[]u8 {
    const get_body_cmd = cdp.networkGetResponseBody(allocator, cmd_id.next(), request_id, session_id) catch return null;
    defer allocator.free(get_body_cmd);

    ws.sendText(get_body_cmd) catch return null;

    ws.setReadTimeout(3000);
    defer ws.setReadTimeout(100);

    for (0..20) |_| {
        const msg = ws.recvMessage() catch return null;
        defer allocator.free(msg);

        const parsed = cdp.parseMessage(allocator, msg) catch continue;
        defer parsed.parsed.deinit();

        if (parsed.message.isEvent()) {
            if (parsed.message.method) |method| {
                if (parsed.message.params) |params| {
                    _ = collector.processEvent(method, params) catch {};
                }
            }
            continue;
        }

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |res| {
                if (cdp.getString(res, "body")) |b| {
                    return allocator.dupe(u8, b) catch null;
                }
            }
            return null;
        }
    }
    return null;
}

fn handleStatus(allocator: Allocator, collector: *const network.Collector, console_msgs: *const std.ArrayList(ConsoleEntry)) []u8 {
    var buf: [256]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "{{\"requests\":{d},\"console\":{d},\"daemon\":\"running\"}}", .{
        collector.count(),
        console_msgs.items.len,
    }) catch return respondErr(allocator, "format error");

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

// ============================================================================
// Helpers
// ============================================================================

fn isPlannedCommand(cmd: []const u8) bool {
    const planned = [_][]const u8{ "replay" };
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
        \\  network list [pattern]  List network requests (optional URL filter)
        \\  network get <requestId> Get request details with response body
        \\  network clear           Clear collected requests
        \\  console list            List captured console messages
        \\  console clear           Clear console messages
        \\  status                  Show daemon status
        \\  close                   Close browser and stop daemon
        \\  find-chrome             Find Chrome executable
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
        \\  --headed                Show browser window (default: headless)
        \\  --port=PORT             Connect to existing Chrome at PORT
        \\  -h, --help              Show this help
        \\  -v, --version           Show version
        \\
    , .{});
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
}

test "isPlannedCommand: recognizes planned commands" {
    try std.testing.expect(isPlannedCommand("replay"));
}

test "isPlannedCommand: implemented commands are not planned" {
    try std.testing.expect(!isPlannedCommand("analyze"));
    try std.testing.expect(!isPlannedCommand("intercept"));
    try std.testing.expect(!isPlannedCommand("record"));
    try std.testing.expect(!isPlannedCommand("diff"));
    try std.testing.expect(!isPlannedCommand("open"));
    try std.testing.expect(!isPlannedCommand("network"));
}

test "isPlannedCommand: rejects implemented commands" {
    try std.testing.expect(!isPlannedCommand("open"));
    try std.testing.expect(!isPlannedCommand("network"));
    try std.testing.expect(!isPlannedCommand("close"));
}

// ============================================================================
// Tests: appendRemoteObjectText (CDP RemoteObject → text)
// Based on: js_protocol.json RemoteObject type
// ============================================================================

fn makeJsonObj(allocator: Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
}

fn remoteObjectToText(json_str: []const u8) ![]u8 {
    const parsed = try makeJsonObj(std.testing.allocator, json_str);
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    appendRemoteObjectText(std.testing.allocator, parsed.value, &buf);
    return buf.toOwnedSlice(std.testing.allocator);
}

test "RemoteObject: string value" {
    const text = try remoteObjectToText("{\"type\":\"string\",\"value\":\"hello world\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "RemoteObject: number value (integer)" {
    const text = try remoteObjectToText("{\"type\":\"number\",\"value\":42,\"description\":\"42\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("42", text);
}

test "RemoteObject: number value (float)" {
    const text = try remoteObjectToText("{\"type\":\"number\",\"value\":3.14,\"description\":\"3.14\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "3.14"));
}

test "RemoteObject: boolean true" {
    const text = try remoteObjectToText("{\"type\":\"boolean\",\"value\":true,\"description\":\"true\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("true", text);
}

test "RemoteObject: boolean false" {
    const text = try remoteObjectToText("{\"type\":\"boolean\",\"value\":false,\"description\":\"false\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("false", text);
}

test "RemoteObject: null (subtype)" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"null\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("null", text);
}

test "RemoteObject: undefined" {
    const text = try remoteObjectToText("{\"type\":\"undefined\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("undefined", text);
}

test "RemoteObject: NaN (unserializable)" {
    const text = try remoteObjectToText("{\"type\":\"number\",\"unserializableValue\":\"NaN\",\"description\":\"NaN\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("NaN", text);
}

test "RemoteObject: Infinity (unserializable)" {
    const text = try remoteObjectToText("{\"type\":\"number\",\"unserializableValue\":\"Infinity\",\"description\":\"Infinity\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Infinity", text);
}

test "RemoteObject: object with description" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"description\":\"Object\",\"className\":\"Object\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Object", text);
}

test "RemoteObject: array with description" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"array\",\"description\":\"Array(3)\",\"className\":\"Array\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Array(3)", text);
}

test "RemoteObject: error with description" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"error\",\"description\":\"Error: something failed\",\"className\":\"Error\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Error: something failed", text);
}

test "RemoteObject: typed array" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"typedarray\",\"description\":\"Uint8Array(3)\",\"className\":\"Uint8Array\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Uint8Array(3)", text);
}

test "RemoteObject: symbol" {
    const text = try remoteObjectToText("{\"type\":\"symbol\",\"description\":\"Symbol(test)\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Symbol(test)", text);
}

test "RemoteObject: function" {
    const text = try remoteObjectToText("{\"type\":\"function\",\"description\":\"function foo() { ... }\",\"className\":\"Function\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("function foo() { ... }", text);
}

test "RemoteObject: bigint" {
    const text = try remoteObjectToText("{\"type\":\"bigint\",\"unserializableValue\":\"123n\",\"description\":\"123n\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("123n", text);
}

test "RemoteObject: object without description falls back to className" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"className\":\"MyClass\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("MyClass", text);
}

test "RemoteObject: object without description or className falls back to type" {
    const text = try remoteObjectToText("{\"type\":\"object\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("object", text);
}

test "RemoteObject: negative zero (-0)" {
    const text = try remoteObjectToText("{\"type\":\"number\",\"unserializableValue\":\"-0\",\"description\":\"-0\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("-0", text);
}

test "RemoteObject: native function (parseInt)" {
    const text = try remoteObjectToText("{\"type\":\"function\",\"description\":\"function parseInt() { [native code] }\",\"className\":\"Function\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("function parseInt() { [native code] }", text);
}

test "RemoteObject: DOM node" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"node\",\"description\":\"body\",\"className\":\"HTMLBodyElement\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("body", text);
}

test "RemoteObject: promise" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"promise\",\"description\":\"Promise\",\"className\":\"Promise\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Promise", text);
}

test "RemoteObject: regexp" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"regexp\",\"description\":\"/test/gi\",\"className\":\"RegExp\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("/test/gi", text);
}

test "RemoteObject: date" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"date\",\"description\":\"Mon Jan 01 2024 00:00:00 GMT+0000\",\"className\":\"Date\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Mon Jan 01 2024 00:00:00 GMT+0000", text);
}

test "RemoteObject: map" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"map\",\"description\":\"Map(2)\",\"className\":\"Map\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Map(2)", text);
}

test "RemoteObject: proxy" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"proxy\",\"description\":\"Proxy\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Proxy", text);
}

test "RemoteObject: arraybuffer" {
    const text = try remoteObjectToText("{\"type\":\"object\",\"subtype\":\"arraybuffer\",\"description\":\"ArrayBuffer(16)\",\"className\":\"ArrayBuffer\"}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ArrayBuffer(16)", text);
}
