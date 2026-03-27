const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// ============================================================================
// Types
// ============================================================================

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _, // reserved opcodes
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    mask_key: [4]u8,
    payload: []const u8,
};

pub const DecodeResult = struct {
    frame: Frame,
    bytes_consumed: usize,
};

pub const DecodeError = error{
    InsufficientData,
    ReservedBitsSet,
    ReservedOpcode,
    ControlFrameTooLarge,
    FragmentedControlFrame,
    NonMinimalLengthEncoding,
    InvalidPayloadLength,
    InvalidClosePayload,
};

pub const EncodeError = error{
    PayloadTooLarge,
} || Allocator.Error;

// ============================================================================
// Constants
// ============================================================================

const HANDSHAKE_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_PAYLOAD_SIZE: u64 = 1 << 48; // 256TB, practical limit

// ============================================================================
// Core Functions
// ============================================================================

/// Decode a WebSocket frame from raw bytes.
/// Returns the decoded frame and number of bytes consumed.
/// The payload slice points into the input data (zero-copy for unmasked frames).
pub fn decode(data: []const u8) DecodeError!DecodeResult {
    if (data.len < 2) return error.InsufficientData;

    const byte0 = data[0];
    const byte1 = data[1];

    const fin = byte0 & 0x80 != 0;
    if (byte0 & 0x70 != 0) return error.ReservedBitsSet;

    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(byte0)));
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        _ => return error.ReservedOpcode,
    }

    if (isControlOpcode(opcode) and !fin) return error.FragmentedControlFrame;

    const masked = byte1 & 0x80 != 0;
    const len7: u7 = @truncate(byte1);

    var offset: usize = 2;
    const payload_len: u64 = switch (len7) {
        126 => blk: {
            if (data.len < offset + 2) return error.InsufficientData;
            const len = std.mem.readInt(u16, data[offset..][0..2], .big);
            // RFC 6455: minimal encoding — 16-bit form must encode values >= 126
            if (len < 126) return error.NonMinimalLengthEncoding;
            offset += 2;
            break :blk len;
        },
        127 => blk: {
            if (data.len < offset + 8) return error.InsufficientData;
            const len = std.mem.readInt(u64, data[offset..][0..8], .big);
            // RFC 6455: MSB must be 0
            if (len >> 63 != 0) return error.InvalidPayloadLength;
            // RFC 6455: minimal encoding — 64-bit form must encode values >= 65536
            if (len <= 65535) return error.NonMinimalLengthEncoding;
            offset += 8;
            break :blk len;
        },
        else => len7,
    };

    if (isControlOpcode(opcode) and payload_len > 125) {
        return error.ControlFrameTooLarge;
    }

    if (opcode == .close and payload_len == 1) {
        return error.InvalidClosePayload;
    }

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (data.len < offset + 4) return error.InsufficientData;
        @memcpy(&mask_key, data[offset..][0..4]);
        offset += 4;
    }

    const payload_usize: usize = std.math.cast(usize, payload_len) orelse
        return error.InsufficientData;

    if (data.len < offset + payload_usize) return error.InsufficientData;

    const payload = data[offset .. offset + payload_usize];

    return .{
        .frame = .{
            .fin = fin,
            .opcode = opcode,
            .masked = masked,
            .mask_key = mask_key,
            .payload = payload,
        },
        .bytes_consumed = offset + payload_usize,
    };
}

/// Encode a WebSocket frame. Client frames are always masked.
/// Uses provided mask_key for deterministic testing.
pub fn encodeWithMask(allocator: Allocator, opcode: Opcode, payload: []const u8, mask_key: [4]u8) EncodeError![]u8 {
    if (payload.len > MAX_PAYLOAD_SIZE) return error.PayloadTooLarge;

    // Calculate header size
    var header_len: usize = 2;
    if (payload.len >= 126 and payload.len <= 65535) {
        header_len += 2;
    } else if (payload.len > 65535) {
        header_len += 8;
    }
    header_len += 4; // mask key (client always masks)

    const total_len = header_len + payload.len;
    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    // Byte 0: FIN + opcode
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));

    // Byte 1: MASK + payload length
    var offset: usize = 2;
    if (payload.len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 65535) {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[2..][0..2], @intCast(payload.len), .big);
        offset += 2;
    } else {
        buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, buf[2..][0..8], @intCast(payload.len), .big);
        offset += 8;
    }

    // Mask key
    @memcpy(buf[offset..][0..4], &mask_key);
    offset += 4;

    // Copy and mask in a single pass
    const dest = buf[offset..][0..payload.len];
    for (dest, payload, 0..) |*d, p, i| {
        d.* = p ^ mask_key[i % 4];
    }

    return buf;
}

/// Encode a WebSocket frame with a random mask key.
pub fn encode(allocator: Allocator, opcode: Opcode, payload: []const u8) EncodeError![]u8 {
    var mask_key: [4]u8 = undefined;
    std.crypto.random.bytes(&mask_key);
    return encodeWithMask(allocator, opcode, payload, mask_key);
}

/// Encode a close frame with status code and reason.
/// Uses stack buffer since close payloads are at most 125 bytes (RFC 6455).
pub fn encodeClose(allocator: Allocator, status_code: u16, reason: []const u8) EncodeError![]u8 {
    if (2 + reason.len > 125) return error.PayloadTooLarge;

    var payload_buf: [125]u8 = undefined;
    std.mem.writeInt(u16, payload_buf[0..2], status_code, .big);
    @memcpy(payload_buf[2..][0..reason.len], reason);

    return encode(allocator, .close, payload_buf[0 .. 2 + reason.len]);
}

/// Apply or remove XOR masking in-place.
pub fn applyMask(data: []u8, mask_key: [4]u8) void {
    for (data, 0..) |*byte, i| {
        byte.* ^= mask_key[i % 4];
    }
}

/// Unmask a frame's payload, returning a newly allocated buffer.
/// If the frame is not masked, returns a copy of the payload.
pub fn unmaskPayload(allocator: Allocator, frame: Frame) ![]u8 {
    const buf = try allocator.alloc(u8, frame.payload.len);
    @memcpy(buf, frame.payload);
    if (frame.masked) {
        applyMask(buf, frame.mask_key);
    }
    return buf;
}

/// Compute the Sec-WebSocket-Accept value for a given key.
/// Returns a 28-byte base64-encoded string.
pub fn computeAcceptKey(key: []const u8) [28]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(HANDSHAKE_GUID);
    const digest = hasher.finalResult();

    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &digest);
    return result;
}

/// Generate a random 16-byte key and return it as 24-byte base64.
pub fn generateHandshakeKey() [24]u8 {
    var raw_key: [16]u8 = undefined;
    std.crypto.random.bytes(&raw_key);

    var encoded: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &raw_key);
    return encoded;
}

/// Build the HTTP upgrade request for WebSocket handshake.
pub fn buildHandshakeRequest(allocator: Allocator, host: []const u8, path: []const u8, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n", .{ path, host, key });
}

// ============================================================================
// Helpers
// ============================================================================

fn isControlOpcode(opcode: Opcode) bool {
    return @intFromEnum(opcode) >= 0x8;
}

/// Validate close frame status code per RFC 6455 Section 7.4.
/// Returns true if the status code is valid.
pub fn isValidCloseCode(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1011 => true, // RFC-defined
        3000...3999 => true, // IANA registered
        4000...4999 => true, // private use
        else => false,
    };
}

// ============================================================================
// Connection State Manager
// ============================================================================

/// Tracks WebSocket connection state for protocol-level validation.
/// Validates fragmentation sequence, close codes, and frame ordering.
pub const Connection = struct {
    /// Non-null when a fragmented message is in progress; holds the original opcode.
    fragment_opcode: ?Opcode,
    close_sent: bool,
    close_received: bool,

    pub const ConnectionError = error{
        UnexpectedContinuation,
        ExpectedContinuation,
        ClosePayloadTooShort,
        InvalidCloseCode,
        FrameAfterClose,
        ServerFrameMasked,
    };

    pub fn init() Connection {
        return .{
            .fragment_opcode = null,
            .close_sent = false,
            .close_received = false,
        };
    }

    pub fn inFragment(self: Connection) bool {
        return self.fragment_opcode != null;
    }

    /// Validate a decoded frame against connection state.
    pub fn validateFrame(self: *Connection, frame: Frame) ConnectionError!void {
        if (frame.masked) return error.ServerFrameMasked;

        if (self.close_received and !isControlOpcode(frame.opcode)) {
            return error.FrameAfterClose;
        }

        if (isControlOpcode(frame.opcode)) {
            if (frame.opcode == .close) {
                try validateClosePayload(frame.payload);
                self.close_received = true;
            }
            return;
        }

        if (frame.opcode == .continuation) {
            if (self.fragment_opcode == null) return error.UnexpectedContinuation;
            if (frame.fin) self.fragment_opcode = null;
        } else {
            if (self.fragment_opcode != null) return error.ExpectedContinuation;
            if (!frame.fin) self.fragment_opcode = frame.opcode;
        }
    }

    pub fn markCloseSent(self: *Connection) void {
        self.close_sent = true;
    }
};

fn validateClosePayload(payload: []const u8) Connection.ConnectionError!void {
    if (payload.len == 0) return;
    if (payload.len < 2) return error.ClosePayloadTooShort;

    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!isValidCloseCode(code)) return error.InvalidCloseCode;
}

// ============================================================================
// WebSocket Client (TCP + Handshake + Frame I/O)
// ============================================================================

pub const Client = struct {
    stream: std.net.Stream,
    allocator: Allocator,
    recv_buf: []u8,
    recv_len: usize,
    conn_state: Connection,

    pub const ConnectError = error{
        HandshakeFailed,
        InvalidAcceptKey,
    } || Allocator.Error || std.net.TcpConnectToHostError || std.net.Stream.ReadError;

    pub const SendError = EncodeError || std.net.Stream.WriteError;
    pub const RecvError = DecodeError || std.net.Stream.ReadError || error{ConnectionClosed};

    const RECV_BUF_SIZE = 64 * 1024; // 64KB receive buffer

    /// Connect to a WebSocket server at the given URL.
    /// URL format: ws://host:port/path
    pub fn connect(allocator: Allocator, url: []const u8) ConnectError!Client {
        const parsed = parseWsUrl(url) orelse return error.HandshakeFailed;

        const stream = try std.net.tcpConnectToHost(allocator, parsed.host, parsed.port);
        errdefer stream.close();

        const recv_buf = try allocator.alloc(u8, RECV_BUF_SIZE);
        errdefer allocator.free(recv_buf);

        var client = Client{
            .stream = stream,
            .allocator = allocator,
            .recv_buf = recv_buf,
            .recv_len = 0,
            .conn_state = Connection.init(),
        };

        try client.performHandshake(parsed.host, parsed.port, parsed.path);

        return client;
    }

    pub fn close(self: *Client) void {
        self.stream.close();
        self.allocator.free(self.recv_buf);
    }

    /// Send a text message over WebSocket.
    pub fn sendText(self: *Client, payload: []const u8) SendError!void {
        const frame = try encode(self.allocator, .text, payload);
        defer self.allocator.free(frame);

        var total_written: usize = 0;
        while (total_written < frame.len) {
            total_written += self.stream.write(frame[total_written..]) catch |err| switch (err) {
                error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
                else => return err,
            };
        }
    }

    /// Send a ping frame.
    pub fn sendPing(self: *Client) SendError!void {
        const frame = try encode(self.allocator, .ping, "");
        defer self.allocator.free(frame);

        _ = self.stream.write(frame) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
            else => return err,
        };
    }

    /// Send a close frame.
    pub fn sendClose(self: *Client, code: u16, reason: []const u8) SendError!void {
        const frame = try encodeClose(self.allocator, code, reason);
        defer self.allocator.free(frame);

        _ = self.stream.write(frame) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
            else => return err,
        };
        self.conn_state.markCloseSent();
    }

    /// Receive the next text/binary message. Handles ping/pong/close automatically.
    /// Returns the payload as an owned slice (caller must free).
    pub fn recvMessage(self: *Client) (RecvError || Allocator.Error)![]u8 {
        while (true) {
            // Try to decode a frame from the buffer
            if (self.recv_len > 0) {
                const result = decode(self.recv_buf[0..self.recv_len]) catch |err| switch (err) {
                    error.InsufficientData => {
                        // Need more data, fall through to read
                        if (self.recv_len >= self.recv_buf.len) {
                            // Buffer full but still insufficient — frame too large
                            return error.InsufficientData;
                        }
                        const n = self.stream.read(self.recv_buf[self.recv_len..]) catch |e| return e;
                        if (n == 0) return error.ConnectionClosed;
                        self.recv_len += n;
                        continue;
                    },
                    else => return err,
                };

                const frame = result.frame;

                // Shift consumed bytes
                const remaining = self.recv_len - result.bytes_consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.recv_buf[0..remaining], self.recv_buf[result.bytes_consumed..self.recv_len]);
                }
                self.recv_len = remaining;

                // Handle control frames automatically
                switch (frame.opcode) {
                    .ping => {
                        // Respond with pong (same payload)
                        const pong = encode(self.allocator, .pong, frame.payload) catch continue;
                        defer self.allocator.free(pong);
                        _ = self.stream.write(pong) catch {};
                        continue;
                    },
                    .pong => continue,
                    .close => {
                        self.conn_state.close_received = true;
                        return error.ConnectionClosed;
                    },
                    .text, .binary => {
                        // Return the payload as an owned copy
                        const payload = try self.allocator.alloc(u8, frame.payload.len);
                        @memcpy(payload, frame.payload);
                        return payload;
                    },
                    .continuation => continue, // TODO: fragmentation support
                    _ => continue,
                }
            }

            // Buffer empty, read from socket
            const n = self.stream.read(self.recv_buf[self.recv_len..]) catch |err| return err;
            if (n == 0) return error.ConnectionClosed;
            self.recv_len += n;
        }
    }

    fn performHandshake(self: *Client, host: []const u8, port: u16, path: []const u8) ConnectError!void {
        const key = generateHandshakeKey();

        // Build host header value
        var host_buf: [256]u8 = undefined;
        const host_header = std.fmt.bufPrint(&host_buf, "{s}:{d}", .{ host, port }) catch return error.HandshakeFailed;

        const request = buildHandshakeRequest(self.allocator, host_header, path, &key) catch return error.HandshakeFailed;
        defer self.allocator.free(request);

        // Send handshake request
        var written: usize = 0;
        while (written < request.len) {
            written += self.stream.write(request[written..]) catch |err| return err;
        }

        // Read response
        var response_buf: [4096]u8 = undefined;
        var response_len: usize = 0;

        while (response_len < response_buf.len) {
            const n = self.stream.read(response_buf[response_len..]) catch |err| return err;
            if (n == 0) return error.HandshakeFailed;
            response_len += n;

            // Check if we have the complete response (ends with \r\n\r\n)
            if (std.mem.indexOf(u8, response_buf[0..response_len], "\r\n\r\n")) |header_end| {
                const response = response_buf[0 .. header_end + 4];

                // Verify HTTP 101
                if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) return error.HandshakeFailed;

                // Verify Sec-WebSocket-Accept
                const expected_accept = computeAcceptKey(&key);
                if (std.mem.indexOf(u8, response, &expected_accept) == null) return error.InvalidAcceptKey;

                // Move any leftover data (after headers) into recv_buf
                const leftover_start = header_end + 4;
                const leftover_len = response_len - leftover_start;
                if (leftover_len > 0) {
                    @memcpy(self.recv_buf[0..leftover_len], response_buf[leftover_start..response_len]);
                    self.recv_len = leftover_len;
                }

                return;
            }
        }

        return error.HandshakeFailed;
    }
};

/// Parse ws://host:port/path URL into components.
fn parseWsUrl(url: []const u8) ?struct { host: []const u8, port: u16, path: []const u8 } {
    const prefix_len: usize = if (std.mem.startsWith(u8, url, "ws://"))
        5
    else if (std.mem.startsWith(u8, url, "wss://"))
        6
    else
        return null;

    const rest = url[prefix_len..];

    // Find path
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const path = if (path_start < rest.len) rest[path_start..] else "/";
    const host_port = rest[0..path_start];

    // Split host:port
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        const host = host_port[0..colon];
        const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return null;
        return .{ .host = host, .port = port, .path = path };
    }

    // No port — default based on scheme
    const default_port: u16 = if (prefix_len == 6) 443 else 80;
    return .{ .host = host_port, .port = default_port, .path = path };
}

// ============================================================================
// Tests: parseWsUrl
// ============================================================================

test "parseWsUrl: full URL" {
    const r = parseWsUrl("ws://127.0.0.1:9222/devtools/browser/abc").?;
    try testing.expectEqualStrings("127.0.0.1", r.host);
    try testing.expectEqual(@as(u16, 9222), r.port);
    try testing.expectEqualStrings("/devtools/browser/abc", r.path);
}

test "parseWsUrl: no path" {
    const r = parseWsUrl("ws://localhost:9222").?;
    try testing.expectEqualStrings("localhost", r.host);
    try testing.expectEqual(@as(u16, 9222), r.port);
    try testing.expectEqualStrings("/", r.path);
}

test "parseWsUrl: no port defaults to 80" {
    const r = parseWsUrl("ws://example.com/path").?;
    try testing.expectEqualStrings("example.com", r.host);
    try testing.expectEqual(@as(u16, 80), r.port);
    try testing.expectEqualStrings("/path", r.path);
}

test "parseWsUrl: wss defaults to 443" {
    const r = parseWsUrl("wss://example.com/path").?;
    try testing.expectEqual(@as(u16, 443), r.port);
}

test "parseWsUrl: invalid scheme" {
    try testing.expect(parseWsUrl("http://example.com") == null);
}

test "parseWsUrl: empty" {
    try testing.expect(parseWsUrl("") == null);
}

test "parseWsUrl: root path" {
    const r = parseWsUrl("ws://host:1234/").?;
    try testing.expectEqualStrings("/", r.path);
}

test "parseWsUrl: port only no host (edge)" {
    // ":9222" is not valid
    const r = parseWsUrl("ws://:9222/path");
    if (r) |result| {
        try testing.expectEqualStrings("", result.host);
    }
}

// ============================================================================
// Tests: Frame Decoding
// ============================================================================

test "decode: unmasked text frame 'hello'" {
    // FIN=1, opcode=text(1), MASK=0, len=5, "hello"
    const data = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const result = try decode(&data);

    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.text, result.frame.opcode);
    try testing.expect(!result.frame.masked);
    try testing.expectEqualStrings("hello", result.frame.payload);
    try testing.expectEqual(@as(usize, 7), result.bytes_consumed);
}

test "decode: unmasked binary frame" {
    const payload = [_]u8{ 0x00, 0xFF, 0x42, 0xAB };
    const data = [_]u8{ 0x82, 0x04 } ++ payload;
    const result = try decode(&data);

    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.binary, result.frame.opcode);
    try testing.expectEqualSlices(u8, &payload, result.frame.payload);
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed);
}

test "decode: empty payload" {
    const data = [_]u8{ 0x81, 0x00 };
    const result = try decode(&data);

    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.text, result.frame.opcode);
    try testing.expectEqual(@as(usize, 0), result.frame.payload.len);
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
}

test "decode: masked frame from client" {
    // FIN=1, opcode=text, MASK=1, len=5, mask=37fa213d, masked "Hello"
    const data = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    const result = try decode(&data);

    try testing.expect(result.frame.masked);
    try testing.expectEqual([4]u8{ 0x37, 0xfa, 0x21, 0x3d }, result.frame.mask_key);
    try testing.expectEqual(@as(usize, 11), result.bytes_consumed);

    // Unmask to verify
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqualStrings("Hello", unmasked);
}

test "decode: payload exactly 125 bytes (max 7-bit length)" {
    var data: [2 + 125]u8 = undefined;
    data[0] = 0x82; // FIN + binary
    data[1] = 125; // no mask
    for (data[2..]) |*b| b.* = 0xAA;

    const result = try decode(&data);
    try testing.expectEqual(@as(usize, 125), result.frame.payload.len);
    try testing.expectEqual(@as(usize, 127), result.bytes_consumed);
}

test "decode: payload exactly 126 bytes (16-bit extended length)" {
    var data: [4 + 126]u8 = undefined;
    data[0] = 0x82; // FIN + binary
    data[1] = 126; // 16-bit length follows
    std.mem.writeInt(u16, data[2..4], 126, .big);
    for (data[4..]) |*b| b.* = 0xBB;

    const result = try decode(&data);
    try testing.expectEqual(@as(usize, 126), result.frame.payload.len);
    try testing.expectEqual(@as(usize, 130), result.bytes_consumed);
}

test "decode: payload 1000 bytes (16-bit extended length)" {
    const payload_len: u16 = 1000;
    var data: [4 + payload_len]u8 = undefined;
    data[0] = 0x82;
    data[1] = 126;
    std.mem.writeInt(u16, data[2..4], payload_len, .big);
    for (data[4..]) |*b| b.* = 0xCC;

    const result = try decode(&data);
    try testing.expectEqual(@as(usize, 1000), result.frame.payload.len);
    try testing.expectEqual(@as(usize, 1004), result.bytes_consumed);
}

test "decode: payload 65535 bytes (max 16-bit length)" {
    const payload_len: usize = 65535;
    const buf = try testing.allocator.alloc(u8, 4 + payload_len);
    defer testing.allocator.free(buf);

    buf[0] = 0x82;
    buf[1] = 126;
    std.mem.writeInt(u16, buf[2..4], @intCast(payload_len), .big);
    @memset(buf[4..], 0xDD);

    const result = try decode(buf);
    try testing.expectEqual(@as(usize, 65535), result.frame.payload.len);
    try testing.expectEqual(@as(usize, 65539), result.bytes_consumed);
}

test "decode: payload 65536 bytes (64-bit extended length)" {
    const payload_len: u64 = 65536;
    const buf = try testing.allocator.alloc(u8, 10 + payload_len);
    defer testing.allocator.free(buf);

    buf[0] = 0x82;
    buf[1] = 127;
    std.mem.writeInt(u64, buf[2..10], payload_len, .big);
    @memset(buf[10..], 0xEE);

    const result = try decode(buf);
    try testing.expectEqual(@as(usize, 65536), result.frame.payload.len);
    try testing.expectEqual(@as(usize, 65546), result.bytes_consumed);
}

test "decode: ping frame" {
    const data = [_]u8{ 0x89, 0x04, 'p', 'i', 'n', 'g' };
    const result = try decode(&data);

    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.ping, result.frame.opcode);
    try testing.expectEqualStrings("ping", result.frame.payload);
}

test "decode: pong frame" {
    const data = [_]u8{ 0x8A, 0x04, 'p', 'o', 'n', 'g' };
    const result = try decode(&data);

    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.pong, result.frame.opcode);
    try testing.expectEqualStrings("pong", result.frame.payload);
}

test "decode: close frame with status code" {
    // Close, len=2, status=1000 (normal closure)
    const data = [_]u8{ 0x88, 0x02, 0x03, 0xE8 };
    const result = try decode(&data);

    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.close, result.frame.opcode);
    try testing.expectEqual(@as(usize, 2), result.frame.payload.len);

    const status = std.mem.readInt(u16, result.frame.payload[0..2], .big);
    try testing.expectEqual(@as(u16, 1000), status);
}

test "decode: close frame with status code and reason" {
    // Close, len=12, status=1001, reason="going away"
    const data = [_]u8{ 0x88, 0x0C, 0x03, 0xE9 } ++ "going away".*;
    const result = try decode(&data);

    try testing.expectEqual(Opcode.close, result.frame.opcode);
    const status = std.mem.readInt(u16, result.frame.payload[0..2], .big);
    try testing.expectEqual(@as(u16, 1001), status);
    try testing.expectEqualStrings("going away", result.frame.payload[2..]);
}

test "decode: close frame empty" {
    const data = [_]u8{ 0x88, 0x00 };
    const result = try decode(&data);

    try testing.expectEqual(Opcode.close, result.frame.opcode);
    try testing.expectEqual(@as(usize, 0), result.frame.payload.len);
}

test "decode: continuation frame (FIN=0)" {
    const data = [_]u8{ 0x00, 0x03, 'a', 'b', 'c' };
    const result = try decode(&data);

    try testing.expect(!result.frame.fin);
    try testing.expectEqual(Opcode.continuation, result.frame.opcode);
    try testing.expectEqualStrings("abc", result.frame.payload);
}

test "decode: fragmented text frame (FIN=0, opcode=text)" {
    const data = [_]u8{ 0x01, 0x03, 'a', 'b', 'c' };
    const result = try decode(&data);

    try testing.expect(!result.frame.fin);
    try testing.expectEqual(Opcode.text, result.frame.opcode);
}

test "decode: multiple frames in buffer" {
    // Frame 1: text "hi"
    // Frame 2: text "ok"
    const data = [_]u8{ 0x81, 0x02, 'h', 'i', 0x81, 0x02, 'o', 'k' };

    const r1 = try decode(&data);
    try testing.expectEqualStrings("hi", r1.frame.payload);
    try testing.expectEqual(@as(usize, 4), r1.bytes_consumed);

    const r2 = try decode(data[r1.bytes_consumed..]);
    try testing.expectEqualStrings("ok", r2.frame.payload);
    try testing.expectEqual(@as(usize, 4), r2.bytes_consumed);
}

// ============================================================================
// Tests: Decode Errors
// ============================================================================

test "decode error: insufficient data - empty" {
    try testing.expectError(error.InsufficientData, decode(&[_]u8{}));
}

test "decode error: insufficient data - 1 byte" {
    try testing.expectError(error.InsufficientData, decode(&[_]u8{0x81}));
}

test "decode error: insufficient data - header ok but payload truncated" {
    // Says 5 bytes payload, but only 3 available
    const data = [_]u8{ 0x81, 0x05, 'h', 'e', 'l' };
    try testing.expectError(error.InsufficientData, decode(&data));
}

test "decode error: insufficient data - 16-bit length truncated" {
    // len=126 but only 1 extra byte
    const data = [_]u8{ 0x81, 126, 0x00 };
    try testing.expectError(error.InsufficientData, decode(&data));
}

test "decode error: insufficient data - 64-bit length truncated" {
    // len=127 but only 4 extra bytes
    const data = [_]u8{ 0x81, 127, 0, 0, 0, 0 };
    try testing.expectError(error.InsufficientData, decode(&data));
}

test "decode error: insufficient data - mask key truncated" {
    // MASK=1, len=1, but no mask key bytes
    const data = [_]u8{ 0x81, 0x81 };
    try testing.expectError(error.InsufficientData, decode(&data));
}

test "decode error: reserved bits set (RSV1)" {
    const data = [_]u8{ 0xC1, 0x00 }; // RSV1=1
    try testing.expectError(error.ReservedBitsSet, decode(&data));
}

test "decode error: reserved bits set (RSV2)" {
    const data = [_]u8{ 0xA1, 0x00 }; // RSV2=1
    try testing.expectError(error.ReservedBitsSet, decode(&data));
}

test "decode error: reserved bits set (RSV3)" {
    const data = [_]u8{ 0x91, 0x00 }; // RSV3=1
    try testing.expectError(error.ReservedBitsSet, decode(&data));
}

test "decode error: control frame too large" {
    // Ping with 126-byte payload (max is 125)
    var data: [4 + 126]u8 = undefined;
    data[0] = 0x89; // FIN + ping
    data[1] = 126; // 16-bit length
    std.mem.writeInt(u16, data[2..4], 126, .big);
    @memset(data[4..], 0);

    try testing.expectError(error.ControlFrameTooLarge, decode(&data));
}

test "decode error: fragmented control frame" {
    // Ping with FIN=0 (not allowed)
    const data = [_]u8{ 0x09, 0x00 }; // FIN=0, ping
    try testing.expectError(error.FragmentedControlFrame, decode(&data));
}

test "decode error: reserved opcode 0x3" {
    const data = [_]u8{ 0x83, 0x00 }; // FIN=1, opcode=0x3
    try testing.expectError(error.ReservedOpcode, decode(&data));
}

test "decode error: reserved opcode 0x4" {
    const data = [_]u8{ 0x84, 0x00 };
    try testing.expectError(error.ReservedOpcode, decode(&data));
}

test "decode error: reserved opcode 0x5" {
    const data = [_]u8{ 0x85, 0x00 };
    try testing.expectError(error.ReservedOpcode, decode(&data));
}

test "decode error: reserved opcode 0xB" {
    const data = [_]u8{ 0x8B, 0x00 }; // FIN=1, opcode=0xB
    try testing.expectError(error.ReservedOpcode, decode(&data));
}

test "decode error: reserved opcode 0xF" {
    const data = [_]u8{ 0x8F, 0x00 }; // FIN=1, opcode=0xF
    try testing.expectError(error.ReservedOpcode, decode(&data));
}

test "decode error: non-minimal 16-bit length encoding (value < 126)" {
    // len7=126, but actual length=100 (should use 7-bit encoding)
    var data: [4 + 100]u8 = undefined;
    data[0] = 0x81; // FIN + text
    data[1] = 126; // 16-bit length
    std.mem.writeInt(u16, data[2..4], 100, .big); // non-minimal!
    @memset(data[4..], 'x');

    try testing.expectError(error.NonMinimalLengthEncoding, decode(&data));
}

test "decode error: non-minimal 64-bit length encoding (value <= 65535)" {
    // len7=127, but actual length=1000 (should use 16-bit encoding)
    var data: [10 + 1000]u8 = undefined;
    data[0] = 0x81;
    data[1] = 127; // 64-bit length
    std.mem.writeInt(u64, data[2..10], 1000, .big); // non-minimal!
    @memset(data[10..], 'x');

    try testing.expectError(error.NonMinimalLengthEncoding, decode(&data));
}

test "decode error: 64-bit length with MSB set" {
    // MSB of 64-bit length must be 0
    var data: [10]u8 = undefined;
    data[0] = 0x81;
    data[1] = 127;
    std.mem.writeInt(u64, data[2..10], @as(u64, 1) << 63, .big); // MSB set!

    try testing.expectError(error.InvalidPayloadLength, decode(&data));
}

test "decode error: close frame with 1-byte payload" {
    // Close payload must be 0 or >= 2
    const data = [_]u8{ 0x88, 0x01, 0xFF };
    try testing.expectError(error.InvalidClosePayload, decode(&data));
}

test "unmaskPayload: on unmasked frame returns copy" {
    const data = [_]u8{ 0x81, 0x03, 'a', 'b', 'c' };
    const result = try decode(&data);
    try testing.expect(!result.frame.masked);

    const payload = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("abc", payload);
}

// ============================================================================
// Tests: Frame Encoding
// ============================================================================

test "encode: text frame with fixed mask" {
    const mask_key = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    const buf = try encodeWithMask(testing.allocator, .text, "hello", mask_key);
    defer testing.allocator.free(buf);

    // Verify header
    try testing.expectEqual(@as(u8, 0x81), buf[0]); // FIN + text
    try testing.expectEqual(@as(u8, 0x85), buf[1]); // MASK + len=5

    // Verify mask key
    try testing.expectEqual(mask_key, buf[2..6].*);

    // Verify masked payload by decoding
    const result = try decode(buf);
    try testing.expect(result.frame.masked);

    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqualStrings("hello", unmasked);
}

test "encode: binary frame" {
    const payload = [_]u8{ 0x00, 0xFF, 0x42 };
    const mask_key = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const buf = try encodeWithMask(testing.allocator, .binary, &payload, mask_key);
    defer testing.allocator.free(buf);

    try testing.expectEqual(@as(u8, 0x82), buf[0]); // FIN + binary

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqualSlices(u8, &payload, unmasked);
}

test "encode: empty payload" {
    const mask_key = [4]u8{ 0, 0, 0, 0 };
    const buf = try encodeWithMask(testing.allocator, .text, "", mask_key);
    defer testing.allocator.free(buf);

    try testing.expectEqual(@as(u8, 0x81), buf[0]);
    try testing.expectEqual(@as(u8, 0x80), buf[1]); // MASK + len=0
    try testing.expectEqual(@as(usize, 6), buf.len); // header(2) + mask(4)
}

test "encode: ping frame" {
    const mask_key = [4]u8{ 1, 2, 3, 4 };
    const buf = try encodeWithMask(testing.allocator, .ping, "ping", mask_key);
    defer testing.allocator.free(buf);

    try testing.expectEqual(@as(u8, 0x89), buf[0]); // FIN + ping

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqualStrings("ping", unmasked);
}

test "encode: close frame with status code" {
    const buf = try encodeClose(testing.allocator, 1000, "normal");
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    try testing.expectEqual(Opcode.close, result.frame.opcode);

    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);

    const status = std.mem.readInt(u16, unmasked[0..2], .big);
    try testing.expectEqual(@as(u16, 1000), status);
    try testing.expectEqualStrings("normal", unmasked[2..]);
}

test "encode: extended 16-bit length (200 bytes)" {
    const payload = try testing.allocator.alloc(u8, 200);
    defer testing.allocator.free(payload);
    @memset(payload, 'X');

    const mask_key = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    const buf = try encodeWithMask(testing.allocator, .text, payload, mask_key);
    defer testing.allocator.free(buf);

    // header(2) + ext_len(2) + mask(4) + payload(200) = 208
    try testing.expectEqual(@as(usize, 208), buf.len);
    try testing.expectEqual(@as(u8, 126), buf[1] & 0x7F);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqual(@as(usize, 200), unmasked.len);
    for (unmasked) |b| try testing.expectEqual(@as(u8, 'X'), b);
}

test "encode: extended 64-bit length (70000 bytes)" {
    const payload = try testing.allocator.alloc(u8, 70000);
    defer testing.allocator.free(payload);
    @memset(payload, 'Y');

    const mask_key = [4]u8{ 0x55, 0x66, 0x77, 0x88 };
    const buf = try encodeWithMask(testing.allocator, .text, payload, mask_key);
    defer testing.allocator.free(buf);

    // header(2) + ext_len(8) + mask(4) + payload(70000) = 70014
    try testing.expectEqual(@as(usize, 70014), buf.len);
    try testing.expectEqual(@as(u8, 127), buf[1] & 0x7F);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqual(@as(usize, 70000), unmasked.len);
}

// ============================================================================
// Tests: Round-trip (encode → decode)
// ============================================================================

test "roundtrip: text frame" {
    const original = "The quick brown fox jumps over the lazy dog";
    const buf = try encode(testing.allocator, .text, original);
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    try testing.expectEqual(Opcode.text, result.frame.opcode);
    try testing.expect(result.frame.fin);
    try testing.expect(result.frame.masked);

    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqualStrings(original, unmasked);
}

test "roundtrip: binary frame" {
    var original: [256]u8 = undefined;
    for (&original, 0..) |*b, i| b.* = @truncate(i);

    const buf = try encode(testing.allocator, .binary, &original);
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqualSlices(u8, &original, unmasked);
}

test "roundtrip: empty payload" {
    const buf = try encode(testing.allocator, .text, "");
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqual(@as(usize, 0), unmasked.len);
}

test "roundtrip: payload boundary 125 bytes" {
    const payload = try testing.allocator.alloc(u8, 125);
    defer testing.allocator.free(payload);
    @memset(payload, 'A');

    const buf = try encode(testing.allocator, .binary, payload);
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqual(@as(usize, 125), unmasked.len);
}

test "roundtrip: payload boundary 126 bytes" {
    const payload = try testing.allocator.alloc(u8, 126);
    defer testing.allocator.free(payload);
    @memset(payload, 'B');

    const buf = try encode(testing.allocator, .binary, payload);
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqual(@as(usize, 126), unmasked.len);
}

test "roundtrip: payload boundary 65535 bytes" {
    const payload = try testing.allocator.alloc(u8, 65535);
    defer testing.allocator.free(payload);
    @memset(payload, 'C');

    const buf = try encode(testing.allocator, .binary, payload);
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqual(@as(usize, 65535), unmasked.len);
}

test "roundtrip: payload boundary 65536 bytes" {
    const payload = try testing.allocator.alloc(u8, 65536);
    defer testing.allocator.free(payload);
    @memset(payload, 'D');

    const buf = try encode(testing.allocator, .binary, payload);
    defer testing.allocator.free(buf);

    const result = try decode(buf);
    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    try testing.expectEqual(@as(usize, 65536), unmasked.len);
}

// ============================================================================
// Tests: Masking
// ============================================================================

test "applyMask: basic XOR" {
    var data = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    applyMask(&data, mask);
    // After masking, data should be XOR'd
    try testing.expectEqual(@as(u8, 'H' ^ 0x37), data[0]);
    try testing.expectEqual(@as(u8, 'e' ^ 0xfa), data[1]);
    try testing.expectEqual(@as(u8, 'l' ^ 0x21), data[2]);
    try testing.expectEqual(@as(u8, 'l' ^ 0x3d), data[3]);
    try testing.expectEqual(@as(u8, 'o' ^ 0x37), data[4]); // wraps to mask[0]

    // Apply again to unmask
    applyMask(&data, mask);
    try testing.expectEqualStrings("Hello", &data);
}

test "applyMask: double apply is identity" {
    var data = [_]u8{ 0x00, 0xFF, 0x42, 0xAB, 0x13, 0x37 };
    const original = data;
    const mask = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    applyMask(&data, mask);
    // Should be different now
    try testing.expect(!std.mem.eql(u8, &data, &original));

    applyMask(&data, mask);
    // Should be back to original
    try testing.expectEqualSlices(u8, &original, &data);
}

test "applyMask: empty data" {
    var data = [_]u8{};
    applyMask(&data, .{ 0xFF, 0xFF, 0xFF, 0xFF });
    // No crash, no-op
}

test "applyMask: zero mask is no-op" {
    var data = [_]u8{ 'a', 'b', 'c' };
    applyMask(&data, .{ 0, 0, 0, 0 });
    try testing.expectEqualStrings("abc", &data);
}

test "encode: each call produces unique mask key (RFC 6455 Section 5.3)" {
    // RFC 5.3: "the client MUST pick a fresh masking key from the set of allowed 32-bit values"
    const buf1 = try encode(testing.allocator, .text, "test");
    defer testing.allocator.free(buf1);
    const buf2 = try encode(testing.allocator, .text, "test");
    defer testing.allocator.free(buf2);
    const buf3 = try encode(testing.allocator, .text, "test");
    defer testing.allocator.free(buf3);

    // Extract mask keys (bytes 2-5 for short payloads)
    const key1 = buf1[2..6];
    const key2 = buf2[2..6];
    const key3 = buf3[2..6];

    // All three should be different (collision probability: 1 in 2^32)
    try testing.expect(!std.mem.eql(u8, key1, key2));
    try testing.expect(!std.mem.eql(u8, key1, key3));
    try testing.expect(!std.mem.eql(u8, key2, key3));
}

// ============================================================================
// Tests: Handshake
// ============================================================================

test "computeAcceptKey: RFC 6455 example" {
    // RFC 6455 Section 4.2.2 example:
    // Key: "dGhlIHNhbXBsZSBub25jZQ=="
    // Expected Accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = computeAcceptKey(key);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "computeAcceptKey: different keys produce different accepts" {
    const accept1 = computeAcceptKey("AAAAAAAAAAAAAAAAAAAAAA==");
    const accept2 = computeAcceptKey("BBBBBBBBBBBBBBBBBBBBBB==");
    try testing.expect(!std.mem.eql(u8, &accept1, &accept2));
}

test "generateHandshakeKey: produces valid base64" {
    const key = generateHandshakeKey();
    // Must be 24 characters of base64
    try testing.expectEqual(@as(usize, 24), key.len);

    // Decode should succeed (valid base64)
    var decoded: [16]u8 = undefined;
    try std.base64.standard.Decoder.decode(&decoded, &key);
}

test "generateHandshakeKey: produces unique keys" {
    const key1 = generateHandshakeKey();
    const key2 = generateHandshakeKey();
    // Extremely unlikely to be the same (128-bit random)
    try testing.expect(!std.mem.eql(u8, &key1, &key2));
}

test "buildHandshakeRequest: format" {
    const req = try buildHandshakeRequest(
        testing.allocator,
        "localhost:9222",
        "/devtools/page/ABC",
        "dGhlIHNhbXBsZSBub25jZQ==",
    );
    defer testing.allocator.free(req);

    // Check required headers
    try testing.expect(std.mem.indexOf(u8, req, "GET /devtools/page/ABC HTTP/1.1\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Host: localhost:9222\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Upgrade: websocket\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Connection: Upgrade\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Version: 13\r\n") != null);
    // Must end with double CRLF
    try testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

// ============================================================================
// Tests: Edge Cases
// ============================================================================

test "decode: trailing data after frame is ignored" {
    // Frame "hi" + trailing garbage
    const data = [_]u8{ 0x81, 0x02, 'h', 'i', 0xFF, 0xFF, 0xFF };
    const result = try decode(&data);

    try testing.expectEqualStrings("hi", result.frame.payload);
    try testing.expectEqual(@as(usize, 4), result.bytes_consumed);
}

test "decode: masked frame with 16-bit length" {
    const payload_len: u16 = 200;
    const total = 4 + 4 + payload_len; // header + ext_len + mask + payload
    var data: [total]u8 = undefined;
    data[0] = 0x82; // FIN + binary
    data[1] = 0x80 | 126; // MASK + 16-bit
    std.mem.writeInt(u16, data[2..4], payload_len, .big);
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    @memcpy(data[4..8], &mask);
    @memset(data[8..], 0x55);
    applyMask(data[8..], mask);

    const result = try decode(&data);
    try testing.expect(result.frame.masked);
    try testing.expectEqual(@as(usize, 200), result.frame.payload.len);

    const unmasked = try unmaskPayload(testing.allocator, result.frame);
    defer testing.allocator.free(unmasked);
    for (unmasked) |b| try testing.expectEqual(@as(u8, 0x55), b);
}

test "encode + decode: all opcodes" {
    const opcodes = [_]Opcode{ .text, .binary, .ping, .pong };
    for (opcodes) |op| {
        const buf = try encode(testing.allocator, op, "test");
        defer testing.allocator.free(buf);

        const result = try decode(buf);
        try testing.expectEqual(op, result.frame.opcode);

        const unmasked = try unmaskPayload(testing.allocator, result.frame);
        defer testing.allocator.free(unmasked);
        try testing.expectEqualStrings("test", unmasked);
    }
}

// ============================================================================
// Tests: Close Code Validation (RFC 6455 Section 7.4)
// ============================================================================

test "isValidCloseCode: normal closure (1000)" {
    try testing.expect(isValidCloseCode(1000));
}

test "isValidCloseCode: going away (1001)" {
    try testing.expect(isValidCloseCode(1001));
}

test "isValidCloseCode: protocol error (1002)" {
    try testing.expect(isValidCloseCode(1002));
}

test "isValidCloseCode: unsupported data (1003)" {
    try testing.expect(isValidCloseCode(1003));
}

test "isValidCloseCode: invalid (1004) - reserved" {
    try testing.expect(!isValidCloseCode(1004));
}

test "isValidCloseCode: invalid (1005) - no status" {
    try testing.expect(!isValidCloseCode(1005));
}

test "isValidCloseCode: invalid (1006) - abnormal" {
    try testing.expect(!isValidCloseCode(1006));
}

test "isValidCloseCode: invalid data (1007)" {
    try testing.expect(isValidCloseCode(1007));
}

test "isValidCloseCode: policy violation (1008)" {
    try testing.expect(isValidCloseCode(1008));
}

test "isValidCloseCode: message too big (1009)" {
    try testing.expect(isValidCloseCode(1009));
}

test "isValidCloseCode: mandatory extension (1010)" {
    try testing.expect(isValidCloseCode(1010));
}

test "isValidCloseCode: internal error (1011)" {
    try testing.expect(isValidCloseCode(1011));
}

test "isValidCloseCode: invalid (1012-2999) - unassigned" {
    try testing.expect(!isValidCloseCode(1012));
    try testing.expect(!isValidCloseCode(1500));
    try testing.expect(!isValidCloseCode(2999));
}

test "isValidCloseCode: IANA registered (3000-3999)" {
    try testing.expect(isValidCloseCode(3000));
    try testing.expect(isValidCloseCode(3500));
    try testing.expect(isValidCloseCode(3999));
}

test "isValidCloseCode: private use (4000-4999)" {
    try testing.expect(isValidCloseCode(4000));
    try testing.expect(isValidCloseCode(4500));
    try testing.expect(isValidCloseCode(4999));
}

test "isValidCloseCode: invalid (5000+)" {
    try testing.expect(!isValidCloseCode(5000));
    try testing.expect(!isValidCloseCode(65535));
}

test "isValidCloseCode: invalid (0-999)" {
    try testing.expect(!isValidCloseCode(0));
    try testing.expect(!isValidCloseCode(999));
}

// ============================================================================
// Tests: Connection State Manager (RFC 6455 Section 5.4, 5.5, 7.4)
// ============================================================================

fn makeFrame(fin: bool, opcode: Opcode, masked: bool, payload: []const u8) Frame {
    return .{
        .fin = fin,
        .opcode = opcode,
        .masked = masked,
        .mask_key = .{ 0, 0, 0, 0 },
        .payload = payload,
    };
}

test "connection: single unfragmented text frame" {
    var conn = Connection.init();
    try conn.validateFrame(makeFrame(true, .text, false, "hello"));
    try testing.expect(!conn.inFragment());
}

test "connection: single unfragmented binary frame" {
    var conn = Connection.init();
    try conn.validateFrame(makeFrame(true, .binary, false, "data"));
    try testing.expect(!conn.inFragment());
}

test "connection: fragmented message (text + continuation + fin)" {
    var conn = Connection.init();

    // First fragment: FIN=0, opcode=text
    try conn.validateFrame(makeFrame(false, .text, false, "hel"));
    try testing.expect(conn.inFragment());
    try testing.expectEqual(Opcode.text, conn.fragment_opcode.?);

    // Middle fragment: FIN=0, opcode=continuation
    try conn.validateFrame(makeFrame(false, .continuation, false, "lo "));
    try testing.expect(conn.inFragment());

    // Final fragment: FIN=1, opcode=continuation
    try conn.validateFrame(makeFrame(true, .continuation, false, "world"));
    try testing.expect(!conn.inFragment());
}

test "connection: control frame mid-fragment" {
    var conn = Connection.init();

    // Start fragment
    try conn.validateFrame(makeFrame(false, .text, false, "hel"));
    try testing.expect(conn.inFragment());

    // Ping in the middle — MUST be allowed (RFC 6455 Section 5.4)
    try conn.validateFrame(makeFrame(true, .ping, false, ""));
    try testing.expect(conn.inFragment()); // fragment state preserved

    // Pong in the middle — also allowed
    try conn.validateFrame(makeFrame(true, .pong, false, ""));
    try testing.expect(conn.inFragment());

    // Continue fragment
    try conn.validateFrame(makeFrame(true, .continuation, false, "lo"));
    try testing.expect(!conn.inFragment());
}

test "connection error: unexpected continuation (no fragment started)" {
    var conn = Connection.init();
    try testing.expectError(
        error.UnexpectedContinuation,
        conn.validateFrame(makeFrame(true, .continuation, false, "data")),
    );
}

test "connection error: expected continuation (new data frame during fragment)" {
    var conn = Connection.init();

    // Start fragment
    try conn.validateFrame(makeFrame(false, .text, false, "hel"));

    // Another text frame instead of continuation — protocol violation
    try testing.expectError(
        error.ExpectedContinuation,
        conn.validateFrame(makeFrame(true, .text, false, "other")),
    );
}

test "connection error: binary frame during text fragment" {
    var conn = Connection.init();

    try conn.validateFrame(makeFrame(false, .text, false, "hel"));

    // Binary frame during text fragment — also protocol violation
    try testing.expectError(
        error.ExpectedContinuation,
        conn.validateFrame(makeFrame(true, .binary, false, "data")),
    );
}

test "connection error: server frame is masked" {
    var conn = Connection.init();
    try testing.expectError(
        error.ServerFrameMasked,
        conn.validateFrame(makeFrame(true, .text, true, "hello")),
    );
}

test "connection error: data frame after close received" {
    var conn = Connection.init();

    // Receive close with valid code
    const close_payload = [_]u8{ 0x03, 0xE8 }; // status 1000
    try conn.validateFrame(makeFrame(true, .close, false, &close_payload));
    try testing.expect(conn.close_received);

    // Data frame after close — protocol violation
    try testing.expectError(
        error.FrameAfterClose,
        conn.validateFrame(makeFrame(true, .text, false, "hello")),
    );
}

test "connection: control frame after close is allowed" {
    var conn = Connection.init();

    const close_payload = [_]u8{ 0x03, 0xE8 };
    try conn.validateFrame(makeFrame(true, .close, false, &close_payload));

    // Another close in response is OK
    try conn.validateFrame(makeFrame(true, .close, false, &close_payload));
}

test "connection error: close with invalid status code (1004)" {
    var conn = Connection.init();
    const close_payload = [_]u8{ 0x03, 0xEC }; // status 1004
    try testing.expectError(
        error.InvalidCloseCode,
        conn.validateFrame(makeFrame(true, .close, false, &close_payload)),
    );
}

test "connection error: close with invalid status code (999)" {
    var conn = Connection.init();
    const close_payload = [_]u8{ 0x03, 0xE7 }; // status 999
    try testing.expectError(
        error.InvalidCloseCode,
        conn.validateFrame(makeFrame(true, .close, false, &close_payload)),
    );
}

test "connection: close with valid code 4000 (private use)" {
    var conn = Connection.init();
    const close_payload = [_]u8{ 0x0F, 0xA0 }; // status 4000
    try conn.validateFrame(makeFrame(true, .close, false, &close_payload));
    try testing.expect(conn.close_received);
}

test "connection: close with empty payload (no status code)" {
    var conn = Connection.init();
    try conn.validateFrame(makeFrame(true, .close, false, ""));
    try testing.expect(conn.close_received);
}

test "connection: multiple fragments then new message" {
    var conn = Connection.init();

    // First fragmented message
    try conn.validateFrame(makeFrame(false, .text, false, "a"));
    try conn.validateFrame(makeFrame(true, .continuation, false, "b"));
    try testing.expect(!conn.inFragment());

    // Second message — should work fine
    try conn.validateFrame(makeFrame(true, .binary, false, "c"));
    try testing.expect(!conn.inFragment());
}

test "connection: fragmented binary message" {
    var conn = Connection.init();

    try conn.validateFrame(makeFrame(false, .binary, false, &[_]u8{0x00}));
    try testing.expect(conn.inFragment());
    try testing.expectEqual(Opcode.binary, conn.fragment_opcode.?);

    try conn.validateFrame(makeFrame(false, .continuation, false, &[_]u8{0x01}));
    try conn.validateFrame(makeFrame(false, .continuation, false, &[_]u8{0x02}));
    try conn.validateFrame(makeFrame(true, .continuation, false, &[_]u8{0x03}));
    try testing.expect(!conn.inFragment());
}
