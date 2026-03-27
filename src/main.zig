const std = @import("std");
const chrome = @import("agent_devtools").chrome;
const cdp = @import("agent_devtools").cdp;

const version = "0.1.0";

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        printVersion();
        return;
    }

    if (std.mem.eql(u8, command, "find-chrome")) {
        runFindChrome();
        return;
    }

    if (std.mem.eql(u8, command, "chrome-args")) {
        try runChromeArgs(allocator);
        return;
    }

    // Unknown command
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print("Unknown command: {s}\n", .{command});
    try stderr.print("Run 'agent-devtools --help' for usage.\n", .{});
    try stderr.flush();
    std.process.exit(1);
}

fn printUsage() void {
    const usage =
        \\agent-devtools - Browser DevTools CLI for AI agents
        \\
        \\Usage: agent-devtools <command> [options]
        \\
        \\Commands:
        \\  find-chrome      Find Chrome executable on the system
        \\  chrome-args      Print Chrome launch arguments for automation
        \\
        \\  (Phase 2+)
        \\  analyze <url>    Reverse-engineer web app API schema
        \\  network list     List captured network requests
        \\  intercept        Intercept and modify network requests
        \\  record <name>    Record a browsing flow
        \\  replay <name>    Replay and compare a recorded flow
        \\  diff <baseline>  Compare against baseline
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -v, --version    Show version
        \\
    ;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    stdout.writeAll(usage) catch {};
    stdout.flush() catch {};
}

fn printVersion() void {
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    stdout.print("agent-devtools {s}\n", .{version}) catch {};
    stdout.flush() catch {};
}

fn runFindChrome() void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    if (chrome.findChrome()) |path| {
        stdout.print("{s}\n", .{path}) catch {};
    } else {
        stdout.writeAll("Chrome not found.\n") catch {};
    }
    stdout.flush() catch {};
}

fn runChromeArgs(allocator: std.mem.Allocator) !void {
    const args = try chrome.buildChromeArgs(allocator, .{});
    defer chrome.freeChromeArgs(allocator, args);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    for (args) |arg| {
        try stdout.print("{s}\n", .{arg});
    }
    try stdout.flush();
}

// ============================================================================
// Tests
// ============================================================================

test "version string is set" {
    try std.testing.expect(version.len > 0);
}
