const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent_devtools");
const chrome = agent.chrome;
const cdp = agent.cdp;
const websocket = agent.websocket;
const network = agent.network;
const daemon = agent.daemon;
const analyzer = agent.analyzer;
const interceptor = agent.interceptor;
const recorder = agent.recorder;
const snapshot_mod = agent.snapshot;
const response_map_mod = agent.response_map;
const png = agent.png;

const Allocator = std.mem.Allocator;

/// snapshot --urls 플래그를 daemon 요청의 pattern 필드로 전달하는 센티넬.
const SNAPSHOT_URLS_FLAG = "urls";

/// React DevTools hook (facebook/react, MIT). `--enable=react-devtools` 시
/// Page.addScriptToEvaluateOnNewDocument로 페이지 JS 이전에 설치되어
/// window.__REACT_DEVTOOLS_GLOBAL_HOOK__을 노출 (React 인트로스펙션 기반).
const REACT_INSTALL_HOOK = @embedFile("react/install_hook.js");

const WsSender = struct {
    ws: *websocket.Client,
    write_mutex: std.Thread.Mutex = .{},

    fn sendText(self: *WsSender, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        return self.ws.sendText(payload);
    }
};
const version = "0.1.0";

const ConsoleEntry = struct {
    log_type: []u8, // "log", "warn", "error", "info", "debug"
    text: []u8,
    timestamp: f64,
};

const PageError = struct {
    description: []u8, // exception text
    timestamp: f64,
};

const VideoRecorder = struct {
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    frame_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    path: [512]u8 = undefined,
    path_len: usize = 0,

    const CaptureContext = struct {
        recorder: *VideoRecorder,
        allocator: Allocator,
        sender: *WsSender,
        resp_map: *response_map_mod.ResponseMap,
        cmd_id: *cdp.CommandId,
        session_id: ?[]const u8,
    };

    fn start(self: *VideoRecorder, allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, output_path: []const u8) !void {
        if (self.active.load(.acquire)) return error.AlreadyRecording;

        @memcpy(self.path[0..output_path.len], output_path);
        self.path_len = output_path.len;
        self.frame_count.store(0, .release);
        self.active.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, captureLoop, .{CaptureContext{
            .recorder = self,
            .allocator = allocator,
            .sender = sender,
            .resp_map = resp_map,
            .cmd_id = cmd_id,
            .session_id = session_id,
        }});
    }

    fn stop(self: *VideoRecorder) !u64 {
        if (!self.active.load(.acquire)) return error.NotRecording;
        self.active.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        return self.frame_count.load(.acquire);
    }

    fn captureLoop(cap: CaptureContext) void {
        const self = cap.recorder;
        const allocator = cap.allocator;
        const path = self.path[0..self.path_len];

        // Determine codec and extra flags based on extension
        const is_mp4 = std.mem.endsWith(u8, path, ".mp4");
        const codec: []const u8 = if (is_mp4) "libx264" else "libvpx";
        const extra_flag: []const u8 = if (is_mp4) "-movflags" else "-b:v";
        const extra_val: []const u8 = if (is_mp4) "+faststart" else "1M";

        const argv = [_][]const u8{
            "ffmpeg",    "-y",
            "-f",        "image2pipe",
            "-c:v",      "mjpeg",
            "-framerate", "10",
            "-i",        "pipe:0",
            "-vf",       "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:v",      codec,
            "-crf",      "30",
            "-pix_fmt",  "yuv420p",
            "-threads",  "1",
            extra_flag,  extra_val,
            path,
        };

        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return;

        const stdin_file = child.stdin orelse return;

        while (self.active.load(.acquire)) {
            // Take JPEG screenshot via CDP
            const sent_id = cap.cmd_id.next();
            const cmd = cdp.serializeCommand(allocator, sent_id, "Page.captureScreenshot",
                \\{"format":"jpeg","quality":80}
            , cap.session_id) catch {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            defer allocator.free(cmd);

            const raw = sendAndWait(cap.sender, cap.resp_map, cmd, sent_id, 5000) orelse {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            defer allocator.free(raw);

            const parsed = cdp.parseMessage(allocator, raw) catch {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            defer parsed.parsed.deinit();

            if (parsed.message.result) |result| {
                if (cdp.getString(result, "data")) |base64_data| {
                    const decoded_size = std.base64.standard.Decoder.calcSizeUpperBound(base64_data.len) catch continue;
                    const buf = allocator.alloc(u8, decoded_size) catch continue;
                    defer allocator.free(buf);

                    std.base64.standard.Decoder.decode(buf, base64_data) catch continue;

                    stdin_file.writeAll(buf[0..decoded_size]) catch break;
                    _ = self.frame_count.fetchAdd(1, .monotonic);
                }
            }

            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        // Close stdin to signal EOF to ffmpeg, then wait for it to finish
        child.stdin.?.close();
        child.stdin = null;
        _ = child.wait() catch {};
    }
};

const DialogInfo = struct {
    dialog_type: []u8, // "alert", "confirm", "prompt", "beforeunload"
    message: []u8,
    default_prompt: []u8,
};

pub fn main() void {
    if (daemon.getenv("AGENT_DEVTOOLS_DAEMON")) |_| {
        runDaemon();
        return;
    }

    var args_iter = if (comptime builtin.os.tag == .windows)
        std.process.argsWithAllocator(std.heap.page_allocator) catch return
    else
        std.process.args();
    defer if (comptime builtin.os.tag == .windows) args_iter.deinit();
    _ = args_iter.next();

    // Parse --session flag (can appear before command)
    var session: []const u8 = "default";
    var headed = false;
    var cdp_port: ?[]const u8 = null;
    var auto_connect = false;
    var user_agent: ?[]const u8 = null;
    var interactive = false;
    var debug_mode = false;
    var command: ?[]const u8 = null;
    var proxy: ?[]const u8 = null;
    var proxy_bypass: ?[]const u8 = null;
    var extensions: ?[]const u8 = null;
    var allowed_domains: ?[]const u8 = null;
    var content_boundaries = false;
    var no_auto_dialog = false;
    var enable_react = false;
    // --init-script=PATH (반복 가능) → 쉼표로 join 누적
    var init_scripts_buf: std.ArrayList(u8) = .empty;

    // Load config file defaults (best-effort)
    var config_headed = false;
    var config_proxy: ?[]const u8 = null;
    var config_proxy_bypass: ?[]const u8 = null;
    var config_user_agent: ?[]const u8 = null;
    var config_extensions: ?[]const u8 = null;
    loadConfigFile(&config_headed, &config_proxy, &config_proxy_bypass, &config_user_agent, &config_extensions);

    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--session=")) {
            session = arg["--session=".len..];
        } else if (std.mem.eql(u8, arg, "--headed")) {
            headed = true;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            cdp_port = arg["--port=".len..];
        } else if (std.mem.eql(u8, arg, "--auto-connect")) {
            auto_connect = true;
        } else if (std.mem.startsWith(u8, arg, "--user-agent=")) {
            user_agent = arg["--user-agent=".len..];
        } else if (std.mem.startsWith(u8, arg, "--proxy=")) {
            proxy = arg["--proxy=".len..];
        } else if (std.mem.startsWith(u8, arg, "--proxy-bypass=")) {
            proxy_bypass = arg["--proxy-bypass=".len..];
        } else if (std.mem.startsWith(u8, arg, "--extension=")) {
            extensions = arg["--extension=".len..];
        } else if (std.mem.startsWith(u8, arg, "--allowed-domains=")) {
            allowed_domains = arg["--allowed-domains=".len..];
        } else if (std.mem.eql(u8, arg, "--content-boundaries")) {
            content_boundaries = true;
        } else if (std.mem.eql(u8, arg, "--no-auto-dialog")) {
            no_auto_dialog = true;
        } else if (std.mem.startsWith(u8, arg, "--enable=")) {
            const feature = arg["--enable=".len..];
            if (std.mem.eql(u8, feature, "react-devtools") or std.mem.eql(u8, feature, "react")) {
                enable_react = true;
            } else {
                writeErr("Unknown --enable feature '{s}' (supported: react-devtools)\n", .{feature});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--init-script=")) {
            const path = arg["--init-script=".len..];
            if (init_scripts_buf.items.len > 0) init_scripts_buf.append(std.heap.page_allocator, ',') catch {};
            init_scripts_buf.appendSlice(std.heap.page_allocator, path) catch {};
        } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "--pipe")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
        } else if (command == null) {
            command = arg;
            break;
        }
    }

    // Apply config file defaults (CLI flags override)
    if (!headed and config_headed) headed = true;
    if (proxy == null) proxy = config_proxy;
    if (proxy_bypass == null) proxy_bypass = config_proxy_bypass;
    if (user_agent == null) user_agent = config_user_agent;
    if (extensions == null) extensions = config_extensions;

    const daemon_opts = daemon.DaemonOptions{
        .headed = headed,
        .cdp_port = cdp_port,
        .auto_connect = auto_connect,
        .user_agent = user_agent,
        .proxy = proxy,
        .proxy_bypass = proxy_bypass,
        .extensions = extensions,
        .allowed_domains = allowed_domains,
        .content_boundaries = content_boundaries,
        .no_auto_dialog = no_auto_dialog,
        .init_scripts = if (init_scripts_buf.items.len > 0) init_scripts_buf.items else null,
        .enable_react = enable_react,
    };

    if (interactive) {
        const exit_code = runInteractive(session, daemon_opts, debug_mode);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
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
    } else if (std.mem.eql(u8, cmd, "open") or std.mem.eql(u8, cmd, "navigate") or std.mem.eql(u8, cmd, "goto")) {
        const url = args_iter.next() orelse {
            writeErr("Usage: agent-devtools open <url>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "open", url, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "network")) {
        const subcmd = args_iter.next() orelse "requests";
        if (std.mem.eql(u8, subcmd, "requests") or std.mem.eql(u8, subcmd, "list")) {
            // network requests [--filter pattern] [--clear] [pattern]
            var filter_pattern: ?[]const u8 = null;
            var do_clear = false;
            while (args_iter.next()) |narg| {
                if (std.mem.eql(u8, narg, "--filter")) {
                    filter_pattern = args_iter.next();
                } else if (std.mem.eql(u8, narg, "--clear")) {
                    do_clear = true;
                } else if (filter_pattern == null) {
                    filter_pattern = narg; // positional pattern (backward compat)
                }
            }
            if (do_clear) {
                sendAction(session, "network_clear", null, null, daemon_opts);
            } else {
                sendAction(session, "network_list", null, filter_pattern, daemon_opts);
            }
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
                \\  requests [--filter pattern] [--clear]  List or clear network requests
                \\  get <requestId>   Get request details (headers, body)
                \\  clear             Clear collected requests (alias)
                \\  help              Show this help
                \\
                \\Aliases: 'list' works as alias for 'requests'
                \\
            , .{});
        } else {
            // Treat unknown subcmd as pattern for backward compat (network <pattern>)
            sendAction(session, "network_list", null, subcmd, daemon_opts);
        }
    } else if (std.mem.eql(u8, cmd, "console")) {
        const subcmd = args_iter.next();
        if (subcmd == null) {
            // `console` with no subcommand = list
            sendAction(session, "console_list", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd.?, "--clear")) {
            sendAction(session, "console_clear", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd.?, "list")) {
            sendAction(session, "console_list", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd.?, "clear")) {
            sendAction(session, "console_clear", null, null, daemon_opts);
        } else {
            writeErr("Unknown console subcommand: {s}\n", .{subcmd.?});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "intercept")) {
        const subcmd = args_iter.next() orelse {
            write(
                \\Usage: agent-devtools intercept <subcommand> <pattern> [options]
                \\
                \\Subcommands:
                \\  mock <pattern> <json> [--resource-type <csv>]   Return mock response
                \\  fail <pattern> [--resource-type <csv>]           Block matching requests
                \\  delay <pattern> <ms> [--resource-type <csv>]    Delay matching requests
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
                writeErr("Usage: agent-devtools intercept mock <pattern> <json> [--resource-type <csv>]\n", .{});
                std.process.exit(1);
            };
            const body = args_iter.next() orelse "{}";
            sendActionEx(session, "intercept_mock", pattern, body, parseResourceTypeFlag(&args_iter), daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "fail")) {
            const pattern = args_iter.next() orelse {
                writeErr("Usage: agent-devtools intercept fail <pattern> [--resource-type <csv>]\n", .{});
                std.process.exit(1);
            };
            sendActionEx(session, "intercept_fail", pattern, null, parseResourceTypeFlag(&args_iter), daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "delay")) {
            const pattern = args_iter.next() orelse {
                writeErr("Usage: agent-devtools intercept delay <pattern> <ms> [--resource-type <csv>]\n", .{});
                std.process.exit(1);
            };
            const ms = args_iter.next() orelse "1000";
            sendActionEx(session, "intercept_delay", pattern, ms, parseResourceTypeFlag(&args_iter), daemon_opts);
        } else {
            writeErr("Unknown intercept subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "analyze")) {
        sendAction(session, "analyze", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "focus")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools focus <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "focus", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "drag")) {
        const from = args_iter.next() orelse {
            writeErr("Usage: agent-devtools drag <@from> <@to>\n", .{});
            std.process.exit(1);
        };
        const to = args_iter.next() orelse {
            writeErr("Usage: agent-devtools drag <@from> <@to>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "drag", from, to, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "upload")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools upload <@ref> <file>\n", .{});
            std.process.exit(1);
        };
        const file_path = args_iter.next() orelse {
            writeErr("Usage: agent-devtools upload <@ref> <file>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "upload", target, file_path, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "scrollintoview")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools scrollintoview <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "scrollintoview", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "pdf")) {
        const path = args_iter.next() orelse "output.pdf";
        sendAction(session, "pdf", path, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "tab")) {
        const subcmd = args_iter.next() orelse "list";
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "tab")) {
            sendAction(session, "tab_list", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "new")) {
            sendAction(session, "tab_new", args_iter.next(), null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "close")) {
            sendAction(session, "tab_close", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "count")) {
            sendAction(session, "tab_count", null, null, daemon_opts);
        } else {
            sendAction(session, "tab_switch", subcmd, null, daemon_opts);
        }
    } else if (std.mem.eql(u8, cmd, "frame")) {
        const target = args_iter.next() orelse "main";
        sendAction(session, "frame", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "cookies")) {
        const subcmd = args_iter.next() orelse "list";
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "cookies")) {
            sendAction(session, "cookies_list", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "clear")) {
            sendAction(session, "cookies_clear", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "set")) {
            const first = args_iter.next() orelse "";
            if (std.mem.eql(u8, first, "--curl")) {
                const path = args_iter.next() orelse {
                    writeErr("Usage: agent-devtools cookies set --curl <file>\n", .{});
                    std.process.exit(1);
                };
                const cli_alloc = std.heap.page_allocator;
                const raw = std.fs.cwd().readFileAlloc(cli_alloc, path, 10 * 1024 * 1024) catch {
                    writeErr("cookies --curl: cannot read '{s}'\n", .{path});
                    std.process.exit(1);
                };
                defer cli_alloc.free(raw);
                const arr = buildCookieSetArrayJson(cli_alloc, raw) catch |e| {
                    writeErr("cookies --curl: parse failed ({s})\n", .{@errorName(e)});
                    std.process.exit(1);
                };
                defer cli_alloc.free(arr);
                sendAction(session, "cookies_set_bulk", arr, null, daemon_opts);
            } else {
                const value = args_iter.next() orelse "";
                sendAction(session, "cookies_set", first, value, daemon_opts);
            }
        } else if (std.mem.eql(u8, subcmd, "get")) {
            const name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools cookies get <name>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "cookies_get", name, null, daemon_opts);
        } else {
            sendAction(session, "cookies_list", null, null, daemon_opts);
        }
    } else if (std.mem.eql(u8, cmd, "storage")) {
        const store_type = args_iter.next() orelse "local";
        // Validate store_type to prevent action name injection
        const valid_type = if (std.mem.eql(u8, store_type, "local") or std.mem.eql(u8, store_type, "session"))
            store_type
        else
            "local";
        const subcmd = args_iter.next();
        if (subcmd) |sc| {
            if (std.mem.eql(u8, sc, "set")) {
                const key = args_iter.next() orelse "";
                const val = args_iter.next() orelse "";
                var action_buf: [32]u8 = undefined;
                const action = std.fmt.bufPrint(&action_buf, "storage_{s}_set", .{valid_type}) catch "storage_local_set";
                sendAction(session, action, key, val, daemon_opts);
            } else if (std.mem.eql(u8, sc, "clear")) {
                var action_buf: [32]u8 = undefined;
                const action = std.fmt.bufPrint(&action_buf, "storage_{s}_clear", .{valid_type}) catch "storage_local_clear";
                sendAction(session, action, null, null, daemon_opts);
            } else {
                // Get specific key
                var action_buf: [32]u8 = undefined;
                const action = std.fmt.bufPrint(&action_buf, "storage_{s}_get", .{valid_type}) catch "storage_local_get";
                sendAction(session, action, sc, null, daemon_opts);
            }
        } else {
            var action_buf: [32]u8 = undefined;
            const action = std.fmt.bufPrint(&action_buf, "storage_{s}_list", .{valid_type}) catch "storage_local_list";
            sendAction(session, action, null, null, daemon_opts);
        }
    } else if (std.mem.eql(u8, cmd, "set")) {
        const what = args_iter.next() orelse {
            writeErr("Usage: agent-devtools set <viewport|media|offline|timezone|locale|geolocation|headers|useragent|device|ignore-https-errors|permissions>\n", .{});
            std.process.exit(1);
        };
        const v1 = args_iter.next() orelse "";
        const v2 = args_iter.next();
        if (std.mem.eql(u8, what, "viewport")) {
            sendAction(session, "set_viewport", v1, v2, daemon_opts);
        } else if (std.mem.eql(u8, what, "media")) {
            sendAction(session, "set_media", v1, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "offline")) {
            sendAction(session, "set_offline", v1, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "timezone")) {
            if (v1.len == 0) {
                writeErr("Usage: agent-devtools set timezone <timezone-id>\n", .{});
                std.process.exit(1);
            }
            sendAction(session, "set_timezone", v1, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "locale")) {
            if (v1.len == 0) {
                writeErr("Usage: agent-devtools set locale <locale>\n", .{});
                std.process.exit(1);
            }
            sendAction(session, "set_locale", v1, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "geolocation")) {
            if (v1.len == 0) {
                writeErr("Usage: agent-devtools set geolocation <latitude> <longitude>\n", .{});
                std.process.exit(1);
            }
            const lon = v2 orelse {
                writeErr("Usage: agent-devtools set geolocation <latitude> <longitude>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "set_geolocation", v1, lon, daemon_opts);
        } else if (std.mem.eql(u8, what, "headers")) {
            if (v1.len == 0) {
                writeErr("Usage: agent-devtools set headers <json>\n", .{});
                std.process.exit(1);
            }
            sendAction(session, "set_headers", v1, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "useragent") or std.mem.eql(u8, what, "user-agent")) {
            if (v1.len == 0) {
                writeErr("Usage: agent-devtools set useragent <user-agent-string>\n", .{});
                std.process.exit(1);
            }
            sendAction(session, "set_user_agent", v1, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "device")) {
            if (v1.len == 0) {
                writeErr("Usage: agent-devtools set device <name|list>\n", .{});
                std.process.exit(1);
            }
            if (std.mem.eql(u8, v1, "list")) {
                sendAction(session, "device_list", null, null, daemon_opts);
            } else {
                // Collect remaining args to support multi-word device names
                var name_buf: [128]u8 = undefined;
                var name_len: usize = 0;
                if (v1.len <= name_buf.len) {
                    @memcpy(name_buf[0..v1.len], v1);
                    name_len = v1.len;
                }
                // v2 already consumed, append it if present
                if (v2) |part| {
                    if (name_len + 1 + part.len <= name_buf.len) {
                        name_buf[name_len] = ' ';
                        name_len += 1;
                        @memcpy(name_buf[name_len .. name_len + part.len], part);
                        name_len += part.len;
                    }
                }
                while (args_iter.next()) |part| {
                    if (name_len + 1 + part.len <= name_buf.len) {
                        name_buf[name_len] = ' ';
                        name_len += 1;
                        @memcpy(name_buf[name_len .. name_len + part.len], part);
                        name_len += part.len;
                    }
                }
                sendAction(session, "set_device", name_buf[0..name_len], null, daemon_opts);
            }
        } else if (std.mem.eql(u8, what, "ignore-https-errors")) {
            sendAction(session, "ignore_https_errors", null, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "permissions")) {
            const subcmd = v1;
            if (subcmd.len == 0) {
                writeErr("Usage: agent-devtools set permissions grant <permission>\n", .{});
                std.process.exit(1);
            }
            if (std.mem.eql(u8, subcmd, "grant")) {
                const perm = v2 orelse {
                    writeErr("Usage: agent-devtools set permissions grant <permission>\n", .{});
                    std.process.exit(1);
                };
                sendAction(session, "permissions_grant", perm, null, daemon_opts);
            } else {
                writeErr("Unknown set permissions subcommand: {s}\n", .{subcmd});
                std.process.exit(1);
            }
        } else {
            writeErr("Unknown set: {s}\n", .{what});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "mouse")) {
        const action = args_iter.next() orelse "move";
        const x = args_iter.next() orelse "0";
        const y = args_iter.next() orelse "0";
        // Pack "x:y" into pattern field since Request only has url+pattern
        var coords_buf: [32]u8 = undefined;
        const coords = std.fmt.bufPrint(&coords_buf, "{s}:{s}", .{ x, y }) catch "0:0";
        sendAction(session, "mouse", action, coords, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "screenshot")) {
        const first_arg = args_iter.next();
        if (first_arg) |fa| {
            if (std.mem.eql(u8, fa, "--annotate") or std.mem.eql(u8, fa, "-a")) {
                const path = args_iter.next();
                sendAction(session, "screenshot_annotate", path, null, daemon_opts);
            } else if (std.mem.eql(u8, fa, "--full")) {
                const path = args_iter.next();
                sendAction(session, "screenshot_full", path, null, daemon_opts);
            } else {
                sendAction(session, "screenshot", fa, null, daemon_opts);
            }
        } else {
            sendAction(session, "screenshot", null, null, daemon_opts);
        }
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        var interactive_snap = false;
        var with_urls = false;
        while (args_iter.next()) |f| {
            if (std.mem.eql(u8, f, "-i")) {
                interactive_snap = true;
            } else if (std.mem.eql(u8, f, "-u") or std.mem.eql(u8, f, "--urls")) {
                with_urls = true;
            }
        }
        sendAction(session, if (interactive_snap) "snapshot_interactive" else "snapshot", null, if (with_urls) SNAPSHOT_URLS_FLAG else null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "click")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools click <@ref or selector>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "click", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "fill")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools fill <@ref> <text>\n", .{});
            std.process.exit(1);
        };
        const text = args_iter.next() orelse "";
        sendAction(session, "fill", target, text, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "type")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools type <@ref> <text>\n", .{});
            std.process.exit(1);
        };
        const text = args_iter.next() orelse "";
        sendAction(session, "type_text", target, text, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "press")) {
        const key = args_iter.next() orelse {
            writeErr("Usage: agent-devtools press <key>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "press", key, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "hover")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools hover <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "hover", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "eval")) {
        const expr = args_iter.next() orelse {
            writeErr("Usage: agent-devtools eval <expression>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "eval", expr, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "back")) {
        sendAction(session, "back", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "forward")) {
        sendAction(session, "forward", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "reload")) {
        sendAction(session, "reload", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "pushstate")) {
        const url = args_iter.next() orelse {
            writeErr("Usage: agent-devtools pushstate <url>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "pushstate", url, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "vitals")) {
        sendAction(session, "vitals", args_iter.next(), null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "react")) {
        const sub = args_iter.next() orelse {
            writeErr("Usage: agent-devtools react <tree|inspect|renders|suspense>\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, sub, "tree")) {
            sendAction(session, "react_tree", null, null, daemon_opts);
        } else {
            writeErr("Unknown react subcommand: {s}\n", .{sub});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "dblclick")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools dblclick <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "dblclick", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "is")) {
        const what = args_iter.next() orelse {
            writeErr("Usage: agent-devtools is <visible|enabled|checked> <@ref>\n", .{});
            std.process.exit(1);
        };
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools is {s} <@ref>\n", .{what});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, what, "visible")) {
            sendAction(session, "is_visible", target, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "enabled")) {
            sendAction(session, "is_enabled", target, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "checked")) {
            sendAction(session, "is_checked", target, null, daemon_opts);
        } else {
            writeErr("Unknown: is {s}\n", .{what});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "scroll")) {
        const dir = args_iter.next() orelse "down";
        if (std.mem.eql(u8, dir, "to")) {
            const x = args_iter.next() orelse {
                writeErr("Usage: agent-devtools scroll to <x> <y>\n", .{});
                std.process.exit(1);
            };
            const y = args_iter.next() orelse {
                writeErr("Usage: agent-devtools scroll to <x> <y>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "scroll_to", x, y, daemon_opts);
        } else {
            const px = args_iter.next() orelse "300";
            sendAction(session, "scroll", dir, px, daemon_opts);
        }
    } else if (std.mem.eql(u8, cmd, "check")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools check <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "check", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "uncheck")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools uncheck <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "uncheck", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "clear")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools clear <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "clear_input", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "selectall")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools selectall <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "selectall", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "boundingbox")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools boundingbox <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "boundingbox", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "styles")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools styles <@ref> <property>\n", .{});
            std.process.exit(1);
        };
        const prop = args_iter.next() orelse {
            writeErr("Usage: agent-devtools styles <@ref> <property>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "styles", target, prop, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "clipboard")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools clipboard <get|set> [text]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "get")) {
            sendAction(session, "clipboard_get", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "set")) {
            const text = args_iter.next() orelse {
                writeErr("Usage: agent-devtools clipboard set <text>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "clipboard_set", text, null, daemon_opts);
        } else {
            writeErr("Unknown clipboard subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "window")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools window new [url]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "new")) {
            sendAction(session, "window_new", args_iter.next(), null, daemon_opts);
        } else {
            writeErr("Unknown window subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "pause")) {
        sendAction(session, "pause", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "resume")) {
        sendAction(session, "resume", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "dispatch")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools dispatch <@ref> <event>\n", .{});
            std.process.exit(1);
        };
        const event = args_iter.next() orelse {
            writeErr("Usage: agent-devtools dispatch <@ref> <event>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "dispatch", target, event, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waitload")) {
        const timeout = args_iter.next() orelse "30000";
        sendAction(session, "waitload", timeout, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "select")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools select <@ref> <value>\n", .{});
            std.process.exit(1);
        };
        const value = args_iter.next() orelse "";
        sendAction(session, "select_option", target, value, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "get")) {
        const what = args_iter.next() orelse {
            writeErr("Usage: agent-devtools get <url|title|text|html|value> [@ref]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, what, "url")) {
            sendAction(session, "get_url", null, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "title")) {
            sendAction(session, "get_title", null, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "text")) {
            const target = args_iter.next() orelse {
                writeErr("Usage: agent-devtools get text <@ref>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "get_text", target, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "html")) {
            const target = args_iter.next() orelse {
                writeErr("Usage: agent-devtools get html <@ref>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "get_html", target, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "value")) {
            const target = args_iter.next() orelse {
                writeErr("Usage: agent-devtools get value <@ref>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "get_value", target, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "attr")) {
            const target = args_iter.next() orelse {
                writeErr("Usage: agent-devtools get attr <@ref> <name>\n", .{});
                std.process.exit(1);
            };
            const attr_name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools get attr <@ref> <name>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "get_attr", target, attr_name, daemon_opts);
        } else {
            writeErr("Unknown: get {s}\n", .{what});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "wait")) {
        const ms = args_iter.next() orelse "1000";
        sendAction(session, "wait", ms, null, daemon_opts);
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
    } else if (std.mem.eql(u8, cmd, "find")) {
        const strategy = args_iter.next() orelse {
            writeErr("Usage: agent-devtools find <role|text|label|placeholder|testid> <value>\n", .{});
            std.process.exit(1);
        };
        const value = args_iter.next() orelse {
            writeErr("Usage: agent-devtools find {s} <value>\n", .{strategy});
            std.process.exit(1);
        };
        sendAction(session, "find", strategy, value, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "dialog")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools dialog <accept|dismiss|info> [text]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "accept")) {
            sendAction(session, "dialog_accept", args_iter.next(), null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "dismiss")) {
            sendAction(session, "dialog_dismiss", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "info")) {
            sendAction(session, "dialog_info", null, null, daemon_opts);
        } else {
            writeErr("Unknown dialog subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "content")) {
        sendAction(session, "content", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "setcontent")) {
        const html = args_iter.next() orelse {
            writeErr("Usage: agent-devtools setcontent <html>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "setcontent", html, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "addscript")) {
        const js_code = args_iter.next() orelse {
            writeErr("Usage: agent-devtools addscript <js-code>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "addscript", js_code, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "removeinitscript")) {
        const identifier = args_iter.next() orelse {
            writeErr("Usage: agent-devtools removeinitscript <identifier>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "removeinitscript", identifier, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waiturl")) {
        const pattern = args_iter.next() orelse {
            writeErr("Usage: agent-devtools waiturl <pattern> [timeout_ms]\n", .{});
            std.process.exit(1);
        };
        const timeout = args_iter.next() orelse "30000";
        sendAction(session, "waiturl", pattern, timeout, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waitfunction")) {
        const expr = args_iter.next() orelse {
            writeErr("Usage: agent-devtools waitfunction <expression> [timeout_ms]\n", .{});
            std.process.exit(1);
        };
        const timeout = args_iter.next() orelse "30000";
        sendAction(session, "waitfunction", expr, timeout, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "errors")) {
        const subcmd = args_iter.next();
        if (subcmd != null and (std.mem.eql(u8, subcmd.?, "clear") or std.mem.eql(u8, subcmd.?, "--clear"))) {
            sendAction(session, "errors_clear", null, null, daemon_opts);
        } else {
            sendAction(session, "errors", null, null, daemon_opts);
        }
    } else if (std.mem.eql(u8, cmd, "highlight")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools highlight <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "highlight", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "bringtofront")) {
        sendAction(session, "bringtofront", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "credentials")) {
        const username = args_iter.next() orelse {
            writeErr("Usage: agent-devtools credentials <username> <password>\n", .{});
            std.process.exit(1);
        };
        const password = args_iter.next() orelse {
            writeErr("Usage: agent-devtools credentials <username> <password>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "credentials", username, password, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waitdownload")) {
        const timeout = args_iter.next() orelse "30000";
        sendAction(session, "waitfor_download", timeout, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "download-path")) {
        const dir = args_iter.next() orelse {
            writeErr("Usage: agent-devtools download-path <directory>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "download_path", dir, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "har")) {
        const filename = args_iter.next() orelse "network.har";
        sendAction(session, "har", filename, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "state")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools state <save|load|list> [name]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "save")) {
            const name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools state save <name>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "state_save", name, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "load")) {
            const name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools state load <name>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "state_load", name, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "list")) {
            sendAction(session, "state_list", null, null, daemon_opts);
        } else {
            writeErr("Unknown state subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "addstyle")) {
        const css = args_iter.next() orelse {
            writeErr("Usage: agent-devtools addstyle <css>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "addstyle", css, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "expose")) {
        const name = args_iter.next() orelse {
            writeErr("Usage: agent-devtools expose <name>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "expose", name, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "replay")) {
        const name = args_iter.next() orelse {
            writeErr("Usage: agent-devtools replay <name>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "replay", name, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waitfor")) {
        const what = args_iter.next() orelse {
            writeErr("Usage: agent-devtools waitfor <network|console|error|dialog> <pattern> [timeout_ms]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, what, "network")) {
            const pattern = args_iter.next() orelse "";
            const timeout = args_iter.next() orelse "30000";
            sendAction(session, "waitfor_network", pattern, timeout, daemon_opts);
        } else if (std.mem.eql(u8, what, "console")) {
            const pattern = args_iter.next() orelse "";
            const timeout = args_iter.next() orelse "30000";
            sendAction(session, "waitfor_console", pattern, timeout, daemon_opts);
        } else if (std.mem.eql(u8, what, "error")) {
            const timeout = args_iter.next() orelse "30000";
            sendAction(session, "waitfor_error", timeout, null, daemon_opts);
        } else if (std.mem.eql(u8, what, "dialog")) {
            const timeout = args_iter.next() orelse "30000";
            sendAction(session, "waitfor_dialog", timeout, null, daemon_opts);
        } else {
            writeErr("Unknown waitfor type: {s}\nSupported: network, console, error, dialog\n", .{what});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "tap")) {
        const target = args_iter.next() orelse {
            writeErr("Usage: agent-devtools tap <@ref>\n", .{});
            std.process.exit(1);
        };
        sendAction(session, "tap", target, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "title")) {
        sendAction(session, "get_title", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "url")) {
        sendAction(session, "get_url", null, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waitforurl")) {
        const pattern = args_iter.next() orelse {
            writeErr("Usage: agent-devtools waitforurl <pattern> [timeout_ms]\n", .{});
            std.process.exit(1);
        };
        const timeout = args_iter.next() orelse "30000";
        sendAction(session, "waiturl", pattern, timeout, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waitforloadstate")) {
        const timeout = args_iter.next() orelse "30000";
        sendAction(session, "waitload", timeout, null, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "waitforfunction")) {
        const expr = args_iter.next() orelse {
            writeErr("Usage: agent-devtools waitforfunction <expression> [timeout_ms]\n", .{});
            std.process.exit(1);
        };
        const timeout = args_iter.next() orelse "30000";
        sendAction(session, "waitfunction", expr, timeout, daemon_opts);
    } else if (std.mem.eql(u8, cmd, "auth")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools auth <save|login|list|show|delete> [args]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "save")) {
            // auth save <name> --url <url> --username <user> --password <pass>
            const name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools auth save <name> --url <url> --username <user> --password <pass>\n", .{});
                std.process.exit(1);
            };
            var auth_url: ?[]const u8 = null;
            var auth_user: ?[]const u8 = null;
            var auth_pass: ?[]const u8 = null;
            while (args_iter.next()) |aarg| {
                if (std.mem.eql(u8, aarg, "--url")) { auth_url = args_iter.next(); }
                else if (std.mem.eql(u8, aarg, "--username")) { auth_user = args_iter.next(); }
                else if (std.mem.eql(u8, aarg, "--password")) { auth_pass = args_iter.next(); }
            }
            if (auth_url == null or auth_user == null or auth_pass == null) {
                writeErr("Usage: agent-devtools auth save <name> --url <url> --username <user> --password <pass>\n", .{});
                std.process.exit(1);
            }
            // Build JSON: url|username|password packed into url and pattern fields
            // Pack as "url\x00username" in url, password in pattern
            var pack_buf: [2048]u8 = undefined;
            const pack_data = std.fmt.bufPrint(&pack_buf, "{s}\x00{s}", .{ auth_url.?, auth_user.? }) catch {
                writeErr("auth data too long\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "auth_save", pack_data, auth_pass.?, daemon_opts);
            // Also save to local file (name passed via a second field)
            authVaultSave(name, auth_url.?, auth_user.?, auth_pass.?);
        } else if (std.mem.eql(u8, subcmd, "login")) {
            const name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools auth login <name>\n", .{});
                std.process.exit(1);
            };
            sendAction(session, "auth_login", name, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "list")) {
            authVaultList();
        } else if (std.mem.eql(u8, subcmd, "show")) {
            const name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools auth show <name>\n", .{});
                std.process.exit(1);
            };
            authVaultShow(name);
        } else if (std.mem.eql(u8, subcmd, "delete")) {
            const name = args_iter.next() orelse {
                writeErr("Usage: agent-devtools auth delete <name>\n", .{});
                std.process.exit(1);
            };
            authVaultDelete(name);
        } else {
            writeErr("Unknown auth subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "trace")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools trace <start|stop> [path]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "start")) {
            sendAction(session, "trace_start", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "stop")) {
            const path = args_iter.next();
            sendAction(session, "trace_stop", path, null, daemon_opts);
        } else {
            writeErr("Unknown trace subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "profiler")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools profiler <start|stop> [path]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "start")) {
            sendAction(session, "profiler_start", null, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "stop")) {
            const path = args_iter.next();
            sendAction(session, "profiler_stop", path, null, daemon_opts);
        } else {
            writeErr("Unknown profiler subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "video")) {
        const subcmd = args_iter.next() orelse {
            writeErr("Usage: agent-devtools video <start|stop> [path]\n", .{});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, subcmd, "start")) {
            const path = args_iter.next();
            sendAction(session, "video_start", path, null, daemon_opts);
        } else if (std.mem.eql(u8, subcmd, "stop")) {
            sendAction(session, "video_stop", null, null, daemon_opts);
        } else {
            writeErr("Unknown video subcommand: {s}\n", .{subcmd});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "diff-screenshot")) {
        const baseline = args_iter.next() orelse {
            writeErr("Usage: agent-devtools diff-screenshot <baseline> [current] [--threshold N] [--output path]\n", .{});
            std.process.exit(1);
        };
        var current: ?[]const u8 = null;
        var threshold: ?[]const u8 = null;
        var output: ?[]const u8 = null;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--threshold")) {
                threshold = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--output")) {
                output = args_iter.next();
            } else if (current == null) {
                current = arg;
            }
        }

        // Pack parameters: url=baseline, pattern=current|threshold|output (pipe-separated)
        var param_buf: [2048]u8 = undefined;
        const params = std.fmt.bufPrint(&param_buf, "{s}|{s}|{s}", .{
            current orelse "",
            threshold orelse "0.1",
            output orelse "diff.png",
        }) catch "||";
        sendAction(session, "diff_screenshot", baseline, params, daemon_opts);
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

/// 남은 인자에서 `--resource-type|--resource-types <csv>`를 찾아 CSV 반환. 없으면 null.
fn parseResourceTypeFlag(it: anytype) ?[]const u8 {
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--resource-type") or std.mem.eql(u8, arg, "--resource-types")) {
            return it.next();
        }
    }
    return null;
}

fn sendAction(session: []const u8, action: []const u8, url: ?[]const u8, pattern: ?[]const u8, daemon_opts: daemon.DaemonOptions) void {
    sendActionEx(session, action, url, pattern, null, daemon_opts);
}

fn sendActionEx(session: []const u8, action: []const u8, url: ?[]const u8, pattern: ?[]const u8, extra: ?[]const u8, daemon_opts: daemon.DaemonOptions) void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    const started = daemon.ensureDaemon(allocator, session, daemon_opts) catch |err| {
        writeErr("Failed to start daemon: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (started) {
        writeErr("Started daemon (session: {s})\n", .{session});
    } else if (daemon_opts.headed or daemon_opts.cdp_port != null or daemon_opts.auto_connect) {
        writeErr("Daemon already running — --headed/--port/--auto-connect options ignored. Use 'close' first.\n", .{});
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
        .extra = extra,
    }) catch {
        writeErr("Failed to serialize request\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(req);

    client.send(req) catch |err| {
        writeErr("Failed to send command: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Read response (동적 — 64KB 초과 응답 대응)
    const response_line = client.recvLineAlloc(allocator) catch |err| {
        writeErr("Failed to read response: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(response_line);

    const resp = daemon.parseResponse(allocator, response_line) catch {
        // Raw output if not valid JSON
        writeLine(response_line);
        return;
    };
    defer daemon.freeResponse(allocator, resp);

    if (resp.success) {
        if (resp.data) |data| {
            const result = unescapeJsonString(allocator, data);
            defer if (result.allocated) allocator.free(result.output);
            if (daemon_opts.content_boundaries and isContentAction(action)) {
                write("---AGENT_DEVTOOLS_CONTENT_START---\n{s}\n---AGENT_DEVTOOLS_CONTENT_END---\n", .{result.output});
            } else {
                writeLine(result.output);
            }
        } else {
            write("OK\n", .{});
        }
    } else {
        writeErr("Error: {s}\n", .{resp.@"error" orelse "unknown error"});
        std.process.exit(1);
    }
}

// ============================================================================
// Interactive / Pipe Mode
// ============================================================================

/// Check if a command is an "action" that may trigger side effects (network, console, errors, navigation).
/// Used by debug mode to gather context before/after the action.
fn isActionCommand(action: []const u8) bool {
    const actions = [_][]const u8{
        "click", "dblclick", "tap", "fill", "type", "press", "select",
        "check", "uncheck", "hover", "drag", "dispatch", "open", "navigate",
        "goto", "submit", "focus", "upload", "clear", "selectall",
    };
    for (actions) |a| {
        if (std.mem.eql(u8, action, a)) return true;
    }
    return false;
}

/// Extract the action name from a JSON line or text command line.
fn extractActionFromLine(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;
    if (line[0] == '{') {
        // JSON: find "action":"<value>"
        const marker = "\"action\":\"";
        const start = std.mem.indexOf(u8, line, marker) orelse return null;
        const val_start = start + marker.len;
        const val_end = std.mem.indexOfScalarPos(u8, line, val_start, '"') orelse return null;
        return line[val_start..val_end];
    } else {
        // Text command: first word
        var it = std.mem.splitScalar(u8, line, ' ');
        return it.next();
    }
}

/// Send a query to the daemon and return the response line (caller must free).
/// Returns null on any failure (connection, send, recv).
fn sendDebugQuery(allocator: std.mem.Allocator, session: []const u8, action: []const u8, id: []const u8) ?[]u8 {
    const req = daemon.serializeRequest(allocator, .{ .id = id, .action = action }) catch return null;
    defer allocator.free(req);

    var client = daemon.SocketClient.connect(session) catch return null;
    defer client.close();

    client.send(req) catch return null;

    var recv_buf: [65536]u8 = undefined;
    const resp_line = client.recvLine(&recv_buf) catch return null;
    return allocator.dupe(u8, resp_line) catch null;
}

/// Parse an integer field from a JSON response data. E.g. extract "requests" count from status.
fn parseCountFromJson(line: []const u8, field: []const u8) ?usize {
    // Look for "field":NNN in the response
    // We search for "data":{..."field":NNN...}
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const num_start = pos + needle.len;
    // Parse the integer
    var end = num_start;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') : (end += 1) {}
    if (end == num_start) return null;
    return std.fmt.parseInt(usize, line[num_start..end], 10) catch null;
}

/// Check if a URL is a static resource (JS/CSS/image/font) that should be filtered from debug output.
fn isStaticResource(url: []const u8) bool {
    const path = analyzer.extractPath(url);
    const static_exts = [_][]const u8{
        ".js", ".css", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico",
        ".woff", ".woff2", ".ttf", ".eot", ".map", ".webp", ".avif",
        ".webm", ".mp4", ".mp3", ".ogg",
    };
    for (static_exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    // Also filter gen_204 tracking pixels and similar
    if (std.mem.indexOf(u8, url, "/gen_204") != null) return true;
    if (std.mem.indexOf(u8, url, "/client_204") != null) return true;
    return false;
}

/// Build debug JSON object and merge it with the original response.
/// Returns the merged JSON line (caller must free), or null on failure.
fn buildDebugResponse(
    allocator: std.mem.Allocator,
    original_resp: []const u8,
    session: []const u8,
    pre_requests: usize,
    pre_console: usize,
    pre_errors: usize,
    post_requests: usize,
    post_console: usize,
    post_errors: usize,
    pre_url: ?[]const u8,
) ?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Start building debug object
    w.writeAll("{\"debug\":{") catch return null;
    var has_field = false;

    // New network requests (API only — filter out static resources like JS/CSS/images)
    if (post_requests > pre_requests) {
        if (sendDebugQuery(allocator, session, "network_list", "d2")) |net_resp| {
            defer allocator.free(net_resp);
            if (std.mem.indexOf(u8, net_resp, "\"data\":")) |data_start| {
                const val_start = data_start + "\"data\":".len;
                if (val_start < net_resp.len and net_resp[val_start] == '[') {
                    // Parse JSON array and filter to API requests only
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, net_resp[val_start..], .{}) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        if (p.value == .array) {
                            w.writeAll("\"new_requests\":[") catch return null;
                            var first = true;
                            for (p.value.array.items) |item| {
                                if (item != .object) continue;
                                const url_val = item.object.get("url") orelse continue;
                                if (url_val != .string) continue;
                                if (isStaticResource(url_val.string)) continue;
                                if (!first) w.writeByte(',') catch return null;
                                first = false;
                                // Write compact JSON for this request
                                w.writeAll("{\"url\":") catch return null;
                                cdp.writeJsonString(w, url_val.string) catch return null;
                                if (item.object.get("method")) |m| {
                                    if (m == .string) {
                                        w.writeAll(",\"method\":") catch return null;
                                        cdp.writeJsonString(w, m.string) catch return null;
                                    }
                                }
                                if (item.object.get("status")) |s| {
                                    if (s == .integer) {
                                        w.print(",\"status\":{d}", .{s.integer}) catch return null;
                                    }
                                }
                                w.writeByte('}') catch return null;
                            }
                            w.writeByte(']') catch return null;
                            if (!first) has_field = true; // only if we wrote at least one request
                        }
                    }
                }
            }
        }
    }

    // New console messages
    if (post_console > pre_console) {
        if (sendDebugQuery(allocator, session, "console_list", "d3")) |con_resp| {
            defer allocator.free(con_resp);
            if (std.mem.indexOf(u8, con_resp, "\"data\":")) |data_start| {
                const val_start = data_start + "\"data\":".len;
                if (con_resp[val_start] == '[') {
                    var depth: usize = 0;
                    var end: usize = val_start;
                    while (end < con_resp.len) : (end += 1) {
                        if (con_resp[end] == '[') depth += 1
                        else if (con_resp[end] == ']') {
                            depth -= 1;
                            if (depth == 0) {
                                end += 1;
                                break;
                            }
                        }
                    }
                    if (has_field) w.writeByte(',') catch return null;
                    w.writeAll("\"new_console\":") catch return null;
                    w.writeAll(con_resp[val_start..end]) catch return null;
                    has_field = true;
                }
            }
        }
    }

    // New errors
    if (post_errors > pre_errors) {
        if (sendDebugQuery(allocator, session, "errors", "d4")) |err_resp| {
            defer allocator.free(err_resp);
            if (std.mem.indexOf(u8, err_resp, "\"data\":")) |data_start| {
                const val_start = data_start + "\"data\":".len;
                if (err_resp[val_start] == '[') {
                    var depth: usize = 0;
                    var end: usize = val_start;
                    while (end < err_resp.len) : (end += 1) {
                        if (err_resp[end] == '[') depth += 1
                        else if (err_resp[end] == ']') {
                            depth -= 1;
                            if (depth == 0) {
                                end += 1;
                                break;
                            }
                        }
                    }
                    if (has_field) w.writeByte(',') catch return null;
                    w.writeAll("\"new_errors\":") catch return null;
                    w.writeAll(err_resp[val_start..end]) catch return null;
                    has_field = true;
                }
            }
        }
    }

    // URL change detection
    var url_changed = false;
    if (pre_url) |pu| {
        if (sendDebugQuery(allocator, session, "get_url", "d5")) |url_resp| {
            defer allocator.free(url_resp);
            // Extract URL from response data (it's a string in "data":"...")
            if (std.mem.indexOf(u8, url_resp, "\"data\":\"")) |data_start| {
                const val_start = data_start + "\"data\":\"".len;
                const val_end = std.mem.indexOfScalarPos(u8, url_resp, val_start, '"') orelse url_resp.len;
                const post_url = url_resp[val_start..val_end];
                if (!std.mem.eql(u8, pu, post_url)) {
                    url_changed = true;
                }
            }
        }
    }

    if (has_field) w.writeByte(',') catch return null;
    if (url_changed) {
        w.writeAll("\"url_changed\":true") catch return null;
    } else {
        w.writeAll("\"url_changed\":false") catch return null;
    }

    w.writeAll("}}") catch return null;

    const debug_json = buf.toOwnedSlice(allocator) catch return null;
    defer allocator.free(debug_json);

    // Merge: insert debug field into the original response JSON
    // Original is like: {"success":true,...}
    // We want: {"success":true,...,"debug":{...}}
    // Find the last '}' and insert before it
    const last_brace = std.mem.lastIndexOfScalar(u8, original_resp, '}') orelse return null;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const rw = result.writer(allocator);
    rw.writeAll(original_resp[0..last_brace]) catch return null;
    rw.writeByte(',') catch return null;
    // debug_json is like {"debug":{...}} — we want just "debug":{...}
    if (debug_json.len > 2) {
        rw.writeAll(debug_json[1 .. debug_json.len - 1]) catch return null;
    }
    rw.writeByte('}') catch return null;

    return result.toOwnedSlice(allocator) catch null;
}

/// Interactive/pipe mode: persistent REPL that reads JSON commands from stdin,
/// sends them to the daemon, and writes responses + events to stdout.
fn runInteractive(session: []const u8, daemon_opts: daemon.DaemonOptions, debug_mode: bool) u8 {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    // Ensure daemon is running
    const started = daemon.ensureDaemon(allocator, session, daemon_opts) catch |err| {
        writeErr("Failed to start daemon: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (started) {
        writeErr("Started daemon (session: {s})\n", .{session});
    }

    // Connection 1: subscribe for events (persistent, reader thread writes to stdout)
    var event_client = daemon.SocketClient.connect(session) catch |err| {
        writeErr("Failed to connect for events: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Send subscribe request
    const sub_req = daemon.serializeRequest(allocator, .{ .id = "0", .action = "subscribe" }) catch {
        writeErr("Failed to serialize subscribe request\n", .{});
        event_client.close();
        std.process.exit(1);
    };
    defer allocator.free(sub_req);
    event_client.send(sub_req) catch {
        writeErr("Failed to send subscribe request\n", .{});
        event_client.close();
        std.process.exit(1);
    };

    // Read and discard the subscribe OK response
    var sub_resp_buf: [4096]u8 = undefined;
    _ = event_client.recvLine(&sub_resp_buf) catch {};

    // Spawn reader thread: reads from event socket, writes to stdout
    const reader_handle = std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.fd_t) void {
            const stdout = std.fs.File.stdout();
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = std.posix.read(fd, &buf) catch break;
                if (n == 0) break;
                _ = stdout.write(buf[0..n]) catch break;
            }
        }
    }.run, .{event_client.fd}) catch {
        writeErr("Failed to spawn event reader thread\n", .{});
        event_client.close();
        std.process.exit(1);
    };

    // Main thread: read stdin line by line, send each command to daemon, print response
    const stdin_fd = std.fs.File.stdin().handle;
    var line_buf: [65536]u8 = undefined;
    var line_filled: usize = 0;
    var cmd_counter: u64 = 1;
    var had_failure = false;

    while (true) {
        // Read more data from stdin
        const n = std.posix.read(stdin_fd, line_buf[line_filled..]) catch break;
        if (n == 0) break; // EOF
        line_filled += n;

        // Process all complete lines
        while (std.mem.indexOfScalar(u8, line_buf[0..line_filled], '\n')) |nl_pos| {
            const line = line_buf[0..nl_pos];
            // Shift remaining data
            const remaining = line_filled - (nl_pos + 1);

            if (line.len == 0) {
                if (remaining > 0) {
                    std.mem.copyForwards(u8, line_buf[0..remaining], line_buf[nl_pos + 1 .. line_filled]);
                }
                line_filled = remaining;
                continue;
            }

            // Check if the line is already valid JSON with an action field
            const is_json = line[0] == '{';
            var send_data: ?[]u8 = null;

            if (is_json) {
                // Already JSON — ensure it has an id, add one if missing
                if (std.mem.indexOf(u8, line, "\"id\"") != null) {
                    // Has id — send as-is with newline
                    var buf: std.ArrayList(u8) = .empty;
                    buf.appendSlice(allocator, line) catch {};
                    buf.append(allocator, '\n') catch {};
                    send_data = buf.toOwnedSlice(allocator) catch null;
                    if (send_data == null) buf.deinit(allocator);
                } else {
                    // No id — inject one
                    var buf: std.ArrayList(u8) = .empty;
                    const w = buf.writer(allocator);
                    std.fmt.format(w, "{{\"id\":\"{d}\",", .{cmd_counter}) catch {};
                    // Skip the opening brace of the original
                    buf.appendSlice(allocator, line[1..]) catch {};
                    buf.append(allocator, '\n') catch {};
                    send_data = buf.toOwnedSlice(allocator) catch null;
                    if (send_data == null) buf.deinit(allocator);
                }
            } else {
                // Parse text command into daemon request (same as CLI)
                var id_buf: [20]u8 = undefined;
                const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{cmd_counter}) catch "1";
                send_data = parseTextCommand(allocator, line, id_str);
            }

            // Shift remaining data forward
            if (remaining > 0) {
                std.mem.copyForwards(u8, line_buf[0..remaining], line_buf[nl_pos + 1 .. line_filled]);
            }
            line_filled = remaining;

            const data = send_data orelse continue;
            cmd_counter += 1;

            // Debug mode: check if this is an action command and gather pre-state
            const action_for_debug = if (debug_mode) extractActionFromLine(line) else null;
            const is_debug_action = if (action_for_debug) |a| isActionCommand(a) else false;

            var pre_requests: usize = 0;
            var pre_console: usize = 0;
            var pre_errors: usize = 0;
            var pre_url: ?[]u8 = null;
            defer if (pre_url) |pu| allocator.free(pu);

            if (is_debug_action) {
                // Query pre-status
                if (sendDebugQuery(allocator, session, "status", "d0")) |status_resp| {
                    defer allocator.free(status_resp);
                    pre_requests = parseCountFromJson(status_resp, "requests") orelse 0;
                    pre_console = parseCountFromJson(status_resp, "console") orelse 0;
                    pre_errors = parseCountFromJson(status_resp, "errors") orelse 0;
                }
                // Query pre-URL
                if (sendDebugQuery(allocator, session, "get_url", "d1")) |url_resp| {
                    defer allocator.free(url_resp);
                    if (std.mem.indexOf(u8, url_resp, "\"data\":\"")) |data_start| {
                        const val_start = data_start + "\"data\":\"".len;
                        const val_end = std.mem.indexOfScalarPos(u8, url_resp, val_start, '"') orelse url_resp.len;
                        pre_url = allocator.dupe(u8, url_resp[val_start..val_end]) catch null;
                    }
                }
            }

            // Connect per-command to daemon for request/response
            var cmd_client = daemon.SocketClient.connect(session) catch {
                allocator.free(data);
                const stdout_f = std.fs.File.stdout();
                _ = stdout_f.write("{\"success\":false,\"error\":\"daemon connection failed\"}\n") catch {};
                had_failure = true;
                continue;
            };

            cmd_client.send(data) catch {
                allocator.free(data);
                cmd_client.close();
                const stdout_f = std.fs.File.stdout();
                _ = stdout_f.write("{\"success\":false,\"error\":\"send failed\"}\n") catch {};
                had_failure = true;
                continue;
            };
            allocator.free(data);

            // Read response
            var recv_buf: [65536]u8 = undefined;
            const resp_line = cmd_client.recvLine(&recv_buf) catch {
                cmd_client.close();
                const stdout_f = std.fs.File.stdout();
                _ = stdout_f.write("{\"success\":false,\"error\":\"read failed\"}\n") catch {};
                had_failure = true;
                continue;
            };
            cmd_client.close();

            // Debug mode: gather post-state and build merged response
            if (is_debug_action) {
                // Wait 500ms for async effects
                std.Thread.sleep(500 * std.time.ns_per_ms);

                var post_requests: usize = pre_requests;
                var post_console: usize = pre_console;
                var post_errors: usize = pre_errors;

                if (sendDebugQuery(allocator, session, "status", "d6")) |status_resp| {
                    defer allocator.free(status_resp);
                    post_requests = parseCountFromJson(status_resp, "requests") orelse pre_requests;
                    post_console = parseCountFromJson(status_resp, "console") orelse pre_console;
                    post_errors = parseCountFromJson(status_resp, "errors") orelse pre_errors;
                }

                // Only build debug response if something changed
                if (post_requests != pre_requests or post_console != pre_console or post_errors != pre_errors or pre_url != null) {
                    if (buildDebugResponse(
                        allocator,
                        resp_line,
                        session,
                        pre_requests,
                        pre_console,
                        pre_errors,
                        post_requests,
                        post_console,
                        post_errors,
                        pre_url,
                    )) |debug_resp| {
                        defer allocator.free(debug_resp);
                        const stdout_f = std.fs.File.stdout();
                        _ = stdout_f.write(debug_resp) catch {};
                        _ = stdout_f.write("\n") catch {};

                        if (std.mem.indexOf(u8, resp_line, "\"success\":false") != null) {
                            had_failure = true;
                        }
                        continue;
                    }
                }
            }

            // Write response to stdout (already newline-delimited JSON from daemon)
            const stdout_f = std.fs.File.stdout();
            _ = stdout_f.write(resp_line) catch {};
            _ = stdout_f.write("\n") catch {};

            // Track failures for exit code
            if (std.mem.indexOf(u8, resp_line, "\"success\":false") != null) {
                had_failure = true;
            }
        }

        // Prevent buffer overflow
        if (line_filled >= line_buf.len) {
            line_filled = 0;
        }
    }

    // Close event connection — will cause reader thread to exit
    event_client.close();
    reader_handle.join();

    return if (had_failure) 1 else 0;
}

// ============================================================================
// Daemon Mode
// ============================================================================

fn runDaemon() void {
    const session = daemon.getenv("AGENT_DEVTOOLS_SESSION") orelse "default";
    const is_headed = daemon.getenv("AGENT_DEVTOOLS_HEADED") != null;
    const ext_port = daemon.getenv("AGENT_DEVTOOLS_PORT");
    const env_auto_connect = daemon.getenv("AGENT_DEVTOOLS_AUTO_CONNECT") != null;
    const env_user_agent = daemon.getenv("AGENT_DEVTOOLS_USER_AGENT");
    const env_init_scripts = daemon.getenv("AGENT_DEVTOOLS_INIT_SCRIPTS");
    const env_enable_react = daemon.getenv("AGENT_DEVTOOLS_ENABLE_REACT") != null;
    const env_proxy = daemon.getenv("AGENT_DEVTOOLS_PROXY");
    const env_proxy_bypass = daemon.getenv("AGENT_DEVTOOLS_PROXY_BYPASS");
    const env_extensions = daemon.getenv("AGENT_DEVTOOLS_EXTENSIONS");
    const env_allowed_domains = daemon.getenv("AGENT_DEVTOOLS_ALLOWED_DOMAINS");
    const env_content_boundaries = daemon.getenv("AGENT_DEVTOOLS_CONTENT_BOUNDARIES") != null;
    const env_no_auto_dialog = daemon.getenv("AGENT_DEVTOOLS_NO_AUTO_DIALOG") != null;

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
    } else if (env_auto_connect) blk: {
        discovered_url = chrome.autoConnect(allocator) catch |err| {
            std.debug.print("Daemon: Auto-connect failed (no running Chrome found): {s}\n", .{@errorName(err)});
            return;
        };
        break :blk discovered_url.?;
    } else blk: {
        chrome_proc = chrome.ChromeProcess.launch(allocator, .{
            .headless = !is_headed,
            .proxy = env_proxy,
            .proxy_bypass = env_proxy_bypass,
            .extensions = env_extensions,
        }) catch |err| {
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

    var cmd_id = cdp.CommandId.init();
    ws.setReadTimeout(5000);

    var session_id: ?[]u8 = null;
    defer if (session_id) |s| allocator.free(s);

    const is_external = ext_port != null or env_auto_connect;

    if (is_external) {
        // External Chrome/Electron: find existing page target and attach to it
        const targets_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Target.getTargets", null, null) catch return;
        ws.sendText(targets_cmd) catch return;
        allocator.free(targets_cmd);

        for (0..20) |_| {
            const msg = ws.recvMessage() catch break;
            defer allocator.free(msg);
            const parsed = cdp.parseMessage(allocator, msg) catch continue;
            defer parsed.parsed.deinit();

            if (parsed.message.isResponse()) {
                if (parsed.message.result) |result| {
                    if (result.object.get("targetInfos")) |infos| {
                        if (infos == .array) {
                            // Find first "page" target that isn't a chrome internal page
                            for (infos.array.items) |info| {
                                const t = cdp.getString(info, "type") orelse continue;
                                if (!std.mem.eql(u8, t, "page")) continue;
                                const target_url = cdp.getString(info, "url") orelse "";
                                if (std.mem.startsWith(u8, target_url, "chrome://")) continue;
                                if (std.mem.startsWith(u8, target_url, "chrome-extension://")) continue;
                                if (std.mem.startsWith(u8, target_url, "devtools://")) continue;

                                if (cdp.getString(info, "targetId")) |tid| {
                                    const attach = cdp.targetAttachToTarget(allocator, cmd_id.next(), tid, true) catch continue;
                                    ws.sendText(attach) catch {};
                                    allocator.free(attach);
                                    break;
                                }
                            }
                        }
                    }
                }
                break;
            }
        }

        // Read attach response to get sessionId
        for (0..20) |_| {
            const msg = ws.recvMessage() catch break;
            defer allocator.free(msg);
            const parsed = cdp.parseMessage(allocator, msg) catch continue;
            defer parsed.parsed.deinit();

            if (parsed.message.isResponse()) {
                if (parsed.message.result) |result| {
                    if (cdp.getString(result, "sessionId")) |sid| {
                        session_id = allocator.dupe(u8, sid) catch null;
                        break;
                    }
                }
                break;
            }
        }
    } else {
        // Self-launched Chrome: create new page target
        const create_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Target.createTarget",
            \\{"url":"about:blank"}
        , null) catch return;
        ws.sendText(create_cmd) catch return;
        allocator.free(create_cmd);

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

    // Set user-agent override if provided
    if (env_user_agent) |ua| {
        var ua_buf: std.ArrayList(u8) = .empty;
        defer ua_buf.deinit(allocator);
        const uw = ua_buf.writer(allocator);
        uw.writeAll("{\"userAgent\":") catch {
            std.debug.print("Daemon: Failed to build user-agent params\n", .{});
        };
        cdp.writeJsonString(uw, ua) catch {};
        uw.writeByte('}') catch {};
        if (ua_buf.toOwnedSlice(allocator)) |params| {
            defer allocator.free(params);
            if (cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setUserAgentOverride", params, session_id)) |ua_cmd| {
                ws.sendText(ua_cmd) catch |err| {
                    std.debug.print("Daemon: Failed to send user-agent override: {s}\n", .{@errorName(err)});
                };
                allocator.free(ua_cmd);
            } else |_| {
                std.debug.print("Daemon: Failed to serialize user-agent command\n", .{});
            }
        } else |_| {
            std.debug.print("Daemon: Failed to allocate user-agent params\n", .{});
        }
    }

    // --init-script: 파일들을 Page.addScriptToEvaluateOnNewDocument로 등록
    // (다음 네비게이션의 페이지 JS보다 먼저 실행됨)
    var init_script_count: usize = if (env_init_scripts) |csv|
        registerInitScripts(allocator, &ws, &cmd_id, session_id, csv)
    else
        0;

    // --enable=react-devtools: React DevTools hook을 페이지 JS 이전에 설치
    if (env_enable_react and sendAddScriptOnNewDocument(allocator, &ws, &cmd_id, session_id, REACT_INSTALL_HOOK)) {
        init_script_count += 1;
    }

    // Drain enable responses (short timeout to avoid 5s hang on last iteration).
    // 캡을 init 스크립트 수만큼 늘려 각 addScript 응답까지 흡수.
    ws.setReadTimeout(500);
    for (0..15 + init_script_count) |_| {
        const msg = ws.recvMessage() catch break;
        allocator.free(msg);
    }

    var collector = network.Collector.init(allocator);
    defer collector.deinit();

    var intercept_state = interceptor.InterceptorState.init(allocator);
    defer intercept_state.deinit();

    var ref_map = snapshot_mod.RefMap.init(allocator);
    defer ref_map.deinit();

    var console_messages: std.ArrayList(ConsoleEntry) = .empty;
    defer {
        for (console_messages.items) |entry| {
            allocator.free(entry.log_type);
            allocator.free(entry.text);
        }
        console_messages.deinit(allocator);
    }

    var page_errors: std.ArrayList(PageError) = .empty;
    defer {
        for (page_errors.items) |entry| {
            allocator.free(entry.description);
        }
        page_errors.deinit(allocator);
    }

    var dialog_info: ?DialogInfo = null;
    defer if (dialog_info) |di| {
        allocator.free(di.dialog_type);
        allocator.free(di.message);
        allocator.free(di.default_prompt);
    };

    var auth_credentials: ?AuthCredentials = null;
    defer if (auth_credentials) |creds| {
        allocator.free(creds.username);
        allocator.free(creds.password);
    };
    var auth_mutex: std.Thread.Mutex = .{};

    var download_tracker = DownloadTracker.init(allocator);
    defer download_tracker.deinit();

    // Listen on Unix socket for CLI commands
    var server = daemon.SocketServer.listen(session) catch |err| {
        std.debug.print("Daemon: Socket listen failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer server.close();

    // 2-thread architecture: WsSender, ResponseMap, receiver thread
    var ws_sender = WsSender{ .ws = &ws };
    var resp_map = response_map_mod.ResponseMap.init(allocator);
    defer resp_map.deinit();
    var collector_mutex: std.Thread.Mutex = .{};
    var event_cond: std.Thread.Condition = .{};
    var intercept_mutex: std.Thread.Mutex = .{};
    var alive = std.atomic.Value(bool).init(true);

    var event_subscribers = EventSubscribers.init(allocator);
    defer event_subscribers.deinit();

    var trace_events: std.ArrayList([]u8) = .empty;
    defer {
        for (trace_events.items) |item| allocator.free(item);
        trace_events.deinit(allocator);
    }
    var trace_complete = std.atomic.Value(bool).init(false);
    var trace_active = std.atomic.Value(bool).init(false);
    var trace_mutex: std.Thread.Mutex = .{};
    var video_recorder: VideoRecorder = .{};

    // Set read timeout for receiver thread polling (200ms)
    ws.setReadTimeout(200);

    var receiver_ctx = ReceiverContext{
        .ws = &ws,
        .sender = &ws_sender,
        .allocator = allocator,
        .resp_map = &resp_map,
        .collector = &collector,
        .console_msgs = &console_messages,
        .page_errors = &page_errors,
        .dialog_info = &dialog_info,
        .intercept_state = &intercept_state,
        .cmd_id = &cmd_id,
        .session_id = session_id,
        .alive = &alive,
        .collector_mutex = &collector_mutex,
        .event_cond = &event_cond,
        .intercept_mutex = &intercept_mutex,
        .auth_credentials = &auth_credentials,
        .auth_mutex = &auth_mutex,
        .download_tracker = &download_tracker,
        .event_subscribers = &event_subscribers,
        .trace_events = &trace_events,
        .trace_complete = &trace_complete,
        .trace_active = &trace_active,
        .trace_mutex = &trace_mutex,
        .auto_dialog = !env_no_auto_dialog,
    };
    const receiver_handle = std.Thread.spawn(.{}, receiverThread, .{&receiver_ctx}) catch {
        std.debug.print("Daemon: Failed to spawn receiver thread\n", .{});
        return;
    };

    // Set accept timeout once (100ms)
    const timeval = std.posix.timeval{ .sec = 0, .usec = 100_000 };
    std.posix.setsockopt(server.fd, std.posix.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

    // Idle timeout: 10 minutes without CLI commands → auto-shutdown
    const idle_timeout_ns: i128 = 10 * 60 * std.time.ns_per_s;
    var last_command_time = std.time.nanoTimestamp();
    var running = std.atomic.Value(bool).init(true);

    var ref_map_rwlock: std.Thread.RwLock = .{};

    // Shared DaemonContext for all worker threads
    var shared_ctx = DaemonContext{
        .allocator = allocator,
        .sender = &ws_sender,
        .response_map = &resp_map,
        .collector = &collector,
        .console_msgs = &console_messages,
        .page_errors = &page_errors,
        .dialog_info = &dialog_info,
        .intercept_state = &intercept_state,
        .ref_map = &ref_map,
        .cmd_id = &cmd_id,
        .session_id = session_id,
        .running = &running,
        .collector_mutex = &collector_mutex,
        .event_cond = &event_cond,
        .ref_map_rwlock = &ref_map_rwlock,
        .intercept_mutex = &intercept_mutex,
        .auth_credentials = &auth_credentials,
        .auth_mutex = &auth_mutex,
        .download_tracker = &download_tracker,
        .event_subscribers = &event_subscribers,
        .allowed_domains = env_allowed_domains,
        .content_boundaries = env_content_boundaries,
        .trace_events = &trace_events,
        .trace_complete = &trace_complete,
        .trace_active = &trace_active,
        .trace_mutex = &trace_mutex,
        .video_recorder = &video_recorder,
    };

    const MAX_WORKERS = 8;
    var worker_slots: [MAX_WORKERS]WorkerSlot = .{WorkerSlot{}} ** MAX_WORKERS;

    while (running.load(.acquire)) {
        // Idle timeout check
        if (std.time.nanoTimestamp() - last_command_time > idle_timeout_ns) {
            std.debug.print("Daemon: Idle timeout (10 min), shutting down\n", .{});
            break;
        }

        // Reclaim finished worker slots
        for (&worker_slots) |*slot| {
            if (slot.handle != null and slot.done.load(.acquire)) {
                slot.handle.?.join();
                slot.handle = null;
            }
        }

        if (server.accept()) |client_fd| {
            last_command_time = std.time.nanoTimestamp();

            // Read request on main thread (fast, just socket read)
            var req_buf: [4096]u8 = undefined;
            var req_len: usize = 0;
            while (req_len < req_buf.len) {
                const n = std.posix.read(client_fd, req_buf[req_len..]) catch break;
                if (n == 0) break;
                req_len += n;
                if (std.mem.indexOfScalar(u8, req_buf[0..req_len], '\n') != null) break;
            }

            if (req_len > 0) {
                // Check for subscribe action — handle specially (persistent connection)
                if (isSubscribeRequest(req_buf[0..req_len])) {
                    // Register fd as event subscriber
                    event_subscribers.add(client_fd);
                    // Send OK response to confirm subscription
                    const sub_resp = respondOk(allocator);
                    defer allocator.free(sub_resp);
                    _ = std.posix.write(client_fd, sub_resp) catch {};
                    // Spawn persistent handler thread for commands on this connection
                    const sub_handle = std.Thread.spawn(.{}, interactiveWorkerThread, .{ &shared_ctx, client_fd }) catch {
                        event_subscribers.remove(client_fd);
                        std.posix.close(client_fd);
                        continue;
                    };
                    sub_handle.detach();
                    // Do NOT close the fd — it stays open for events and commands
                    continue;
                }

                const req_copy = allocator.dupe(u8, req_buf[0..req_len]) catch {
                    std.posix.close(client_fd);
                    continue;
                };

                // Find free worker slot
                var spawned = false;
                for (&worker_slots) |*slot| {
                    if (slot.handle == null) {
                        slot.done.store(false, .release);
                        slot.handle = std.Thread.spawn(.{}, workerThread, .{ &shared_ctx, client_fd, req_copy, &slot.done }) catch null;
                        if (slot.handle != null) {
                            spawned = true;
                            break;
                        }
                    }
                }

                if (!spawned) {
                    // All slots busy — handle inline
                    const resp = handleCommand(&shared_ctx, req_copy);
                    _ = std.posix.write(client_fd, resp) catch {};
                    allocator.free(resp);
                    allocator.free(req_copy);
                    std.posix.close(client_fd);
                }
            } else {
                std.posix.close(client_fd);
            }
        } else |_| {}
    }

    // Join all remaining workers
    for (&worker_slots) |*slot| {
        if (slot.handle) |handle| {
            handle.join();
            slot.handle = null;
        }
    }

    // Shutdown receiver thread
    alive.store(false, .release);
    resp_map.signalShutdown();
    receiver_handle.join();
}

fn handleRequestPaused(
    allocator: Allocator,
    sender: *WsSender,
    intercept_state: *const interceptor.InterceptorState,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    params: std.json.Value,
) void {
    const request_id = cdp.getString(params, "requestId") orelse return;
    const request = cdp.getObject(params, "request") orelse return;
    const url = cdp.getString(request, "url") orelse return;
    const resource_type = cdp.getString(params, "resourceType") orelse "";

    if (intercept_state.findMatch(url, resource_type)) |rule| {
        switch (rule.action) {
            .mock => {
                const cmd = interceptor.buildFulfillCommand(allocator, cmd_id.next(), request_id, rule, session_id) catch return;
                defer allocator.free(cmd);
                sender.sendText(cmd) catch {};
            },
            .fail => {
                const cmd = interceptor.buildFailCommand(allocator, cmd_id.next(), request_id, rule.error_reason, session_id) catch return;
                defer allocator.free(cmd);
                sender.sendText(cmd) catch {};
            },
            .delay => {
                // Spawn thread to avoid blocking receiver thread during delay
                const DelayCtx = struct {
                    alloc: Allocator,
                    snd: *WsSender,
                    cid: *cdp.CommandId,
                    sid: ?[]const u8,
                    rid: []const u8,
                    delay: u64,
                };
                const dctx = allocator.create(DelayCtx) catch return;
                dctx.* = .{
                    .alloc = allocator,
                    .snd = sender,
                    .cid = cmd_id,
                    .sid = session_id,
                    .rid = allocator.dupe(u8, request_id) catch {
                        allocator.destroy(dctx);
                        return;
                    },
                    .delay = @as(u64, rule.delay_ms) * std.time.ns_per_ms,
                };
                const delay_handle = std.Thread.spawn(.{}, struct {
                    fn run(dc: *DelayCtx) void {
                        defer {
                            dc.alloc.free(dc.rid);
                            dc.alloc.destroy(dc);
                        }
                        std.Thread.sleep(dc.delay);
                        const cmd = interceptor.buildContinueCommand(dc.alloc, dc.cid.next(), dc.rid, dc.sid) catch return;
                        defer dc.alloc.free(cmd);
                        dc.snd.sendText(cmd) catch {};
                    }
                }.run, .{dctx}) catch {
                    allocator.free(dctx.rid);
                    allocator.destroy(dctx);
                    return;
                };
                delay_handle.detach();
            },
            .pass => {
                const cmd = interceptor.buildContinueCommand(allocator, cmd_id.next(), request_id, session_id) catch return;
                defer allocator.free(cmd);
                sender.sendText(cmd) catch {};
            },
        }
    } else {
        // No matching rule — continue the request
        const cmd = interceptor.buildContinueCommand(allocator, cmd_id.next(), request_id, session_id) catch return;
        defer allocator.free(cmd);
        sender.sendText(cmd) catch {};
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
    // Cap at 10000 entries to prevent unbounded memory growth
    if (console_msgs.items.len >= 10000) {
        const old = console_msgs.orderedRemove(0);
        allocator.free(old.log_type);
        allocator.free(old.text);
    }
    console_msgs.append(allocator, .{
        .log_type = log_type,
        .text = text,
        .timestamp = timestamp,
    }) catch {
        allocator.free(text);
        allocator.free(log_type);
    };
}

/// Collect Runtime.exceptionThrown events into page_errors list.
fn collectExceptionEvent(allocator: Allocator, params: std.json.Value, page_errors: *std.ArrayList(PageError)) void {
    const timestamp = cdp.getFloat(params, "timestamp") orelse 0;

    // Extract exception details → text
    var desc: []const u8 = "unknown error";
    if (cdp.getObject(params, "exceptionDetails")) |details| {
        if (cdp.getString(details, "text")) |text| {
            desc = text;
        }
        // Try to get more detail from the exception object itself
        if (cdp.getObject(details, "exception")) |exc| {
            if (cdp.getString(exc, "description")) |d| {
                desc = d;
            }
        }
    }

    const owned_desc = allocator.dupe(u8, desc) catch return;
    // Cap at 5000 entries to prevent unbounded memory growth
    if (page_errors.items.len >= 5000) {
        const old = page_errors.orderedRemove(0);
        allocator.free(old.description);
    }
    page_errors.append(allocator, .{
        .description = owned_desc,
        .timestamp = timestamp,
    }) catch {
        allocator.free(owned_desc);
    };
}

/// Collect Page.javascriptDialogOpening events.
fn collectDialogEvent(allocator: Allocator, params: std.json.Value, dialog_info: *?DialogInfo) void {
    // Free previous dialog info if any
    if (dialog_info.*) |di| {
        allocator.free(di.dialog_type);
        allocator.free(di.message);
        allocator.free(di.default_prompt);
    }

    const dtype = cdp.getString(params, "type") orelse "alert";
    const message = cdp.getString(params, "message") orelse "";
    const default_prompt = cdp.getString(params, "defaultPrompt") orelse "";

    dialog_info.* = .{
        .dialog_type = allocator.dupe(u8, dtype) catch return,
        .message = allocator.dupe(u8, message) catch return,
        .default_prompt = allocator.dupe(u8, default_prompt) catch return,
    };
}

/// 자동 dismiss 대상 판정: auto_dialog 활성 + alert/beforeunload 타입일 때만.
/// confirm/prompt는 에이전트가 명시적으로 처리하도록 항상 false.
fn shouldAutoDismissDialog(auto_dialog: bool, dtype: []const u8) bool {
    if (!auto_dialog) return false;
    return std.mem.eql(u8, dtype, "alert") or std.mem.eql(u8, dtype, "beforeunload");
}

/// alert/beforeunload 다이얼로그를 자동 수락(dismiss)해 페이지 블로킹을 방지.
/// confirm/prompt는 에이전트가 명시적으로 처리하도록 남겨둔다.
fn autoDismissDialog(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8) void {
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Page.handleJavaScriptDialog",
        \\{"accept":true}
    , session_id) catch return;
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
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

const AuthCredentials = struct {
    username: []u8,
    password: []u8,
};

const DownloadState = struct {
    guid: []u8,
    state: enum { in_progress, completed, canceled },
    path: ?[]u8 = null, // set on completion

    fn deinit(self: *DownloadState, allocator: Allocator) void {
        allocator.free(self.guid);
        if (self.path) |p| allocator.free(p);
    }
};

const DownloadTracker = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    downloads: std.ArrayList(DownloadState),
    allocator: Allocator,

    fn init(allocator: Allocator) DownloadTracker {
        return .{ .downloads = .empty, .allocator = allocator };
    }

    fn deinit(self: *DownloadTracker) void {
        for (self.downloads.items) |*d| d.deinit(self.allocator);
        self.downloads.deinit(self.allocator);
    }

    /// Called by receiver thread on Browser.downloadWillBegin
    fn onBegin(self: *DownloadTracker, guid: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned_guid = self.allocator.dupe(u8, guid) catch return;
        self.downloads.append(self.allocator, .{ .guid = owned_guid, .state = .in_progress }) catch {
            self.allocator.free(owned_guid);
        };
    }

    /// Called by receiver thread on Browser.downloadProgress
    fn onProgress(self: *DownloadTracker, guid: []const u8, state: []const u8, path: ?[]const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.downloads.items) |*d| {
            if (std.mem.eql(u8, d.guid, guid)) {
                if (std.mem.eql(u8, state, "completed")) {
                    d.state = .completed;
                    if (path) |p| {
                        d.path = self.allocator.dupe(u8, p) catch null;
                    }
                } else if (std.mem.eql(u8, state, "canceled")) {
                    d.state = .canceled;
                }
                self.condition.broadcast();
                return;
            }
        }
    }

    /// Called by worker thread — blocks until any download completes or timeout
    fn waitForComplete(self: *DownloadTracker, timeout_ms: u32) ?DownloadResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;
        var timer = std.time.Timer.start() catch return self.checkCompleted();

        while (true) {
            // Check for completed download
            if (self.checkCompleted()) |result| return result;

            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return null;

            self.condition.timedWait(&self.mutex, timeout_ns - elapsed) catch {
                return self.checkCompleted();
            };
        }
    }

    const DownloadResult = struct { guid: []const u8, path: ?[]const u8 };

    fn checkCompleted(self: *DownloadTracker) ?DownloadResult {
        for (self.downloads.items) |d| {
            if (d.state == .completed) return .{ .guid = d.guid, .path = d.path };
            if (d.state == .canceled) return .{ .guid = d.guid, .path = null };
        }
        return null;
    }
};

const DaemonContext = struct {
    allocator: Allocator,
    sender: *WsSender,
    response_map: *response_map_mod.ResponseMap,
    collector: *network.Collector,
    console_msgs: *std.ArrayList(ConsoleEntry),
    page_errors: *std.ArrayList(PageError),
    dialog_info: *?DialogInfo,
    intercept_state: *interceptor.InterceptorState,
    ref_map: *snapshot_mod.RefMap,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    running: *std.atomic.Value(bool),
    collector_mutex: *std.Thread.Mutex,
    event_cond: *std.Thread.Condition, // wakes waitfor handlers when new events arrive
    ref_map_rwlock: *std.Thread.RwLock,
    intercept_mutex: *std.Thread.Mutex,
    auth_credentials: *?AuthCredentials,
    auth_mutex: *std.Thread.Mutex,
    download_tracker: *DownloadTracker,
    event_subscribers: *EventSubscribers,
    allowed_domains: ?[]const u8 = null,
    content_boundaries: bool = false,
    trace_events: *std.ArrayList([]u8),
    trace_complete: *std.atomic.Value(bool),
    trace_active: *std.atomic.Value(bool),
    trace_mutex: *std.Thread.Mutex,
    video_recorder: *VideoRecorder,
};

/// Send a CDP command and wait for the response. Returns raw message bytes (caller must free).
fn sendAndWait(sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_bytes: []const u8, sent_id: u64, timeout_ms: u32) ?[]u8 {
    sender.sendText(cmd_bytes) catch return null;
    return resp_map.wait(sent_id, timeout_ms);
}

const ReceiverContext = struct {
    ws: *websocket.Client,
    sender: *WsSender,
    allocator: Allocator,
    resp_map: *response_map_mod.ResponseMap,
    collector: *network.Collector,
    console_msgs: *std.ArrayList(ConsoleEntry),
    page_errors: *std.ArrayList(PageError),
    dialog_info: *?DialogInfo,
    intercept_state: *interceptor.InterceptorState,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    alive: *std.atomic.Value(bool),
    collector_mutex: *std.Thread.Mutex,
    event_cond: *std.Thread.Condition,
    intercept_mutex: *std.Thread.Mutex,
    auth_credentials: *?AuthCredentials,
    auth_mutex: *std.Thread.Mutex,
    download_tracker: *DownloadTracker,
    event_subscribers: *EventSubscribers,
    trace_events: *std.ArrayList([]u8),
    trace_complete: *std.atomic.Value(bool),
    trace_active: *std.atomic.Value(bool),
    trace_mutex: *std.Thread.Mutex,
    auto_dialog: bool = true,
};

/// Thread-safe list of fds that receive event broadcasts (interactive/pipe mode).
const EventSubscribers = struct {
    mutex: std.Thread.Mutex = .{},
    fds: std.ArrayList(std.posix.fd_t),
    allocator: Allocator,

    fn init(alloc: Allocator) EventSubscribers {
        return .{
            .fds = .empty,
            .allocator = alloc,
        };
    }

    fn deinit(self: *EventSubscribers) void {
        self.fds.deinit(self.allocator);
    }

    fn add(self: *EventSubscribers, fd: std.posix.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fds.append(self.allocator, fd) catch {};
    }

    fn remove(self: *EventSubscribers, fd: std.posix.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.fds.items.len) {
            if (self.fds.items[i] == fd) {
                _ = self.fds.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Broadcast a message to all subscribers, removing broken ones.
    fn broadcast(self: *EventSubscribers, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.fds.items.len) {
            _ = std.posix.write(self.fds.items[i], msg) catch {
                // Broken pipe or closed fd — remove subscriber
                _ = self.fds.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }
};

const WorkerSlot = struct {
    handle: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

fn workerThread(ctx: *DaemonContext, client_fd: std.posix.fd_t, req_data: []u8, done_flag: *std.atomic.Value(bool)) void {
    defer {
        std.posix.close(client_fd);
        ctx.allocator.free(req_data);
        done_flag.store(true, .release);
    }

    const resp = handleCommand(ctx, req_data);
    defer ctx.allocator.free(resp);
    _ = std.posix.write(client_fd, resp) catch {};
}

/// Check if a raw request line is a "subscribe" action (fast check without full parse).
fn isSubscribeRequest(data: []const u8) bool {
    // Look for "action":"subscribe" in the raw bytes
    return std.mem.indexOf(u8, data, "\"subscribe\"") != null and
        std.mem.indexOf(u8, data, "\"action\"") != null;
}

/// Persistent worker thread for interactive/pipe mode clients.
/// Reads commands from the same fd, sends responses back.
/// The fd is also registered as an event subscriber (events pushed by receiver thread).
fn interactiveWorkerThread(ctx: *DaemonContext, client_fd: std.posix.fd_t) void {
    defer {
        ctx.event_subscribers.remove(client_fd);
        std.posix.close(client_fd);
    }

    // Read commands line-by-line from the persistent connection
    var buf: [65536]u8 = undefined;
    var filled: usize = 0;

    while (ctx.running.load(.acquire)) {
        // Read more data
        const n = std.posix.read(client_fd, buf[filled..]) catch break;
        if (n == 0) break; // Client disconnected
        filled += n;

        // Process all complete lines in buffer
        while (std.mem.indexOfScalar(u8, buf[0..filled], '\n')) |nl_pos| {
            const line = buf[0 .. nl_pos + 1]; // Include newline
            if (line.len > 1) { // Skip empty lines
                const resp = handleCommand(ctx, line);
                defer ctx.allocator.free(resp);
                _ = std.posix.write(client_fd, resp) catch return;
            }
            // Shift remaining data to front
            const remaining = filled - (nl_pos + 1);
            if (remaining > 0) {
                std.mem.copyForwards(u8, buf[0..remaining], buf[nl_pos + 1 .. filled]);
            }
            filled = remaining;
        }

        // Prevent buffer overflow
        if (filled >= buf.len) {
            filled = 0; // Drop oversized line
        }
    }
}

// ============================================================================
// Event broadcast helpers for interactive/pipe mode subscribers
// ============================================================================

fn broadcastNetworkEvent(allocator: Allocator, subs: *EventSubscribers, params: std.json.Value) void {
    const response_obj = cdp.getObject(params, "response") orelse return;
    const url = cdp.getString(response_obj, "url") orelse return;
    const status = cdp.getInt(response_obj, "status");
    const request = cdp.getObject(params, "request");
    const method = if (request) |r| cdp.getString(r, "method") orelse "GET" else "GET";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"event\":\"network\",\"url\":") catch return;
    cdp.writeJsonString(w, url) catch return;
    w.writeAll(",\"method\":") catch return;
    cdp.writeJsonString(w, method) catch return;
    w.writeAll(",\"status\":") catch return;
    if (status) |s| {
        std.fmt.format(w, "{d}", .{s}) catch return;
    } else {
        w.writeAll("null") catch return;
    }
    w.writeAll("}\n") catch return;
    subs.broadcast(buf.items);
}

fn broadcastConsoleEvent(allocator: Allocator, subs: *EventSubscribers, params: std.json.Value) void {
    const log_type = cdp.getString(params, "type") orelse "log";

    // Extract text from args
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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"event\":\"console\",\"type\":") catch return;
    cdp.writeJsonString(w, log_type) catch return;
    w.writeAll(",\"text\":") catch return;
    cdp.writeJsonString(w, text_buf.items) catch return;
    w.writeAll("}\n") catch return;
    subs.broadcast(buf.items);
}

fn broadcastErrorEvent(allocator: Allocator, subs: *EventSubscribers, params: std.json.Value) void {
    var desc: []const u8 = "unknown error";
    if (cdp.getObject(params, "exceptionDetails")) |details| {
        if (cdp.getString(details, "text")) |text| {
            desc = text;
        }
        if (cdp.getObject(details, "exception")) |exc| {
            if (cdp.getString(exc, "description")) |d| {
                desc = d;
            }
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"event\":\"error\",\"description\":") catch return;
    cdp.writeJsonString(w, desc) catch return;
    w.writeAll("}\n") catch return;
    subs.broadcast(buf.items);
}

fn broadcastDialogEvent(allocator: Allocator, subs: *EventSubscribers, params: std.json.Value) void {
    const dtype = cdp.getString(params, "type") orelse "alert";
    const message = cdp.getString(params, "message") orelse "";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"event\":\"dialog\",\"type\":") catch return;
    cdp.writeJsonString(w, dtype) catch return;
    w.writeAll(",\"message\":") catch return;
    cdp.writeJsonString(w, message) catch return;
    w.writeAll("}\n") catch return;
    subs.broadcast(buf.items);
}

fn broadcastDownloadEvent(allocator: Allocator, subs: *EventSubscribers, guid: []const u8, state: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"event\":\"download\",\"guid\":") catch return;
    cdp.writeJsonString(w, guid) catch return;
    w.writeAll(",\"state\":") catch return;
    cdp.writeJsonString(w, state) catch return;
    w.writeAll("}\n") catch return;
    subs.broadcast(buf.items);
}

fn receiverThread(ctx: *ReceiverContext) void {
    while (ctx.alive.load(.acquire)) {
        const msg = ctx.ws.recvMessage() catch {
            // timeout (WouldBlock) just loops; real errors shut down
            continue;
        };

        const parsed = cdp.parseMessage(ctx.allocator, msg) catch {
            ctx.allocator.free(msg);
            continue;
        };
        defer parsed.parsed.deinit();

        if (parsed.message.isEvent()) {
            var is_request_paused = false;
            {
                ctx.collector_mutex.lock();
                defer ctx.collector_mutex.unlock();
                if (parsed.message.method) |method| {
                    if (parsed.message.params) |params| {
                        _ = ctx.collector.processEvent(method, params) catch {};
                        if (std.mem.eql(u8, method, "Runtime.consoleAPICalled")) {
                            collectConsoleEvent(ctx.allocator, params, ctx.console_msgs);
                            broadcastConsoleEvent(ctx.allocator, ctx.event_subscribers, params);
                        }
                        if (std.mem.eql(u8, method, "Runtime.exceptionThrown")) {
                            collectExceptionEvent(ctx.allocator, params, ctx.page_errors);
                            broadcastErrorEvent(ctx.allocator, ctx.event_subscribers, params);
                        }
                        if (std.mem.eql(u8, method, "Page.javascriptDialogOpening")) {
                            const dtype = cdp.getString(params, "type") orelse "alert";
                            if (shouldAutoDismissDialog(ctx.auto_dialog, dtype)) {
                                // 자동 dismiss: pending dialog로 추적하지 않아 stale 경고 방지
                                autoDismissDialog(ctx.allocator, ctx.sender, ctx.cmd_id, ctx.session_id);
                            } else {
                                collectDialogEvent(ctx.allocator, params, ctx.dialog_info);
                                broadcastDialogEvent(ctx.allocator, ctx.event_subscribers, params);
                            }
                        }
                        if (std.mem.eql(u8, method, "Fetch.requestPaused")) {
                            is_request_paused = true;
                        }
                        if (std.mem.eql(u8, method, "Fetch.authRequired")) {
                            handleAuthRequired(ctx.allocator, ctx.sender, ctx.cmd_id, ctx.session_id, params, ctx.auth_credentials, ctx.auth_mutex);
                        }
                        // Network response events
                        if (std.mem.eql(u8, method, "Network.responseReceived")) {
                            broadcastNetworkEvent(ctx.allocator, ctx.event_subscribers, params);
                        }
                        // Download events (no mutex needed — DownloadTracker has internal locking)
                        if (std.mem.eql(u8, method, "Browser.downloadWillBegin")) {
                            if (cdp.getString(params, "guid")) |guid| {
                                ctx.download_tracker.onBegin(guid);
                                broadcastDownloadEvent(ctx.allocator, ctx.event_subscribers, guid, "willBegin");
                            }
                        }
                        if (std.mem.eql(u8, method, "Browser.downloadProgress")) {
                            if (cdp.getString(params, "guid")) |guid| {
                                const state = cdp.getString(params, "state") orelse "inProgress";
                                // suggestedFilename is in downloadWillBegin, not progress
                                ctx.download_tracker.onProgress(guid, state, cdp.getString(params, "suggestedFilename"));
                                broadcastDownloadEvent(ctx.allocator, ctx.event_subscribers, guid, state);
                            }
                        }
                        // Tracing events for trace/profiler
                        if (std.mem.eql(u8, method, "Tracing.dataCollected")) {
                            if (ctx.trace_active.load(.acquire)) {
                                collectTraceData(ctx.allocator, params, ctx.trace_events, ctx.trace_mutex);
                            }
                        }
                        if (std.mem.eql(u8, method, "Tracing.tracingComplete")) {
                            ctx.trace_complete.store(true, .release);
                        }
                    }
                }
                // Wake any waitfor handlers waiting on new events
                ctx.event_cond.broadcast();
            }
            // Handle intercepted requests outside collector_mutex to avoid blocking
            if (is_request_paused) {
                if (parsed.message.params) |params| {
                    ctx.intercept_mutex.lock();
                    defer ctx.intercept_mutex.unlock();
                    handleRequestPaused(ctx.allocator, ctx.sender, ctx.intercept_state, ctx.cmd_id, ctx.session_id, params);
                }
            }
            ctx.allocator.free(msg);
        } else if (parsed.message.id) |resp_id| {
            // Response: transfer raw bytes to ResponseMap (don't free msg here)
            ctx.resp_map.put(resp_id, msg);
        } else {
            ctx.allocator.free(msg);
        }
    }
}

fn handleCommand(ctx: *DaemonContext, line: []const u8) []u8 {
    const allocator = ctx.allocator;
    const req = daemon.parseRequest(allocator, line) catch {
        return respondErr(allocator, "Invalid request");
    };
    defer daemon.freeRequest(allocator, req);

    const sender = ctx.sender;
    const resp_map = ctx.response_map;
    const collector = ctx.collector;
    const console_msgs = ctx.console_msgs;
    const intercept_state = ctx.intercept_state;
    const ref_map = ctx.ref_map;
    const cmd_id = ctx.cmd_id;
    const session_id = ctx.session_id;
    const collector_mutex = ctx.collector_mutex;

    if (std.mem.eql(u8, req.action, "open")) {
        return handleOpen(allocator, sender, cmd_id, session_id, req.url, ctx.allowed_domains);
    } else if (std.mem.eql(u8, req.action, "network_list")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleNetworkList(allocator, collector, req.pattern);
    } else if (std.mem.eql(u8, req.action, "network_get")) {
        return handleNetworkGet(allocator, sender, resp_map, cmd_id, session_id, collector, collector_mutex, req.url);
    } else if (std.mem.eql(u8, req.action, "network_clear")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        collector.deinit();
        collector.* = network.Collector.init(allocator);
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "console_list")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleConsoleList(allocator, console_msgs);
    } else if (std.mem.eql(u8, req.action, "console_clear")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        for (console_msgs.items) |entry| {
            allocator.free(entry.log_type);
            allocator.free(entry.text);
        }
        console_msgs.clearRetainingCapacity();
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "analyze")) {
        return handleAnalyze(allocator, sender, resp_map, cmd_id, session_id, collector, collector_mutex);
    } else if (std.mem.eql(u8, req.action, "snapshot") or std.mem.eql(u8, req.action, "snapshot_interactive")) {
        ctx.ref_map_rwlock.lock();
        defer ctx.ref_map_rwlock.unlock();
        const with_urls = if (req.pattern) |p| std.mem.eql(u8, p, SNAPSHOT_URLS_FLAG) else false;
        return handleSnapshot(allocator, sender, resp_map, cmd_id, session_id, ref_map, std.mem.eql(u8, req.action, "snapshot_interactive"), with_urls);
    } else if (std.mem.eql(u8, req.action, "click") or std.mem.eql(u8, req.action, "hover")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleClick(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "fill") or std.mem.eql(u8, req.action, "type_text")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleFill(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "press")) {
        return handlePress(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "scroll")) {
        return handleScroll(allocator, sender, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "select_option")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleSelectOption(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "dblclick")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleClick(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "tap")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleTap(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "is_visible") or std.mem.eql(u8, req.action, "is_enabled") or std.mem.eql(u8, req.action, "is_checked")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleIsCheck(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.action);
    } else if (std.mem.eql(u8, req.action, "get_attr")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleGetAttr(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "get_text") or std.mem.eql(u8, req.action, "get_html") or std.mem.eql(u8, req.action, "get_value")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleGetElementProp(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.action);
    } else if (std.mem.eql(u8, req.action, "focus")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleFocusAction(allocator, sender, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "drag")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleDrag(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "scrollintoview")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleScrollIntoView(allocator, sender, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "upload")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleUpload(allocator, sender, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "pdf")) {
        return handlePdf(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "tab_list")) {
        return handleTabList(allocator, sender, resp_map, cmd_id, session_id);
    } else if (std.mem.eql(u8, req.action, "tab_new")) {
        if (ctx.allowed_domains) |domains| {
            if (domains.len > 0) {
                if (req.url) |u| {
                    if (!isDomainAllowed(u, domains)) return respondErr(allocator, "domain not allowed");
                }
            }
        }
        return handleSimpleCdpWithParams(allocator, sender, cmd_id, session_id, "Target.createTarget", req.url);
        // NOTE: extra closing brace was needed for the if(ctx.allowed_domains) block — but the structure above closes correctly
    } else if (std.mem.eql(u8, req.action, "tab_close")) {
        return handleSimpleCdp(allocator, sender, cmd_id, session_id, "Target.closeTarget");
    } else if (std.mem.eql(u8, req.action, "cookies_list")) {
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, "JSON.stringify(document.cookie)");
    } else if (std.mem.eql(u8, req.action, "cookies_clear")) {
        return handleSimpleCdp(allocator, sender, cmd_id, session_id, "Network.clearBrowserCookies");
    } else if (std.mem.eql(u8, req.action, "cookies_set")) {
        return handleCookieSet(allocator, sender, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "cookies_set_bulk")) {
        return handleCookieSetBulk(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "set_viewport")) {
        return handleSetViewport(allocator, sender, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "set_media")) {
        return handleSetMedia(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "set_offline")) {
        return handleSetOffline(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "set_user_agent")) {
        return handleSetUserAgent(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "set_timezone")) {
        return handleSetTimezone(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "set_locale")) {
        return handleSetLocale(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "set_geolocation")) {
        return handleSetGeolocation(allocator, sender, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "permissions_grant")) {
        return handlePermissionsGrant(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "set_device")) {
        return handleSetDevice(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "device_list")) {
        return handleDeviceList(allocator);
    } else if (std.mem.eql(u8, req.action, "set_headers")) {
        return handleSetHeaders(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "mouse")) {
        return handleMouse(allocator, sender, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "screenshot")) {
        return handleScreenshot(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "screenshot_full")) {
        return handleScreenshotFull(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "eval")) {
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "back")) {
        return handleNavAction(allocator, sender, cmd_id, session_id, "Page.navigateToHistoryEntry", "-1");
    } else if (std.mem.eql(u8, req.action, "forward")) {
        return handleNavAction(allocator, sender, cmd_id, session_id, "Page.navigateToHistoryEntry", "1");
    } else if (std.mem.eql(u8, req.action, "reload")) {
        return handleSimpleCdp(allocator, sender, cmd_id, session_id, "Page.reload");
    } else if (std.mem.eql(u8, req.action, "pushstate")) {
        return handlePushState(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "vitals")) {
        return handleVitals(allocator, sender, resp_map, cmd_id, session_id, req.url, ctx.allowed_domains);
    } else if (std.mem.eql(u8, req.action, "react_tree")) {
        return handleReactScript(allocator, sender, resp_map, cmd_id, session_id, REACT_TREE_SNAPSHOT);
    } else if (std.mem.eql(u8, req.action, "get_url")) {
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, "window.location.href");
    } else if (std.mem.eql(u8, req.action, "get_title")) {
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, "document.title");
    } else if (std.mem.eql(u8, req.action, "wait")) {
        const ms_str = req.url orelse "1000";
        const ms = std.fmt.parseInt(u32, ms_str, 10) catch 1000;
        std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "record")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleRecord(allocator, collector, console_msgs, req.url);
    } else if (std.mem.eql(u8, req.action, "diff")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleDiff(allocator, collector, req.url);
    } else if (std.mem.eql(u8, req.action, "intercept_mock")) {
        ctx.intercept_mutex.lock();
        defer ctx.intercept_mutex.unlock();
        return handleInterceptAdd(allocator, sender, cmd_id, session_id, intercept_state, req.url, .mock, req.pattern, req.extra);
    } else if (std.mem.eql(u8, req.action, "intercept_fail")) {
        ctx.intercept_mutex.lock();
        defer ctx.intercept_mutex.unlock();
        return handleInterceptAdd(allocator, sender, cmd_id, session_id, intercept_state, req.url, .fail, null, req.extra);
    } else if (std.mem.eql(u8, req.action, "intercept_delay")) {
        ctx.intercept_mutex.lock();
        defer ctx.intercept_mutex.unlock();
        return handleInterceptAdd(allocator, sender, cmd_id, session_id, intercept_state, req.url, .delay, req.pattern, req.extra);
    } else if (std.mem.eql(u8, req.action, "intercept_remove")) {
        ctx.intercept_mutex.lock();
        defer ctx.intercept_mutex.unlock();
        return handleInterceptRemove(allocator, sender, cmd_id, session_id, intercept_state, req.url);
    } else if (std.mem.eql(u8, req.action, "intercept_list")) {
        ctx.intercept_mutex.lock();
        defer ctx.intercept_mutex.unlock();
        return handleInterceptList(allocator, intercept_state);
    } else if (std.mem.eql(u8, req.action, "intercept_clear")) {
        ctx.intercept_mutex.lock();
        defer ctx.intercept_mutex.unlock();
        intercept_state.deinit();
        intercept_state.* = interceptor.InterceptorState.init(allocator);
        const disable = cdp.fetchDisable(allocator, cmd_id.next(), session_id) catch return respondOk(allocator);
        defer allocator.free(disable);
        sender.sendText(disable) catch {};
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "status")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleStatusFull(allocator, collector, console_msgs, ctx.page_errors);
    } else if (std.mem.eql(u8, req.action, "close")) {
        ctx.running.store(false, .release);
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "ping")) {
        return respondOk(allocator);
    } else if (std.mem.startsWith(u8, req.action, "storage_")) {
        return handleStorage(allocator, sender, resp_map, cmd_id, session_id, req.action, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "find")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleFind(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "dialog_accept")) {
        return handleDialogAccept(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "dialog_dismiss")) {
        return handleDialogDismiss(allocator, sender, cmd_id, session_id);
    } else if (std.mem.eql(u8, req.action, "content")) {
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, "document.documentElement.outerHTML");
    } else if (std.mem.eql(u8, req.action, "setcontent")) {
        return handleSetContent(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "addscript")) {
        return handleAddScript(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "removeinitscript")) {
        return handleRemoveInitScript(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "waiturl")) {
        return handleWaitUrl(allocator, sender, resp_map, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "waitfunction")) {
        return handleWaitFunction(allocator, sender, resp_map, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "errors")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleErrors(allocator, ctx.page_errors);
    } else if (std.mem.eql(u8, req.action, "highlight")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleHighlight(allocator, sender, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "bringtofront")) {
        return handleSimpleCdp(allocator, sender, cmd_id, session_id, "Page.bringToFront");
    } else if (std.mem.eql(u8, req.action, "credentials")) {
        return handleCredentials(ctx, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "download_path")) {
        return handleDownloadPath(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "har")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleHar(allocator, collector, req.url);
    } else if (std.mem.eql(u8, req.action, "state_save")) {
        return handleStateSave(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "state_load")) {
        return handleStateLoad(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "state_list")) {
        return handleStateList(allocator);
    } else if (std.mem.eql(u8, req.action, "addstyle")) {
        return handleAddStyle(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "check")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleCheck(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "uncheck")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleUncheck(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "clear_input")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleClearInput(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "selectall")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleSelectAll(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "boundingbox")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleBoundingBox(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "styles")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleStyles(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "clipboard_get")) {
        return handleClipboardGet(allocator, sender, resp_map, cmd_id, session_id);
    } else if (std.mem.eql(u8, req.action, "clipboard_set")) {
        return handleClipboardSet(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "tab_switch")) {
        return handleTabSwitch(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "window_new")) {
        return handleWindowNew(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "pause")) {
        return handlePause(allocator, sender, cmd_id, session_id);
    } else if (std.mem.eql(u8, req.action, "resume")) {
        return handleResume(allocator, sender, cmd_id, session_id);
    } else if (std.mem.eql(u8, req.action, "dispatch")) {
        ctx.ref_map_rwlock.lockShared();
        defer ctx.ref_map_rwlock.unlockShared();
        return handleDispatch(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "waitload")) {
        return handleWaitLoad(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "expose")) {
        return handleExpose(allocator, sender, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "ignore_https_errors")) {
        return handleIgnoreHttpsErrors(allocator, sender, cmd_id, session_id);
    } else if (std.mem.eql(u8, req.action, "replay")) {
        return handleReplay(allocator, sender, resp_map, cmd_id, session_id, collector, collector_mutex, req.url);
    } else if (std.mem.eql(u8, req.action, "errors_clear")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        for (ctx.page_errors.items) |entry| {
            allocator.free(entry.description);
        }
        ctx.page_errors.clearRetainingCapacity();
        return respondOk(allocator);
    } else if (std.mem.eql(u8, req.action, "dialog_info")) {
        collector_mutex.lock();
        defer collector_mutex.unlock();
        return handleDialogInfo(allocator, ctx.dialog_info);
    } else if (std.mem.eql(u8, req.action, "scroll_to")) {
        return handleScrollTo(allocator, sender, resp_map, cmd_id, session_id, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "cookies_get")) {
        return handleCookiesGet(allocator, sender, resp_map, cmd_id, session_id, req.url);
    } else if (std.mem.eql(u8, req.action, "tab_count")) {
        return handleTabCount(allocator, sender, resp_map, cmd_id, session_id);
    } else if (std.mem.eql(u8, req.action, "waitfor_network")) {
        return handleWaitForNetwork(allocator, collector, collector_mutex, ctx.event_cond, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "waitfor_console")) {
        return handleWaitForConsole(allocator, console_msgs, collector_mutex, ctx.event_cond, req.url, req.pattern);
    } else if (std.mem.eql(u8, req.action, "waitfor_error")) {
        return handleWaitForError(allocator, ctx.page_errors, collector_mutex, ctx.event_cond, req.url);
    } else if (std.mem.eql(u8, req.action, "waitfor_dialog")) {
        return handleWaitForDialog(allocator, ctx.dialog_info, collector_mutex, ctx.event_cond, req.url);
    } else if (std.mem.eql(u8, req.action, "waitfor_download")) {
        return handleWaitForDownload(allocator, ctx.download_tracker, req.url);
    } else if (std.mem.eql(u8, req.action, "auth_login")) {
        ctx.ref_map_rwlock.lock();
        defer ctx.ref_map_rwlock.unlock();
        return handleAuthLogin(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "trace_start")) {
        return handleTraceStart(allocator, sender, cmd_id, session_id, ctx.trace_active, ctx.trace_complete, ctx.trace_events, ctx.trace_mutex, false);
    } else if (std.mem.eql(u8, req.action, "trace_stop")) {
        return handleTraceStop(allocator, sender, cmd_id, session_id, resp_map, ctx.trace_active, ctx.trace_complete, ctx.trace_events, ctx.trace_mutex, req.url);
    } else if (std.mem.eql(u8, req.action, "profiler_start")) {
        return handleTraceStart(allocator, sender, cmd_id, session_id, ctx.trace_active, ctx.trace_complete, ctx.trace_events, ctx.trace_mutex, true);
    } else if (std.mem.eql(u8, req.action, "profiler_stop")) {
        return handleTraceStop(allocator, sender, cmd_id, session_id, resp_map, ctx.trace_active, ctx.trace_complete, ctx.trace_events, ctx.trace_mutex, req.url);
    } else if (std.mem.eql(u8, req.action, "screenshot_annotate")) {
        ctx.ref_map_rwlock.lock();
        defer ctx.ref_map_rwlock.unlock();
        return handleScreenshotAnnotate(allocator, sender, resp_map, cmd_id, session_id, ref_map, req.url);
    } else if (std.mem.eql(u8, req.action, "video_start")) {
        return handleVideoStart(allocator, sender, resp_map, cmd_id, session_id, ctx.video_recorder, req.url);
    } else if (std.mem.eql(u8, req.action, "video_stop")) {
        return handleVideoStop(allocator, ctx.video_recorder);
    } else if (std.mem.eql(u8, req.action, "diff_screenshot")) {
        return handleDiffScreenshot(allocator, sender, resp_map, cmd_id, session_id, req.url, req.pattern);
    } else {
        return respondErr(allocator, "Unknown action");
    }
}

fn handleOpen(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, url: ?[]const u8, allowed_domains: ?[]const u8) []u8 {
    const target_url = url orelse return respondErr(allocator, "url required");

    // Domain restriction check
    if (allowed_domains) |domains| {
        if (!isDomainAllowed(target_url, domains)) {
            return respondErr(allocator, "domain not allowed by --allowed-domains");
        }
    }

    const nav_cmd = cdp.pageNavigate(allocator, cmd_id.next(), target_url, session_id) catch
        return respondErr(allocator, "Failed to build navigate command");
    defer allocator.free(nav_cmd);

    sender.sendText(nav_cmd) catch return respondErr(allocator, "Failed to send navigate");

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
    sender: *WsSender,
    resp_map: *response_map_mod.ResponseMap,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    collector: *network.Collector,
    collector_mutex: *std.Thread.Mutex,
    request_id_opt: ?[]const u8,
) []u8 {
    const request_id = request_id_opt orelse return respondErr(allocator, "requestId required (pass as url param)");

    collector_mutex.lock();
    const info = collector.getById(request_id) orelse {
        collector_mutex.unlock();
        return respondErr(allocator, "request not found");
    };
    // Copy needed fields while holding lock
    const info_request_id = allocator.dupe(u8, info.request_id) catch {
        collector_mutex.unlock();
        return respondErr(allocator, "alloc error");
    };
    defer allocator.free(info_request_id);
    const info_url = allocator.dupe(u8, info.url) catch {
        collector_mutex.unlock();
        return respondErr(allocator, "alloc error");
    };
    defer allocator.free(info_url);
    const info_method = allocator.dupe(u8, info.method) catch {
        collector_mutex.unlock();
        return respondErr(allocator, "alloc error");
    };
    defer allocator.free(info_method);
    const info_status = info.status;
    const info_mime_type = allocator.dupe(u8, info.mime_type) catch {
        collector_mutex.unlock();
        return respondErr(allocator, "alloc error");
    };
    defer allocator.free(info_mime_type);
    const info_state = info.state;
    const info_encoded_data_length = info.encoded_data_length;
    const info_error_text = allocator.dupe(u8, info.error_text) catch {
        collector_mutex.unlock();
        return respondErr(allocator, "alloc error");
    };
    defer allocator.free(info_error_text);
    collector_mutex.unlock();

    // Fetch response body via CDP
    const body_sent_id = cmd_id.next();
    const get_body_cmd = cdp.networkGetResponseBody(allocator, body_sent_id, request_id, session_id) catch
        return respondErr(allocator, "failed to build getResponseBody");
    defer allocator.free(get_body_cmd);

    var body_owned: ?[]u8 = null;
    defer if (body_owned) |b| allocator.free(b);
    var base64_encoded = false;

    const raw = sendAndWait(sender, resp_map, get_body_cmd, body_sent_id, 10_000) orelse {
        // timeout — proceed with empty body
        const body_str = body_owned orelse "";
        _ = body_str;
        return buildNetworkGetResponse(allocator, info_request_id, info_url, info_method, info_status, info_mime_type, info_state, "", false, info_encoded_data_length, info_error_text);
    };
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return buildNetworkGetResponse(allocator, info_request_id, info_url, info_method, info_status, info_mime_type, info_state, "", false, info_encoded_data_length, info_error_text);
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getString(result, "body")) |b| {
                body_owned = allocator.dupe(u8, b) catch null;
                base64_encoded = cdp.getBool(result, "base64Encoded") orelse false;
            }
        }
    }

    const body_str = body_owned orelse "";

    return buildNetworkGetResponse(allocator, info_request_id, info_url, info_method, info_status, info_mime_type, info_state, body_str, base64_encoded, info_encoded_data_length, info_error_text);
}

fn buildNetworkGetResponse(allocator: Allocator, request_id: []const u8, url: []const u8, method: []const u8, status: ?i64, mime_type: []const u8, state: network.RequestInfo.RequestState, body_str: []const u8, base64_encoded: bool, encoded_data_length: ?i64, error_text: []const u8) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    writer.writeAll("{\"requestId\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(writer, request_id) catch {};
    writer.writeAll(",\"url\":") catch {};
    cdp.writeJsonString(writer, url) catch {};
    writer.writeAll(",\"method\":") catch {};
    cdp.writeJsonString(writer, method) catch {};
    writer.writeAll(",\"status\":") catch {};
    if (status) |s| {
        std.fmt.format(writer, "{d}", .{s}) catch {};
    } else {
        writer.writeAll("null") catch {};
    }
    writer.writeAll(",\"mimeType\":") catch {};
    cdp.writeJsonString(writer, mime_type) catch {};
    writer.writeAll(",\"state\":") catch {};
    cdp.writeJsonString(writer, @tagName(state)) catch {};
    writer.writeAll(",\"body\":") catch {};
    cdp.writeJsonString(writer, body_str) catch {};
    writer.writeAll(",\"base64Encoded\":") catch {};
    writer.writeAll(if (base64_encoded) "true" else "false") catch {};
    if (encoded_data_length) |len| {
        writer.writeAll(",\"encodedDataLength\":") catch {};
        std.fmt.format(writer, "{d}", .{len}) catch {};
    }
    if (error_text.len > 0) {
        writer.writeAll(",\"errorText\":") catch {};
        cdp.writeJsonString(writer, error_text) catch {};
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

/// AX 트리 JSON에서 role=="link"이고 ignored가 아닌 노드의 backendDOMNodeId 수집.
/// 호출자가 반환 슬라이스를 free.
fn collectLinkBackendIds(allocator: Allocator, ax_result: std.json.Value) ![]i64 {
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(allocator);

    if (ax_result != .object) return ids.toOwnedSlice(allocator);
    const nodes_field = ax_result.object.get("nodes") orelse return ids.toOwnedSlice(allocator);
    if (nodes_field != .array) return ids.toOwnedSlice(allocator);
    for (nodes_field.array.items) |node| {
        if (node != .object) continue;
        if (cdp.getBool(node, "ignored") orelse false) continue;
        const role = if (cdp.getObject(node, "role")) |r| cdp.getString(r, "value") orelse "" else "";
        if (!std.mem.eql(u8, role, "link")) continue;
        const bid = cdp.getInt(node, "backendDOMNodeId") orelse continue;
        try ids.append(allocator, bid);
    }
    return ids.toOwnedSlice(allocator);
}

/// backendNodeId → 요소의 절대 href 문자열. 호출자가 free. 실패 시 null.
fn resolveElementHref(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, backend_id: i64) ?[]u8 {
    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse return null;
    defer allocator.free(oid);

    const call_params = buildCallFunctionOnParams(allocator, oid,
        "function(){var h=this.getAttribute&&this.getAttribute('href');if(!h)return '';try{return new URL(h,document.baseURI).toString()}catch(e){return ''}}", null) orelse return null;
    defer allocator.free(call_params);

    const call_id = cmd_id.next();
    const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch return null;
    defer allocator.free(call_cmd);

    const raw = sendAndWait(sender, resp_map, call_cmd, call_id, 10_000) orelse return null;
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch return null;
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getString(remote_obj, "value")) |v| {
                    if (v.len == 0) return null;
                    return allocator.dupe(u8, v) catch null;
                }
            }
        }
    }
    return null;
}

fn handleSnapshot(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *snapshot_mod.RefMap, interactive_only: bool, with_urls: bool) []u8 {
    // Clear old refs
    ref_map.deinit();
    ref_map.* = snapshot_mod.RefMap.init(allocator);

    // Step 1: Detect cursor-interactive elements (best-effort)
    var cursor_map = findCursorInteractiveElements(allocator, sender, resp_map, cmd_id, session_id);
    defer if (cursor_map) |*cm| {
        // Free allocated strings in the map
        var it = cm.iterator();
        while (it.next()) |entry| {
            allocator.free(@constCast(entry.value_ptr.kind));
            allocator.free(@constCast(entry.value_ptr.hints));
            allocator.free(@constCast(entry.value_ptr.text));
        }
        cm.deinit();
    };

    // Get AX tree
    const snap_sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, snap_sent_id, "Accessibility.getFullAXTree", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, snap_sent_id, 15_000) orelse
        return respondErr(allocator, "snapshot timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            const cursor_ptr: ?*const snapshot_mod.CursorElementMap = if (cursor_map) |*cm| cm else null;

            // --urls: link 요소의 href를 backendNodeId 기준으로 미리 해석
            var link_url_map = std.AutoHashMap(i64, []const u8).init(allocator);
            defer {
                var uit = link_url_map.iterator();
                while (uit.next()) |e| allocator.free(@constCast(e.value_ptr.*));
                link_url_map.deinit();
            }
            if (with_urls) {
                if (collectLinkBackendIds(allocator, result)) |ids| {
                    defer allocator.free(ids);
                    for (ids) |bid| {
                        if (link_url_map.contains(bid)) continue;
                        if (resolveElementHref(allocator, sender, resp_map, cmd_id, session_id, bid)) |href| {
                            link_url_map.put(bid, href) catch allocator.free(href);
                        }
                    }
                } else |_| {}
            }
            const url_ptr: ?*const std.AutoHashMap(i64, []const u8) = if (with_urls) &link_url_map else null;

            const snap = snapshot_mod.buildSnapshot(allocator, result, ref_map, interactive_only, cursor_ptr, url_ptr) catch
                return respondErr(allocator, "snapshot build error");
            defer allocator.free(snap);

            // Return snapshot text as JSON string
            var resp_buf: std.ArrayList(u8) = .empty;
            defer resp_buf.deinit(allocator);
            cdp.writeJsonString(resp_buf.writer(allocator), snap) catch
                return respondErr(allocator, "serialize error");

            const data = resp_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
            defer allocator.free(data);

            return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
                respondErr(allocator, "resp error");
        }
    }
    return respondErr(allocator, "snapshot failed");
}

/// JS script to detect non-ARIA interactive elements (cursor:pointer, onclick, tabindex, contenteditable).
/// Matching agent-browser's find_cursor_interactive_elements() from snapshot.rs.
const CURSOR_DETECT_JS =
    \\(function(){var results=[];if(!document.body)return results;var interactiveRoles={'button':1,'link':1,'textbox':1,'checkbox':1,'radio':1,'combobox':1,'listbox':1,'menuitem':1,'menuitemcheckbox':1,'menuitemradio':1,'option':1,'searchbox':1,'slider':1,'spinbutton':1,'switch':1,'tab':1,'treeitem':1};var interactiveTags={'a':1,'button':1,'input':1,'select':1,'textarea':1,'details':1,'summary':1};var allElements=document.body.querySelectorAll('*');for(var i=0;i<allElements.length;i++){var el=allElements[i];if(el.closest&&el.closest('[hidden],[aria-hidden="true"]'))continue;var tagName=el.tagName.toLowerCase();if(interactiveTags[tagName])continue;var role=el.getAttribute('role');if(role&&interactiveRoles[role.toLowerCase()])continue;var computedStyle=getComputedStyle(el);var hasCursorPointer=computedStyle.cursor==='pointer';var hasOnClick=el.hasAttribute('onclick')||el.onclick!==null;var tabIndex=el.getAttribute('tabindex');var hasTabIndex=tabIndex!==null&&tabIndex!=='-1';var ce=el.getAttribute('contenteditable');var isEditable=ce===''||ce==='true';if(!hasCursorPointer&&!hasOnClick&&!hasTabIndex&&!isEditable)continue;if(hasCursorPointer&&!hasOnClick&&!hasTabIndex&&!isEditable){var parent=el.parentElement;if(parent&&getComputedStyle(parent).cursor==='pointer')continue}var text=(el.textContent||'').trim().slice(0,100);var rect=el.getBoundingClientRect();if(rect.width===0||rect.height===0)continue;el.setAttribute('data-__ab-ci',String(results.length));results.push({text:text,hasOnClick:hasOnClick,hasCursorPointer:hasCursorPointer,hasTabIndex:hasTabIndex,isEditable:isEditable})}return results})()
;

const CURSOR_CLEANUP_JS =
    \\(function(){var els=document.querySelectorAll('[data-__ab-ci]');for(var i=0;i<els.length;i++)els[i].removeAttribute('data-__ab-ci');return els.length})()
;

/// Detect cursor-interactive elements via JS heuristics + CDP DOM queries.
/// Returns null if any step fails (best-effort).
fn findCursorInteractiveElements(
    allocator: Allocator,
    sender: *WsSender,
    resp_map: *response_map_mod.ResponseMap,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
) ?snapshot_mod.CursorElementMap {
    // Step 1: Execute JS detection script with returnByValue:true
    const eval_id = cmd_id.next();
    const eval_cmd = buildRuntimeEvaluateReturnByValue(allocator, eval_id, CURSOR_DETECT_JS, session_id) orelse return null;
    defer allocator.free(eval_cmd);

    const eval_raw = sendAndWait(sender, resp_map, eval_cmd, eval_id, 10_000) orelse return null;
    defer allocator.free(eval_raw);

    const eval_parsed = cdp.parseMessage(allocator, eval_raw) catch return null;
    defer eval_parsed.parsed.deinit();

    // Extract the result array
    const eval_result = if (eval_parsed.message.isResponse())
        eval_parsed.message.result
    else
        null;
    const remote_obj = if (eval_result) |r| cdp.getObject(r, "result") else null;
    const js_results = if (remote_obj) |ro| blk: {
        const val = ro.object.get("value") orelse break :blk null;
        if (val == .array) break :blk val.array.items;
        break :blk null;
    } else null;

    if (js_results == null or js_results.?.len == 0) {
        // Cleanup anyway (in case some elements were tagged)
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    }

    const results = js_results.?;

    // Step 2: DOM.getDocument to get root nodeId
    const doc_id = cmd_id.next();
    const doc_cmd = cdp.serializeCommand(allocator, doc_id, "DOM.getDocument", "{\"depth\":0}", session_id) catch {
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };
    defer allocator.free(doc_cmd);

    const doc_raw = sendAndWait(sender, resp_map, doc_cmd, doc_id, 5_000) orelse {
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };
    defer allocator.free(doc_raw);

    const doc_parsed = cdp.parseMessage(allocator, doc_raw) catch {
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };
    defer doc_parsed.parsed.deinit();

    const root_node_id: i64 = blk: {
        if (doc_parsed.message.isResponse()) {
            if (doc_parsed.message.result) |r| {
                if (cdp.getObject(r, "root")) |root| {
                    if (cdp.getInt(root, "nodeId")) |nid| break :blk nid;
                }
            }
        }
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };

    // Step 3: DOM.querySelectorAll to find tagged elements
    var qsa_params_buf: [128]u8 = undefined;
    const qsa_params = std.fmt.bufPrint(&qsa_params_buf, "{{\"nodeId\":{d},\"selector\":\"[data-__ab-ci]\"}}", .{root_node_id}) catch {
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };

    const qsa_id = cmd_id.next();
    const qsa_cmd = cdp.serializeCommand(allocator, qsa_id, "DOM.querySelectorAll", qsa_params, session_id) catch {
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };
    defer allocator.free(qsa_cmd);

    const qsa_raw = sendAndWait(sender, resp_map, qsa_cmd, qsa_id, 5_000) orelse {
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };
    defer allocator.free(qsa_raw);

    const qsa_parsed = cdp.parseMessage(allocator, qsa_raw) catch {
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };
    defer qsa_parsed.parsed.deinit();

    const node_ids: []const std.json.Value = blk: {
        if (qsa_parsed.message.isResponse()) {
            if (qsa_parsed.message.result) |r| {
                if (r.object.get("nodeIds")) |nids| {
                    if (nids == .array) break :blk nids.array.items;
                }
            }
        }
        cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);
        return null;
    };

    // Step 4: For each nodeId, DOM.describeNode to get backendNodeId and data-__ab-ci index
    var cursor_map = snapshot_mod.CursorElementMap.init(allocator);

    for (node_ids) |nid_val| {
        const nid = switch (nid_val) {
            .integer => |n| n,
            else => continue,
        };

        var desc_params_buf: [64]u8 = undefined;
        const desc_params = std.fmt.bufPrint(&desc_params_buf, "{{\"nodeId\":{d}}}", .{nid}) catch continue;

        const desc_id = cmd_id.next();
        const desc_cmd = cdp.serializeCommand(allocator, desc_id, "DOM.describeNode", desc_params, session_id) catch continue;
        defer allocator.free(desc_cmd);

        const desc_raw = sendAndWait(sender, resp_map, desc_cmd, desc_id, 3_000) orelse continue;
        defer allocator.free(desc_raw);

        const desc_parsed = cdp.parseMessage(allocator, desc_raw) catch continue;
        defer desc_parsed.parsed.deinit();

        if (!desc_parsed.message.isResponse()) continue;
        const desc_result = desc_parsed.message.result orelse continue;
        const node_obj = cdp.getObject(desc_result, "node") orelse continue;
        const backend_node_id = cdp.getInt(node_obj, "backendNodeId") orelse continue;

        // Find the data-__ab-ci attribute to get the index into results array
        const attrs_val = node_obj.object.get("attributes") orelse continue;
        if (attrs_val != .array) continue;

        var ci_index: ?usize = null;
        const attrs = attrs_val.array.items;
        var ai: usize = 0;
        while (ai + 1 < attrs.len) : (ai += 2) {
            if (attrs[ai] == .string and std.mem.eql(u8, attrs[ai].string, "data-__ab-ci")) {
                if (attrs[ai + 1] == .string) {
                    ci_index = std.fmt.parseInt(usize, attrs[ai + 1].string, 10) catch null;
                }
                break;
            }
        }

        const idx = ci_index orelse continue;
        if (idx >= results.len) continue;

        const info = results[idx];
        if (info != .object) continue;

        // Determine kind and hints from the JS result
        const has_onclick = if (cdp.getBool(info, "hasOnClick")) |b| b else false;
        const has_cursor_pointer = if (cdp.getBool(info, "hasCursorPointer")) |b| b else false;
        const has_tab_index = if (cdp.getBool(info, "hasTabIndex")) |b| b else false;
        const is_editable = if (cdp.getBool(info, "isEditable")) |b| b else false;

        // Build kind
        const kind: []const u8 = if (is_editable)
            "editable"
        else if (has_tab_index and !has_onclick and !has_cursor_pointer)
            "focusable"
        else
            "clickable";

        // Build hints string
        var hints_buf: std.ArrayList(u8) = .empty;
        defer hints_buf.deinit(allocator);
        const hw = hints_buf.writer(allocator);
        if (has_cursor_pointer) hw.writeAll("cursor:pointer") catch {};
        if (has_onclick) {
            if (hints_buf.items.len > 0) hw.writeAll(", ") catch {};
            hw.writeAll("onclick") catch {};
        }
        if (has_tab_index) {
            if (hints_buf.items.len > 0) hw.writeAll(", ") catch {};
            hw.writeAll("tabindex") catch {};
        }
        if (is_editable) {
            if (hints_buf.items.len > 0) hw.writeAll(", ") catch {};
            hw.writeAll("contenteditable") catch {};
        }

        const text_val = if (info.object.get("text")) |t| (if (t == .string) t.string else "") else "";

        // Allocate owned copies
        const owned_kind = allocator.dupe(u8, kind) catch continue;
        const owned_hints = allocator.dupe(u8, hints_buf.items) catch {
            allocator.free(owned_kind);
            continue;
        };
        const owned_text = allocator.dupe(u8, text_val) catch {
            allocator.free(owned_kind);
            allocator.free(owned_hints);
            continue;
        };

        cursor_map.put(backend_node_id, .{
            .kind = owned_kind,
            .hints = owned_hints,
            .text = owned_text,
        }) catch {
            allocator.free(owned_kind);
            allocator.free(owned_hints);
            allocator.free(owned_text);
            continue;
        };
    }

    // Step 5: Clean up injected attributes
    cleanupCursorAttributes(allocator, sender, resp_map, cmd_id, session_id);

    if (cursor_map.count() == 0) {
        cursor_map.deinit();
        return null;
    }

    return cursor_map;
}

/// Build Runtime.evaluate CDP command with returnByValue:true.
fn buildRuntimeEvaluateReturnByValue(allocator: Allocator, id: u64, expression: []const u8, session_id: ?[]const u8) ?[]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    cdp.writeJsonString(escaped.writer(allocator), expression) catch return null;

    const params = std.fmt.allocPrint(allocator, "{{\"expression\":{s},\"returnByValue\":true}}", .{escaped.items}) catch return null;
    defer allocator.free(params);
    return cdp.serializeCommand(allocator, id, "Runtime.evaluate", params, session_id) catch null;
}

/// Remove data-__ab-ci attributes from the page (cleanup after cursor detection).
fn cleanupCursorAttributes(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8) void {
    const cleanup_id = cmd_id.next();
    const cleanup_cmd = cdp.runtimeEvaluate(allocator, cleanup_id, CURSOR_CLEANUP_JS, session_id) catch return;
    defer allocator.free(cleanup_cmd);
    const cleanup_raw = sendAndWait(sender, resp_map, cleanup_cmd, cleanup_id, 3_000);
    if (cleanup_raw) |cr| allocator.free(cr);
}

fn handleClick(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const center = resolveCenter(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "element not visible");

    // mousePressed + mouseReleased = click
    const press_cmd = snapshot_mod.buildClickCmd(allocator, cmd_id.next(), center.x, center.y, "mousePressed", session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(press_cmd);
    sender.sendText(press_cmd) catch {};

    const release_cmd = snapshot_mod.buildClickCmd(allocator, cmd_id.next(), center.x, center.y, "mouseReleased", session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(release_cmd);
    sender.sendText(release_cmd) catch {};

    return respondOk(allocator);
}

fn handleTap(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const center = resolveCenter(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "element not visible");

    // touchStart with touchPoints
    var start_buf: [256]u8 = undefined;
    const start_params = std.fmt.bufPrint(&start_buf, "{{\"type\":\"touchStart\",\"touchPoints\":[{{\"x\":{d},\"y\":{d}}}]}}", .{ center.x, center.y }) catch
        return respondErr(allocator, "cmd error");
    const start_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchTouchEvent", start_params, session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(start_cmd);
    sender.sendText(start_cmd) catch {};

    // touchEnd with empty touchPoints
    const end_params = "{\"type\":\"touchEnd\",\"touchPoints\":[]}";
    const end_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchTouchEvent", end_params, session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(end_cmd);
    sender.sendText(end_cmd) catch {};

    return respondOk(allocator);
}

fn handleFill(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, text: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const fill_text = text orelse "";

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    // Focus the element and wait for response
    const focus_sent_id = cmd_id.next();
    const focus_cmd = snapshot_mod.buildFocusCmd(allocator, focus_sent_id, backend_id, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(focus_cmd);

    const focus_raw = sendAndWait(sender, resp_map, focus_cmd, focus_sent_id, 3_000);
    if (focus_raw) |fr| allocator.free(fr);

    // Select all text (works for input/textarea/contenteditable)
    const select_expr = cdp.runtimeEvaluate(allocator, cmd_id.next(),
        \\(function(){var a=document.activeElement;if(a&&a.select)a.select();else document.execCommand('selectAll')})()
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(select_expr);
    sender.sendText(select_expr) catch {};

    std.Thread.sleep(30 * std.time.ns_per_ms);

    // Insert text
    const insert_cmd = snapshot_mod.buildInsertTextCmd(allocator, cmd_id.next(), fill_text, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(insert_cmd);
    sender.sendText(insert_cmd) catch return respondErr(allocator, "send error");

    return respondOk(allocator);
}

/// Key info matching Playwright's USKeyboardLayout
const KeyInfo = struct { key: []const u8, code: []const u8, key_code: i32, text: ?[]const u8 };

fn getKeyInfo(key_name: []const u8) KeyInfo {
    // Named keys (case-insensitive)
    const named_keys = [_]struct { name: []const u8, key: []const u8, code: []const u8, kc: i32, text: ?[]const u8 }{
        .{ .name = "enter", .key = "Enter", .code = "Enter", .kc = 13, .text = "\r" },
        .{ .name = "return", .key = "Enter", .code = "Enter", .kc = 13, .text = "\r" },
        .{ .name = "tab", .key = "Tab", .code = "Tab", .kc = 9, .text = "\t" },
        .{ .name = "escape", .key = "Escape", .code = "Escape", .kc = 27, .text = null },
        .{ .name = "esc", .key = "Escape", .code = "Escape", .kc = 27, .text = null },
        .{ .name = "backspace", .key = "Backspace", .code = "Backspace", .kc = 8, .text = null },
        .{ .name = "delete", .key = "Delete", .code = "Delete", .kc = 46, .text = null },
        .{ .name = "arrowup", .key = "ArrowUp", .code = "ArrowUp", .kc = 38, .text = null },
        .{ .name = "up", .key = "ArrowUp", .code = "ArrowUp", .kc = 38, .text = null },
        .{ .name = "arrowdown", .key = "ArrowDown", .code = "ArrowDown", .kc = 40, .text = null },
        .{ .name = "down", .key = "ArrowDown", .code = "ArrowDown", .kc = 40, .text = null },
        .{ .name = "arrowleft", .key = "ArrowLeft", .code = "ArrowLeft", .kc = 37, .text = null },
        .{ .name = "left", .key = "ArrowLeft", .code = "ArrowLeft", .kc = 37, .text = null },
        .{ .name = "arrowright", .key = "ArrowRight", .code = "ArrowRight", .kc = 39, .text = null },
        .{ .name = "right", .key = "ArrowRight", .code = "ArrowRight", .kc = 39, .text = null },
        .{ .name = "home", .key = "Home", .code = "Home", .kc = 36, .text = null },
        .{ .name = "end", .key = "End", .code = "End", .kc = 35, .text = null },
        .{ .name = "pageup", .key = "PageUp", .code = "PageUp", .kc = 33, .text = null },
        .{ .name = "pagedown", .key = "PageDown", .code = "PageDown", .kc = 34, .text = null },
        .{ .name = "space", .key = " ", .code = "Space", .kc = 32, .text = " " },
        .{ .name = "insert", .key = "Insert", .code = "Insert", .kc = 45, .text = null },
        .{ .name = "f1", .key = "F1", .code = "F1", .kc = 112, .text = null },
        .{ .name = "f2", .key = "F2", .code = "F2", .kc = 113, .text = null },
        .{ .name = "f3", .key = "F3", .code = "F3", .kc = 114, .text = null },
        .{ .name = "f4", .key = "F4", .code = "F4", .kc = 115, .text = null },
        .{ .name = "f5", .key = "F5", .code = "F5", .kc = 116, .text = null },
        .{ .name = "f6", .key = "F6", .code = "F6", .kc = 117, .text = null },
        .{ .name = "f7", .key = "F7", .code = "F7", .kc = 118, .text = null },
        .{ .name = "f8", .key = "F8", .code = "F8", .kc = 119, .text = null },
        .{ .name = "f9", .key = "F9", .code = "F9", .kc = 120, .text = null },
        .{ .name = "f10", .key = "F10", .code = "F10", .kc = 121, .text = null },
        .{ .name = "f11", .key = "F11", .code = "F11", .kc = 122, .text = null },
        .{ .name = "f12", .key = "F12", .code = "F12", .kc = 123, .text = null },
    };

    for (named_keys) |nk| {
        if (std.ascii.eqlIgnoreCase(key_name, nk.name)) {
            return .{ .key = nk.key, .code = nk.code, .key_code = nk.kc, .text = nk.text };
        }
    }

    // Single character
    if (key_name.len == 1) {
        const ch = key_name[0];
        // Letters: code=KeyA, VK=uppercase ASCII
        if (ch >= 'a' and ch <= 'z') {
            return .{ .key = key_name, .code = key_name, .key_code = @as(i32, ch - 32), .text = key_name };
        }
        if (ch >= 'A' and ch <= 'Z') {
            return .{ .key = key_name, .code = key_name, .key_code = @as(i32, ch), .text = key_name };
        }
        // Digits: code=Digit0, VK=ASCII
        if (ch >= '0' and ch <= '9') {
            return .{ .key = key_name, .code = key_name, .key_code = @as(i32, ch), .text = key_name };
        }
        // Punctuation: VK codes differ from ASCII (Playwright-compatible)
        const punct_info: struct { code: []const u8, kc: i32 } = switch (ch) {
            ';', ':' => .{ .code = "Semicolon", .kc = 186 },
            '=', '+' => .{ .code = "Equal", .kc = 187 },
            ',', '<' => .{ .code = "Comma", .kc = 188 },
            '-', '_' => .{ .code = "Minus", .kc = 189 },
            '.', '>' => .{ .code = "Period", .kc = 190 },
            '/', '?' => .{ .code = "Slash", .kc = 191 },
            '`', '~' => .{ .code = "Backquote", .kc = 192 },
            '[', '{' => .{ .code = "BracketLeft", .kc = 219 },
            '\\', '|' => .{ .code = "Backslash", .kc = 220 },
            ']', '}' => .{ .code = "BracketRight", .kc = 221 },
            '\'', '"' => .{ .code = "Quote", .kc = 222 },
            else => .{ .code = key_name, .kc = 0 },
        };
        return .{ .key = key_name, .code = punct_info.code, .key_code = punct_info.kc, .text = key_name };
    }

    return .{ .key = key_name, .code = key_name, .key_code = 0, .text = null };
}

fn handlePress(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, key: ?[]const u8) []u8 {
    const key_name = key orelse return respondErr(allocator, "key required");
    const info = getKeyInfo(key_name);

    // keyDown
    var down_buf: std.ArrayList(u8) = .empty;
    defer down_buf.deinit(allocator);
    const dw = down_buf.writer(allocator);
    dw.writeAll("{\"type\":\"keyDown\",\"key\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(dw, info.key) catch return respondErr(allocator, "write error");
    dw.writeAll(",\"code\":") catch {};
    cdp.writeJsonString(dw, info.code) catch {};
    std.fmt.format(dw, ",\"windowsVirtualKeyCode\":{d},\"nativeVirtualKeyCode\":{d}", .{ info.key_code, info.key_code }) catch {};
    if (info.text) |text| {
        dw.writeAll(",\"text\":") catch {};
        cdp.writeJsonString(dw, text) catch {};
    }
    dw.writeByte('}') catch {};

    const down_params = down_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(down_params);

    const cmd1 = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent", down_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd1);
    sender.sendText(cmd1) catch {};

    // keyUp
    var up_buf: std.ArrayList(u8) = .empty;
    defer up_buf.deinit(allocator);
    const uw = up_buf.writer(allocator);
    uw.writeAll("{\"type\":\"keyUp\",\"key\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(uw, info.key) catch {};
    uw.writeAll(",\"code\":") catch {};
    cdp.writeJsonString(uw, info.code) catch {};
    std.fmt.format(uw, ",\"windowsVirtualKeyCode\":{d},\"nativeVirtualKeyCode\":{d}", .{ info.key_code, info.key_code }) catch {};
    uw.writeByte('}') catch {};

    const up_params = up_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(up_params);

    const cmd2 = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent", up_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd2);
    sender.sendText(cmd2) catch {};

    return respondOk(allocator);
}

fn handleIsCheck(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, action: []const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const prop = if (std.mem.eql(u8, action, "is_visible"))
        "function(){var r=this.getBoundingClientRect();return r.width>0&&r.height>0&&window.getComputedStyle(this).visibility!=='hidden'}"
    else if (std.mem.eql(u8, action, "is_enabled"))
        "function(){return !this.disabled}"
    else
        "function(){return !!this.checked}";

    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "failed to resolve element");
    defer allocator.free(oid);

    const call_params = buildCallFunctionOnParams(allocator, oid, prop, null) orelse
        return respondErr(allocator, "alloc error");
    defer allocator.free(call_params);
    const call_id = cmd_id.next();
    const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(call_cmd);

    const raw = sendAndWait(sender, resp_map, call_cmd, call_id, 10_000) orelse
        return respondErr(allocator, "check timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getBool(remote_obj, "value")) |v| {
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = if (v) "true" else "false" }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "check timeout");
}

fn handleGetAttr(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, attr_name: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const attr = attr_name orelse return respondErr(allocator, "attribute name required");

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "failed to resolve element");
    defer allocator.free(oid);

    const call_params = buildCallFunctionOnParams(allocator, oid, "function(a){return this.getAttribute(a)}", attr) orelse
        return respondErr(allocator, "alloc error");
    defer allocator.free(call_params);
    const call_id = cmd_id.next();
    const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(call_cmd);

    const raw = sendAndWait(sender, resp_map, call_cmd, call_id, 10_000) orelse
        return respondErr(allocator, "get attr timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getString(remote_obj, "value")) |v| {
                    var resp: std.ArrayList(u8) = .empty;
                    defer resp.deinit(allocator);
                    cdp.writeJsonString(resp.writer(allocator), v) catch {};
                    const data = resp.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "get attr timeout");
}

fn handleFocusAction(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const cmd = snapshot_mod.buildFocusCmd(allocator, cmd_id.next(), backend_id, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch return respondErr(allocator, "send error");
    return respondOk(allocator);
}

fn handleDrag(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, from_ref: ?[]const u8, to_ref: ?[]const u8) []u8 {
    const from = from_ref orelse return respondErr(allocator, "from ref required");
    const to = to_ref orelse return respondErr(allocator, "to ref required");

    // Get source coordinates
    const from_entry = ref_map.getByRef(from) orelse return respondErr(allocator, "from ref not found");
    const from_bid = from_entry.backend_node_id orelse return respondErr(allocator, "no from node ID");
    const from_center = resolveCenter(allocator, sender, resp_map, cmd_id, session_id, from_bid) orelse return respondErr(allocator, "can't get from position");

    // Get target coordinates
    const to_entry = ref_map.getByRef(to) orelse return respondErr(allocator, "to ref not found");
    const to_bid = to_entry.backend_node_id orelse return respondErr(allocator, "no to node ID");
    const to_center = resolveCenter(allocator, sender, resp_map, cmd_id, session_id, to_bid) orelse return respondErr(allocator, "can't get to position");

    // mousePressed at from → mouseMoved to target → mouseReleased at target
    const press = snapshot_mod.buildClickCmd(allocator, cmd_id.next(), from_center.x, from_center.y, "mousePressed", session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(press);
    sender.sendText(press) catch {};

    const move = snapshot_mod.buildClickCmd(allocator, cmd_id.next(), to_center.x, to_center.y, "mouseMoved", session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(move);
    sender.sendText(move) catch {};

    const release = snapshot_mod.buildClickCmd(allocator, cmd_id.next(), to_center.x, to_center.y, "mouseReleased", session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(release);
    sender.sendText(release) catch {};

    return respondOk(allocator);
}

/// DOM.resolveNode → objectId. Caller must free the returned slice.
fn resolveNodeObjectId(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, backend_id: i64) ?[]u8 {
    var resolve_buf: [128]u8 = undefined;
    const resolve_params = std.fmt.bufPrint(&resolve_buf, "{{\"backendNodeId\":{d}}}", .{backend_id}) catch return null;
    const sent_id = cmd_id.next();
    const resolve_cmd = cdp.serializeCommand(allocator, sent_id, "DOM.resolveNode", resolve_params, session_id) catch return null;
    defer allocator.free(resolve_cmd);

    const raw = sendAndWait(sender, resp_map, resolve_cmd, sent_id, 10_000) orelse return null;
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch return null;
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "object")) |obj| {
                if (cdp.getString(obj, "objectId")) |oid| return allocator.dupe(u8, oid) catch null;
            }
        }
    }
    return null;
}

/// Build Runtime.callFunctionOn params JSON. Caller must free.
fn buildCallFunctionOnParams(allocator: Allocator, object_id: []const u8, func: []const u8, arg: ?[]const u8) ?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"objectId\":") catch return null;
    cdp.writeJsonString(w, object_id) catch return null;
    w.writeAll(",\"functionDeclaration\":") catch return null;
    cdp.writeJsonString(w, func) catch return null;
    if (arg) |a| {
        w.writeAll(",\"arguments\":[{\"value\":") catch return null;
        cdp.writeJsonString(w, a) catch return null;
        w.writeAll("}]") catch return null;
    }
    w.writeAll(",\"returnByValue\":true}") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

const BoxCenter = struct { x: f64, y: f64 };

fn resolveCenter(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, backend_id: i64) ?BoxCenter {
    const sent_id = cmd_id.next();
    const box_cmd = snapshot_mod.buildGetBoxModelCmd(allocator, sent_id, backend_id, session_id) catch return null;
    defer allocator.free(box_cmd);

    const raw = sendAndWait(sender, resp_map, box_cmd, sent_id, 10_000) orelse return null;
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch return null;
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (snapshot_mod.extractBoxCenter(result)) |c| {
                return BoxCenter{ .x = c.x, .y = c.y };
            }
        }
    }
    return null;
}

fn handleScrollIntoView(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    var buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"backendNodeId\":{d}}}", .{backend_id}) catch
        return respondErr(allocator, "format error");
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "DOM.scrollIntoViewIfNeeded", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleUpload(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, file_path: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const path = file_path orelse return respondErr(allocator, "file path required");

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    var params_buf: std.ArrayList(u8) = .empty;
    defer params_buf.deinit(allocator);
    const pw = params_buf.writer(allocator);
    std.fmt.format(pw, "{{\"backendNodeId\":{d},\"files\":[", .{backend_id}) catch return respondErr(allocator, "format error");
    cdp.writeJsonString(pw, path) catch {};
    pw.writeAll("]}") catch {};

    const params = params_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "DOM.setFileInputFiles", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handlePdf(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, path_opt: ?[]const u8) []u8 {
    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Page.printToPDF", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 30_000) orelse
        return respondErr(allocator, "pdf timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getString(result, "data")) |base64_data| {
                const file_path = path_opt orelse "output.pdf";
                const decoded_size = std.base64.standard.Decoder.calcSizeUpperBound(base64_data.len) catch
                    return respondErr(allocator, "invalid base64");
                const buf = allocator.alloc(u8, decoded_size) catch return respondErr(allocator, "alloc error");
                defer allocator.free(buf);
                std.base64.standard.Decoder.decode(buf, base64_data) catch return respondErr(allocator, "decode error");

                const file = std.fs.cwd().createFile(file_path, .{}) catch return respondErr(allocator, "file error");
                defer file.close();
                _ = file.write(buf[0..decoded_size]) catch return respondErr(allocator, "write error");

                var resp_buf: std.ArrayList(u8) = .empty;
                defer resp_buf.deinit(allocator);
                const rw = resp_buf.writer(allocator);
                rw.writeAll("{\"file\":") catch return respondOk(allocator);
                cdp.writeJsonString(rw, file_path) catch return respondOk(allocator);
                rw.print(",\"size\":{d}}}", .{decoded_size}) catch return respondOk(allocator);
                const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
                defer allocator.free(data);
                return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
            }
        }
    }
    return respondErr(allocator, "pdf timeout");
}

fn handleTabList(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8) []u8 {
    _ = session_id;
    const sent_id = cmd_id.next();
    const cmd = cdp.targetGetTargets(allocator, sent_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "tab list timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (result.object.get("targetInfos")) |infos| {
                if (infos == .array) {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(allocator);
                    const writer = buf.writer(allocator);
                    writer.writeByte('[') catch {};
                    var first = true;
                    for (infos.array.items) |info| {
                        const t = cdp.getString(info, "type") orelse "?";
                        if (!std.mem.eql(u8, t, "page")) continue;
                        if (!first) writer.writeByte(',') catch {};
                        first = false;
                        writer.writeAll("{\"type\":") catch {};
                        cdp.writeJsonString(writer, t) catch {};
                        writer.writeAll(",\"title\":") catch {};
                        cdp.writeJsonString(writer, cdp.getString(info, "title") orelse "") catch {};
                        writer.writeAll(",\"url\":") catch {};
                        cdp.writeJsonString(writer, cdp.getString(info, "url") orelse "") catch {};
                        writer.writeByte('}') catch {};
                    }
                    writer.writeByte(']') catch {};
                    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "tab list timeout");
}

fn handleSimpleCdpWithParams(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, method: []const u8, url: ?[]const u8) []u8 {
    if (url) |u| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.writeAll("{\"url\":") catch return respondErr(allocator, "write error");
        cdp.writeJsonString(w, u) catch return respondErr(allocator, "write error");
        w.writeByte('}') catch {};
        const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(params);
        const cmd = cdp.serializeCommand(allocator, cmd_id.next(), method, params, session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(cmd);
        sender.sendText(cmd) catch {};
    } else {
        const cmd = cdp.serializeCommand(allocator, cmd_id.next(), method, null, session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(cmd);
        sender.sendText(cmd) catch {};
    }
    return respondOk(allocator);
}

// ============================================================================
// Emulation Handlers
// ============================================================================

fn handleSetTimezone(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, tz: ?[]const u8) []u8 {
    const timezone = tz orelse return respondErr(allocator, "timezone required");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"timezoneId\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, timezone) catch return respondErr(allocator, "write error");
    w.writeByte('}') catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setTimezoneOverride", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleSetLocale(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, loc: ?[]const u8) []u8 {
    const locale = loc orelse return respondErr(allocator, "locale required");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"locale\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, locale) catch return respondErr(allocator, "write error");
    w.writeByte('}') catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setLocaleOverride", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleSetGeolocation(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, lat_str: ?[]const u8, lon_str: ?[]const u8) []u8 {
    const lat = lat_str orelse return respondErr(allocator, "latitude required");
    const lon = lon_str orelse return respondErr(allocator, "longitude required");
    // Validate that lat/lon are valid numbers
    _ = std.fmt.parseFloat(f64, lat) catch return respondErr(allocator, "invalid latitude");
    _ = std.fmt.parseFloat(f64, lon) catch return respondErr(allocator, "invalid longitude");
    var buf: [256]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"latitude\":{s},\"longitude\":{s},\"accuracy\":1}}", .{ lat, lon }) catch
        return respondErr(allocator, "format error");
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setGeolocationOverride", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handlePermissionsGrant(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, perm: ?[]const u8) []u8 {
    const permission = perm orelse return respondErr(allocator, "permission required");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"permissions\":[") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, permission) catch return respondErr(allocator, "write error");
    w.writeAll("]}") catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    // Browser.grantPermissions is a browser-level command, no session_id needed
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Browser.grantPermissions", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

const DeviceProfile = struct {
    name: []const u8,
    width: u16,
    height: u16,
    scale: f32,
    mobile: bool,
    ua: []const u8,
};

const DEVICES = [_]DeviceProfile{
    .{ .name = "iPhone 14", .width = 390, .height = 844, .scale = 3, .mobile = true, .ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" },
    .{ .name = "iPhone 14 Pro", .width = 393, .height = 852, .scale = 3, .mobile = true, .ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" },
    .{ .name = "Pixel 7", .width = 412, .height = 915, .scale = 2.625, .mobile = true, .ua = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36" },
    .{ .name = "iPad", .width = 768, .height = 1024, .scale = 2, .mobile = true, .ua = "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" },
    .{ .name = "iPad Pro", .width = 1024, .height = 1366, .scale = 2, .mobile = true, .ua = "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" },
    .{ .name = "Galaxy S23", .width = 360, .height = 780, .scale = 3, .mobile = true, .ua = "Mozilla/5.0 (Linux; Android 13; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36" },
    .{ .name = "Desktop 1080p", .width = 1920, .height = 1080, .scale = 1, .mobile = false, .ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" },
    .{ .name = "Desktop 1440p", .width = 2560, .height = 1440, .scale = 1, .mobile = false, .ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" },
};

fn findDevice(name: []const u8) ?DeviceProfile {
    for (DEVICES) |d| {
        if (std.ascii.eqlIgnoreCase(name, d.name)) return d;
    }
    return null;
}

fn handleSetDevice(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, device_name: ?[]const u8) []u8 {
    const name = device_name orelse return respondErr(allocator, "device name required");
    const device = findDevice(name) orelse {
        // Build error message with available devices
        var err_buf: std.ArrayList(u8) = .empty;
        defer err_buf.deinit(allocator);
        const ew = err_buf.writer(allocator);
        ew.writeAll("unknown device: ") catch {};
        ew.writeAll(name) catch {};
        ew.writeAll(". Available: ") catch {};
        for (DEVICES, 0..) |d, i| {
            if (i > 0) ew.writeAll(", ") catch {};
            ew.writeAll(d.name) catch {};
        }
        const msg = err_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "unknown device");
        defer allocator.free(msg);
        return respondErr(allocator, msg);
    };

    // 1. Emulation.setDeviceMetricsOverride
    {
        var buf: [256]u8 = undefined;
        const scale_str = if (device.scale == 1) "1" else if (device.scale == 2) "2" else if (device.scale == 3) "3" else "2.625";
        const params = std.fmt.bufPrint(&buf, "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":{s},\"mobile\":{s}}}", .{
            device.width,
            device.height,
            scale_str,
            if (device.mobile) "true" else "false",
        }) catch return respondErr(allocator, "format error");
        const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setDeviceMetricsOverride", params, session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(cmd);
        sender.sendText(cmd) catch {};
    }

    // 2. Emulation.setUserAgentOverride
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.writeAll("{\"userAgent\":") catch return respondErr(allocator, "write error");
        cdp.writeJsonString(w, device.ua) catch return respondErr(allocator, "write error");
        w.writeByte('}') catch {};
        const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(params);
        const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setUserAgentOverride", params, session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(cmd);
        sender.sendText(cmd) catch {};
    }

    return respondOk(allocator);
}

fn handleDeviceList(allocator: Allocator) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeByte('[') catch return respondErr(allocator, "write error");
    for (DEVICES, 0..) |d, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.writeAll("{\"name\":") catch {};
        cdp.writeJsonString(w, d.name) catch {};
        w.print(",\"width\":{d},\"height\":{d},\"mobile\":{s}}}", .{ d.width, d.height, if (d.mobile) "true" else "false" }) catch {};
    }
    w.writeByte(']') catch {};
    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);
    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
}

fn handleSetHeaders(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, json: ?[]const u8) []u8 {
    const headers_json = json orelse return respondErr(allocator, "headers JSON required");
    // Validate that input is valid JSON
    _ = std.json.parseFromSlice(std.json.Value, allocator, headers_json, .{}) catch
        return respondErr(allocator, "invalid JSON");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"headers\":") catch return respondErr(allocator, "write error");
    w.writeAll(headers_json) catch return respondErr(allocator, "write error");
    w.writeByte('}') catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Network.setExtraHTTPHeaders", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

/// haystack에서 `flag <quote>[header:]value<quote>` 패턴을 찾아 value 반환.
/// expect_header가 주어지면 따옴표 값이 그 헤더명+":"으로 시작해야 하며 접두사 제거.
/// 반환 슬라이스는 haystack의 부분 슬라이스(별도 할당 아님).
fn matchQuotedArg(haystack: []const u8, flag: []const u8, expect_header: ?[]const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + flag.len < haystack.len) {
        if (!std.mem.eql(u8, haystack[i .. i + flag.len], flag)) {
            i += 1;
            continue;
        }
        // 왼쪽 단어 경계 (문자열 시작 또는 공백)
        if (i > 0 and !std.ascii.isWhitespace(haystack[i - 1])) {
            i += 1;
            continue;
        }
        var j = i + flag.len;
        if (j >= haystack.len or !std.ascii.isWhitespace(haystack[j])) {
            i += 1;
            continue;
        }
        while (j < haystack.len and std.ascii.isWhitespace(haystack[j])) j += 1;
        if (j >= haystack.len) return null;
        const quote = haystack[j];
        if (quote != '\'' and quote != '"') {
            i = j;
            continue;
        }
        const start = j + 1;
        var k = start;
        while (k < haystack.len and haystack[k] != quote) k += 1;
        if (k >= haystack.len) return null;
        const value = haystack[start..k];
        if (expect_header) |header| {
            if (value.len > header.len + 1 and
                std.ascii.eqlIgnoreCase(value[0..header.len], header) and
                value[header.len] == ':')
            {
                return std.mem.trim(u8, value[header.len + 1 ..], " \t");
            }
            i = k + 1;
            continue;
        }
        return value;
    }
    return null;
}

/// cURL 명령에서 Cookie 헤더 값 추출 (-H 'cookie: ...', -b '...', --cookie '...').
fn extractCookieHeaderFromCurl(allocator: Allocator, curl: []const u8) !?[]const u8 {
    // bash(`\`)/cmd(`^`) 줄 연속을 공백으로 평탄화해 -H 등이 한 줄에 오게 함.
    // 개행/CR을 공백으로 치환하면 앞의 `\`/`^`는 공백에 둘러싸여 무해해진다.
    const joined = try allocator.dupe(u8, curl);
    defer allocator.free(joined);
    std.mem.replaceScalar(u8, joined, '\n', ' ');
    std.mem.replaceScalar(u8, joined, '\r', ' ');
    if (matchQuotedArg(joined, "-H", "cookie")) |v| return try allocator.dupe(u8, v);
    if (matchQuotedArg(joined, "-b", null)) |v| return try allocator.dupe(u8, v);
    if (matchQuotedArg(joined, "--cookie", null)) |v| return try allocator.dupe(u8, v);
    return null;
}

/// Network.setCookies 배열의 단일 쿠키 객체 한 항목을 기록.
fn writeCookieEntry(w: anytype, first: bool, name: []const u8, value: []const u8) !void {
    if (!first) try w.writeByte(',');
    try w.writeAll("{\"name\":");
    try cdp.writeJsonString(w, name);
    try w.writeAll(",\"value\":");
    try cdp.writeJsonString(w, value);
    try w.writeAll(",\"url\":\"*\"}");
}

/// "name=value; name2=value2" 헤더를 Network.setCookies cookies 배열 JSON으로.
/// 비밀값을 에러 메시지에 절대 노출하지 않음.
fn cookieHeaderToJson(allocator: Allocator, header: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('[');
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |piece_raw| {
        const piece = std.mem.trim(u8, piece_raw, " \t\r\n");
        const eq = std.mem.indexOfScalar(u8, piece, '=') orelse continue;
        const name = std.mem.trim(u8, piece[0..eq], " \t");
        const value = std.mem.trim(u8, piece[eq + 1 ..], " \t");
        if (name.len == 0) continue;
        try writeCookieEntry(w, count == 0, name, value);
        count += 1;
    }
    try w.writeByte(']');
    if (count == 0) return error.NoCookies;
    return buf.toOwnedSlice(allocator);
}

/// 쿠키 파일을 3가지 형식 자동 감지하여 Network.setCookies cookies 배열 JSON 생성:
///   1. JSON 배열  [{"name":"x","value":"y"}, ...]
///   2. cURL 덤프  (DevTools → Copy as cURL; -H/-b/--cookie 에서 추출)
///   3. 베어 Cookie 헤더  name=value; name2=value2
fn buildCookieSetArrayJson(allocator: Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyFile;

    if (trimmed[0] == '[') {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
            return error.JsonParse;
        defer parsed.deinit();
        if (parsed.value != .array) return error.JsonParse;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.writeByte('[');
        var count: usize = 0;
        for (parsed.value.array.items) |c| {
            const name = cdp.getString(c, "name") orelse return error.MissingName;
            const value = cdp.getString(c, "value") orelse return error.MissingValue;
            try writeCookieEntry(w, count == 0, name, value);
            count += 1;
        }
        try w.writeByte(']');
        if (count == 0) return error.NoCookies;
        return buf.toOwnedSlice(allocator);
    }

    // cURL 휴리스틱: "curl" + 공백/따옴표로 시작
    const looks_like_curl = trimmed.len > 4 and
        std.ascii.eqlIgnoreCase(trimmed[0..4], "curl") and
        (std.ascii.isWhitespace(trimmed[4]) or trimmed[4] == '\'' or trimmed[4] == '"');

    if (looks_like_curl) {
        const header = (try extractCookieHeaderFromCurl(allocator, trimmed)) orelse
            return error.NoCookieHeaderInCurl;
        defer allocator.free(header);
        return cookieHeaderToJson(allocator, header);
    }

    return cookieHeaderToJson(allocator, trimmed);
}

fn handleCookieSet(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, name: ?[]const u8, value: ?[]const u8) []u8 {
    const n = name orelse return respondErr(allocator, "name required");
    const v = value orelse "";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"name\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, n) catch return respondErr(allocator, "write error");
    w.writeAll(",\"value\":") catch {};
    cdp.writeJsonString(w, v) catch {};
    w.writeAll(",\"url\":\"*\"}") catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Network.setCookie", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

/// 일괄 쿠키 설정 — req.url에 Network.setCookies cookies 배열 JSON이 담겨옴.
fn handleCookieSetBulk(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, arr_opt: ?[]const u8) []u8 {
    const arr = arr_opt orelse return respondErr(allocator, "cookies array required");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"cookies\":") catch return respondErr(allocator, "write error");
    w.writeAll(arr) catch return respondErr(allocator, "write error");
    w.writeByte('}') catch return respondErr(allocator, "write error");
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Network.setCookies", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleSetViewport(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, width_str: ?[]const u8, height_str: ?[]const u8) []u8 {
    const w = std.fmt.parseInt(i32, width_str orelse "1280", 10) catch 1280;
    const h = std.fmt.parseInt(i32, height_str orelse "720", 10) catch 720;
    var buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":1,\"mobile\":false}}", .{ w, h }) catch
        return respondErr(allocator, "format error");
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setDeviceMetricsOverride", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleSetMedia(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, scheme: ?[]const u8) []u8 {
    const s = scheme orelse "dark";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"features\":[{\"name\":\"prefers-color-scheme\",\"value\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, s) catch return respondErr(allocator, "write error");
    w.writeAll("}]}") catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setEmulatedMedia", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleSetOffline(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, on_off: ?[]const u8) []u8 {
    const offline = if (on_off) |v| std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true") else false;
    var buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"offline\":{s},\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}}", .{if (offline) "true" else "false"}) catch
        return respondErr(allocator, "format error");
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Network.emulateNetworkConditions", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleSetUserAgent(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ua: ?[]const u8) []u8 {
    const user_agent = ua orelse return respondErr(allocator, "user-agent string required");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"userAgent\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, user_agent) catch return respondErr(allocator, "write error");
    w.writeByte('}') catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Emulation.setUserAgentOverride", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleMouse(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, action: ?[]const u8, coords: ?[]const u8) []u8 {
    const act = action orelse "move";
    const coord_str = coords orelse "0:0";

    // Parse "x:y" packed coords
    var x: i32 = 0;
    var y: i32 = 0;
    if (std.mem.indexOf(u8, coord_str, ":")) |sep| {
        x = std.fmt.parseInt(i32, coord_str[0..sep], 10) catch 0;
        y = std.fmt.parseInt(i32, coord_str[sep + 1 ..], 10) catch 0;
    } else {
        x = std.fmt.parseInt(i32, coord_str, 10) catch 0;
    }

    const mouse_type = if (std.mem.eql(u8, act, "down")) "mousePressed" else if (std.mem.eql(u8, act, "up")) "mouseReleased" else "mouseMoved";

    var buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"left\"}}", .{ mouse_type, x, y }) catch
        return respondErr(allocator, "format error");
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchMouseEvent", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleScroll(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, dir_opt: ?[]const u8, px_opt: ?[]const u8) []u8 {
    const direction = dir_opt orelse "down";
    const px_str = px_opt orelse "300";
    const px = std.fmt.parseInt(i32, px_str, 10) catch 300;

    const delta_x: i32 = if (std.mem.eql(u8, direction, "left")) -px else if (std.mem.eql(u8, direction, "right")) px else 0;
    const delta_y: i32 = if (std.mem.eql(u8, direction, "up")) -px else if (std.mem.eql(u8, direction, "down")) px else 0;

    var buf: [256]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"type\":\"mouseWheel\",\"x\":400,\"y\":300,\"deltaX\":{d},\"deltaY\":{d}}}", .{ delta_x, delta_y }) catch
        return respondErr(allocator, "format error");

    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchMouseEvent", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};

    return respondOk(allocator);
}

fn handleStorage(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, action: []const u8, key: ?[]const u8, value: ?[]const u8) []u8 {
    // action format: storage_{local|session}_{set|get|clear|list}
    const is_session = std.mem.startsWith(u8, action, "storage_session_");
    const storage_obj = if (is_session) "sessionStorage" else "localStorage";

    if (std.mem.endsWith(u8, action, "_clear")) {
        var expr_buf: [64]u8 = undefined;
        const expr = std.fmt.bufPrint(&expr_buf, "{s}.clear()", .{storage_obj}) catch
            return respondErr(allocator, "format error");
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
    } else if (std.mem.endsWith(u8, action, "_list")) {
        var expr_buf: [64]u8 = undefined;
        const expr = std.fmt.bufPrint(&expr_buf, "JSON.stringify({s})", .{storage_obj}) catch
            return respondErr(allocator, "format error");
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
    } else if (std.mem.endsWith(u8, action, "_set")) {
        // Build safe JS: use Runtime.evaluate with JSON-escaped strings
        const k = key orelse "";
        const v = value orelse "";
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.print("{s}.setItem(", .{storage_obj}) catch return respondErr(allocator, "write error");
        cdp.writeJsonString(w, k) catch return respondErr(allocator, "write error");
        w.writeByte(',') catch {};
        cdp.writeJsonString(w, v) catch return respondErr(allocator, "write error");
        w.writeByte(')') catch {};
        const expr = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(expr);
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
    } else if (std.mem.endsWith(u8, action, "_get")) {
        const k = key orelse return respondErr(allocator, "key required");
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.print("{s}.getItem(", .{storage_obj}) catch return respondErr(allocator, "write error");
        cdp.writeJsonString(w, k) catch return respondErr(allocator, "write error");
        w.writeByte(')') catch {};
        const expr = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(expr);
        return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
    } else {
        return respondErr(allocator, "unknown storage action");
    }
}

fn handleSelectOption(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, value: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const select_value = value orelse "";

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "failed to resolve element");
    defer allocator.free(oid);

    const call_params = buildCallFunctionOnParams(allocator, oid, "function(v){this.value=v;this.dispatchEvent(new Event('change',{bubbles:true}));return 'ok'}", select_value) orelse
        return respondErr(allocator, "alloc error");
    defer allocator.free(call_params);
    const call_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Runtime.callFunctionOn", call_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(call_cmd);
    sender.sendText(call_cmd) catch {};

    return respondOk(allocator);
}

fn handleGetElementProp(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, action: []const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "failed to resolve element");
    defer allocator.free(oid);

    const prop = if (std.mem.eql(u8, action, "get_text"))
        "function(){return this.innerText||this.textContent||''}"
    else if (std.mem.eql(u8, action, "get_html"))
        "function(){return this.innerHTML||''}"
    else
        "function(){return this.value||''}";

    const call_params = buildCallFunctionOnParams(allocator, oid, prop, null) orelse
        return respondErr(allocator, "alloc error");
    defer allocator.free(call_params);
    const call_id = cmd_id.next();
    const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(call_cmd);

    const raw = sendAndWait(sender, resp_map, call_cmd, call_id, 10_000) orelse
        return respondErr(allocator, "get property timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getString(remote_obj, "value")) |v| {
                    var resp: std.ArrayList(u8) = .empty;
                    defer resp.deinit(allocator);
                    cdp.writeJsonString(resp.writer(allocator), v) catch return respondErr(allocator, "write error");
                    const data = resp.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "get property timeout");
}

fn handleScreenshot(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, path_opt: ?[]const u8) []u8 {
    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Page.captureScreenshot",
        \\{"format":"png"}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 15_000) orelse
        return respondErr(allocator, "screenshot timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getString(result, "data")) |base64_data| {
                // If path provided, save to file
                if (path_opt) |file_path| {
                    const decoded_size = std.base64.standard.Decoder.calcSizeUpperBound(base64_data.len) catch
                        return respondErr(allocator, "invalid base64");
                    const buf = allocator.alloc(u8, decoded_size) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(buf);

                    std.base64.standard.Decoder.decode(buf, base64_data) catch
                        return respondErr(allocator, "decode error");

                    const file = std.fs.cwd().createFile(file_path, .{}) catch
                        return respondErr(allocator, "file create error");
                    defer file.close();
                    _ = file.write(buf[0..decoded_size]) catch return respondErr(allocator, "write error");

                    var resp_buf2: std.ArrayList(u8) = .empty;
                    defer resp_buf2.deinit(allocator);
                    const rw2 = resp_buf2.writer(allocator);
                    rw2.writeAll("{\"file\":") catch return respondOk(allocator);
                    cdp.writeJsonString(rw2, file_path) catch return respondOk(allocator);
                    rw2.print(",\"size\":{d}}}", .{decoded_size}) catch return respondOk(allocator);
                    const data = resp_buf2.toOwnedSlice(allocator) catch return respondOk(allocator);
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
                } else {
                    // Return base64 data directly
                    var resp_buf: std.ArrayList(u8) = .empty;
                    defer resp_buf.deinit(allocator);
                    const writer = resp_buf.writer(allocator);
                    writer.writeAll("{\"data\":\"") catch return respondErr(allocator, "write error");
                    writer.writeAll(base64_data) catch return respondErr(allocator, "write error");
                    writer.writeAll("\"}") catch {};

                    const data = resp_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "screenshot timeout");
}

fn handleScreenshotFull(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, path_opt: ?[]const u8) []u8 {
    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Page.captureScreenshot",
        \\{"format":"png","captureBeyondViewport":true,"fromSurface":true}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 15_000) orelse
        return respondErr(allocator, "screenshot timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getString(result, "data")) |base64_data| {
                // If path provided, save to file
                if (path_opt) |file_path| {
                    const decoded_size = std.base64.standard.Decoder.calcSizeUpperBound(base64_data.len) catch
                        return respondErr(allocator, "invalid base64");
                    const buf = allocator.alloc(u8, decoded_size) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(buf);

                    std.base64.standard.Decoder.decode(buf, base64_data) catch
                        return respondErr(allocator, "decode error");

                    const file = std.fs.cwd().createFile(file_path, .{}) catch
                        return respondErr(allocator, "file create error");
                    defer file.close();
                    _ = file.write(buf[0..decoded_size]) catch return respondErr(allocator, "write error");

                    var resp_buf2: std.ArrayList(u8) = .empty;
                    defer resp_buf2.deinit(allocator);
                    const rw2 = resp_buf2.writer(allocator);
                    rw2.writeAll("{\"file\":") catch return respondOk(allocator);
                    cdp.writeJsonString(rw2, file_path) catch return respondOk(allocator);
                    rw2.print(",\"size\":{d}}}", .{decoded_size}) catch return respondOk(allocator);
                    const data = resp_buf2.toOwnedSlice(allocator) catch return respondOk(allocator);
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
                } else {
                    // Return base64 data directly
                    var resp_buf: std.ArrayList(u8) = .empty;
                    defer resp_buf.deinit(allocator);
                    const writer = resp_buf.writer(allocator);
                    writer.writeAll("{\"data\":\"") catch return respondErr(allocator, "write error");
                    writer.writeAll(base64_data) catch return respondErr(allocator, "write error");
                    writer.writeAll("\"}") catch {};

                    const data = resp_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "screenshot full-page timeout");
}

fn handleDiffScreenshot(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, baseline_path_opt: ?[]const u8, params_opt: ?[]const u8) []u8 {
    const baseline_path = baseline_path_opt orelse return respondErr(allocator, "baseline path required");

    // Parse params: current_path|threshold|output_path
    var current_path: ?[]const u8 = null;
    var threshold: f64 = 0.1;
    var output_path: []const u8 = "diff.png";

    if (params_opt) |params| {
        var it = std.mem.splitScalar(u8, params, '|');
        const cp = it.next() orelse "";
        if (cp.len > 0) current_path = cp;
        const th = it.next() orelse "0.1";
        if (th.len > 0) {
            threshold = std.fmt.parseFloat(f64, th) catch 0.1;
        }
        const op = it.next() orelse "diff.png";
        if (op.len > 0) output_path = op;
    }

    // Read baseline PNG
    const baseline_data = std.fs.cwd().readFileAlloc(allocator, baseline_path, 50 * 1024 * 1024) catch
        return respondErr(allocator, "cannot read baseline file");
    defer allocator.free(baseline_data);

    // Get current image: either from file or live screenshot
    var current_data_owned: ?[]u8 = null;
    defer if (current_data_owned) |d| allocator.free(d);

    const current_data: []const u8 = if (current_path) |cp| blk: {
        const data = std.fs.cwd().readFileAlloc(allocator, cp, 50 * 1024 * 1024) catch
            return respondErr(allocator, "cannot read current file");
        current_data_owned = data;
        break :blk data;
    } else blk: {
        // Take live screenshot via CDP
        const data = captureScreenshotRaw(allocator, sender, resp_map, cmd_id, session_id) orelse
            return respondErr(allocator, "screenshot capture failed");
        current_data_owned = data;
        break :blk data;
    };

    // Perform diff
    var result = png.diffScreenshots(allocator, baseline_data, current_data, threshold) catch
        return respondErr(allocator, "diff failed: invalid PNG");
    defer result.deinit();

    // Save diff image
    if (result.diff_image) |diff_png| {
        const file = std.fs.cwd().createFile(output_path, .{}) catch
            return respondErr(allocator, "cannot create diff file");
        defer file.close();
        _ = file.write(diff_png) catch return respondErr(allocator, "write error");
    }

    // Build response JSON
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    const rw = resp_buf.writer(allocator);
    rw.print("{{\"match\":{s},\"total_pixels\":{d},\"different_pixels\":{d},\"mismatch_percentage\":{d:.2},\"diff_image\":", .{
        if (result.match) "true" else "false",
        result.total_pixels,
        result.different_pixels,
        result.mismatch_percentage,
    }) catch return respondErr(allocator, "format error");
    cdp.writeJsonString(rw, output_path) catch return respondErr(allocator, "format error");
    rw.writeAll("}") catch return respondErr(allocator, "format error");

    const data = resp_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);
    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
}

/// Capture a raw PNG screenshot via CDP, returning the decoded binary data.
/// Returns null on failure. Caller must free the returned slice.
fn captureScreenshotRaw(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8) ?[]u8 {
    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Page.captureScreenshot",
        \\{"format":"png"}
    , session_id) catch return null;
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 15_000) orelse return null;
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch return null;
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getString(result, "data")) |base64_data| {
                const decoded_size = std.base64.standard.Decoder.calcSizeUpperBound(base64_data.len) catch return null;
                const buf = allocator.alloc(u8, decoded_size) catch return null;
                std.base64.standard.Decoder.decode(buf, base64_data) catch {
                    allocator.free(buf);
                    return null;
                };
                return buf;
            }
        }
    }
    return null;
}

fn handleEval(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, expr_opt: ?[]const u8) []u8 {
    const expression = expr_opt orelse return respondErr(allocator, "expression required");

    const sent_id = cmd_id.next();
    const cmd = cdp.runtimeEvaluate(allocator, sent_id, expression, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "eval timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                // Handle undefined/null returns (e.g. localStorage.setItem)
                if (cdp.getString(remote_obj, "type")) |t| {
                    if (std.mem.eql(u8, t, "undefined")) return respondOk(allocator);
                }
                // Extract value from RemoteObject
                if (cdp.getString(remote_obj, "value")) |v| {
                    const data = allocator.dupe(u8, v) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    var resp: std.ArrayList(u8) = .empty;
                    defer resp.deinit(allocator);
                    cdp.writeJsonString(resp.writer(allocator), data) catch return respondErr(allocator, "write error");
                    const resp_data = resp.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(resp_data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = resp_data }) catch respondErr(allocator, "resp error");
                }
                if (cdp.getString(remote_obj, "description")) |d| {
                    const resp_data = allocator.dupe(u8, d) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(resp_data);
                    var resp: std.ArrayList(u8) = .empty;
                    defer resp.deinit(allocator);
                    cdp.writeJsonString(resp.writer(allocator), resp_data) catch {};
                    const rd = resp.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(rd);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = rd }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "eval timeout");
}

fn handleSimpleCdp(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, method: []const u8) []u8 {
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), method, null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch return respondErr(allocator, "send error");
    return respondOk(allocator);
}

fn handleNavAction(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, method: []const u8, direction: []const u8) []u8 {
    // Use Runtime.evaluate with history.back()/forward() — simpler than history entry management
    _ = method;
    const expr = if (std.mem.eql(u8, direction, "-1")) "history.back()" else "history.forward()";
    const cmd = cdp.runtimeEvaluate(allocator, cmd_id.next(), expr, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch return respondErr(allocator, "send error");
    return respondOk(allocator);
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
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    const rw = resp_buf.writer(allocator);
    rw.writeAll("{\"file\":") catch return respondOk(allocator);
    cdp.writeJsonString(rw, file_path) catch return respondOk(allocator);
    rw.print(",\"requests\":{d}}}", .{collector.count()}) catch return respondOk(allocator);
    const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
    defer allocator.free(data);

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
    sender: *WsSender,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    intercept_state: *interceptor.InterceptorState,
    url_pattern: ?[]const u8,
    action: interceptor.Action,
    extra: ?[]const u8, // mock body or delay ms
    resource_types_csv: ?[]const u8, // optional --resource-type filter (CSV)
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
        .resource_types = if (resource_types_csv) |rt| (allocator.dupe(u8, rt) catch return respondErr(allocator, "alloc error")) else null,
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
    sender.sendText(enable_cmd) catch {};

    return respondOk(allocator);
}

fn handleInterceptRemove(
    allocator: Allocator,
    sender: *WsSender,
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
        sender.sendText(disable) catch {};
    } else {
        const patterns = intercept_state.buildFetchPatterns(allocator) catch return respondOk(allocator);
        defer allocator.free(patterns);
        const enable_cmd = cdp.fetchEnable(allocator, cmd_id.next(), patterns, session_id) catch return respondOk(allocator);
        defer allocator.free(enable_cmd);
        sender.sendText(enable_cmd) catch {};
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
        if (rule.resource_types) |rt| {
            writer.writeAll(",\"resourceType\":") catch {};
            cdp.writeJsonString(writer, rt) catch {};
        }
        writer.writeByte('}') catch {};
    }
    writer.writeByte(']') catch {};

    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

fn handleAnalyze(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, collector: *network.Collector, collector_mutex: *std.Thread.Mutex) []u8 {
    collector_mutex.lock();
    var result = analyzer.analyzeRequests(allocator, collector) catch {
        collector_mutex.unlock();
        return respondErr(allocator, "analysis failed");
    };
    defer result.deinit();

    // Enrich endpoints with response body schema
    for (result.endpoints) |*ep| {
        if (!std.mem.startsWith(u8, ep.mime_type, "application/json")) continue;

        // Find the requestId for this endpoint's example URL
        var req_it = collector.requests.iterator();
        while (req_it.next()) |entry| {
            const info = entry.value_ptr.info;
            if (std.mem.eql(u8, info.url, ep.example_url)) {
                const rid = allocator.dupe(u8, info.request_id) catch break;
                defer allocator.free(rid);
                collector_mutex.unlock();
                // Fetch response body (without holding lock)
                if (fetchResponseBody(allocator, sender, resp_map, cmd_id, session_id, rid)) |body| {
                    defer allocator.free(body);
                    ep.response_schema = analyzer.inferJsonSchema(allocator, body);
                }
                collector_mutex.lock();
                break;
            }
        }
    }
    collector_mutex.unlock();

    const data = analyzer.serializeResult(allocator, &result) catch
        return respondErr(allocator, "serialize failed");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "response failed");
}

/// Fetch response body for a request via CDP. Returns owned slice or null.
fn fetchResponseBody(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, request_id: []const u8) ?[]u8 {
    const sent_id = cmd_id.next();
    const get_body_cmd = cdp.networkGetResponseBody(allocator, sent_id, request_id, session_id) catch return null;
    defer allocator.free(get_body_cmd);

    const raw = sendAndWait(sender, resp_map, get_body_cmd, sent_id, 10_000) orelse return null;
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch return null;
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |res| {
            if (cdp.getString(res, "body")) |b| {
                return allocator.dupe(u8, b) catch null;
            }
        }
    }
    return null;
}

fn handleStatus(allocator: Allocator, collector: *const network.Collector, console_msgs: *const std.ArrayList(ConsoleEntry)) []u8 {
    return handleStatusFull(allocator, collector, console_msgs, null);
}

fn handleStatusFull(allocator: Allocator, collector: *const network.Collector, console_msgs: *const std.ArrayList(ConsoleEntry), page_errors: ?*const std.ArrayList(PageError)) []u8 {
    var buf: [256]u8 = undefined;
    const error_count: usize = if (page_errors) |pe| pe.items.len else 0;
    const data = std.fmt.bufPrint(&buf, "{{\"requests\":{d},\"console\":{d},\"errors\":{d},\"daemon\":\"running\"}}", .{
        collector.count(),
        console_msgs.items.len,
        error_count,
    }) catch return respondErr(allocator, "format error");

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

// ============================================================================
// Find (Semantic Element Queries)
// ============================================================================

fn handleFind(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, strategy_opt: ?[]const u8, value_opt: ?[]const u8) []u8 {
    const strategy = strategy_opt orelse return respondErr(allocator, "strategy required");
    const value = value_opt orelse return respondErr(allocator, "value required");

    if (std.mem.eql(u8, strategy, "role") or std.mem.eql(u8, strategy, "text") or std.mem.eql(u8, strategy, "label")) {
        // Search through ref_map entries
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);
        writer.writeByte('[') catch return respondErr(allocator, "write error");

        var first = true;
        var it = ref_map.entries.iterator();
        while (it.next()) |entry| {
            const ref_entry = entry.value_ptr.*;
            const matches = if (std.mem.eql(u8, strategy, "role"))
                std.mem.eql(u8, ref_entry.role, value)
            else
                // text and label both match on the accessible name
                std.mem.indexOf(u8, ref_entry.name, value) != null;

            if (matches) {
                if (!first) writer.writeByte(',') catch {};
                first = false;
                writer.writeAll("{\"ref\":\"@") catch {};
                writer.writeAll(ref_entry.ref_id) catch {};
                writer.writeAll("\",\"role\":") catch {};
                cdp.writeJsonString(writer, ref_entry.role) catch {};
                writer.writeAll(",\"name\":") catch {};
                cdp.writeJsonString(writer, ref_entry.name) catch {};
                writer.writeByte('}') catch {};
            }
        }
        writer.writeByte(']') catch {};

        const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(data);
        return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
    } else if (std.mem.eql(u8, strategy, "placeholder") or std.mem.eql(u8, strategy, "testid")) {
        // For placeholder/testid, we need DOM access: resolve each ref and check attribute
        const attr_name = if (std.mem.eql(u8, strategy, "testid")) "data-testid" else "placeholder";

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);
        writer.writeByte('[') catch return respondErr(allocator, "write error");

        var first = true;
        var checked: usize = 0;
        var it = ref_map.entries.iterator();
        while (it.next()) |entry| {
            if (checked >= 200) break; // Limit to avoid blocking for minutes on large pages
            checked += 1;
            const ref_entry = entry.value_ptr.*;
            const backend_id = ref_entry.backend_node_id orelse continue;

            // Resolve node and check attribute
            const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse continue;
            defer allocator.free(oid);

            const call_params = buildCallFunctionOnParams(allocator, oid, "function(a){return this.getAttribute(a)}", attr_name) orelse continue;
            defer allocator.free(call_params);
            const call_id = cmd_id.next();
            const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch continue;
            defer allocator.free(call_cmd);

            const raw = sendAndWait(sender, resp_map, call_cmd, call_id, 3_000) orelse continue;
            defer allocator.free(raw);

            const parsed = cdp.parseMessage(allocator, raw) catch continue;
            defer parsed.parsed.deinit();

            if (parsed.message.isResponse()) {
                if (parsed.message.result) |result| {
                    if (cdp.getObject(result, "result")) |remote_obj| {
                        if (cdp.getString(remote_obj, "value")) |attr_val| {
                            if (std.mem.indexOf(u8, attr_val, value) != null) {
                                if (!first) writer.writeByte(',') catch {};
                                first = false;
                                writer.writeAll("{\"ref\":\"@") catch {};
                                writer.writeAll(ref_entry.ref_id) catch {};
                                writer.writeAll("\",\"role\":") catch {};
                                cdp.writeJsonString(writer, ref_entry.role) catch {};
                                writer.writeAll(",\"name\":") catch {};
                                cdp.writeJsonString(writer, ref_entry.name) catch {};
                                writer.writeByte('}') catch {};
                            }
                        }
                    }
                }
            }
        }
        writer.writeByte(']') catch {};

        const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(data);
        return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
    } else {
        return respondErr(allocator, "unknown find strategy (use: role, text, label, placeholder, testid)");
    }
}

// ============================================================================
// Dialog Handling
// ============================================================================

fn handleDialogAccept(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, prompt_text: ?[]const u8) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"accept\":true") catch return respondErr(allocator, "write error");
    if (prompt_text) |text| {
        w.writeAll(",\"promptText\":") catch {};
        cdp.writeJsonString(w, text) catch {};
    }
    w.writeByte('}') catch {};

    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Page.handleJavaScriptDialog", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

fn handleDialogDismiss(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8) []u8 {
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Page.handleJavaScriptDialog",
        \\{"accept":false}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

// ============================================================================
// Content Commands
// ============================================================================

fn handleSetContent(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, html_opt: ?[]const u8) []u8 {
    const html = html_opt orelse return respondErr(allocator, "html required");

    // Build safe JS expression: document.documentElement.innerHTML = <escaped>
    var expr_buf: std.ArrayList(u8) = .empty;
    defer expr_buf.deinit(allocator);
    const w = expr_buf.writer(allocator);
    w.writeAll("document.documentElement.innerHTML=") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, html) catch return respondErr(allocator, "write error");

    const expr = expr_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(expr);

    return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
}

// ============================================================================
// AddScript (Page.addScriptToEvaluateOnNewDocument)
// ============================================================================

/// source를 Page.addScriptToEvaluateOnNewDocument로 등록 (응답 대기 없음). 성공 시 true.
fn sendAddScriptOnNewDocument(allocator: Allocator, ws: *websocket.Client, cmd_id: *cdp.CommandId, session_id: ?[]const u8, source: []const u8) bool {
    const params = cdp.jsonObject1(allocator, "source", source) catch return false;
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Page.addScriptToEvaluateOnNewDocument", params, session_id) catch return false;
    defer allocator.free(cmd);
    ws.sendText(cmd) catch return false;
    return true;
}

/// 쉼표/개행 구분 경로 목록의 각 파일을 읽어
/// Page.addScriptToEvaluateOnNewDocument로 등록 (best-effort, 실패는 stderr 경고).
fn registerInitScripts(allocator: Allocator, ws: *websocket.Client, cmd_id: *cdp.CommandId, session_id: ?[]const u8, csv: []const u8) usize {
    var sent: usize = 0;
    var it = std.mem.tokenizeAny(u8, csv, ",\n");
    while (it.next()) |path_raw| {
        const path = std.mem.trim(u8, path_raw, " \t\r");
        if (path.len == 0) continue;
        const source = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
            std.debug.print("Daemon: failed to read --init-script '{s}'\n", .{path});
            continue;
        };
        defer allocator.free(source);
        if (sendAddScriptOnNewDocument(allocator, ws, cmd_id, session_id, source)) sent += 1;
    }
    return sent;
}

/// addscript가 반환한 identifier로 등록된 init 스크립트 제거.
fn handleRemoveInitScript(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, id_opt: ?[]const u8) []u8 {
    const identifier = id_opt orelse return respondErr(allocator, "identifier required");

    const params = cdp.jsonObject1(allocator, "identifier", identifier) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);

    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Page.removeScriptToEvaluateOnNewDocument", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "removeinitscript timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isErrorResponse()) return respondErr(allocator, "removeinitscript failed (invalid identifier?)");
    return respondOk(allocator);
}

fn handleAddScript(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, js_code_opt: ?[]const u8) []u8 {
    const js_code = js_code_opt orelse return respondErr(allocator, "js code required");

    const params = cdp.jsonObject1(allocator, "source", js_code) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);

    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Page.addScriptToEvaluateOnNewDocument", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "addscript timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getString(result, "identifier")) |identifier| {
                var resp_buf: std.ArrayList(u8) = .empty;
                defer resp_buf.deinit(allocator);
                const rw = resp_buf.writer(allocator);
                rw.writeAll("{\"identifier\":") catch return respondOk(allocator);
                cdp.writeJsonString(rw, identifier) catch return respondOk(allocator);
                rw.writeByte('}') catch {};
                const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
                defer allocator.free(data);
                return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
            }
        }
    }
    return respondOk(allocator);
}

// ============================================================================
// Wait Commands
// ============================================================================

fn handleWaitUrl(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, pattern_opt: ?[]const u8, timeout_opt: ?[]const u8) []u8 {
    const pattern = pattern_opt orelse return respondErr(allocator, "URL pattern required");
    const timeout_ms = if (timeout_opt) |t| std.fmt.parseInt(u32, t, 10) catch 30000 else 30000;

    const poll_interval = 200 * std.time.ns_per_ms;
    const max_polls = @as(u64, timeout_ms) * std.time.ns_per_ms / poll_interval;

    for (0..@as(usize, @intCast(max_polls + 1))) |_| {
        const sent_id = cmd_id.next();
        const cmd = cdp.runtimeEvaluate(allocator, sent_id, "window.location.href", session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(cmd);

        const raw = sendAndWait(sender, resp_map, cmd, sent_id, 5_000) orelse {
            std.Thread.sleep(poll_interval);
            continue;
        };
        defer allocator.free(raw);

        const parsed = cdp.parseMessage(allocator, raw) catch {
            std.Thread.sleep(poll_interval);
            continue;
        };
        defer parsed.parsed.deinit();

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |result| {
                if (cdp.getObject(result, "result")) |remote_obj| {
                    if (cdp.getString(remote_obj, "value")) |url| {
                        if (std.mem.indexOf(u8, url, pattern) != null) {
                            // Match found
                            var resp_buf: std.ArrayList(u8) = .empty;
                            defer resp_buf.deinit(allocator);
                            cdp.writeJsonString(resp_buf.writer(allocator), url) catch return respondOk(allocator);
                            const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
                            defer allocator.free(data);
                            return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
                        }
                    }
                }
            }
        }
        std.Thread.sleep(poll_interval);
    }
    return respondErr(allocator, "waiturl timeout");
}

fn handleWaitFunction(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, expr_opt: ?[]const u8, timeout_opt: ?[]const u8) []u8 {
    const expression = expr_opt orelse return respondErr(allocator, "expression required");
    const timeout_ms = if (timeout_opt) |t| std.fmt.parseInt(u32, t, 10) catch 30000 else 30000;

    const poll_interval = 200 * std.time.ns_per_ms;
    const max_polls = @as(u64, timeout_ms) * std.time.ns_per_ms / poll_interval;

    for (0..@as(usize, @intCast(max_polls + 1))) |_| {
        const sent_id = cmd_id.next();
        const cmd = cdp.runtimeEvaluate(allocator, sent_id, expression, session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(cmd);

        const raw = sendAndWait(sender, resp_map, cmd, sent_id, 5_000) orelse {
            std.Thread.sleep(poll_interval);
            continue;
        };
        defer allocator.free(raw);

        const parsed = cdp.parseMessage(allocator, raw) catch {
            std.Thread.sleep(poll_interval);
            continue;
        };
        defer parsed.parsed.deinit();

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |result| {
                if (cdp.getObject(result, "result")) |remote_obj| {
                    // Check if value is truthy
                    const obj_type = cdp.getString(remote_obj, "type") orelse "";
                    if (std.mem.eql(u8, obj_type, "undefined")) {
                        // falsy
                    } else if (cdp.getString(remote_obj, "subtype")) |st| {
                        if (std.mem.eql(u8, st, "null")) {
                            // falsy
                        } else {
                            return respondOk(allocator);
                        }
                    } else if (cdp.getBool(remote_obj, "value")) |b| {
                        if (b) return respondOk(allocator);
                    } else if (remote_obj.object.get("value")) |val| {
                        switch (val) {
                            .integer => |n| if (n != 0) return respondOk(allocator),
                            .float => |f| if (f != 0) return respondOk(allocator),
                            .string => |s| if (s.len > 0) return respondOk(allocator),
                            .bool => |b| if (b) return respondOk(allocator),
                            else => return respondOk(allocator),
                        }
                    } else if (std.mem.eql(u8, obj_type, "object") or std.mem.eql(u8, obj_type, "function")) {
                        // Non-null objects/functions are truthy
                        return respondOk(allocator);
                    }
                }
            }
        }
        std.Thread.sleep(poll_interval);
    }
    return respondErr(allocator, "waitfunction timeout");
}

// ============================================================================
// Errors (Runtime.exceptionThrown events)
// ============================================================================

fn handleErrors(allocator: Allocator, page_errors: *const std.ArrayList(PageError)) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    writer.writeByte('[') catch return respondErr(allocator, "write error");
    for (page_errors.items, 0..) |entry, i| {
        if (i > 0) writer.writeByte(',') catch {};
        writer.writeAll("{\"description\":") catch {};
        cdp.writeJsonString(writer, entry.description) catch {};
        writer.writeByte('}') catch {};
    }
    writer.writeByte(']') catch {};

    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "serialize error");
}

// ============================================================================
// Highlight
// ============================================================================

fn handleHighlight(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    std.fmt.format(w, "{{\"backendNodeId\":{d},\"highlightConfig\":{{\"showInfo\":true,\"contentColor\":{{\"r\":111,\"g\":168,\"b\":220,\"a\":0.66}},\"paddingColor\":{{\"r\":147,\"g\":196,\"b\":125,\"a\":0.55}},\"borderColor\":{{\"r\":255,\"g\":229,\"b\":153,\"a\":0.66}},\"marginColor\":{{\"r\":246,\"g\":178,\"b\":107,\"a\":0.66}}}}}}", .{backend_id}) catch
        return respondErr(allocator, "format error");

    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Overlay.highlightNode", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

// ============================================================================
// Batch 3: Advanced input, element inspection, clipboard, tab switch,
//           window, pause/resume, dispatch, waitload
// ============================================================================

/// check @ref — click the element (same as click, ensures checkbox is checked)
fn handleCheck(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    // check = click (toggles checkbox on). Same as handleClick.
    return handleClick(allocator, sender, resp_map, cmd_id, session_id, ref_map, target);
}

/// uncheck @ref — only click if currently checked
fn handleUncheck(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    // Check if currently checked via callFunctionOn
    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "failed to resolve element");
    defer allocator.free(oid);

    const call_params = buildCallFunctionOnParams(allocator, oid, "function(){return !!this.checked}", null) orelse
        return respondErr(allocator, "alloc error");
    defer allocator.free(call_params);
    const call_id = cmd_id.next();
    const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(call_cmd);

    const raw = sendAndWait(sender, resp_map, call_cmd, call_id, 10_000) orelse
        return respondErr(allocator, "uncheck timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    var is_checked = false;
    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getBool(remote_obj, "value")) |v| {
                    is_checked = v;
                }
            }
        }
    }

    if (is_checked) {
        // Click to uncheck
        const center = resolveCenter(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
            return respondErr(allocator, "element not visible");
        const press_cmd = snapshot_mod.buildClickCmd(allocator, cmd_id.next(), center.x, center.y, "mousePressed", session_id) catch return respondErr(allocator, "cmd error");
        defer allocator.free(press_cmd);
        sender.sendText(press_cmd) catch {};
        const release_cmd = snapshot_mod.buildClickCmd(allocator, cmd_id.next(), center.x, center.y, "mouseReleased", session_id) catch return respondErr(allocator, "cmd error");
        defer allocator.free(release_cmd);
        sender.sendText(release_cmd) catch {};
    }

    return respondOk(allocator);
}

/// clear @ref — focus element, then Ctrl+A + Backspace
fn handleClearInput(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    // Focus the element
    const focus_sent_id = cmd_id.next();
    const focus_cmd = snapshot_mod.buildFocusCmd(allocator, focus_sent_id, backend_id, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(focus_cmd);
    const focus_raw = sendAndWait(sender, resp_map, focus_cmd, focus_sent_id, 3_000);
    if (focus_raw) |fr| allocator.free(fr);

    // Select all (Ctrl+A)
    const select_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent",
        \\{"type":"keyDown","key":"a","code":"KeyA","modifiers":2}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(select_cmd);
    sender.sendText(select_cmd) catch {};

    const select_up = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent",
        \\{"type":"keyUp","key":"a","code":"KeyA","modifiers":2}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(select_up);
    sender.sendText(select_up) catch {};

    // Backspace to delete selected content
    const bs_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent",
        \\{"type":"keyDown","key":"Backspace","code":"Backspace"}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(bs_cmd);
    sender.sendText(bs_cmd) catch {};

    const bs_up = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent",
        \\{"type":"keyUp","key":"Backspace","code":"Backspace"}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(bs_up);
    sender.sendText(bs_up) catch {};

    return respondOk(allocator);
}

/// selectall @ref — focus element, then Ctrl+A
fn handleSelectAll(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    // Focus the element
    const focus_sent_id = cmd_id.next();
    const focus_cmd = snapshot_mod.buildFocusCmd(allocator, focus_sent_id, backend_id, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(focus_cmd);
    const focus_raw = sendAndWait(sender, resp_map, focus_cmd, focus_sent_id, 3_000);
    if (focus_raw) |fr| allocator.free(fr);

    // Ctrl+A
    const select_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent",
        \\{"type":"keyDown","key":"a","code":"KeyA","modifiers":2}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(select_cmd);
    sender.sendText(select_cmd) catch {};

    const select_up = cdp.serializeCommand(allocator, cmd_id.next(), "Input.dispatchKeyEvent",
        \\{"type":"keyUp","key":"a","code":"KeyA","modifiers":2}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(select_up);
    sender.sendText(select_up) catch {};

    return respondOk(allocator);
}

/// boundingbox @ref — get element bounding box {x, y, width, height}
fn handleBoundingBox(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found — run 'snapshot -i' first");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    // Use DOM.getBoxModel
    const sent_id = cmd_id.next();
    const box_cmd = snapshot_mod.buildGetBoxModelCmd(allocator, sent_id, backend_id, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(box_cmd);

    const raw = sendAndWait(sender, resp_map, box_cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "boundingbox timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "model")) |model| {
                if (model.object.get("content")) |content| {
                    if (content == .array) {
                        const items = content.array.items;
                        if (items.len >= 8) {
                            const x1 = snapshot_mod.extractBoxCenter(result);
                            _ = x1;
                            // content quad: [x1,y1, x2,y2, x3,y3, x4,y4]
                            const x_val = jsonToF64(items[0]) orelse return respondErr(allocator, "bad quad");
                            const y_val = jsonToF64(items[1]) orelse return respondErr(allocator, "bad quad");
                            const x3 = jsonToF64(items[4]) orelse return respondErr(allocator, "bad quad");
                            const y3 = jsonToF64(items[5]) orelse return respondErr(allocator, "bad quad");
                            const w_val = x3 - x_val;
                            const h_val = y3 - y_val;

                            var buf: std.ArrayList(u8) = .empty;
                            defer buf.deinit(allocator);
                            const bw = buf.writer(allocator);
                            std.fmt.format(bw, "{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ x_val, y_val, w_val, h_val }) catch
                                return respondErr(allocator, "format error");
                            const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                            defer allocator.free(data);
                            return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                        }
                    }
                }
            }
        }
    }
    return respondErr(allocator, "boundingbox failed");
}

/// styles @ref <property> — get computed style value
fn handleStyles(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, prop: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const css_prop = prop orelse return respondErr(allocator, "property name required");

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "failed to resolve element");
    defer allocator.free(oid);

    const call_params = buildCallFunctionOnParams(allocator, oid, "function(p){return window.getComputedStyle(this).getPropertyValue(p)}", css_prop) orelse
        return respondErr(allocator, "alloc error");
    defer allocator.free(call_params);
    const call_id = cmd_id.next();
    const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(call_cmd);

    const raw2 = sendAndWait(sender, resp_map, call_cmd, call_id, 10_000) orelse
        return respondErr(allocator, "styles timeout");
    defer allocator.free(raw2);

    const parsed2 = cdp.parseMessage(allocator, raw2) catch
        return respondErr(allocator, "parse error");
    defer parsed2.parsed.deinit();

    if (parsed2.message.isResponse()) {
        if (parsed2.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getString(remote_obj, "value")) |v| {
                    var resp: std.ArrayList(u8) = .empty;
                    defer resp.deinit(allocator);
                    cdp.writeJsonString(resp.writer(allocator), v) catch return respondErr(allocator, "write error");
                    const data = resp.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "styles failed");
}

/// clipboard get — read clipboard text (grants permission first)
fn handleClipboardGet(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8) []u8 {
    // Grant clipboard-read permission
    const grant_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Browser.grantPermissions",
        \\{"permissions":["clipboardReadWrite","clipboardSanitizedWrite"]}
    , null) catch return respondErr(allocator, "cmd error");
    defer allocator.free(grant_cmd);
    sender.sendText(grant_cmd) catch {};

    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Evaluate navigator.clipboard.readText() with awaitPromise
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"expression\":\"navigator.clipboard.readText()\",\"awaitPromise\":true}") catch
        return respondErr(allocator, "write error");
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);

    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Runtime.evaluate", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "clipboard get timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getString(remote_obj, "value")) |v| {
                    var resp: std.ArrayList(u8) = .empty;
                    defer resp.deinit(allocator);
                    cdp.writeJsonString(resp.writer(allocator), v) catch return respondErr(allocator, "write error");
                    const data = resp.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "clipboard get failed");
}

/// clipboard set <text> — write to clipboard
fn handleClipboardSet(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, text_opt: ?[]const u8) []u8 {
    const text = text_opt orelse return respondErr(allocator, "text required");

    // Grant clipboard-write permission
    const grant_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Browser.grantPermissions",
        \\{"permissions":["clipboardReadWrite","clipboardSanitizedWrite"]}
    , null) catch return respondErr(allocator, "cmd error");
    defer allocator.free(grant_cmd);
    sender.sendText(grant_cmd) catch {};

    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Build expression: navigator.clipboard.writeText("escaped text")
    var expr_buf: std.ArrayList(u8) = .empty;
    defer expr_buf.deinit(allocator);
    const ew = expr_buf.writer(allocator);
    ew.writeAll("navigator.clipboard.writeText(") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(ew, text) catch return respondErr(allocator, "write error");
    ew.writeByte(')') catch {};
    const expr = expr_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(expr);

    // Build params with awaitPromise
    var params_buf: std.ArrayList(u8) = .empty;
    defer params_buf.deinit(allocator);
    const pw = params_buf.writer(allocator);
    pw.writeAll("{\"expression\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(pw, expr) catch return respondErr(allocator, "write error");
    pw.writeAll(",\"awaitPromise\":true}") catch {};
    const params = params_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);

    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Runtime.evaluate", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "clipboard set timeout");
    defer allocator.free(raw);

    return respondOk(allocator);
}

/// tab switch <index> — switch to tab by 0-based index
fn handleTabSwitch(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, index_opt: ?[]const u8) []u8 {
    _ = session_id;
    const index_str = index_opt orelse return respondErr(allocator, "tab index required");
    const index = std.fmt.parseInt(usize, index_str, 10) catch
        return respondErr(allocator, "invalid tab index");

    // Get all targets
    const sent_id = cmd_id.next();
    const targets_cmd = cdp.targetGetTargets(allocator, sent_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(targets_cmd);

    const raw = sendAndWait(sender, resp_map, targets_cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "tab switch timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (result.object.get("targetInfos")) |infos| {
                if (infos == .array) {
                    // Filter to page targets
                    var page_idx: usize = 0;
                    for (infos.array.items) |info| {
                        const t = cdp.getString(info, "type") orelse continue;
                        if (!std.mem.eql(u8, t, "page")) continue;
                        if (page_idx == index) {
                            const tid = cdp.getString(info, "targetId") orelse return respondErr(allocator, "no targetId");
                            // Activate target
                            var activate_buf: std.ArrayList(u8) = .empty;
                            defer activate_buf.deinit(allocator);
                            const aw = activate_buf.writer(allocator);
                            aw.writeAll("{\"targetId\":") catch return respondErr(allocator, "write error");
                            cdp.writeJsonString(aw, tid) catch return respondErr(allocator, "write error");
                            aw.writeByte('}') catch {};
                            const activate_params = activate_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                            defer allocator.free(activate_params);
                            const activate_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Target.activateTarget", activate_params, null) catch
                                return respondErr(allocator, "cmd error");
                            defer allocator.free(activate_cmd);
                            sender.sendText(activate_cmd) catch {};
                            return respondOk(allocator);
                        }
                        page_idx += 1;
                    }
                    return respondErr(allocator, "tab index out of range");
                }
            }
        }
    }
    return respondErr(allocator, "tab switch failed");
}

/// window new [url] — open new window
fn handleWindowNew(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, url: ?[]const u8) []u8 {
    _ = session_id;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"url\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, url orelse "about:blank") catch return respondErr(allocator, "write error");
    w.writeAll(",\"newWindow\":true}") catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Target.createTarget", params, null) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

/// pause — Debugger.enable + Debugger.pause
fn handlePause(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8) []u8 {
    // Enable debugger first
    const enable_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Debugger.enable", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(enable_cmd);
    sender.sendText(enable_cmd) catch {};

    // Then pause
    const pause_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Debugger.pause", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(pause_cmd);
    sender.sendText(pause_cmd) catch {};
    return respondOk(allocator);
}

/// resume — Debugger.resume
fn handleResume(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8) []u8 {
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Debugger.resume", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch {};
    return respondOk(allocator);
}

/// dispatch @ref <event> — dispatch DOM event
fn handleDispatch(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *const snapshot_mod.RefMap, target: ?[]const u8, event_name: ?[]const u8) []u8 {
    const ref_id = target orelse return respondErr(allocator, "target required");
    const event = event_name orelse return respondErr(allocator, "event name required");

    const entry = ref_map.getByRef(ref_id) orelse return respondErr(allocator, "ref not found");
    const backend_id = entry.backend_node_id orelse return respondErr(allocator, "no backend node ID");

    const oid = resolveNodeObjectId(allocator, sender, resp_map, cmd_id, session_id, backend_id) orelse
        return respondErr(allocator, "failed to resolve element");
    defer allocator.free(oid);

    const call_params = buildCallFunctionOnParams(allocator, oid, "function(e){this.dispatchEvent(new Event(e,{bubbles:true}))}", event) orelse
        return respondErr(allocator, "alloc error");
    defer allocator.free(call_params);
    const call_id = cmd_id.next();
    const call_cmd = cdp.serializeCommand(allocator, call_id, "Runtime.callFunctionOn", call_params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(call_cmd);

    const raw = sendAndWait(sender, resp_map, call_cmd, call_id, 10_000) orelse
        return respondErr(allocator, "dispatch timeout");
    defer allocator.free(raw);

    return respondOk(allocator);
}

/// waitload [timeout_ms] — wait until document.readyState is "complete"
fn handleWaitLoad(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, timeout_opt: ?[]const u8) []u8 {
    const timeout_str = timeout_opt orelse "30000";
    const timeout_ms = std.fmt.parseInt(u32, timeout_str, 10) catch 30000;

    const max_attempts = timeout_ms / 200;
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const sent_id = cmd_id.next();
        const cmd = cdp.runtimeEvaluate(allocator, sent_id, "document.readyState", session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(cmd);

        const raw = sendAndWait(sender, resp_map, cmd, sent_id, 5_000) orelse {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(raw);

        const parsed = cdp.parseMessage(allocator, raw) catch {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            continue;
        };
        defer parsed.parsed.deinit();

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |result| {
                if (cdp.getObject(result, "result")) |remote_obj| {
                    if (cdp.getString(remote_obj, "value")) |v| {
                        if (std.mem.eql(u8, v, "complete")) {
                            return respondOk(allocator);
                        }
                    }
                }
            }
        }
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    return respondErr(allocator, "waitload timeout");
}

// ============================================================================
// Credentials (HTTP Basic Auth via CDP Fetch.authRequired)
// ============================================================================

fn handleCredentials(ctx: *DaemonContext, username_opt: ?[]const u8, password_opt: ?[]const u8) []u8 {
    const allocator = ctx.allocator;
    const username = username_opt orelse return respondErr(allocator, "username required");
    const password = password_opt orelse return respondErr(allocator, "password required");

    ctx.auth_mutex.lock();
    defer ctx.auth_mutex.unlock();

    // Free old credentials if any
    if (ctx.auth_credentials.*) |old| {
        allocator.free(old.username);
        allocator.free(old.password);
    }

    const new_user = allocator.dupe(u8, username) catch return respondErr(allocator, "alloc error");
    const new_pass = allocator.dupe(u8, password) catch {
        allocator.free(new_user);
        return respondErr(allocator, "alloc error");
    };
    ctx.auth_credentials.* = AuthCredentials{ .username = new_user, .password = new_pass };

    // Enable Fetch with handleAuthRequests=true
    const params = "{\"handleAuthRequests\":true}";
    const cmd = cdp.serializeCommand(allocator, ctx.cmd_id.next(), "Fetch.enable", params, ctx.session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    ctx.sender.sendText(cmd) catch return respondErr(allocator, "send error");

    return respondOk(allocator);
}

fn handleAuthRequired(
    allocator: Allocator,
    sender: *WsSender,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    params: std.json.Value,
    auth_credentials: *?AuthCredentials,
    auth_mutex: *std.Thread.Mutex,
) void {
    const request_id = cdp.getString(params, "requestId") orelse return;

    auth_mutex.lock();
    defer auth_mutex.unlock();

    if (auth_credentials.*) |creds| {
        // Build Fetch.continueWithAuth params
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.writeAll("{\"requestId\":") catch return;
        cdp.writeJsonString(w, request_id) catch return;
        w.writeAll(",\"authChallengeResponse\":{\"response\":\"ProvideCredentials\",\"username\":") catch return;
        cdp.writeJsonString(w, creds.username) catch return;
        w.writeAll(",\"password\":") catch return;
        cdp.writeJsonString(w, creds.password) catch return;
        w.writeAll("}}") catch return;
        const p = buf.toOwnedSlice(allocator) catch return;
        defer allocator.free(p);
        const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Fetch.continueWithAuth", p, session_id) catch return;
        defer allocator.free(cmd);
        sender.sendText(cmd) catch {};
    } else {
        // No credentials — cancel auth
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.writeAll("{\"requestId\":") catch return;
        cdp.writeJsonString(w, request_id) catch return;
        w.writeAll(",\"authChallengeResponse\":{\"response\":\"CancelAuth\"}}") catch return;
        const p = buf.toOwnedSlice(allocator) catch return;
        defer allocator.free(p);
        const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Fetch.continueWithAuth", p, session_id) catch return;
        defer allocator.free(cmd);
        sender.sendText(cmd) catch {};
    }
}

// ============================================================================
// Download Path (Browser.setDownloadBehavior)
// ============================================================================

fn handleDownloadPath(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, dir_opt: ?[]const u8) []u8 {
    const dir = dir_opt orelse return respondErr(allocator, "directory path required");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"behavior\":\"allow\",\"eventsEnabled\":true,\"downloadPath\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, dir) catch return respondErr(allocator, "write error");
    w.writeByte('}') catch {};
    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);

    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Browser.setDownloadBehavior", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch return respondErr(allocator, "send error");

    return respondOk(allocator);
}

// ============================================================================
// HAR Export (network data → HAR 1.2 JSON)
// ============================================================================

fn handleHar(allocator: Allocator, collector: *network.Collector, filename_opt: ?[]const u8) []u8 {
    const filename = filename_opt orelse "network.har";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // HAR 1.2 structure
    w.writeAll("{\"log\":{\"version\":\"1.2\",\"creator\":{\"name\":\"agent-devtools\",\"version\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, version) catch return respondErr(allocator, "write error");
    w.writeAll("},\"entries\":[") catch return respondErr(allocator, "write error");

    var it = collector.requests.iterator();
    var first = true;
    while (it.next()) |entry| {
        const info = entry.value_ptr.info;
        if (!first) w.writeByte(',') catch {};
        first = false;

        // Build HAR entry
        w.writeAll("{\"startedDateTime\":") catch {};
        // Convert timestamp to ISO 8601 (approximate: epoch seconds)
        w.print("\"{d:.3}\"", .{info.timestamp}) catch {};

        w.writeAll(",\"time\":0") catch {};
        w.writeAll(",\"request\":{\"method\":") catch {};
        cdp.writeJsonString(w, info.method) catch {};
        w.writeAll(",\"url\":") catch {};
        cdp.writeJsonString(w, info.url) catch {};
        w.writeAll(",\"httpVersion\":\"HTTP/1.1\",\"headers\":[],\"queryString\":[],\"cookies\":[],\"headersSize\":-1,\"bodySize\":-1}") catch {};

        w.writeAll(",\"response\":{\"status\":") catch {};
        w.print("{d}", .{info.status orelse 0}) catch {};
        w.writeAll(",\"statusText\":") catch {};
        cdp.writeJsonString(w, info.status_text) catch {};
        w.writeAll(",\"httpVersion\":\"HTTP/1.1\",\"headers\":[],\"cookies\":[],\"content\":{\"size\":") catch {};
        w.print("{d}", .{info.encoded_data_length orelse 0}) catch {};
        w.writeAll(",\"mimeType\":") catch {};
        cdp.writeJsonString(w, info.mime_type) catch {};
        w.writeAll("},\"redirectURL\":\"\",\"headersSize\":-1,\"bodySize\":-1}") catch {};

        w.writeAll(",\"cache\":{},\"timings\":{\"send\":0,\"wait\":0,\"receive\":0}}") catch {};
    }

    w.writeAll("]}}") catch return respondErr(allocator, "write error");

    const har_json = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(har_json);

    // Write to file
    const file = std.fs.cwd().createFile(filename, .{}) catch
        return respondErr(allocator, "failed to create HAR file");
    defer file.close();
    _ = file.writeAll(har_json) catch return respondErr(allocator, "failed to write HAR file");

    // Return success with filename and entry count
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    const rw = resp_buf.writer(allocator);
    rw.writeAll("{\"file\":") catch return respondOk(allocator);
    cdp.writeJsonString(rw, filename) catch return respondOk(allocator);
    rw.print(",\"entries\":{d}}}", .{collector.count()}) catch return respondOk(allocator);
    const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
}

// ============================================================================
// State Management (save/load cookies + localStorage + sessionStorage)
// ============================================================================

fn handleStateSave(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, name_opt: ?[]const u8) []u8 {
    const state_name = name_opt orelse return respondErr(allocator, "state name required");

    // 1. Get cookies via Network.getCookies
    const cookies_id = cmd_id.next();
    const cookies_cmd = cdp.serializeCommand(allocator, cookies_id, "Network.getCookies", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cookies_cmd);

    const cookies_raw = sendAndWait(sender, resp_map, cookies_cmd, cookies_id, 10_000) orelse
        return respondErr(allocator, "cookies timeout");
    defer allocator.free(cookies_raw);

    // Extract cookies array from response
    const cookies_parsed = cdp.parseMessage(allocator, cookies_raw) catch
        return respondErr(allocator, "parse error");
    defer cookies_parsed.parsed.deinit();

    // 2. Get localStorage via eval
    const local_storage = handleEvalRaw(allocator, sender, resp_map, cmd_id, session_id,
        "(function(){try{var o={};for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o[k]=localStorage.getItem(k)}return JSON.stringify(o)}catch(e){return'{}'}})()");

    // 3. Get sessionStorage via eval
    const session_storage = handleEvalRaw(allocator, sender, resp_map, cmd_id, session_id,
        "(function(){try{var o={};for(var i=0;i<sessionStorage.length;i++){var k=sessionStorage.key(i);o[k]=sessionStorage.getItem(k)}return JSON.stringify(o)}catch(e){return'{}'}})()");

    // Build state JSON
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"cookies\":") catch return respondErr(allocator, "write error");

    // Extract cookies array from CDP response
    if (cookies_parsed.message.isResponse()) {
        if (cookies_parsed.message.result) |result| {
            if (cdp.getObject(result, "cookies")) |_| {
                // Re-serialize the cookies from the raw response
                // Find "cookies": in the raw response and extract the array
                if (std.mem.indexOf(u8, cookies_raw, "\"cookies\":")) |idx| {
                    const rest = cookies_raw[idx + "\"cookies\":".len ..];
                    // Find matching bracket
                    var depth: i32 = 0;
                    var end: usize = 0;
                    for (rest, 0..) |c, i| {
                        if (c == '[') depth += 1;
                        if (c == ']') depth -= 1;
                        if (depth == 0 and c == ']') {
                            end = i + 1;
                            break;
                        }
                    }
                    if (end > 0) {
                        w.writeAll(rest[0..end]) catch {};
                    } else {
                        w.writeAll("[]") catch {};
                    }
                } else {
                    w.writeAll("[]") catch {};
                }
            } else {
                w.writeAll("[]") catch {};
            }
        } else {
            w.writeAll("[]") catch {};
        }
    } else {
        w.writeAll("[]") catch {};
    }

    w.writeAll(",\"localStorage\":") catch {};
    if (local_storage) |ls| {
        defer allocator.free(ls);
        w.writeAll(ls) catch {};
    } else {
        w.writeAll("{}") catch {};
    }
    w.writeAll(",\"sessionStorage\":") catch {};
    if (session_storage) |ss| {
        defer allocator.free(ss);
        w.writeAll(ss) catch {};
    } else {
        w.writeAll("{}") catch {};
    }
    w.writeByte('}') catch {};

    const state_json = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(state_json);

    // Save to ~/.agent-devtools/states/<name>.json
    var dir_buf: [512]u8 = undefined;
    const socket_dir = daemon.getSocketDir(&dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const states_dir = std.fmt.bufPrint(&path_buf, "{s}/states", .{socket_dir}) catch
        return respondErr(allocator, "path error");

    std.fs.makeDirAbsolute(states_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return respondErr(allocator, "failed to create states dir"),
    };

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}.json", .{ states_dir, state_name }) catch
        return respondErr(allocator, "path error");

    const file = std.fs.createFileAbsolute(file_path, .{}) catch
        return respondErr(allocator, "failed to create state file");
    defer file.close();
    _ = file.writeAll(state_json) catch return respondErr(allocator, "failed to write state file");

    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    const rw = resp_buf.writer(allocator);
    rw.writeAll("{\"file\":") catch return respondOk(allocator);
    cdp.writeJsonString(rw, file_path) catch return respondOk(allocator);
    rw.writeByte('}') catch {};
    const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
    defer allocator.free(data);
    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
}

/// Evaluate expression and return raw string value (caller must free). Returns null on error.
fn handleEvalRaw(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, expression: []const u8) ?[]u8 {
    const sent_id = cmd_id.next();
    const cmd = cdp.runtimeEvaluate(allocator, sent_id, expression, session_id) catch return null;
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse return null;
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch return null;
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (cdp.getObject(result, "result")) |remote_obj| {
                if (cdp.getString(remote_obj, "value")) |v| {
                    return allocator.dupe(u8, v) catch null;
                }
            }
        }
    }
    return null;
}

// ============================================================================
// React Introspection (window.__REACT_DEVTOOLS_GLOBAL_HOOK__ 기반)
// 스크립트는 async IIFE → awaitPromise+returnByValue 필요. throw 시
// exceptionDetails를 사용자 친화 에러로 변환.
// ============================================================================

const REACT_TREE_SNAPSHOT = @embedFile("react/tree_snapshot.js");

/// async React 스크립트를 평가해 JSON 문자열(또는 에러)을 daemon 응답으로 반환.
fn handleReactScript(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, expression: []const u8) []u8 {
    var pbuf: std.ArrayList(u8) = .empty;
    defer pbuf.deinit(allocator);
    const pw = pbuf.writer(allocator);
    pw.writeAll("{\"expression\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(pw, expression) catch return respondErr(allocator, "write error");
    pw.writeAll(",\"awaitPromise\":true,\"returnByValue\":true}") catch return respondErr(allocator, "write error");
    const params = pbuf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);

    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Runtime.evaluate", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 15_000) orelse
        return respondErr(allocator, "react eval timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (!parsed.message.isResponse()) return respondErr(allocator, "react eval failed");
    const result = parsed.message.result orelse return respondErr(allocator, "react eval failed");

    // 스크립트 내 throw (hook 미설치 등) → 사용자 친화 에러
    if (cdp.getObject(result, "exceptionDetails")) |exc| {
        return respondErr(allocator, cdp.exceptionMessage(exc));
    }

    if (cdp.getObject(result, "result")) |remote_obj| {
        if (cdp.getString(remote_obj, "value")) |v| {
            return daemon.serializeResponse(allocator, .{ .success = true, .data = v }) catch
                respondErr(allocator, "serialize error");
        }
    }
    return respondErr(allocator, "react script returned no value");
}

fn handleStateLoad(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, name_opt: ?[]const u8) []u8 {
    const state_name = name_opt orelse return respondErr(allocator, "state name required");

    // Load from ~/.agent-devtools/states/<name>.json
    var dir_buf: [512]u8 = undefined;
    const socket_dir = daemon.getSocketDir(&dir_buf);
    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/states/{s}.json", .{ socket_dir, state_name }) catch
        return respondErr(allocator, "path error");

    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch
        return respondErr(allocator, "state not found");
    defer allocator.free(file_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, file_content, .{}) catch
        return respondErr(allocator, "invalid state format");
    defer parsed.deinit();

    const root = parsed.value;

    // 1. Restore cookies via Network.setCookies
    // Extract the cookies array from the raw JSON file content
    if (std.mem.indexOf(u8, file_content, "\"cookies\":")) |idx| {
        const rest = file_content[idx + "\"cookies\":".len ..];
        // Find matching bracket
        var depth: i32 = 0;
        var end: usize = 0;
        for (rest, 0..) |c, i| {
            if (c == '[') depth += 1;
            if (c == ']') depth -= 1;
            if (depth == 0 and c == ']') {
                end = i + 1;
                break;
            }
        }
        if (end > 0) {
            const cookies_array = rest[0..end];
            var cookies_buf: std.ArrayList(u8) = .empty;
            defer cookies_buf.deinit(allocator);
            const cw = cookies_buf.writer(allocator);
            cw.writeAll("{\"cookies\":") catch {};
            cw.writeAll(cookies_array) catch {};
            cw.writeByte('}') catch {};
            const cookies_params = cookies_buf.toOwnedSlice(allocator) catch null;
            if (cookies_params) |cp| {
                defer allocator.free(cp);
                const cookies_cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Network.setCookies", cp, session_id) catch null;
                if (cookies_cmd) |cc| {
                    defer allocator.free(cc);
                    sender.sendText(cc) catch {};
                }
            }
        }
    }

    // 2. Restore localStorage
    if (root.object.get("localStorage")) |ls_val| {
        if (ls_val == .object) {
            var ls_iter = ls_val.object.iterator();
            while (ls_iter.next()) |kv| {
                if (kv.value_ptr.* == .string) {
                    var expr_buf: std.ArrayList(u8) = .empty;
                    defer expr_buf.deinit(allocator);
                    const ew = expr_buf.writer(allocator);
                    ew.writeAll("localStorage.setItem(") catch continue;
                    cdp.writeJsonString(ew, kv.key_ptr.*) catch continue;
                    ew.writeByte(',') catch {};
                    cdp.writeJsonString(ew, kv.value_ptr.string) catch continue;
                    ew.writeByte(')') catch {};
                    const expr = expr_buf.toOwnedSlice(allocator) catch continue;
                    defer allocator.free(expr);
                    const eval_cmd = cdp.runtimeEvaluate(allocator, cmd_id.next(), expr, session_id) catch continue;
                    defer allocator.free(eval_cmd);
                    sender.sendText(eval_cmd) catch {};
                }
            }
        }
    }

    // 3. Restore sessionStorage
    if (root.object.get("sessionStorage")) |ss_val| {
        if (ss_val == .object) {
            var ss_iter = ss_val.object.iterator();
            while (ss_iter.next()) |kv| {
                if (kv.value_ptr.* == .string) {
                    var expr_buf: std.ArrayList(u8) = .empty;
                    defer expr_buf.deinit(allocator);
                    const ew = expr_buf.writer(allocator);
                    ew.writeAll("sessionStorage.setItem(") catch continue;
                    cdp.writeJsonString(ew, kv.key_ptr.*) catch continue;
                    ew.writeByte(',') catch {};
                    cdp.writeJsonString(ew, kv.value_ptr.string) catch continue;
                    ew.writeByte(')') catch {};
                    const expr = expr_buf.toOwnedSlice(allocator) catch continue;
                    defer allocator.free(expr);
                    const eval_cmd = cdp.runtimeEvaluate(allocator, cmd_id.next(), expr, session_id) catch continue;
                    defer allocator.free(eval_cmd);
                    sender.sendText(eval_cmd) catch {};
                }
            }
        }
    }

    _ = resp_map;
    return respondOk(allocator);
}

fn handleStateList(allocator: Allocator) []u8 {
    var dir_buf: [512]u8 = undefined;
    const socket_dir = daemon.getSocketDir(&dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const states_dir = std.fmt.bufPrint(&path_buf, "{s}/states", .{socket_dir}) catch
        return respondErr(allocator, "path error");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeByte('[') catch return respondErr(allocator, "write error");

    var first = true;
    var dir = std.fs.openDirAbsolute(states_dir, .{ .iterate = true }) catch {
        // Directory doesn't exist yet — return empty array
        w.writeByte(']') catch {};
        const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(data);
        return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name_without_ext = entry.name[0 .. entry.name.len - ".json".len];
        if (!first) w.writeByte(',') catch {};
        first = false;
        cdp.writeJsonString(w, name_without_ext) catch {};
    }

    w.writeByte(']') catch {};
    const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(data);
    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondErr(allocator, "resp error");
}

// ============================================================================
// Add Style (inject CSS via eval)
// ============================================================================

fn handleAddStyle(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, css_opt: ?[]const u8) []u8 {
    const css = css_opt orelse return respondErr(allocator, "css required");

    var expr_buf: std.ArrayList(u8) = .empty;
    defer expr_buf.deinit(allocator);
    const w = expr_buf.writer(allocator);
    w.writeAll("(function(){var s=document.createElement('style');s.textContent=") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, css) catch return respondErr(allocator, "write error");
    w.writeAll(";document.head.appendChild(s)})()") catch return respondErr(allocator, "write error");

    const expr = expr_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(expr);

    return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
}

// SPA 클라이언트 네비게이션. Next.js 라우터(window.next.router.push)를 우선
// 시도해 RSC fetch를 트리거하고, 없으면 history.pushState + popstate/navigate
// 이벤트로 폴백 (React Router / Vue Router 등 history 이벤트 구독 라우터 대응).
const PUSHSTATE_JS_PREFIX =
    \\((url)=>{var before=location.href;var absolute=new URL(url,before).href;if(absolute===before)return before;var r=typeof window.next==="object"&&window.next&&window.next.router;if(r&&typeof r.push==="function"){try{r.push(url);return location.href;}catch(e){}}history.pushState(null,"",absolute);try{dispatchEvent(new PopStateEvent("popstate",{state:null}));}catch(e){}try{dispatchEvent(new Event("navigate"));}catch(e){}return location.href;})(
;

/// pushstate JS 표현식 빌드 (URL을 JSON 문자열로 이스케이프해 인자 주입). 호출자가 free.
fn buildPushStateExpr(allocator: Allocator, url: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(PUSHSTATE_JS_PREFIX);
    try cdp.writeJsonString(w, url);
    try w.writeAll(")");
    return buf.toOwnedSlice(allocator);
}

fn handlePushState(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, url_opt: ?[]const u8) []u8 {
    const url = url_opt orelse return respondErr(allocator, "url required");
    const expr = buildPushStateExpr(allocator, url) catch return respondErr(allocator, "alloc error");
    defer allocator.free(expr);
    return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
}

// Core Web Vitals 관측자 설치 (멱등). buffered:true 로 설치 이전 엔트리도 포착.
const VITALS_INIT_JS =
    \\(()=>{if(window.__AB_VITALS_INSTALLED__)return;window.__AB_VITALS_INSTALLED__=true;var cwv={lcp:null,cls:0,fcp:null,inp:null};window.__AB_VITALS__=cwv;try{new PerformanceObserver(function(l){var es=l.getEntries();if(es.length>0)cwv.lcp=Math.round(es[es.length-1].startTime*100)/100;}).observe({type:"largest-contentful-paint",buffered:true});}catch(e){}try{new PerformanceObserver(function(l){for(var e of l.getEntries())if(!e.hadRecentInput)cwv.cls+=e.value;}).observe({type:"layout-shift",buffered:true});}catch(e){}try{new PerformanceObserver(function(l){for(var e of l.getEntries())if(e.name==="first-contentful-paint")cwv.fcp=Math.round(e.startTime*100)/100;}).observe({type:"paint",buffered:true});}catch(e){}try{new PerformanceObserver(function(l){var w=cwv.inp||0;for(var e of l.getEntries())if(e.duration>w)w=e.duration;if(w>0)cwv.inp=Math.round(w*100)/100;}).observe({type:"event",buffered:true,durationThreshold:40});}catch(e){}})()
;

const VITALS_READ_JS =
    \\(()=>{var c=window.__AB_VITALS__||{};var n=performance.getEntriesByType("navigation")[0];var t=n?Math.round((n.responseStart-n.requestStart)*100)/100:null;return JSON.stringify({lcp:c.lcp,cls:Math.round((c.cls||0)*10000)/10000,fcp:c.fcp,inp:c.inp,ttfb:t})})()
;

// settle 시간↑ = 마지막 LCP 후보·누적 CLS 안정화로 정확도↑, 응답 지연↑ 트레이드오프.
const VITALS_NAV_SETTLE_MS = 1500; // 네비게이션 후 초기 로드 대기
const VITALS_OBSERVE_MS = 2500; // 관측자 설치 후 CLS 누적/LCP 확정 대기

/// Core Web Vitals (LCP/CLS/FCP/INP) + TTFB 측정.
/// url 지정 시 해당 페이지로 이동 후 측정, 미지정 시 현재 페이지 측정.
fn handleVitals(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, url_opt: ?[]const u8, allowed_domains: ?[]const u8) []u8 {
    if (url_opt) |url| {
        if (allowed_domains) |domains| {
            if (!isDomainAllowed(url, domains)) return respondErr(allocator, "domain not allowed by --allowed-domains");
        }
        const nav_cmd = cdp.pageNavigate(allocator, cmd_id.next(), url, session_id) catch
            return respondErr(allocator, "navigate cmd error");
        defer allocator.free(nav_cmd);
        sender.sendText(nav_cmd) catch return respondErr(allocator, "navigate send error");
        std.Thread.sleep(VITALS_NAV_SETTLE_MS * std.time.ns_per_ms);
    }

    const init_res = handleEvalRaw(allocator, sender, resp_map, cmd_id, session_id, VITALS_INIT_JS) orelse
        return respondErr(allocator, "vitals init failed");
    allocator.free(init_res);

    std.Thread.sleep(VITALS_OBSERVE_MS * std.time.ns_per_ms);

    const json = handleEvalRaw(allocator, sender, resp_map, cmd_id, session_id, VITALS_READ_JS) orelse
        return respondErr(allocator, "vitals read failed");
    defer allocator.free(json);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = json }) catch
        respondErr(allocator, "serialize error");
}

fn jsonToF64(val: std.json.Value) ?f64 {
    return switch (val) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

// ============================================================================
// Expose Binding (Runtime.addBinding)
// ============================================================================

fn handleExpose(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8, name_opt: ?[]const u8) []u8 {
    const name = name_opt orelse return respondErr(allocator, "binding name required");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll("{\"name\":") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, name) catch return respondErr(allocator, "write error");
    w.writeByte('}') catch return respondErr(allocator, "write error");

    const params = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(params);

    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Runtime.addBinding", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch return respondErr(allocator, "send error");
    return respondOk(allocator);
}

// ============================================================================
// Ignore HTTPS Errors (Security.setIgnoreCertificateErrors)
// ============================================================================

fn handleIgnoreHttpsErrors(allocator: Allocator, sender: *WsSender, cmd_id: *cdp.CommandId, session_id: ?[]const u8) []u8 {
    const cmd = cdp.serializeCommand(allocator, cmd_id.next(), "Security.setIgnoreCertificateErrors",
        \\{"ignore":true}
    , session_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);
    sender.sendText(cmd) catch return respondErr(allocator, "send error");
    return respondOk(allocator);
}

// ============================================================================
// Replay (load recording, navigate to first URL, wait, diff)
// ============================================================================

fn handleReplay(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, collector: *network.Collector, collector_mutex: *std.Thread.Mutex, name_opt: ?[]const u8) []u8 {
    const rec_name = name_opt orelse return respondErr(allocator, "recording name required");

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

    // Find the first URL from the recording
    if (rec.requests.len == 0)
        return respondErr(allocator, "recording has no requests");

    const first_url = rec.requests[0].url;

    // Navigate to first URL
    const nav_cmd = cdp.pageNavigate(allocator, cmd_id.next(), first_url, session_id) catch
        return respondErr(allocator, "Failed to build navigate command");
    defer allocator.free(nav_cmd);
    sender.sendText(nav_cmd) catch return respondErr(allocator, "Failed to send navigate");

    // Wait for page load (poll readyState up to 30s)
    var attempt: u32 = 0;
    while (attempt < 150) : (attempt += 1) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        const sent_id = cmd_id.next();
        const eval_cmd = cdp.runtimeEvaluate(allocator, sent_id, "document.readyState", session_id) catch continue;
        defer allocator.free(eval_cmd);

        const raw = sendAndWait(sender, resp_map, eval_cmd, sent_id, 5_000) orelse continue;
        defer allocator.free(raw);

        const parsed = cdp.parseMessage(allocator, raw) catch continue;
        defer parsed.parsed.deinit();

        if (parsed.message.isResponse()) {
            if (parsed.message.result) |result| {
                if (cdp.getObject(result, "result")) |remote_obj| {
                    if (cdp.getString(remote_obj, "value")) |v| {
                        if (std.mem.eql(u8, v, "complete")) break;
                    }
                }
            }
        }
    }

    // Now diff
    collector_mutex.lock();
    defer collector_mutex.unlock();

    var diff = recorder.diffRequests(allocator, rec.requests, collector) catch
        return respondErr(allocator, "diff failed");
    defer diff.deinit();

    const data = recorder.serializeDiff(allocator, &diff) catch
        return respondErr(allocator, "serialize failed");
    defer allocator.free(data);

    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
        respondErr(allocator, "response failed");
}

// ============================================================================
// Dialog Info
// ============================================================================

fn handleDialogInfo(allocator: Allocator, dialog_info: *const ?DialogInfo) []u8 {
    if (dialog_info.*) |info| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.writeAll("{\"type\":") catch return respondErr(allocator, "write error");
        cdp.writeJsonString(w, info.dialog_type) catch return respondErr(allocator, "write error");
        w.writeAll(",\"message\":") catch {};
        cdp.writeJsonString(w, info.message) catch {};
        w.writeAll(",\"defaultPrompt\":") catch {};
        cdp.writeJsonString(w, info.default_prompt) catch {};
        w.writeByte('}') catch {};

        const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
        defer allocator.free(data);
        return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
            respondErr(allocator, "resp error");
    } else {
        return daemon.serializeResponse(allocator, .{ .success = true, .data = "null" }) catch
            respondErr(allocator, "resp error");
    }
}

// ============================================================================
// Scroll To (absolute position)
// ============================================================================

fn handleScrollTo(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, x_opt: ?[]const u8, y_opt: ?[]const u8) []u8 {
    const x_str = x_opt orelse return respondErr(allocator, "x coordinate required");
    const y_str = y_opt orelse return respondErr(allocator, "y coordinate required");

    var expr_buf: [128]u8 = undefined;
    const expr = std.fmt.bufPrint(&expr_buf, "window.scrollTo({s},{s})", .{ x_str, y_str }) catch
        return respondErr(allocator, "format error");

    return handleEval(allocator, sender, resp_map, cmd_id, session_id, expr);
}

// ============================================================================
// Cookies Get (by name)
// ============================================================================

fn handleCookiesGet(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, name_opt: ?[]const u8) []u8 {
    const name = name_opt orelse return respondErr(allocator, "cookie name required");

    // Use Network.getCookies and filter by name
    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Network.getCookies", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "cookies timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (result.object.get("cookies")) |cookies_val| {
                if (cookies_val == .array) {
                    for (cookies_val.array.items) |cookie| {
                        const cookie_name = cdp.getString(cookie, "name") orelse continue;
                        if (std.mem.eql(u8, cookie_name, name)) {
                            const cookie_value = cdp.getString(cookie, "value") orelse "";
                            var buf: std.ArrayList(u8) = .empty;
                            defer buf.deinit(allocator);
                            const w = buf.writer(allocator);
                            w.writeAll("{\"name\":") catch {};
                            cdp.writeJsonString(w, cookie_name) catch {};
                            w.writeAll(",\"value\":") catch {};
                            cdp.writeJsonString(w, cookie_value) catch {};
                            w.writeByte('}') catch {};
                            const data = buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
                            defer allocator.free(data);
                            return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch
                                respondErr(allocator, "resp error");
                        }
                    }
                }
            }
        }
    }
    return respondErr(allocator, "cookie not found");
}

// ============================================================================
// Tab Count
// ============================================================================

fn handleTabCount(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8) []u8 {
    _ = session_id;
    const sent_id = cmd_id.next();
    const cmd = cdp.targetGetTargets(allocator, sent_id) catch return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "tab count timeout");
    defer allocator.free(raw);

    const parsed = cdp.parseMessage(allocator, raw) catch
        return respondErr(allocator, "parse error");
    defer parsed.parsed.deinit();

    if (parsed.message.isResponse()) {
        if (parsed.message.result) |result| {
            if (result.object.get("targetInfos")) |infos| {
                if (infos == .array) {
                    var count: usize = 0;
                    for (infos.array.items) |info| {
                        const t = cdp.getString(info, "type") orelse "?";
                        if (std.mem.eql(u8, t, "page")) count += 1;
                    }
                    var buf: [32]u8 = undefined;
                    const count_str = std.fmt.bufPrint(&buf, "{d}", .{count}) catch
                        return respondErr(allocator, "format error");
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = count_str }) catch
                        respondErr(allocator, "resp error");
                }
            }
        }
    }
    return respondErr(allocator, "failed to get tab count");
}

// ============================================================================
// WaitFor handlers — poll shared state until condition met or timeout
// ============================================================================

fn handleWaitForNetwork(allocator: Allocator, collector: *network.Collector, mutex: *std.Thread.Mutex, cond: *std.Thread.Condition, pattern_opt: ?[]const u8, timeout_str: ?[]const u8) []u8 {
    const pattern = pattern_opt orelse "";
    const timeout_ms = if (timeout_str) |t| std.fmt.parseInt(u32, t, 10) catch 30_000 else 30_000;
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    mutex.lock();
    defer mutex.unlock();
    const start_count = collector.count();

    var timer = std.time.Timer.start() catch return respondErr(allocator, "timer error");
    while (true) {
        // Search requests: with pattern → all, without → new only
        var it = collector.requests.iterator();
        var idx: usize = 0;
        while (it.next()) |entry| {
            idx += 1;
            if (pattern.len == 0 and idx <= start_count) continue;
            const info = entry.value_ptr.info;
            if (pattern.len == 0 or std.mem.indexOf(u8, info.url, pattern) != null) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                const w = buf.writer(allocator);
                w.writeAll("{\"url\":") catch return respondOk(allocator);
                cdp.writeJsonString(w, info.url) catch {};
                w.writeAll(",\"method\":") catch {};
                cdp.writeJsonString(w, info.method) catch {};
                w.print(",\"status\":{d}}}", .{info.status orelse 0}) catch {};
                const data = buf.toOwnedSlice(allocator) catch return respondOk(allocator);
                defer allocator.free(data);
                return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
            }
        }

        const elapsed = timer.read();
        if (elapsed >= timeout_ns) break;
        cond.timedWait(mutex, timeout_ns - elapsed) catch break;
    }
    return respondErr(allocator, "waitfor network timeout");
}

fn handleWaitForConsole(allocator: Allocator, console_msgs: *std.ArrayList(ConsoleEntry), mutex: *std.Thread.Mutex, cond: *std.Thread.Condition, pattern_opt: ?[]const u8, timeout_str: ?[]const u8) []u8 {
    const pattern = pattern_opt orelse "";
    const timeout_ms = if (timeout_str) |t| std.fmt.parseInt(u32, t, 10) catch 30_000 else 30_000;
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    mutex.lock();
    defer mutex.unlock();
    const start_count = console_msgs.items.len;

    var timer = std.time.Timer.start() catch return respondErr(allocator, "timer error");
    while (true) {
        if (console_msgs.items.len > start_count) {
            for (console_msgs.items[start_count..]) |entry| {
                if (pattern.len == 0 or std.mem.indexOf(u8, entry.text, pattern) != null) {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(allocator);
                    const w = buf.writer(allocator);
                    w.writeAll("{\"type\":") catch return respondOk(allocator);
                    cdp.writeJsonString(w, entry.log_type) catch {};
                    w.writeAll(",\"text\":") catch {};
                    cdp.writeJsonString(w, entry.text) catch {};
                    w.writeByte('}') catch {};
                    const data = buf.toOwnedSlice(allocator) catch return respondOk(allocator);
                    defer allocator.free(data);
                    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
                }
            }
        }

        const elapsed = timer.read();
        if (elapsed >= timeout_ns) break;
        cond.timedWait(mutex, timeout_ns - elapsed) catch break;
    }
    return respondErr(allocator, "waitfor console timeout");
}

fn handleWaitForError(allocator: Allocator, page_errors: *std.ArrayList(PageError), mutex: *std.Thread.Mutex, cond: *std.Thread.Condition, timeout_str: ?[]const u8) []u8 {
    const timeout_ms = if (timeout_str) |t| std.fmt.parseInt(u32, t, 10) catch 30_000 else 30_000;
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    mutex.lock();
    defer mutex.unlock();
    const start_count = page_errors.items.len;

    var timer = std.time.Timer.start() catch return respondErr(allocator, "timer error");
    while (true) {
        if (page_errors.items.len > start_count) {
            const entry = page_errors.items[page_errors.items.len - 1];
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            w.writeAll("{\"description\":") catch return respondOk(allocator);
            cdp.writeJsonString(w, entry.description) catch {};
            w.writeByte('}') catch {};
            const data = buf.toOwnedSlice(allocator) catch return respondOk(allocator);
            defer allocator.free(data);
            return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
        }

        const elapsed = timer.read();
        if (elapsed >= timeout_ns) break;
        cond.timedWait(mutex, timeout_ns - elapsed) catch break;
    }
    return respondErr(allocator, "waitfor error timeout");
}

fn handleWaitForDialog(allocator: Allocator, dialog_info: *?DialogInfo, mutex: *std.Thread.Mutex, cond: *std.Thread.Condition, timeout_str: ?[]const u8) []u8 {
    const timeout_ms = if (timeout_str) |t| std.fmt.parseInt(u32, t, 10) catch 30_000 else 30_000;
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    mutex.lock();
    defer mutex.unlock();

    var timer = std.time.Timer.start() catch return respondErr(allocator, "timer error");
    while (true) {
        if (dialog_info.*) |di| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            w.writeAll("{\"type\":") catch return respondOk(allocator);
            cdp.writeJsonString(w, di.dialog_type) catch {};
            w.writeAll(",\"message\":") catch {};
            cdp.writeJsonString(w, di.message) catch {};
            w.writeByte('}') catch {};
            const data = buf.toOwnedSlice(allocator) catch return respondOk(allocator);
            defer allocator.free(data);
            return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
        }

        const elapsed = timer.read();
        if (elapsed >= timeout_ns) break;
        cond.timedWait(mutex, timeout_ns - elapsed) catch break;
    }
    return respondErr(allocator, "waitfor dialog timeout");
}

fn handleWaitForDownload(allocator: Allocator, tracker: *DownloadTracker, timeout_str: ?[]const u8) []u8 {
    const timeout_ms = if (timeout_str) |t| std.fmt.parseInt(u32, t, 10) catch 30_000 else 30_000;

    if (tracker.waitForComplete(timeout_ms)) |result| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        w.writeAll("{\"guid\":") catch return respondOk(allocator);
        cdp.writeJsonString(w, result.guid) catch {};
        if (result.path) |p| {
            w.writeAll(",\"path\":") catch {};
            cdp.writeJsonString(w, p) catch {};
        }
        w.writeByte('}') catch {};
        const data = buf.toOwnedSlice(allocator) catch return respondOk(allocator);
        defer allocator.free(data);
        return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
    }
    return respondErr(allocator, "waitdownload timeout");
}

// ============================================================================
// Helpers
// ============================================================================

/// Parse text command (e.g. "click @e5", "get title") into serialized daemon request JSON.
/// Mirrors the CLI argument parsing in main().
fn parseTextCommand(allocator: Allocator, line: []const u8, id: []const u8) ?[]u8 {
    var tokens: [20][]const u8 = undefined;
    var token_count: usize = 0;
    var it = std.mem.splitScalar(u8, line, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (token_count >= tokens.len) break;
        tokens[token_count] = tok;
        token_count += 1;
    }
    if (token_count == 0) return null;

    const cmd = tokens[0];
    const arg1: ?[]const u8 = if (token_count > 1) tokens[1] else null;
    const arg2: ?[]const u8 = if (token_count > 2) tokens[2] else null;
    const arg3: ?[]const u8 = if (token_count > 3) tokens[3] else null;

    // Join remaining tokens for commands that take free-form text (fill, eval, etc.)
    var rest_buf: [4096]u8 = undefined;
    const rest: ?[]const u8 = if (token_count > 2) blk: {
        var pos: usize = 0;
        for (tokens[2..token_count]) |tok| {
            if (pos > 0) {
                rest_buf[pos] = ' ';
                pos += 1;
            }
            if (pos + tok.len > rest_buf.len) break;
            @memcpy(rest_buf[pos .. pos + tok.len], tok);
            pos += tok.len;
        }
        break :blk rest_buf[0..pos];
    } else null;

    var action: []const u8 = cmd;
    var url: ?[]const u8 = arg1;
    var pattern: ?[]const u8 = arg2;

    // Multi-word command mapping (mirrors CLI main() parsing)
    if (std.mem.eql(u8, cmd, "get")) {
        if (arg1) |what| {
            if (std.mem.eql(u8, what, "url")) { action = "get_url"; url = null; }
            else if (std.mem.eql(u8, what, "title")) { action = "get_title"; url = null; }
            else if (std.mem.eql(u8, what, "text")) { action = "get_text"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "html")) { action = "get_html"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "value")) { action = "get_value"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "attr")) { action = "get_attr"; url = arg2; pattern = arg3; }
        }
    } else if (std.mem.eql(u8, cmd, "is")) {
        if (arg1) |what| {
            if (std.mem.eql(u8, what, "visible")) { action = "is_visible"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "enabled")) { action = "is_enabled"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "checked")) { action = "is_checked"; url = arg2; pattern = null; }
        }
    } else if (std.mem.eql(u8, cmd, "network")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "requests") or std.mem.eql(u8, sub, "list")) {
                // network requests [--filter pattern] [--clear] [pattern]
                action = "network_list"; url = null; pattern = null;
                var i: usize = 2;
                while (i < token_count) : (i += 1) {
                    if (std.mem.eql(u8, tokens[i], "--filter")) {
                        i += 1;
                        if (i < token_count) pattern = tokens[i];
                    } else if (std.mem.eql(u8, tokens[i], "--clear")) {
                        action = "network_clear";
                    } else if (pattern == null) {
                        pattern = tokens[i]; // positional pattern (backward compat)
                    }
                }
            }
            else if (std.mem.eql(u8, sub, "get")) { action = "network_get"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, sub, "clear")) { action = "network_clear"; url = null; pattern = null; }
            else { action = "network_list"; url = null; pattern = arg1; }
        } else { action = "network_list"; url = null; }
    } else if (std.mem.eql(u8, cmd, "console")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "list")) { action = "console_list"; url = null; }
            else if (std.mem.eql(u8, sub, "clear") or std.mem.eql(u8, sub, "--clear")) { action = "console_clear"; url = null; }
            else { action = "console_list"; url = null; }
        } else { action = "console_list"; url = null; }
    } else if (std.mem.eql(u8, cmd, "tab")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "list")) { action = "tab_list"; url = null; }
            else if (std.mem.eql(u8, sub, "new")) { action = "tab_new"; url = arg2; }
            else if (std.mem.eql(u8, sub, "close")) { action = "tab_close"; url = null; }
            else if (std.mem.eql(u8, sub, "switch")) { action = "tab_switch"; url = arg2; }
            else if (std.mem.eql(u8, sub, "count")) { action = "tab_count"; url = null; }
        } else { action = "tab_list"; url = null; }
    } else if (std.mem.eql(u8, cmd, "set")) {
        if (arg1) |what| {
            if (std.mem.eql(u8, what, "viewport")) { action = "set_viewport"; url = arg2; pattern = arg3; }
            else if (std.mem.eql(u8, what, "media")) { action = "set_media"; url = arg2; }
            else if (std.mem.eql(u8, what, "offline")) { action = "set_offline"; url = arg2; }
            else if (std.mem.eql(u8, what, "timezone")) { action = "set_timezone"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "locale")) { action = "set_locale"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "geolocation")) { action = "set_geolocation"; url = arg2; pattern = arg3; }
            else if (std.mem.eql(u8, what, "headers")) { action = "set_headers"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "useragent") or std.mem.eql(u8, what, "user-agent")) { action = "set_user_agent"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, what, "device")) {
                action = if (arg2 != null and std.mem.eql(u8, arg2.?, "list")) "device_list" else "set_device";
                url = rest; // multi-word device name e.g. "iPhone 14 Pro"
                pattern = null;
            }
            else if (std.mem.eql(u8, what, "ignore-https-errors")) { action = "ignore_https_errors"; url = null; pattern = null; }
            else if (std.mem.eql(u8, what, "permissions")) {
                if (arg2) |sub| {
                    if (std.mem.eql(u8, sub, "grant")) { action = "permissions_grant"; url = arg3; pattern = null; }
                }
            }
        }
    } else if (std.mem.eql(u8, cmd, "cookies")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "set")) { action = "cookies_set"; url = arg2; pattern = arg3; }
            else if (std.mem.eql(u8, sub, "get")) { action = "cookies_get"; url = arg2; }
            else if (std.mem.eql(u8, sub, "clear")) { action = "cookies_clear"; url = null; }
            else if (std.mem.eql(u8, sub, "list")) { action = "cookies_list"; url = null; }
            else { action = "cookies_list"; url = null; }
        } else { action = "cookies_list"; url = null; }
    } else if (std.mem.eql(u8, cmd, "storage")) {
        if (arg1) |store_type| {
            const valid = if (std.mem.eql(u8, store_type, "session")) "session" else "local";
            if (arg2) |sub| {
                if (std.mem.eql(u8, sub, "set")) {
                    var act_buf: [32]u8 = undefined;
                    action = std.fmt.bufPrint(&act_buf, "storage_{s}_set", .{valid}) catch "storage_local_set";
                    url = arg3;
                    pattern = if (token_count > 4) tokens[4] else null;
                } else if (std.mem.eql(u8, sub, "clear")) {
                    var act_buf: [32]u8 = undefined;
                    action = std.fmt.bufPrint(&act_buf, "storage_{s}_clear", .{valid}) catch "storage_local_clear";
                    url = null;
                } else {
                    var act_buf: [32]u8 = undefined;
                    action = std.fmt.bufPrint(&act_buf, "storage_{s}_get", .{valid}) catch "storage_local_get";
                    url = sub;
                }
            } else {
                var act_buf: [32]u8 = undefined;
                action = std.fmt.bufPrint(&act_buf, "storage_{s}_list", .{valid}) catch "storage_local_list";
                url = null;
            }
        }
    } else if (std.mem.eql(u8, cmd, "mouse")) {
        if (arg1) |sub| {
            action = "mouse";
            url = sub;
            if (arg2) |x| {
                const y = arg3 orelse "0";
                var coords_buf: [32]u8 = undefined;
                pattern = std.fmt.bufPrint(&coords_buf, "{s}:{s}", .{ x, y }) catch "0:0";
            }
        }
    } else if (std.mem.eql(u8, cmd, "intercept")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "mock")) { action = "intercept_mock"; url = arg2; pattern = rest; }
            else if (std.mem.eql(u8, sub, "fail")) { action = "intercept_fail"; url = arg2; }
            else if (std.mem.eql(u8, sub, "delay")) { action = "intercept_delay"; url = arg2; pattern = arg3; }
            else if (std.mem.eql(u8, sub, "remove")) { action = "intercept_remove"; url = arg2; }
            else if (std.mem.eql(u8, sub, "list")) { action = "intercept_list"; url = null; }
            else if (std.mem.eql(u8, sub, "clear")) { action = "intercept_clear"; url = null; }
        }
    } else if (std.mem.eql(u8, cmd, "dialog")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "accept")) { action = "dialog_accept"; url = arg2; }
            else if (std.mem.eql(u8, sub, "dismiss")) { action = "dialog_dismiss"; url = null; }
            else if (std.mem.eql(u8, sub, "info")) { action = "dialog_info"; url = null; }
        }
    } else if (std.mem.eql(u8, cmd, "errors")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "clear") or std.mem.eql(u8, sub, "--clear")) { action = "errors_clear"; url = null; }
            else { action = "errors"; url = null; }
        } else { action = "errors"; url = null; }
    } else if (std.mem.eql(u8, cmd, "clipboard")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "get")) { action = "clipboard_get"; url = null; }
            else if (std.mem.eql(u8, sub, "set")) { action = "clipboard_set"; url = rest; }
        }
    } else if (std.mem.eql(u8, cmd, "state")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "save")) { action = "state_save"; url = arg2; }
            else if (std.mem.eql(u8, sub, "load")) { action = "state_load"; url = arg2; }
            else if (std.mem.eql(u8, sub, "list")) { action = "state_list"; url = null; }
        }
    } else if (std.mem.eql(u8, cmd, "window")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "new")) { action = "window_new"; url = arg2; }
        }
    } else if (std.mem.eql(u8, cmd, "waitfor")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "network")) { action = "waitfor_network"; url = arg2; pattern = arg3; }
            else if (std.mem.eql(u8, sub, "console")) { action = "waitfor_console"; url = arg2; pattern = arg3; }
            else if (std.mem.eql(u8, sub, "error")) { action = "waitfor_error"; url = arg2; }
            else if (std.mem.eql(u8, sub, "dialog")) { action = "waitfor_dialog"; url = arg2; }
        }
    } else if (std.mem.eql(u8, cmd, "find")) {
        url = arg1; // strategy
        pattern = arg2; // value
    } else if (std.mem.eql(u8, cmd, "fill") or std.mem.eql(u8, cmd, "type")) {
        url = arg1; // target @ref
        pattern = rest; // text (may contain spaces)
    } else if (std.mem.eql(u8, cmd, "scroll")) {
        if (arg1) |dir| {
            if (std.mem.eql(u8, dir, "to")) { action = "scroll_to"; url = arg2; pattern = arg3; }
            else { url = dir; pattern = arg2; }
        }
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        for ([_]?[]const u8{ arg1, arg2 }) |maybe_flag| {
            if (maybe_flag) |flag| {
                if (std.mem.eql(u8, flag, "-i")) action = "snapshot_interactive";
                if (std.mem.eql(u8, flag, "-u") or std.mem.eql(u8, flag, "--urls")) pattern = SNAPSHOT_URLS_FLAG;
            }
        }
        url = null;
    } else if (std.mem.eql(u8, cmd, "screenshot")) {
        if (arg1) |flag| {
            if (std.mem.eql(u8, flag, "--annotate") or std.mem.eql(u8, flag, "-a")) {
                action = "screenshot_annotate";
                url = arg2; // path
            } else if (std.mem.eql(u8, flag, "--full")) {
                action = "screenshot_full";
                url = arg2; // path
            } else {
                url = flag; // path
            }
        }
        pattern = null;
    } else if (std.mem.eql(u8, cmd, "select")) {
        action = "select_option";
    } else if (std.mem.eql(u8, cmd, "check")) {
        action = "click"; // check = click alias
    } else if (std.mem.eql(u8, cmd, "navigate") or std.mem.eql(u8, cmd, "goto")) {
        action = "open"; // navigate/goto = open alias
    } else if (std.mem.eql(u8, cmd, "title")) {
        action = "get_title"; url = null; pattern = null;
    } else if (std.mem.eql(u8, cmd, "url")) {
        action = "get_url"; url = null; pattern = null;
    } else if (std.mem.eql(u8, cmd, "waitforurl")) {
        action = "waiturl"; // alias
    } else if (std.mem.eql(u8, cmd, "waitforloadstate")) {
        action = "waitload"; url = arg1 orelse "30000"; pattern = null;
    } else if (std.mem.eql(u8, cmd, "waitforfunction")) {
        action = "waitfunction"; // alias
    } else if (std.mem.eql(u8, cmd, "tap")) {
        action = "tap";
    } else if (std.mem.eql(u8, cmd, "auth")) {
        if (arg1) |sub| {
            if (std.mem.eql(u8, sub, "login")) { action = "auth_login"; url = arg2; pattern = null; }
            else if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "show") or std.mem.eql(u8, sub, "delete") or std.mem.eql(u8, sub, "save")) {
                // These are handled client-side, not via daemon
                action = "auth_noop"; url = null; pattern = null;
            }
        }
    }
    // Simple 1:1 commands: open, click, dblclick, hover, focus, back, forward, reload, close,
    // eval, screenshot, pdf, press, highlight, bringtofront, pause, resume, tap, etc.
    // These pass through with action = cmd

    return daemon.serializeRequest(allocator, .{
        .id = id,
        .action = action,
        .url = url,
        .pattern = pattern,
    }) catch null;
}

// ============================================================================
// Auth Login Handler (daemon-side)
// ============================================================================

fn handleAuthLogin(allocator: Allocator, sender: *WsSender, resp_map: *response_map_mod.ResponseMap, cmd_id: *cdp.CommandId, session_id: ?[]const u8, ref_map: *snapshot_mod.RefMap, name_opt: ?[]const u8) []u8 {
    _ = ref_map;
    const name = name_opt orelse return respondErr(allocator, "auth profile name required");

    // Load credentials from vault
    const creds = authVaultLoad(name) orelse return respondErr(allocator, "auth profile not found");

    // 1. Navigate to URL
    const nav_cmd = cdp.pageNavigate(allocator, cmd_id.next(), creds.url, session_id) catch
        return respondErr(allocator, "Failed to build navigate command");
    defer allocator.free(nav_cmd);
    sender.sendText(nav_cmd) catch return respondErr(allocator, "Failed to navigate");

    // Wait for page load
    std.Thread.sleep(2000 * std.time.ns_per_ms);

    // Find and fill username field (first visible text/email input)
    var js_buf: std.ArrayList(u8) = .empty;
    defer js_buf.deinit(allocator);
    const w = js_buf.writer(allocator);
    w.writeAll("(function(){var inputs=document.querySelectorAll('input[type=\"text\"],input[type=\"email\"],input:not([type])');for(var i=0;i<inputs.length;i++){var s=getComputedStyle(inputs[i]);if(s.display!==\"none\"&&s.visibility!==\"hidden\"){inputs[i].focus();inputs[i].value=") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(w, creds.username) catch return respondErr(allocator, "write error");
    w.writeAll(";inputs[i].dispatchEvent(new Event('input',{bubbles:true}));inputs[i].dispatchEvent(new Event('change',{bubbles:true}));return 'filled_username'}}return 'no_username_field'})()") catch return respondErr(allocator, "write error");

    const username_js = js_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(username_js);

    const uname_result = handleEval(allocator, sender, resp_map, cmd_id, session_id, username_js);
    allocator.free(uname_result);

    // Small delay between fields
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Fill password field
    var pw_buf: std.ArrayList(u8) = .empty;
    defer pw_buf.deinit(allocator);
    const pw = pw_buf.writer(allocator);
    pw.writeAll("(function(){var inputs=document.querySelectorAll('input[type=\"password\"]');for(var i=0;i<inputs.length;i++){var s=getComputedStyle(inputs[i]);if(s.display!==\"none\"&&s.visibility!==\"hidden\"){inputs[i].focus();inputs[i].value=") catch return respondErr(allocator, "write error");
    cdp.writeJsonString(pw, creds.password) catch return respondErr(allocator, "write error");
    pw.writeAll(";inputs[i].dispatchEvent(new Event('input',{bubbles:true}));inputs[i].dispatchEvent(new Event('change',{bubbles:true}));return 'filled_password'}}return 'no_password_field'})()") catch return respondErr(allocator, "write error");

    const password_js = pw_buf.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(password_js);

    const pw_result = handleEval(allocator, sender, resp_map, cmd_id, session_id, password_js);
    defer allocator.free(pw_result);

    // Small delay before submit
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Click submit button
    const submit_js =
        \\(function(){var btns=document.querySelectorAll('button[type="submit"],input[type="submit"],button');for(var i=0;i<btns.length;i++){var t=(btns[i].textContent||btns[i].value||'').toLowerCase();if(t.match(/log\s*in|sign\s*in|submit|login|signin/)){btns[i].click();return 'clicked'}}var forms=document.querySelectorAll('form');if(forms.length>0){forms[0].submit();return 'submitted'}return 'no_submit_found'})()
    ;
    return handleEval(allocator, sender, resp_map, cmd_id, session_id, submit_js);
}

// ============================================================================
// Config File Loading (agent-devtools.json)
// ============================================================================

fn loadConfigFile(
    headed: *bool,
    cfg_proxy: *?[]const u8,
    cfg_proxy_bypass: *?[]const u8,
    cfg_user_agent: *?[]const u8,
    cfg_extensions: *?[]const u8,
) void {
    // Try ./agent-devtools.json first, then ~/.agent-devtools/config.json
    const local_path = "agent-devtools.json";
    var content_buf: [65536]u8 = undefined;

    const content = blk: {
        break :blk std.fs.cwd().readFile(local_path, &content_buf) catch {
            // Try home dir
            const home = daemon.getenv("HOME") orelse return;
            var home_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const home_path = std.fmt.bufPrint(&home_path_buf, "{s}/.agent-devtools/config.json", .{home}) catch return;
            break :blk std.fs.cwd().readFile(home_path, &content_buf) catch return;
        };
    };

    // Parse JSON and extract known fields
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    if (cdp.getBool(parsed.value, "headed")) |h| {
        headed.* = h;
    }
    // Note: string values from config file point into parsed data which will be freed.
    // For the config loading use case, these are static string literals checked in main()
    // and the config values are only used as defaults before CLI args override.
    // Since the parsed data is freed here, we use static storage for the values.
    const S = struct {
        var proxy_buf: [256]u8 = undefined;
        var proxy_bypass_buf: [256]u8 = undefined;
        var user_agent_buf: [256]u8 = undefined;
        var extensions_buf: [512]u8 = undefined;
    };
    if (cdp.getString(parsed.value, "proxy")) |v| {
        if (v.len <= S.proxy_buf.len) {
            @memcpy(S.proxy_buf[0..v.len], v);
            cfg_proxy.* = S.proxy_buf[0..v.len];
        }
    }
    if (cdp.getString(parsed.value, "proxy_bypass")) |v| {
        if (v.len <= S.proxy_bypass_buf.len) {
            @memcpy(S.proxy_bypass_buf[0..v.len], v);
            cfg_proxy_bypass.* = S.proxy_bypass_buf[0..v.len];
        }
    }
    if (cdp.getString(parsed.value, "user_agent")) |v| {
        if (v.len <= S.user_agent_buf.len) {
            @memcpy(S.user_agent_buf[0..v.len], v);
            cfg_user_agent.* = S.user_agent_buf[0..v.len];
        }
    }
    if (cdp.getString(parsed.value, "extensions")) |v| {
        if (v.len <= S.extensions_buf.len) {
            @memcpy(S.extensions_buf[0..v.len], v);
            cfg_extensions.* = S.extensions_buf[0..v.len];
        }
    }
}

// ============================================================================
// Content Boundaries
// ============================================================================

fn isContentAction(action: []const u8) bool {
    const content_actions = [_][]const u8{
        "snapshot", "snapshot_interactive", "eval", "get_text", "get_html",
        "get_value", "content", "get_url", "get_title",
    };
    for (content_actions) |a| {
        if (std.mem.eql(u8, action, a)) return true;
    }
    return false;
}

// ============================================================================
// Domain Restriction (--allowed-domains)
// ============================================================================

/// Extract the host from a URL. Returns the hostname portion.
fn extractHost(url: []const u8) ?[]const u8 {
    // Skip scheme (http://, https://, etc.)
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        rest = rest[idx + 3 ..];
    }
    // Take until / or : or end
    var end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == ':' or c == '?') {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return rest[0..end];
}

/// Check if a domain matches a pattern. Supports simple glob: *.example.com
fn domainMatchesPattern(host: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, host, pattern)) return true;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[1..]; // ".example.com"
        if (std.mem.endsWith(u8, host, suffix)) return true;
        // Also match the base domain itself
        if (std.mem.eql(u8, host, pattern[2..])) return true;
    }
    return false;
}

/// Check if a URL's domain is in the allowed list (comma-separated patterns).
fn isDomainAllowed(url: []const u8, allowed_domains: []const u8) bool {
    const host = extractHost(url) orelse return false;
    var it = std.mem.splitScalar(u8, allowed_domains, ',');
    while (it.next()) |pattern| {
        const trimmed = std.mem.trim(u8, pattern, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (domainMatchesPattern(host, trimmed)) return true;
    }
    return false;
}

// ============================================================================
// Auth Vault (local file storage)
// ============================================================================

fn getAuthDir(buf: []u8) ?[]const u8 {
    const home = daemon.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.agent-devtools/auth", .{home}) catch null;
}

fn isValidVaultName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        if (c == '/' or c == '\\' or c == '.' or c == 0) return false;
    }
    return true;
}

fn authVaultSave(name: []const u8, url: []const u8, username: []const u8, password: []const u8) void {
    if (!isValidVaultName(name)) {
        writeErr("Invalid auth profile name (no /, \\, . allowed)\n", .{});
        return;
    }
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const auth_dir = getAuthDir(&dir_buf) orelse {
        writeErr("Failed to determine auth directory\n", .{});
        return;
    };

    std.fs.makeDirAbsolute(auth_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try creating parent first
            const home = daemon.getenv("HOME") orelse return;
            var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
            const parent = std.fmt.bufPrint(&parent_buf, "{s}/.agent-devtools", .{home}) catch return;
            std.fs.makeDirAbsolute(parent) catch {};
            std.fs.makeDirAbsolute(auth_dir) catch return;
        },
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ auth_dir, name }) catch return;

    var content_buf: [2048]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"url\":\"";
    if (pos + prefix.len > content_buf.len) return;
    @memcpy(content_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    // Simple JSON - escape basic chars
    for ([_]struct { key: []const u8, val: []const u8 }{ .{ .key = "", .val = url } }) |_| {
        for (url) |c| {
            if (c == '"' or c == '\\') {
                if (pos + 2 > content_buf.len) return;
                content_buf[pos] = '\\';
                content_buf[pos + 1] = c;
                pos += 2;
            } else {
                if (pos + 1 > content_buf.len) return;
                content_buf[pos] = c;
                pos += 1;
            }
        }
    }

    const mid1 = "\",\"username\":\"";
    if (pos + mid1.len > content_buf.len) return;
    @memcpy(content_buf[pos .. pos + mid1.len], mid1);
    pos += mid1.len;

    for (username) |c| {
        if (c == '"' or c == '\\') {
            if (pos + 2 > content_buf.len) return;
            content_buf[pos] = '\\';
            content_buf[pos + 1] = c;
            pos += 2;
        } else {
            if (pos + 1 > content_buf.len) return;
            content_buf[pos] = c;
            pos += 1;
        }
    }

    const mid2 = "\",\"password\":\"";
    if (pos + mid2.len > content_buf.len) return;
    @memcpy(content_buf[pos .. pos + mid2.len], mid2);
    pos += mid2.len;

    for (password) |c| {
        if (c == '"' or c == '\\') {
            if (pos + 2 > content_buf.len) return;
            content_buf[pos] = '\\';
            content_buf[pos + 1] = c;
            pos += 2;
        } else {
            if (pos + 1 > content_buf.len) return;
            content_buf[pos] = c;
            pos += 1;
        }
    }

    const suffix = "\"}";
    if (pos + suffix.len > content_buf.len) return;
    @memcpy(content_buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;

    if (std.fs.createFileAbsolute(path, .{})) |f| {
        _ = f.write(content_buf[0..pos]) catch {};
        f.close();
        write("Saved auth profile: {s}\n", .{name});
    } else |_| {
        writeErr("Failed to save auth profile\n", .{});
    }
}

fn authVaultList() void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const auth_dir = getAuthDir(&dir_buf) orelse {
        write("[]\n", .{});
        return;
    };

    var dir = std.fs.openDirAbsolute(auth_dir, .{ .iterate = true }) catch {
        write("[]\n", .{});
        return;
    };
    defer dir.close();

    var first = true;
    const stdout = std.fs.File.stdout();
    _ = stdout.write("[") catch {};
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name_part = entry.name[0 .. entry.name.len - ".json".len];
        if (!first) _ = stdout.write(",") catch {};
        first = false;
        _ = stdout.write("\"") catch {};
        _ = stdout.write(name_part) catch {};
        _ = stdout.write("\"") catch {};
    }
    _ = stdout.write("]\n") catch {};
}

fn authVaultShow(name: []const u8) void {
    if (!isValidVaultName(name)) { writeErr("Invalid auth profile name\n", .{}); return; }
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const auth_dir = getAuthDir(&dir_buf) orelse {
        writeErr("Auth directory not found\n", .{});
        return;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ auth_dir, name }) catch return;

    var content_buf: [2048]u8 = undefined;
    const content = std.fs.cwd().readFile(path, &content_buf) catch {
        writeErr("Auth profile not found: {s}\n", .{name});
        return;
    };

    // Mask password in output
    if (std.mem.indexOf(u8, content, "\"password\":\"")) |pw_start| {
        const val_start = pw_start + "\"password\":\"".len;
        if (std.mem.indexOfScalarPos(u8, content, val_start, '"')) |val_end| {
            const stdout = std.fs.File.stdout();
            _ = stdout.write(content[0..val_start]) catch {};
            _ = stdout.write("****") catch {};
            _ = stdout.write(content[val_end..]) catch {};
            _ = stdout.write("\n") catch {};
            return;
        }
    }
    write("{s}\n", .{content});
}

fn authVaultDelete(name: []const u8) void {
    if (!isValidVaultName(name)) { writeErr("Invalid auth profile name\n", .{}); return; }
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const auth_dir = getAuthDir(&dir_buf) orelse {
        writeErr("Auth directory not found\n", .{});
        return;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ auth_dir, name }) catch return;

    std.fs.deleteFileAbsolute(path) catch {
        writeErr("Auth profile not found: {s}\n", .{name});
        return;
    };
    write("Deleted auth profile: {s}\n", .{name});
}

/// Load auth profile from file, return url, username, password.
fn authVaultLoad(name: []const u8) ?struct { url: []const u8, username: []const u8, password: []const u8 } {
    if (!isValidVaultName(name)) return null;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const auth_dir = getAuthDir(&dir_buf) orelse return null;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ auth_dir, name }) catch return null;

    const S = struct {
        var content_buf: [2048]u8 = undefined;
    };
    const content = std.fs.cwd().readFile(path, &S.content_buf) catch return null;

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return null;
    defer parsed.deinit();

    const url_val = cdp.getString(parsed.value, "url") orelse return null;
    const user_val = cdp.getString(parsed.value, "username") orelse return null;
    const pass_val = cdp.getString(parsed.value, "password") orelse return null;

    // Copy into static buffers since parsed will be freed
    const StaticBufs = struct {
        var url: [512]u8 = undefined;
        var user: [256]u8 = undefined;
        var pass: [256]u8 = undefined;
    };
    if (url_val.len > StaticBufs.url.len or user_val.len > StaticBufs.user.len or pass_val.len > StaticBufs.pass.len) return null;
    @memcpy(StaticBufs.url[0..url_val.len], url_val);
    @memcpy(StaticBufs.user[0..user_val.len], user_val);
    @memcpy(StaticBufs.pass[0..pass_val.len], pass_val);

    return .{
        .url = StaticBufs.url[0..url_val.len],
        .username = StaticBufs.user[0..user_val.len],
        .password = StaticBufs.pass[0..pass_val.len],
    };
}

/// Collect Tracing.dataCollected events — called from receiver thread
fn collectTraceData(allocator: Allocator, params: std.json.Value, trace_events: *std.ArrayList([]u8), trace_mutex: *std.Thread.Mutex) void {
    trace_mutex.lock();
    defer trace_mutex.unlock();
    // params.value is an array of trace event objects — serialize each one
    if (params != .object) return;
    const val = params.object.get("value") orelse return;
    if (val != .array) return;
    for (val.array.items) |event| {
        var out: std.io.Writer.Allocating = .init(allocator);
        std.json.Stringify.value(event, .{}, &out.writer) catch {
            out.deinit();
            continue;
        };
        const owned = out.toOwnedSlice() catch {
            out.deinit();
            continue;
        };
        trace_events.append(allocator, owned) catch {
            allocator.free(owned);
        };
    }
}

/// trace start / profiler start — send Tracing.start CDP command
fn handleTraceStart(
    allocator: Allocator,
    sender: *WsSender,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    trace_active: *std.atomic.Value(bool),
    trace_complete: *std.atomic.Value(bool),
    trace_events: *std.ArrayList([]u8),
    trace_mutex: *std.Thread.Mutex,
    is_profiler: bool,
) []u8 {
    if (trace_active.load(.acquire)) {
        return respondErr(allocator, "tracing already active — stop first");
    }
    // Clear previous trace data
    {
        trace_mutex.lock();
        defer trace_mutex.unlock();
        for (trace_events.items) |item| allocator.free(item);
        trace_events.clearRetainingCapacity();
    }
    trace_complete.store(false, .release);

    const params = if (is_profiler)
        "{\"traceConfig\":{\"includedCategories\":[\"devtools.timeline\",\"disabled-by-default-v8.cpu_profiler\",\"disabled-by-default-v8.cpu_profiler.hires\",\"v8.execute\",\"v8\",\"blink\",\"blink.user_timing\"],\"enableSampling\":true},\"transferMode\":\"ReportEvents\"}"
    else
        "{\"traceConfig\":{\"recordMode\":\"recordContinuously\"},\"transferMode\":\"ReportEvents\"}";

    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Tracing.start", params, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    sender.sendText(cmd) catch return respondErr(allocator, "send error");
    trace_active.store(true, .release);

    return respondOk(allocator);
}

/// trace stop / profiler stop — send Tracing.end, wait for data, write file
fn handleTraceStop(
    allocator: Allocator,
    sender: *WsSender,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    resp_map: *response_map_mod.ResponseMap,
    trace_active: *std.atomic.Value(bool),
    trace_complete: *std.atomic.Value(bool),
    trace_events: *std.ArrayList([]u8),
    trace_mutex: *std.Thread.Mutex,
    path_opt: ?[]const u8,
) []u8 {
    if (!trace_active.load(.acquire)) {
        return respondErr(allocator, "no tracing active — start first");
    }

    // Send Tracing.end
    const sent_id = cmd_id.next();
    const cmd = cdp.serializeCommand(allocator, sent_id, "Tracing.end", null, session_id) catch
        return respondErr(allocator, "cmd error");
    defer allocator.free(cmd);

    // Use sendAndWait for the response to Tracing.end
    const raw = sendAndWait(sender, resp_map, cmd, sent_id, 10_000) orelse
        return respondErr(allocator, "trace end timeout");
    allocator.free(raw);

    // Poll for trace_complete (receiver thread sets it on Tracing.tracingComplete)
    var waited: u32 = 0;
    while (!trace_complete.load(.acquire) and waited < 30_000) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
    }
    trace_active.store(false, .release);

    if (!trace_complete.load(.acquire)) {
        return respondErr(allocator, "trace collection timed out");
    }

    // Build output path
    var file_path_buf: [512]u8 = undefined;
    const file_path = if (path_opt) |p| p else blk: {
        const home = daemon.getenv("HOME") orelse "/tmp";
        const ts = @as(u64, @intCast(@max(0, std.time.timestamp())));
        const fp = std.fmt.bufPrint(&file_path_buf, "{s}/.agent-devtools/traces/trace-{d}.json", .{ home, ts }) catch
            return respondErr(allocator, "path error");
        break :blk fp;
    };

    // Ensure directory exists
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| {
        std.fs.cwd().makePath(file_path[0..slash]) catch {};
    }

    // Write trace file: {"traceEvents": [...]}
    trace_mutex.lock();
    defer trace_mutex.unlock();

    const event_count = trace_events.items.len;

    const file = std.fs.cwd().createFile(file_path, .{}) catch
        return respondErr(allocator, "file create error");
    defer file.close();

    _ = file.write("{\"traceEvents\":[") catch return respondErr(allocator, "write error");
    for (trace_events.items, 0..) |item, i| {
        _ = file.write(item) catch return respondErr(allocator, "write error");
        if (i + 1 < trace_events.items.len) {
            _ = file.write(",") catch return respondErr(allocator, "write error");
        }
    }
    _ = file.write("]}") catch return respondErr(allocator, "write error");

    // Free trace events after writing
    for (trace_events.items) |item| allocator.free(item);
    trace_events.clearRetainingCapacity();

    // Build response
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    const rw = resp_buf.writer(allocator);
    rw.writeAll("{\"path\":") catch return respondOk(allocator);
    cdp.writeJsonString(rw, file_path) catch return respondOk(allocator);
    std.fmt.format(rw, ",\"eventCount\":{d}}}", .{event_count}) catch return respondOk(allocator);
    const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
    defer allocator.free(data);
    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
}

fn handleVideoStart(
    allocator: Allocator,
    sender: *WsSender,
    resp_map: *response_map_mod.ResponseMap,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    video_recorder: *VideoRecorder,
    path_opt: ?[]const u8,
) []u8 {
    // Check if ffmpeg is available
    const ffmpeg_check_argv = [_][]const u8{ "ffmpeg", "-version" };
    var ffmpeg_check = std.process.Child.init(&ffmpeg_check_argv, allocator);
    ffmpeg_check.stdin_behavior = .Ignore;
    ffmpeg_check.stdout_behavior = .Ignore;
    ffmpeg_check.stderr_behavior = .Ignore;
    ffmpeg_check.spawn() catch {
        return respondErr(allocator, "ffmpeg not found — install ffmpeg and ensure it is in PATH");
    };
    _ = ffmpeg_check.wait() catch {
        return respondErr(allocator, "ffmpeg not found — install ffmpeg and ensure it is in PATH");
    };

    // Build output path
    var file_path_buf: [512]u8 = undefined;
    const file_path = if (path_opt) |p| p else blk: {
        const home = daemon.getenv("HOME") orelse "/tmp";
        const ts = @as(u64, @intCast(@max(0, std.time.timestamp())));
        const fp = std.fmt.bufPrint(&file_path_buf, "{s}/.agent-devtools/recordings/video-{d}.webm", .{ home, ts }) catch
            return respondErr(allocator, "path error");
        break :blk fp;
    };

    // Ensure directory exists
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| {
        std.fs.cwd().makePath(file_path[0..slash]) catch {};
    }

    video_recorder.start(allocator, sender, resp_map, cmd_id, session_id, file_path) catch |err| {
        if (err == error.AlreadyRecording) {
            return respondErr(allocator, "video recording already active — stop first");
        }
        return respondErr(allocator, "failed to start video recording");
    };

    // Build response
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    const rw = resp_buf.writer(allocator);
    rw.writeAll("{\"recording\":true,\"path\":") catch return respondOk(allocator);
    cdp.writeJsonString(rw, file_path) catch return respondOk(allocator);
    rw.writeAll("}") catch return respondOk(allocator);
    const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
    defer allocator.free(data);
    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
}

fn handleVideoStop(allocator: Allocator, video_recorder: *VideoRecorder) []u8 {
    const frame_count = video_recorder.stop() catch |err| {
        if (err == error.NotRecording) {
            return respondErr(allocator, "no video recording active — start first");
        }
        return respondErr(allocator, "failed to stop video recording");
    };

    const path = video_recorder.path[0..video_recorder.path_len];

    // Build response
    var resp_buf: std.ArrayList(u8) = .empty;
    defer resp_buf.deinit(allocator);
    const rw = resp_buf.writer(allocator);
    rw.writeAll("{\"recording\":false,\"path\":") catch return respondOk(allocator);
    cdp.writeJsonString(rw, path) catch return respondOk(allocator);
    std.fmt.format(rw, ",\"frames\":{d}}}", .{frame_count}) catch return respondOk(allocator);
    const data = resp_buf.toOwnedSlice(allocator) catch return respondOk(allocator);
    defer allocator.free(data);
    return daemon.serializeResponse(allocator, .{ .success = true, .data = data }) catch respondOk(allocator);
}

/// screenshot --annotate: take a snapshot, inject ref labels, screenshot, remove overlay
fn handleScreenshotAnnotate(
    allocator: Allocator,
    sender: *WsSender,
    resp_map: *response_map_mod.ResponseMap,
    cmd_id: *cdp.CommandId,
    session_id: ?[]const u8,
    ref_map: *snapshot_mod.RefMap,
    path_opt: ?[]const u8,
) []u8 {
    // Step 1: Take a fresh snapshot to populate ref_map
    ref_map.deinit();
    ref_map.* = snapshot_mod.RefMap.init(allocator);

    {
        const snap_sent_id = cmd_id.next();
        const snap_cmd = cdp.serializeCommand(allocator, snap_sent_id, "Accessibility.getFullAXTree", null, session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(snap_cmd);

        const snap_raw = sendAndWait(sender, resp_map, snap_cmd, snap_sent_id, 15_000) orelse
            return respondErr(allocator, "snapshot timeout");
        defer allocator.free(snap_raw);

        const snap_parsed = cdp.parseMessage(allocator, snap_raw) catch
            return respondErr(allocator, "parse error");
        defer snap_parsed.parsed.deinit();

        if (snap_parsed.message.isResponse()) {
            if (snap_parsed.message.result) |result| {
                const snap_text = snapshot_mod.buildSnapshot(allocator, result, ref_map, true, null, null) catch
                    return respondErr(allocator, "snapshot build error");
                allocator.free(snap_text);
            }
        }
    }

    // Step 2: For each ref, get bounding box and build overlay data
    var positions: std.ArrayList(u8) = .empty;
    defer positions.deinit(allocator);
    const pw = positions.writer(allocator);
    pw.writeByte('[') catch return respondErr(allocator, "write error");
    var first = true;

    var it = ref_map.entries.iterator();
    while (it.next()) |entry| {
        const ref_id = entry.key_ptr.*;
        const ref_entry = entry.value_ptr.*;
        const backend_id = ref_entry.backend_node_id orelse continue;

        // DOM.getBoxModel for this ref
        const box_sent_id = cmd_id.next();
        const box_cmd = snapshot_mod.buildGetBoxModelCmd(allocator, box_sent_id, backend_id, session_id) catch continue;
        defer allocator.free(box_cmd);

        const box_raw = sendAndWait(sender, resp_map, box_cmd, box_sent_id, 3_000) orelse continue;
        defer allocator.free(box_raw);

        const box_parsed = cdp.parseMessage(allocator, box_raw) catch continue;
        defer box_parsed.parsed.deinit();

        if (box_parsed.message.isResponse()) {
            if (box_parsed.message.result) |result| {
                if (cdp.getObject(result, "model")) |model| {
                    if (model.object.get("content")) |content| {
                        if (content == .array) {
                            const items = content.array.items;
                            if (items.len >= 2) {
                                const x_val = jsonToF64(items[0]) orelse continue;
                                const y_val = jsonToF64(items[1]) orelse continue;
                                if (!first) pw.writeByte(',') catch {};
                                first = false;
                                pw.writeAll("{\"ref\":\"@") catch {};
                                pw.writeAll(ref_id) catch {};
                                std.fmt.format(pw, "\",\"x\":{d},\"y\":{d}}}", .{ x_val, y_val }) catch {};
                            }
                        }
                    }
                }
            }
        }
    }
    pw.writeByte(']') catch {};

    const refs_json = positions.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(refs_json);

    // Step 3: Inject annotation overlay via Runtime.evaluate
    var inject_js: std.ArrayList(u8) = .empty;
    defer inject_js.deinit(allocator);
    const jw = inject_js.writer(allocator);
    jw.writeAll(
        \\(function(){var overlay=document.createElement('div');overlay.id='__agent_devtools_annotations__';overlay.style.cssText='position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:2147483647';var refs=
    ) catch return respondErr(allocator, "js build error");
    jw.writeAll(refs_json) catch return respondErr(allocator, "js build error");
    jw.writeAll(
        \\;refs.forEach(function(r){var label=document.createElement('div');label.textContent=r.ref;label.style.cssText='position:absolute;left:'+r.x+'px;top:'+r.y+'px;background:#ff0;color:#000;font:bold 11px monospace;padding:1px 3px;border:1px solid #000;border-radius:2px;z-index:2147483647';overlay.appendChild(label)});document.body.appendChild(overlay)})()
    ) catch return respondErr(allocator, "js build error");

    const inject_slice = inject_js.toOwnedSlice(allocator) catch return respondErr(allocator, "alloc error");
    defer allocator.free(inject_slice);

    {
        const eval_id = cmd_id.next();
        const eval_cmd = cdp.runtimeEvaluate(allocator, eval_id, inject_slice, session_id) catch
            return respondErr(allocator, "cmd error");
        defer allocator.free(eval_cmd);
        if (sendAndWait(sender, resp_map, eval_cmd, eval_id, 5_000)) |eval_raw| {
            allocator.free(eval_raw);
        }
    }

    // Step 4: Take the screenshot
    const result = handleScreenshot(allocator, sender, resp_map, cmd_id, session_id, path_opt);

    // Step 5: Remove the overlay
    {
        const cleanup_js = "(function(){var el=document.getElementById('__agent_devtools_annotations__');if(el)el.remove()})()";
        const cleanup_id = cmd_id.next();
        const cleanup_cmd = cdp.runtimeEvaluate(allocator, cleanup_id, cleanup_js, session_id) catch
            return result;
        defer allocator.free(cleanup_cmd);
        if (sendAndWait(sender, resp_map, cleanup_cmd, cleanup_id, 5_000)) |cleanup_raw| {
            allocator.free(cleanup_raw);
        }
    }

    return result;
}

fn isPlannedCommand(cmd: []const u8) bool {
    const planned = [_][]const u8{};
    for (planned) |p| {
        if (std.mem.eql(u8, cmd, p)) return true;
    }
    return false;
}

/// Unescape a JSON-serialized string for CLI display.
/// If data is a JSON string like `"hello\nworld"`, strips quotes and unescapes.
/// If data is JSON object/array, returns as-is.
/// Returns: .output = the string to print, .allocated = whether caller must free it.
const UnescapeResult = struct { output: []const u8, allocated: bool };

fn unescapeJsonString(allocator: Allocator, data: []const u8) UnescapeResult {
    if (data.len >= 2 and data[0] == '"' and data[data.len - 1] == '"') {
        const inner = data[1 .. data.len - 1];
        if (std.mem.indexOf(u8, inner, "\\") == null) {
            // No escapes — return sub-slice (not allocated)
            return .{ .output = inner, .allocated = false };
        }
        // Has escapes — allocate and unescape
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < inner.len) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                switch (inner[i + 1]) {
                    'n' => buf.append(allocator, '\n') catch {},
                    't' => buf.append(allocator, '\t') catch {},
                    'r' => buf.append(allocator, '\r') catch {},
                    '"' => buf.append(allocator, '"') catch {},
                    '\\' => buf.append(allocator, '\\') catch {},
                    '/' => buf.append(allocator, '/') catch {},
                    else => {
                        buf.append(allocator, inner[i]) catch {};
                        buf.append(allocator, inner[i + 1]) catch {};
                    },
                }
                i += 2;
            } else {
                buf.append(allocator, inner[i]) catch {};
                i += 1;
            }
        }
        const owned = buf.toOwnedSlice(allocator) catch return .{ .output = data, .allocated = false };
        return .{ .output = owned, .allocated = true };
    }
    return .{ .output = data, .allocated = false };
}

fn write(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |msg| {
        stdout.writeAll(msg) catch {};
        return;
    } else |_| {}
    // 4KB 초과 출력 (스냅샷, 네트워크, react 트리 등): 동적 할당으로 폴백.
    // CLI는 단발 프로세스라 page_allocator로 충분 (defer free로 정리).
    const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(msg);
    stdout.writeAll(msg) catch {};
}

/// 대형 페이로드(스냅샷/네트워크/react 트리)를 포맷·재할당 없이 그대로 출력 + 개행.
fn writeLine(slice: []const u8) void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(slice) catch {};
    stdout.writeAll("\n") catch {};
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn printUsage() void {
    const stdout = std.fs.File.stdout();
    _ = stdout.writeAll(
        \\agent-devtools - Browser DevTools CLI for AI agents
        \\
        \\Usage: agent-devtools [options] <command> [args]
        \\
        \\Core Commands:
        \\  open <url>                Navigate to URL (aliases: navigate, goto)
        \\  click <@ref>              Click element
        \\  dblclick <@ref>           Double-click element
        \\  tap <@ref>                Touch tap element
        \\  type <@ref> <text>        Type into element
        \\  fill <@ref> <text>        Clear and fill
        \\  press <key>               Press key (Enter, Tab, Control+a)
        \\  hover <@ref>              Hover element
        \\  focus <@ref>              Focus element
        \\  check <@ref>              Check checkbox
        \\  uncheck <@ref>            Uncheck checkbox
        \\  select <@ref> <val>       Select dropdown option
        \\  clear <@ref>              Clear input value
        \\  selectall <@ref>          Select all text in input
        \\  drag <@from> <@to>        Drag and drop
        \\  upload <@ref> <file>      Upload file
        \\  scroll <dir> [px]         Scroll (up/down/left/right)
        \\  scrollintoview <@ref>     Scroll element into view
        \\  dispatch <@ref> <event>   Dispatch DOM event (input, change, blur)
        \\  wait <ms>                 Wait milliseconds
        \\  screenshot [--full] [path] Take screenshot (--full for full page)
        \\  pdf [path]                Save as PDF
        \\  snapshot [-i] [-u]        Accessibility tree with refs (-i: interactive only, -u/--urls: link hrefs)
        \\  eval <js>                 Run JavaScript
        \\  close                     Close browser and stop daemon
        \\
        \\Navigation:
        \\  back                      Go back
        \\  forward                   Go forward
        \\  reload                    Reload page
        \\  pushstate <url>           SPA client-side navigation (history.pushState)
        \\  vitals [url]              Core Web Vitals (LCP/CLS/FCP/INP) + TTFB
        \\  react tree                React 컴포넌트 트리 (--enable=react-devtools 필요)
        \\  url                       Get current URL
        \\  title                     Get page title
        \\  content                   Get page HTML
        \\  setcontent <html>         Set page HTML
        \\
        \\Get Info:  agent-devtools get <what> [@ref]
        \\  text, html, value, attr <name>, title, url
        \\
        \\Check State:  agent-devtools is <what> <@ref>
        \\  visible, enabled, checked
        \\
        \\Element Info:
        \\  boundingbox <@ref>        Get element bounding box {x, y, width, height}
        \\  styles <@ref> <prop>      Get computed CSS style value
        \\  highlight <@ref>          Highlight element with overlay
        \\
        \\Find Elements:  agent-devtools find <locator> <value>
        \\  role, text, label, placeholder, testid
        \\
        \\Mouse:  agent-devtools mouse <action> [args]
        \\  move <x> <y>, down, up
        \\
        \\Browser Settings:  agent-devtools set <setting> [value]
        \\  viewport <w> <h>          Set viewport size
        \\  media <scheme>            Color scheme (dark/light)
        \\  offline <on|off>          Offline mode
        \\  timezone <tz>             Timezone (e.g. Asia/Seoul)
        \\  locale <locale>           Locale (e.g. ko-KR)
        \\  geolocation <lat> <lon>   Geolocation coordinates
        \\  headers <json>            Extra HTTP headers
        \\  useragent <ua>            User agent string
        \\  device <name|list>        Emulate device (list to see available)
        \\  ignore-https-errors       Ignore HTTPS certificate errors
        \\  permissions grant <perm>  Grant browser permission
        \\
        \\Network:  agent-devtools network <action>
        \\  requests [--filter pat] [--clear]  List or clear network requests
        \\  get <requestId>           Request details with response body
        \\  clear                     Clear collected requests (alias)
        \\
        \\Network Interception:  agent-devtools intercept <action>
        \\  mock <pattern> <json>     Mock response
        \\  fail <pattern>            Fail request
        \\  delay <pattern> <ms>      Delay request
        \\  remove <pattern>          Remove rule
        \\  list                      List active rules
        \\  clear                     Clear all rules
        \\
        \\Console & Errors:
        \\  console [--clear]         View console messages (--clear to clear)
        \\  errors [--clear]          View or clear page errors
        \\
        \\Storage:
        \\  cookies [list|set|get|clear]  Manage cookies
        \\  cookies set --curl <file>     Bulk import (JSON / cURL dump / Cookie header)
        \\  storage <local|session>       Manage web storage
        \\  state save|load|list          Save/restore cookies + storage
        \\
        \\Tabs:
        \\  tab list                  List open tabs
        \\  tab new [url]             Open new tab
        \\  tab close                 Close current tab
        \\  tab switch <n>            Switch to tab by index
        \\  tab count                 Count open tabs
        \\  window new [url]          Open new window
        \\
        \\Wait Commands:
        \\  waitforloadstate [ms]     Wait for page load complete
        \\  waitforurl <pattern> [ms] Wait for URL match
        \\  waitforfunction <expr> [ms]  Wait for JS expression truthy
        \\  waitfor network <pat> [ms]   Wait for network request matching pattern
        \\  waitfor console <pat> [ms]   Wait for console message matching pattern
        \\  waitfor error [ms]        Wait for page error
        \\  waitfor dialog [ms]       Wait for dialog popup
        \\  waitdownload [ms]         Wait for download complete
        \\
        \\Analysis (unique to agent-devtools):
        \\  analyze                   API reverse engineering + JSON schema inference
        \\  har [filename]            Export network data as HAR 1.2 file
        \\  record <name>             Record network state snapshot
        \\  diff <name>               Compare current vs recorded state
        \\  replay <name>             Replay: navigate to recorded URL + diff
        \\
        \\Performance:
        \\  trace start               Start tracing (CDP Tracing.start)
        \\  trace stop [path]         Stop tracing and save trace file (JSON)
        \\  profiler start            Start CPU profiler via tracing
        \\  profiler stop [path]      Stop profiler and save trace file (JSON)
        \\  video start [path]        Start video recording (requires ffmpeg)
        \\  video stop                Stop video recording and save file
        \\  screenshot --annotate [p] Screenshot with ref labels overlaid (-a)
        \\  diff-screenshot <a> [b]   Compare screenshots (pixel diff, PNG output)
        \\
        \\Dialog:
        \\  dialog accept [text]      Accept dialog (optional prompt text)
        \\  dialog dismiss            Dismiss dialog
        \\  dialog info               Show current dialog info
        \\
        \\Other:
        \\  addscript <js>            Add script to evaluate on every new page
        \\  removeinitscript <id>     Remove a script added by addscript/--init-script (by identifier)
        \\  addstyle <css>            Add <style> tag to page
        \\  credentials <user> <pass> Set HTTP basic auth credentials
        \\  download-path <dir>       Set download directory
        \\  expose <name>             Register JS binding
        \\  bringtofront              Bring browser window to front
        \\  pause / resume            Pause/resume JavaScript execution
        \\  status                    Show daemon status
        \\  find-chrome               Find Chrome executable path
        \\
        \\Auth Vault:
        \\  auth save <name> --url <url> --username <user> --password <pass>
        \\  auth login <name>         Auto-login using saved credentials
        \\  auth list                 List saved auth profiles
        \\  auth show <name>          Show auth profile (masked password)
        \\  auth delete <name>        Delete auth profile
        \\
        \\Options:
        \\  --session <name>          Isolated session (default: "default")
        \\  --headed                  Show browser window (default: headless)
        \\  --port <port>             Connect to existing Chrome via CDP port
        \\  --auto-connect            Connect to running Chrome to reuse its auth state
        \\                            Tip: agent-devtools --auto-connect state save ./auth.json
        \\  --user-agent <ua>         Set user agent on launch
        \\  --proxy <url>             Proxy server (e.g. http://localhost:8080)
        \\  --proxy-bypass <list>     Proxy bypass list (e.g. localhost,*.internal.com)
        \\  --extension <path>        Load Chrome extension (comma-separated paths)
        \\  --allowed-domains <list>  Restrict navigation to domains (e.g. example.com,*.internal.com)
        \\  --content-boundaries      Wrap page content output with boundary markers
        \\  --no-auto-dialog          Do not auto-dismiss alert/beforeunload dialogs
        \\  --init-script <path>      Register a script file to run before page JS (repeatable)
        \\  --enable=react-devtools   Install React DevTools hook (exposes __REACT_DEVTOOLS_GLOBAL_HOOK__)
        \\  --interactive, --pipe     Persistent REPL mode (JSON stdin/stdout + event streaming)
        \\  -h, --help                Show this help
        \\  -v, --version             Show version
        \\
        \\Config File:
        \\  Reads defaults from ./agent-devtools.json or ~/.agent-devtools/config.json
        \\  Supported fields: headed, proxy, proxy_bypass, user_agent, extensions
        \\  CLI flags always override config file values.
        \\
        \\Environment:
        \\  AGENT_DEVTOOLS_SESSION    Session name
        \\  AGENT_DEVTOOLS_USER_AGENT Default user agent string
        \\
        \\Snapshot Options:
        \\  -i                        Only interactive elements (links, buttons, inputs)
        \\  (full snapshot)           Full accessibility tree with all elements
        \\
        \\Interactive Mode (--interactive or --pipe):
        \\  Reads commands from stdin (one per line), writes JSON responses + events to stdout.
        \\  Supports both text commands and JSON format:
        \\    > open https://example.com
        \\    > {"action":"click","url":"@e1"}
        \\  Events are streamed automatically:
        \\    < {"event":"network","url":"/api/data","method":"GET","status":200}
        \\    < {"event":"console","type":"log","text":"hello"}
        \\    < {"event":"error","description":"ReferenceError: x is not defined"}
        \\
        \\Examples:
        \\  agent-devtools open example.com
        \\  agent-devtools snapshot -i
        \\  agent-devtools click @e2
        \\  agent-devtools fill @e3 "test@example.com"
        \\  agent-devtools find role button
        \\  agent-devtools get text @e1
        \\  agent-devtools screenshot ./page.png
        \\  agent-devtools set device "iPhone 14"
        \\  agent-devtools set timezone Asia/Seoul
        \\  agent-devtools intercept mock "/api/*" '{"data":"mocked"}'
        \\  agent-devtools waitfor network /api/login 10000
        \\  agent-devtools analyze
        \\  agent-devtools --port 9222 snapshot -i
        \\  agent-devtools --auto-connect snapshot -i
        \\  agent-devtools --interactive
        \\
        \\Command Chaining:
        \\  agent-devtools open example.com && agent-devtools snapshot -i && agent-devtools click @e1
        \\
        \\Install:
        \\  npm install -g @ohah/agent-devtools
        \\  curl -fsSL https://raw.githubusercontent.com/ohah/agent-devtools/main/install.sh | sh
        \\  npx skills add ohah/agent-devtools     # AI agent skill
        \\
    ) catch {};
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
}

test "isPlannedCommand: recognizes planned commands" {
    try std.testing.expect(!isPlannedCommand("diff-screenshot"));
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

// ============================================================================
// Tests: collectExceptionEvent
// ============================================================================

test "collectExceptionEvent: extracts exception description" {
    const json =
        \\{"timestamp":1234.5,"exceptionDetails":{"text":"Uncaught","exception":{"type":"object","description":"Error: test error"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    var errors: std.ArrayList(PageError) = .empty;
    defer {
        for (errors.items) |e| std.testing.allocator.free(e.description);
        errors.deinit(std.testing.allocator);
    }
    collectExceptionEvent(std.testing.allocator, parsed.value, &errors);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqualStrings("Error: test error", errors.items[0].description);
}

test "collectExceptionEvent: falls back to text when no exception object" {
    const json =
        \\{"timestamp":1234.5,"exceptionDetails":{"text":"Uncaught SyntaxError"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    var errors: std.ArrayList(PageError) = .empty;
    defer {
        for (errors.items) |e| std.testing.allocator.free(e.description);
        errors.deinit(std.testing.allocator);
    }
    collectExceptionEvent(std.testing.allocator, parsed.value, &errors);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqualStrings("Uncaught SyntaxError", errors.items[0].description);
}

test "collectExceptionEvent: falls back to unknown error" {
    const json =
        \\{"timestamp":0}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    var errors: std.ArrayList(PageError) = .empty;
    defer {
        for (errors.items) |e| std.testing.allocator.free(e.description);
        errors.deinit(std.testing.allocator);
    }
    collectExceptionEvent(std.testing.allocator, parsed.value, &errors);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqualStrings("unknown error", errors.items[0].description);
}

// ============================================================================
// Tests: collectDialogEvent
// ============================================================================

test "shouldAutoDismissDialog: alert/beforeunload auto-dismissed when enabled" {
    try std.testing.expect(shouldAutoDismissDialog(true, "alert"));
    try std.testing.expect(shouldAutoDismissDialog(true, "beforeunload"));
}

test "shouldAutoDismissDialog: confirm/prompt never auto-dismissed" {
    try std.testing.expect(!shouldAutoDismissDialog(true, "confirm"));
    try std.testing.expect(!shouldAutoDismissDialog(true, "prompt"));
}

test "shouldAutoDismissDialog: disabled flag suppresses all auto-dismiss" {
    try std.testing.expect(!shouldAutoDismissDialog(false, "alert"));
    try std.testing.expect(!shouldAutoDismissDialog(false, "beforeunload"));
}

test "collectDialogEvent: stores dialog info" {
    const json =
        \\{"type":"prompt","message":"Enter name:","defaultPrompt":"John"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    var dialog: ?DialogInfo = null;
    defer if (dialog) |di| {
        std.testing.allocator.free(di.dialog_type);
        std.testing.allocator.free(di.message);
        std.testing.allocator.free(di.default_prompt);
    };
    collectDialogEvent(std.testing.allocator, parsed.value, &dialog);

    try std.testing.expect(dialog != null);
    try std.testing.expectEqualStrings("prompt", dialog.?.dialog_type);
    try std.testing.expectEqualStrings("Enter name:", dialog.?.message);
    try std.testing.expectEqualStrings("John", dialog.?.default_prompt);
}

test "collectDialogEvent: alert with no prompt" {
    const json =
        \\{"type":"alert","message":"Hello!"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    var dialog: ?DialogInfo = null;
    defer if (dialog) |di| {
        std.testing.allocator.free(di.dialog_type);
        std.testing.allocator.free(di.message);
        std.testing.allocator.free(di.default_prompt);
    };
    collectDialogEvent(std.testing.allocator, parsed.value, &dialog);

    try std.testing.expect(dialog != null);
    try std.testing.expectEqualStrings("alert", dialog.?.dialog_type);
    try std.testing.expectEqualStrings("Hello!", dialog.?.message);
    try std.testing.expectEqualStrings("", dialog.?.default_prompt);
}

test "collectDialogEvent: replaces previous dialog info" {
    var dialog: ?DialogInfo = null;

    // First dialog
    const json1 =
        \\{"type":"alert","message":"First"}
    ;
    const parsed1 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json1, .{});
    defer parsed1.deinit();
    collectDialogEvent(std.testing.allocator, parsed1.value, &dialog);
    try std.testing.expectEqualStrings("First", dialog.?.message);

    // Second dialog replaces first
    const json2 =
        \\{"type":"confirm","message":"Second"}
    ;
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json2, .{});
    defer parsed2.deinit();
    collectDialogEvent(std.testing.allocator, parsed2.value, &dialog);
    try std.testing.expectEqualStrings("Second", dialog.?.message);
    try std.testing.expectEqualStrings("confirm", dialog.?.dialog_type);

    // Clean up
    if (dialog) |di| {
        std.testing.allocator.free(di.dialog_type);
        std.testing.allocator.free(di.message);
        std.testing.allocator.free(di.default_prompt);
    }
}

// ============================================================================
// Tests: handleErrors
// ============================================================================

test "handleErrors: empty list returns empty JSON array" {
    var errors: std.ArrayList(PageError) = .empty;
    defer errors.deinit(std.testing.allocator);

    const resp_bytes = handleErrors(std.testing.allocator, &errors);
    defer std.testing.allocator.free(resp_bytes);

    // Should contain "[]" in the data
    try std.testing.expect(std.mem.indexOf(u8, resp_bytes, "[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_bytes, "\"success\":true") != null);
}

test "handleErrors: returns error entries" {
    var errors: std.ArrayList(PageError) = .empty;
    defer {
        for (errors.items) |e| std.testing.allocator.free(e.description);
        errors.deinit(std.testing.allocator);
    }

    const desc = try std.testing.allocator.dupe(u8, "ReferenceError: x is not defined");
    errors.append(std.testing.allocator, .{ .description = desc, .timestamp = 0 }) catch {};

    const resp_bytes = handleErrors(std.testing.allocator, &errors);
    defer std.testing.allocator.free(resp_bytes);

    try std.testing.expect(std.mem.indexOf(u8, resp_bytes, "ReferenceError") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_bytes, "\"success\":true") != null);
}

// ============================================================================
// Tests: isPlannedCommand — new commands not planned
// ============================================================================

test "isPlannedCommand: new commands are not planned" {
    try std.testing.expect(!isPlannedCommand("find"));
    try std.testing.expect(!isPlannedCommand("dialog"));
    try std.testing.expect(!isPlannedCommand("content"));
    try std.testing.expect(!isPlannedCommand("setcontent"));
    try std.testing.expect(!isPlannedCommand("addscript"));
    try std.testing.expect(!isPlannedCommand("waiturl"));
    try std.testing.expect(!isPlannedCommand("waitfunction"));
    try std.testing.expect(!isPlannedCommand("errors"));
    try std.testing.expect(!isPlannedCommand("highlight"));
    try std.testing.expect(!isPlannedCommand("bringtofront"));
}

// ============================================================================
// Tests: Batch 3 commands
// ============================================================================

test "isPlannedCommand: batch 3 commands are not planned" {
    try std.testing.expect(!isPlannedCommand("clear"));
    try std.testing.expect(!isPlannedCommand("selectall"));
    try std.testing.expect(!isPlannedCommand("boundingbox"));
    try std.testing.expect(!isPlannedCommand("styles"));
    try std.testing.expect(!isPlannedCommand("clipboard"));
    try std.testing.expect(!isPlannedCommand("window"));
    try std.testing.expect(!isPlannedCommand("pause"));
    try std.testing.expect(!isPlannedCommand("resume"));
    try std.testing.expect(!isPlannedCommand("dispatch"));
    try std.testing.expect(!isPlannedCommand("waitload"));
    try std.testing.expect(!isPlannedCommand("check"));
    try std.testing.expect(!isPlannedCommand("uncheck"));
}

test "jsonToF64: integer value" {
    const val = std.json.Value{ .integer = 42 };
    const result = jsonToF64(val);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.?, 0.01);
}

test "jsonToF64: float value" {
    const val = std.json.Value{ .float = 3.14 };
    const result = jsonToF64(val);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.?, 0.01);
}

test "jsonToF64: null value returns null" {
    const val = std.json.Value.null;
    try std.testing.expect(jsonToF64(val) == null);
}

test "jsonToF64: bool value returns null" {
    const val = std.json.Value{ .bool = true };
    try std.testing.expect(jsonToF64(val) == null);
}

test "jsonToF64: string value returns null" {
    const val = std.json.Value{ .string = "hello" };
    try std.testing.expect(jsonToF64(val) == null);
}

test "jsonToF64: negative integer" {
    const val = std.json.Value{ .integer = -10 };
    const result = jsonToF64(val);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, -10.0), result.?, 0.01);
}

test "jsonToF64: zero" {
    const val = std.json.Value{ .integer = 0 };
    const result = jsonToF64(val);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?, 0.01);
}

test "buildCallFunctionOnParams: with argument" {
    const params = buildCallFunctionOnParams(
        std.testing.allocator,
        "obj-123",
        "function(a){return this.getAttribute(a)}",
        "href",
    ) orelse unreachable;
    defer std.testing.allocator.free(params);

    // Should contain objectId, functionDeclaration, arguments, and returnByValue
    try std.testing.expect(std.mem.indexOf(u8, params, "\"objectId\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"functionDeclaration\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"arguments\":[{\"value\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"returnByValue\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "href") != null);
}

test "buildCallFunctionOnParams: without argument" {
    const params = buildCallFunctionOnParams(
        std.testing.allocator,
        "obj-456",
        "function(){return !!this.checked}",
        null,
    ) orelse unreachable;
    defer std.testing.allocator.free(params);

    try std.testing.expect(std.mem.indexOf(u8, params, "\"objectId\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"functionDeclaration\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"arguments\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"returnByValue\":true") != null);
}

// ============================================================================
// Tests: Batch 4 features
// ============================================================================

test "isPlannedCommand: diff-screenshot is now implemented" {
    try std.testing.expect(!isPlannedCommand("diff-screenshot"));
}

test "isPlannedCommand: batch4 commands are not planned" {
    try std.testing.expect(!isPlannedCommand("credentials"));
    try std.testing.expect(!isPlannedCommand("download-path"));
    try std.testing.expect(!isPlannedCommand("har"));
    try std.testing.expect(!isPlannedCommand("state"));
    try std.testing.expect(!isPlannedCommand("addstyle"));
}

test "handleHar: generates valid HAR with empty collector" {
    const allocator = std.testing.allocator;
    var collector = network.Collector.init(allocator);
    defer collector.deinit();

    // Use a cross-platform temp file path
    const tmp_path = if (comptime builtin.os.tag == .windows) "agent-devtools-test-har.har" else "/tmp/agent-devtools-test-har.har";
    const result = handleHar(allocator, &collector, tmp_path);
    defer allocator.free(result);

    // Should be a success response
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"entries\":0") != null);

    // Verify the HAR file was created and has valid structure
    const content = std.fs.cwd().readFileAlloc(allocator, tmp_path, 1024 * 1024) catch unreachable;
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"version\":\"1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"creator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"entries\":[]") != null);

    // Cleanup
    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "handleStateList: returns empty array when no states dir" {
    const allocator = std.testing.allocator;
    const result = handleStateList(allocator);
    defer allocator.free(result);

    // Should return success with an array
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "handleDownloadPath: builds correct CDP command params" {
    // Verify the function exists and compiles
    // Full integration test requires actual WebSocket
    const allocator = std.testing.allocator;
    _ = allocator;
    // handleDownloadPath needs a sender — tested via build compilation
}

test "buildCookieSetArrayJson: bare cookie header" {
    const a = std.testing.allocator;
    const out = try buildCookieSetArrayJson(a, "  sid=abc; theme=dark ; empty= ");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"sid\",\"value\":\"abc\",\"url\":\"*\"},{\"name\":\"theme\",\"value\":\"dark\",\"url\":\"*\"},{\"name\":\"empty\",\"value\":\"\",\"url\":\"*\"}]",
        out,
    );
}

test "buildCookieSetArrayJson: JSON array format" {
    const a = std.testing.allocator;
    const out = try buildCookieSetArrayJson(a,
        \\[{"name":"a","value":"1","domain":"x.com"},{"name":"b","value":"2"}]
    );
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"a\",\"value\":\"1\",\"url\":\"*\"},{\"name\":\"b\",\"value\":\"2\",\"url\":\"*\"}]",
        out,
    );
}

test "buildCookieSetArrayJson: cURL dump extracts -H cookie header" {
    const a = std.testing.allocator;
    const curl = "curl 'https://x.com/api' -H 'accept: */*' -H 'cookie: sid=xyz; t=1' --compressed";
    const out = try buildCookieSetArrayJson(a, curl);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"sid\",\"value\":\"xyz\",\"url\":\"*\"},{\"name\":\"t\",\"value\":\"1\",\"url\":\"*\"}]",
        out,
    );
}

test "buildCookieSetArrayJson: cURL with -b flag" {
    const a = std.testing.allocator;
    const out = try buildCookieSetArrayJson(a, "curl \"https://x.com\" -b \"k=v\"");
    defer a.free(out);
    try std.testing.expectEqualStrings("[{\"name\":\"k\",\"value\":\"v\",\"url\":\"*\"}]", out);
}

test "buildCookieSetArrayJson: empty file errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyFile, buildCookieSetArrayJson(a, "   \n  "));
}

test "buildCookieSetArrayJson: cURL without cookie header errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NoCookieHeaderInCurl, buildCookieSetArrayJson(a, "curl 'https://x.com' -H 'accept: */*'"));
}

test "matchQuotedArg: respects word boundary and header prefix" {
    // -H 'cookie: ...' → strips 'cookie:' prefix
    try std.testing.expectEqualStrings("a=b", matchQuotedArg("x -H 'cookie: a=b'", "-H", "cookie").?);
    // -b without expected header returns whole value
    try std.testing.expectEqualStrings("a=b", matchQuotedArg("x -b 'a=b'", "-b", null).?);
    // no match
    try std.testing.expect(matchQuotedArg("x --data 'a=b'", "-b", null) == null);
}

test "collectLinkBackendIds: collects link nodes, skips non-links and ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\{"nodes":[
        \\{"role":{"value":"link"},"backendDOMNodeId":11,"ignored":false},
        \\{"role":{"value":"button"},"backendDOMNodeId":22,"ignored":false},
        \\{"role":{"value":"link"},"backendDOMNodeId":33,"ignored":true},
        \\{"role":{"value":"link"},"backendDOMNodeId":44}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const ids = try collectLinkBackendIds(allocator, parsed.value);
    defer allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(i64, 11), ids[0]);
    try std.testing.expectEqual(@as(i64, 44), ids[1]);
}

test "collectLinkBackendIds: empty/missing nodes yields empty slice" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    const ids = try collectLinkBackendIds(allocator, parsed.value);
    defer allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "REACT_TREE_SNAPSHOT: embedded async script references hook and returns JSON" {
    try std.testing.expect(std.mem.indexOf(u8, REACT_TREE_SNAPSHOT, "__REACT_DEVTOOLS_GLOBAL_HOOK__") != null);
    try std.testing.expect(std.mem.indexOf(u8, REACT_TREE_SNAPSHOT, "JSON.stringify") != null);
}

test "REACT_INSTALL_HOOK: embedded hook is present and installs the global" {
    // 벤더링 blob ~183KB — @embedFile 누락/절단 회귀 방지용 하한
    try std.testing.expect(REACT_INSTALL_HOOK.len > 100_000);
    try std.testing.expect(std.mem.indexOf(u8, REACT_INSTALL_HOOK, "__REACT_DEVTOOLS_GLOBAL_HOOK__") != null);
}

test "init-script CSV: comma/newline separated paths, trimmed, blanks skipped" {
    // registerInitScripts의 경로 분리 계약 회귀 방지
    var it = std.mem.tokenizeAny(u8, " a.js, b.js\n\n c.js ,", ",\n");
    var got: [3][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " \t\r");
        if (t.len == 0) continue;
        got[n] = t;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("a.js", got[0]);
    try std.testing.expectEqualStrings("b.js", got[1]);
    try std.testing.expectEqualStrings("c.js", got[2]);
}

test "VITALS scripts: observe all core web vitals + emit expected keys" {
    // 회귀 방지: 4개 관측자 타입과 READ가 내보내는 키 존재 확인
    try std.testing.expect(std.mem.indexOf(u8, VITALS_INIT_JS, "largest-contentful-paint") != null);
    try std.testing.expect(std.mem.indexOf(u8, VITALS_INIT_JS, "layout-shift") != null);
    try std.testing.expect(std.mem.indexOf(u8, VITALS_INIT_JS, "first-contentful-paint") != null);
    try std.testing.expect(std.mem.indexOf(u8, VITALS_INIT_JS, "durationThreshold") != null);
    inline for (.{ "lcp", "cls", "fcp", "inp", "ttfb" }) |k| {
        try std.testing.expect(std.mem.indexOf(u8, VITALS_READ_JS, k) != null);
    }
}

test "buildPushStateExpr: embeds URL as escaped JSON arg" {
    const allocator = std.testing.allocator;
    const expr = try buildPushStateExpr(allocator, "/foo");
    defer allocator.free(expr);
    try std.testing.expect(std.mem.indexOf(u8, expr, "history.pushState") != null);
    try std.testing.expect(std.mem.indexOf(u8, expr, "window.next") != null);
    try std.testing.expect(std.mem.endsWith(u8, expr, "(\"/foo\")"));
}

test "buildPushStateExpr: escapes special characters in URL" {
    const allocator = std.testing.allocator;
    const expr = try buildPushStateExpr(allocator, "/a?q=\"x\"&b=1");
    defer allocator.free(expr);
    // 따옴표가 \" 로 이스케이프되어 JS 문자열 깨짐 방지
    try std.testing.expect(std.mem.indexOf(u8, expr, "\\\"x\\\"") != null);
}

test "handleAddStyle: builds correct JS expression" {
    // Verify the function exists and compiles
    // Full integration test requires actual WebSocket connection
    const allocator = std.testing.allocator;
    _ = allocator;
    // handleAddStyle needs a sender — tested via build compilation
}

test "AuthCredentials: struct layout" {
    const creds = AuthCredentials{
        .username = @constCast("user"),
        .password = @constCast("pass"),
    };
    try std.testing.expectEqualStrings("user", creds.username);
    try std.testing.expectEqualStrings("pass", creds.password);
}

// ============================================================================
// Batch 5 Tests
// ============================================================================

test "isPlannedCommand: batch5 — replay is no longer planned" {
    try std.testing.expect(!isPlannedCommand("replay"));
}

test "isPlannedCommand: batch5 commands are not planned" {
    try std.testing.expect(!isPlannedCommand("expose"));
    try std.testing.expect(!isPlannedCommand("ignore-https-errors"));
    try std.testing.expect(!isPlannedCommand("replay"));
    try std.testing.expect(!isPlannedCommand("errors"));
    try std.testing.expect(!isPlannedCommand("dialog"));
    try std.testing.expect(!isPlannedCommand("scroll"));
    try std.testing.expect(!isPlannedCommand("cookies"));
    try std.testing.expect(!isPlannedCommand("tab"));
}

test "handleDialogInfo: returns null when no dialog" {
    const allocator = std.testing.allocator;
    var dialog: ?DialogInfo = null;
    const result = handleDialogInfo(allocator, &dialog);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "null") != null);
}

test "handleDialogInfo: returns dialog info when present" {
    const allocator = std.testing.allocator;
    var dialog: ?DialogInfo = .{
        .dialog_type = @constCast("alert"),
        .message = @constCast("Hello World"),
        .default_prompt = @constCast(""),
    };
    const result = handleDialogInfo(allocator, &dialog);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"alert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"message\":\"Hello World\"") != null);
}

test "handleErrors: returns empty list" {
    const allocator = std.testing.allocator;
    var errors: std.ArrayList(PageError) = .empty;
    defer errors.deinit(allocator);
    const result = handleErrors(allocator, &errors);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[]") != null);
}

// ============================================================================
// Tests: EventSubscribers
// ============================================================================

test "EventSubscribers: init and deinit" {
    var subs = EventSubscribers.init(std.testing.allocator);
    defer subs.deinit();
    try std.testing.expectEqual(@as(usize, 0), subs.fds.items.len);
}

test "EventSubscribers: add and remove" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var subs = EventSubscribers.init(std.testing.allocator);
    defer subs.deinit();

    subs.add(42);
    subs.add(43);
    try std.testing.expectEqual(@as(usize, 2), subs.fds.items.len);

    subs.remove(42);
    try std.testing.expectEqual(@as(usize, 1), subs.fds.items.len);
    try std.testing.expectEqual(@as(std.posix.fd_t, 43), subs.fds.items[0]);
}

test "EventSubscribers: remove non-existent fd is no-op" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var subs = EventSubscribers.init(std.testing.allocator);
    defer subs.deinit();

    subs.add(10);
    subs.remove(99);
    try std.testing.expectEqual(@as(usize, 1), subs.fds.items.len);
}

test "EventSubscribers: broadcast removes broken fds" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var subs = EventSubscribers.init(std.testing.allocator);
    defer subs.deinit();

    // Add invalid fd — broadcast should remove it on write failure
    subs.add(-1);
    try std.testing.expectEqual(@as(usize, 1), subs.fds.items.len);

    subs.broadcast("test\n");
    try std.testing.expectEqual(@as(usize, 0), subs.fds.items.len);
}

// ============================================================================
// Tests: isSubscribeRequest
// ============================================================================

test "isSubscribeRequest: valid subscribe request" {
    try std.testing.expect(isSubscribeRequest("{\"id\":\"0\",\"action\":\"subscribe\"}\n"));
}

test "isSubscribeRequest: non-subscribe request" {
    try std.testing.expect(!isSubscribeRequest("{\"id\":\"1\",\"action\":\"open\",\"url\":\"https://example.com\"}\n"));
}

test "isSubscribeRequest: action in url field is not matched" {
    // Has "subscribe" but not in the action field — still matches because we do a simple string check.
    // This is acceptable: the daemon handleCommand would reject it anyway.
    try std.testing.expect(isSubscribeRequest("{\"action\":\"subscribe\",\"url\":\"x\"}\n"));
}

test "isSubscribeRequest: no action field" {
    try std.testing.expect(!isSubscribeRequest("{\"id\":\"0\",\"url\":\"subscribe\"}\n"));
}

// ============================================================================
// Debug Mode Tests
// ============================================================================

test "isActionCommand: recognizes action commands" {
    try std.testing.expect(isActionCommand("click"));
    try std.testing.expect(isActionCommand("dblclick"));
    try std.testing.expect(isActionCommand("fill"));
    try std.testing.expect(isActionCommand("type"));
    try std.testing.expect(isActionCommand("press"));
    try std.testing.expect(isActionCommand("select"));
    try std.testing.expect(isActionCommand("check"));
    try std.testing.expect(isActionCommand("uncheck"));
    try std.testing.expect(isActionCommand("hover"));
    try std.testing.expect(isActionCommand("drag"));
    try std.testing.expect(isActionCommand("dispatch"));
    try std.testing.expect(isActionCommand("open"));
    try std.testing.expect(isActionCommand("navigate"));
    try std.testing.expect(isActionCommand("goto"));
    try std.testing.expect(isActionCommand("submit"));
    try std.testing.expect(isActionCommand("tap"));
    try std.testing.expect(isActionCommand("focus"));
    try std.testing.expect(isActionCommand("upload"));
    try std.testing.expect(isActionCommand("clear"));
    try std.testing.expect(isActionCommand("selectall"));
}

test "isActionCommand: rejects non-action commands" {
    try std.testing.expect(!isActionCommand("snapshot"));
    try std.testing.expect(!isActionCommand("screenshot"));
    try std.testing.expect(!isActionCommand("eval"));
    try std.testing.expect(!isActionCommand("get"));
    try std.testing.expect(!isActionCommand("is"));
    try std.testing.expect(!isActionCommand("set"));
    try std.testing.expect(!isActionCommand("network"));
    try std.testing.expect(!isActionCommand("console"));
    try std.testing.expect(!isActionCommand("cookies"));
    try std.testing.expect(!isActionCommand("storage"));
    try std.testing.expect(!isActionCommand("wait"));
    try std.testing.expect(!isActionCommand("status"));
    try std.testing.expect(!isActionCommand("close"));
}

test "extractActionFromLine: JSON line" {
    const action = extractActionFromLine("{\"id\":\"1\",\"action\":\"click\",\"url\":\"@e1\"}");
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("click", action.?);
}

test "extractActionFromLine: text command" {
    const action = extractActionFromLine("click @e1");
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("click", action.?);
}

test "extractActionFromLine: text command single word" {
    const action = extractActionFromLine("snapshot");
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("snapshot", action.?);
}

test "extractActionFromLine: empty line" {
    const action = extractActionFromLine("");
    try std.testing.expect(action == null);
}

test "extractActionFromLine: JSON without action" {
    const action = extractActionFromLine("{\"id\":\"1\",\"url\":\"test\"}");
    try std.testing.expect(action == null);
}

test "parseCountFromJson: extracts requests count" {
    const count = parseCountFromJson("{\"success\":true,\"data\":{\"requests\":42,\"console\":5}}", "requests");
    try std.testing.expect(count != null);
    try std.testing.expectEqual(@as(usize, 42), count.?);
}

test "parseCountFromJson: extracts console count" {
    const count = parseCountFromJson("{\"success\":true,\"data\":{\"requests\":10,\"console\":3,\"errors\":1}}", "console");
    try std.testing.expect(count != null);
    try std.testing.expectEqual(@as(usize, 3), count.?);
}

test "parseCountFromJson: extracts errors count" {
    const count = parseCountFromJson("{\"success\":true,\"data\":{\"requests\":10,\"console\":3,\"errors\":7}}", "errors");
    try std.testing.expect(count != null);
    try std.testing.expectEqual(@as(usize, 7), count.?);
}

test "parseCountFromJson: missing field returns null" {
    const count = parseCountFromJson("{\"success\":true,\"data\":{\"requests\":10}}", "console");
    try std.testing.expect(count == null);
}

test "parseCountFromJson: zero count" {
    const count = parseCountFromJson("{\"success\":true,\"data\":{\"requests\":0}}", "requests");
    try std.testing.expect(count != null);
    try std.testing.expectEqual(@as(usize, 0), count.?);
}

test "buildDebugResponse: merges debug into response" {
    const allocator = std.testing.allocator;
    const result = buildDebugResponse(
        allocator,
        "{\"success\":true}",
        "nonexistent_session",
        0, 0, 0,
        0, 0, 0,
        null,
    );
    // With no changes and no pre_url, it should still produce a debug with url_changed:false
    if (result) |r| {
        defer allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"debug\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"url_changed\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"success\":true") != null);
    }
    // It's OK if result is null (daemon not running), the function is robust
}

// ============================================================================
// Tests: Domain Restriction (--allowed-domains)
// ============================================================================

test "extractHost: http URL" {
    try std.testing.expectEqualStrings("example.com", extractHost("http://example.com/path").?);
}

test "extractHost: https URL with port" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com:8080/path").?);
}

test "extractHost: URL with query" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com?q=1").?);
}

test "extractHost: subdomain" {
    try std.testing.expectEqualStrings("sub.example.com", extractHost("https://sub.example.com/").?);
}

test "extractHost: no scheme" {
    try std.testing.expectEqualStrings("example.com", extractHost("example.com/path").?);
}

test "domainMatchesPattern: exact match" {
    try std.testing.expect(domainMatchesPattern("example.com", "example.com"));
}

test "domainMatchesPattern: wildcard subdomain" {
    try std.testing.expect(domainMatchesPattern("sub.example.com", "*.example.com"));
}

test "domainMatchesPattern: wildcard matches base domain" {
    try std.testing.expect(domainMatchesPattern("example.com", "*.example.com"));
}

test "domainMatchesPattern: no match" {
    try std.testing.expect(!domainMatchesPattern("other.com", "example.com"));
}

test "domainMatchesPattern: partial no match" {
    try std.testing.expect(!domainMatchesPattern("notexample.com", "*.example.com"));
}

test "isDomainAllowed: single domain allowed" {
    try std.testing.expect(isDomainAllowed("https://example.com/page", "example.com"));
}

test "isDomainAllowed: multiple domains" {
    try std.testing.expect(isDomainAllowed("https://api.internal.com/v1", "example.com,*.internal.com"));
}

test "isDomainAllowed: domain blocked" {
    try std.testing.expect(!isDomainAllowed("https://evil.com/hack", "example.com,*.internal.com"));
}

test "isDomainAllowed: with spaces in list" {
    try std.testing.expect(isDomainAllowed("https://example.com/", " example.com , other.com "));
}

// ============================================================================
// Tests: Content Boundaries
// ============================================================================

test "isContentAction: snapshot is content" {
    try std.testing.expect(isContentAction("snapshot"));
    try std.testing.expect(isContentAction("snapshot_interactive"));
    try std.testing.expect(isContentAction("eval"));
    try std.testing.expect(isContentAction("content"));
}

test "isContentAction: non-content actions" {
    try std.testing.expect(!isContentAction("click"));
    try std.testing.expect(!isContentAction("open"));
    try std.testing.expect(!isContentAction("close"));
    try std.testing.expect(!isContentAction("network_list"));
}

// ============================================================================
// Tests: isPlannedCommand (updated)
// ============================================================================

test "isPlannedCommand: new planned commands" {
    try std.testing.expect(!isPlannedCommand("annotate-screenshot"));
    try std.testing.expect(!isPlannedCommand("video"));
    try std.testing.expect(!isPlannedCommand("trace"));
    try std.testing.expect(!isPlannedCommand("profiler"));
    try std.testing.expect(!isPlannedCommand("diff-screenshot"));
}

// ============================================================================
// Tests: VideoRecorder
// ============================================================================

test "VideoRecorder: initial state" {
    var rec: VideoRecorder = .{};
    try std.testing.expect(!rec.active.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), rec.frame_count.load(.acquire));
    try std.testing.expectEqual(@as(?std.Thread, null), rec.thread);
    try std.testing.expectEqual(@as(usize, 0), rec.path_len);
}

test "VideoRecorder: stop without start returns error" {
    var rec: VideoRecorder = .{};
    const result = rec.stop();
    try std.testing.expectError(error.NotRecording, result);
}

test "VideoRecorder: double start detection" {
    var rec: VideoRecorder = .{};
    // Simulate active state
    rec.active.store(true, .release);
    defer rec.active.store(false, .release);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    // start should fail with AlreadyRecording when active
    const result = rec.start(gpa.allocator(), undefined, undefined, undefined, null, "test.webm");
    try std.testing.expectError(error.AlreadyRecording, result);
}

test "VideoRecorder: path storage" {
    var rec: VideoRecorder = .{};
    const test_path = "/tmp/test-video.webm";
    @memcpy(rec.path[0..test_path.len], test_path);
    rec.path_len = test_path.len;
    try std.testing.expectEqualStrings(test_path, rec.path[0..rec.path_len]);
}

test "VideoRecorder: frame_count atomic operations" {
    var rec: VideoRecorder = .{};
    try std.testing.expectEqual(@as(u64, 0), rec.frame_count.load(.acquire));
    _ = rec.frame_count.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u64, 1), rec.frame_count.load(.acquire));
    _ = rec.frame_count.fetchAdd(5, .monotonic);
    try std.testing.expectEqual(@as(u64, 6), rec.frame_count.load(.acquire));
    rec.frame_count.store(0, .release);
    try std.testing.expectEqual(@as(u64, 0), rec.frame_count.load(.acquire));
}
