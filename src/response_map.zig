const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Thread-safe map for CDP responses keyed by command ID.
/// Receiver thread puts responses, main thread waits for them.
pub const ResponseMap = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    entries: std.AutoHashMap(u64, []u8),
    allocator: Allocator,
    shutdown: bool = false,

    pub fn init(allocator: Allocator) ResponseMap {
        return .{
            .entries = std.AutoHashMap(u64, []u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResponseMap) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Called by receiver thread. Transfers ownership of msg bytes.
    pub fn put(self: *ResponseMap, id: u64, msg: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If there's already an unclaimed response for this ID, free it
        if (self.entries.fetchRemove(id)) |old| {
            self.allocator.free(old.value);
        }

        self.entries.put(id, msg) catch {
            self.allocator.free(msg);
            return;
        };
        self.condition.broadcast();
    }

    /// Called by main thread. Blocks until response arrives or timeout.
    /// Returns owned bytes (caller must free) or null on timeout/shutdown.
    pub fn wait(self: *ResponseMap, id: u64, timeout_ms: u32) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;
        var timer = std.time.Timer.start() catch return self.pollLocked(id);
        while (true) {
            // Check if response already arrived
            if (self.entries.fetchRemove(id)) |entry| {
                return entry.value;
            }
            if (self.shutdown) return null;

            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return null;

            const remaining = timeout_ns - elapsed;
            self.condition.timedWait(&self.mutex, remaining) catch {
                // Timeout
                if (self.entries.fetchRemove(id)) |entry| {
                    return entry.value;
                }
                return null;
            };
        }
    }

    fn pollLocked(self: *ResponseMap, id: u64) ?[]u8 {
        if (self.entries.fetchRemove(id)) |entry| {
            return entry.value;
        }
        return null;
    }

    /// Unblocks all waiting threads (for shutdown).
    pub fn signalShutdown(self: *ResponseMap) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown = true;
        self.condition.broadcast();
    }

    /// Remove stale entries (responses that were never waited for).
    /// Called periodically from main thread during idle.
    pub fn pruneStale(self: *ResponseMap, max_entries: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.entries.count() > max_entries) {
            var it = self.entries.iterator();
            if (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
                self.entries.removeByPtr(entry.key_ptr);
            } else break;
        }
    }
};

// Tests

test "ResponseMap: put and immediate wait" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const msg = try testing.allocator.dupe(u8, "response data");
    map.put(42, msg);

    const result = map.wait(42, 1000);
    try testing.expect(result != null);
    try testing.expectEqualStrings("response data", result.?);
    testing.allocator.free(result.?);
}

test "ResponseMap: wait timeout returns null" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const result = map.wait(99, 10); // 10ms timeout
    try testing.expect(result == null);
}

test "ResponseMap: put overwrites unclaimed" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const msg1 = try testing.allocator.dupe(u8, "first");
    const msg2 = try testing.allocator.dupe(u8, "second");
    map.put(1, msg1);
    map.put(1, msg2); // should free msg1

    const result = map.wait(1, 100);
    try testing.expect(result != null);
    try testing.expectEqualStrings("second", result.?);
    testing.allocator.free(result.?);
}

test "ResponseMap: shutdown unblocks wait" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    map.signalShutdown();
    const result = map.wait(1, 5000);
    try testing.expect(result == null);
}

test "ResponseMap: concurrent put and wait" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const handle = try std.Thread.spawn(.{}, struct {
        fn run(m: *ResponseMap) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            const msg = testing.allocator.dupe(u8, "async response") catch return;
            m.put(7, msg);
        }
    }.run, .{&map});

    const result = map.wait(7, 5000);
    try testing.expect(result != null);
    try testing.expectEqualStrings("async response", result.?);
    testing.allocator.free(result.?);
    handle.join();
}

test "ResponseMap: pruneStale" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    for (0..10) |i| {
        const msg = try testing.allocator.dupe(u8, "x");
        map.put(i, msg);
    }

    try testing.expectEqual(@as(usize, 10), map.entries.count());
    map.pruneStale(5);
    try testing.expect(map.entries.count() <= 5);
}

test "ResponseMap: multiple waiters get their own responses" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const NUM_WAITERS = 8;
    var results: [NUM_WAITERS]?[]u8 = .{null} ** NUM_WAITERS;
    var handles: [NUM_WAITERS]?std.Thread = .{null} ** NUM_WAITERS;

    // Spawn waiter threads — each waits for its own ID
    for (0..NUM_WAITERS) |i| {
        handles[i] = try std.Thread.spawn(.{}, struct {
            fn run(m: *ResponseMap, slot: *?[]u8, id: u64) void {
                slot.* = m.wait(id, 5000);
            }
        }.run, .{ &map, &results[i], @as(u64, i + 100) });
    }

    // Small delay, then put responses
    std.Thread.sleep(5 * std.time.ns_per_ms);
    for (0..NUM_WAITERS) |i| {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "resp-{d}", .{i}) catch "?";
        const msg = testing.allocator.dupe(u8, text) catch continue;
        map.put(@as(u64, i + 100), msg);
    }

    // Join and verify
    for (0..NUM_WAITERS) |i| {
        if (handles[i]) |h| h.join();
        try testing.expect(results[i] != null);
        var expected_buf: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "resp-{d}", .{i}) catch "?";
        try testing.expectEqualStrings(expected, results[i].?);
        testing.allocator.free(results[i].?);
    }
}

test "ResponseMap: stress — 100 concurrent put/wait pairs" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const N = 100;
    var handles: [N]?std.Thread = .{null} ** N;
    var ok_count = std.atomic.Value(u32).init(0);

    // Each thread: put response with its ID, then wait for (ID + N) response
    for (0..N) |i| {
        handles[i] = std.Thread.spawn(.{}, struct {
            fn run(m: *ResponseMap, id: usize, ok: *std.atomic.Value(u32)) void {
                // Put own response
                const msg = testing.allocator.dupe(u8, "ok") catch return;
                m.put(@intCast(id), msg);

                // Small jitter
                std.Thread.sleep(@as(u64, @intCast(id % 5)) * std.time.ns_per_ms);

                // Wait for partner response
                const result = m.wait(@as(u64, id + N), 3000);
                if (result) |r| {
                    testing.allocator.free(r);
                    _ = ok.fetchAdd(1, .monotonic);
                }
            }
        }.run, .{ &map, i, &ok_count }) catch null;
    }

    // Put partner responses
    std.Thread.sleep(10 * std.time.ns_per_ms);
    for (0..N) |i| {
        const msg = testing.allocator.dupe(u8, "partner") catch continue;
        map.put(@as(u64, i + N), msg);
    }

    // Join all
    for (&handles) |*h| {
        if (h.*) |handle| handle.join();
    }

    try testing.expectEqual(@as(u32, N), ok_count.load(.monotonic));
}

test "ResponseMap: shutdown unblocks multiple waiters" {
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const N = 4;
    var got_null: [N]std.atomic.Value(bool) = undefined;
    var handles: [N]?std.Thread = .{null} ** N;

    for (0..N) |i| {
        got_null[i] = std.atomic.Value(bool).init(false);
        handles[i] = std.Thread.spawn(.{}, struct {
            fn run(m: *ResponseMap, flag: *std.atomic.Value(bool), id: u64) void {
                const result = m.wait(id, 30_000); // long timeout
                if (result == null) flag.store(true, .release);
            }
        }.run, .{ &map, &got_null[i], @as(u64, i + 200) }) catch null;
    }

    std.Thread.sleep(20 * std.time.ns_per_ms);
    map.signalShutdown();

    for (0..N) |i| {
        if (handles[i]) |h| h.join();
        try testing.expect(got_null[i].load(.acquire));
    }
}

test "ResponseMap: wait returns correct data under contention" {
    // Multiple threads put different values for different IDs simultaneously
    var map = ResponseMap.init(testing.allocator);
    defer map.deinit();

    const WRITERS = 10;
    const MSGS_PER_WRITER = 10;
    var writer_handles: [WRITERS]?std.Thread = .{null} ** WRITERS;

    for (0..WRITERS) |w| {
        writer_handles[w] = std.Thread.spawn(.{}, struct {
            fn run(m: *ResponseMap, writer_id: usize) void {
                for (0..MSGS_PER_WRITER) |msg_i| {
                    const id: u64 = @intCast(writer_id * MSGS_PER_WRITER + msg_i);
                    var buf: [64]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "w{d}m{d}", .{ writer_id, msg_i }) catch "?";
                    const msg = testing.allocator.dupe(u8, text) catch continue;
                    m.put(id, msg);
                }
            }
        }.run, .{ &map, w }) catch null;
    }

    for (&writer_handles) |*h| {
        if (h.*) |handle| handle.join();
    }

    // Verify all messages are retrievable
    var found: usize = 0;
    for (0..WRITERS) |w| {
        for (0..MSGS_PER_WRITER) |msg_i| {
            const id: u64 = @intCast(w * MSGS_PER_WRITER + msg_i);
            if (map.wait(id, 10)) |result| {
                var expected_buf: [64]u8 = undefined;
                const expected = std.fmt.bufPrint(&expected_buf, "w{d}m{d}", .{ w, msg_i }) catch "?";
                testing.expectEqualStrings(expected, result) catch {};
                testing.allocator.free(result);
                found += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, WRITERS * MSGS_PER_WRITER), found);
}
