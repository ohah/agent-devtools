const std = @import("std");
const chrome = @import("agent_devtools").chrome;

const version = "0.1.0";

pub fn main() void {
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip executable name

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
        var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa_impl.deinit();
        const allocator = gpa_impl.allocator();

        const args = chrome.buildChromeArgs(allocator, .{}) catch {
            writeErr("Failed to build Chrome args\n", .{});
            std.process.exit(1);
        };
        defer chrome.freeChromeArgs(allocator, args);

        for (args) |arg| write("{s}\n", .{arg});
    } else if (isPlannedCommand(command)) {
        writeErr("{s}: not yet implemented (Phase 2+)\n", .{command});
        std.process.exit(1);
    } else {
        writeErr("Unknown command: {s}\nRun 'agent-devtools --help' for usage.\n", .{command});
        std.process.exit(1);
    }
}

fn isPlannedCommand(cmd: []const u8) bool {
    const planned = [_][]const u8{ "analyze", "network", "intercept", "record", "replay", "diff" };
    for (planned) |p| {
        if (std.mem.eql(u8, cmd, p)) return true;
    }
    return false;
}

fn write(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    out.print(fmt, args) catch {};
    out.flush() catch {};
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const out = &w.interface;
    out.print(fmt, args) catch {};
    out.flush() catch {};
}

fn printUsage() void {
    write(
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
    , .{});
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, version, ".") != null);
}

test "isPlannedCommand: recognizes planned commands" {
    try std.testing.expect(isPlannedCommand("analyze"));
    try std.testing.expect(isPlannedCommand("network"));
    try std.testing.expect(isPlannedCommand("intercept"));
    try std.testing.expect(isPlannedCommand("record"));
    try std.testing.expect(isPlannedCommand("replay"));
    try std.testing.expect(isPlannedCommand("diff"));
}

test "isPlannedCommand: rejects unknown commands" {
    try std.testing.expect(!isPlannedCommand("bogus"));
    try std.testing.expect(!isPlannedCommand(""));
    try std.testing.expect(!isPlannedCommand("--help"));
}
