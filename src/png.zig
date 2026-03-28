const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA, 4 bytes per pixel
    allocator: Allocator,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
    }
};

pub const Error = error{
    InvalidSignature,
    InvalidChunk,
    MissingIhdr,
    UnsupportedColorType,
    UnsupportedBitDepth,
    InvalidFilterType,
    DecompressError,
    InvalidDimensions,
    DataTooShort,
    OutOfMemory,
};

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

// ============================================================================
// PNG Decoder
// ============================================================================

pub fn decode(allocator: Allocator, png_data: []const u8) Error!Image {
    // 1. Verify signature
    if (png_data.len < 8) return Error.InvalidSignature;
    if (!std.mem.eql(u8, png_data[0..8], &png_signature)) return Error.InvalidSignature;

    // 2. Parse chunks
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var ihdr_found = false;

    // Collect all IDAT data
    var idat_list: std.ArrayListUnmanaged(u8) = .empty;
    defer idat_list.deinit(allocator);

    var offset: usize = 8;
    while (offset + 12 <= png_data.len) {
        const chunk_len = std.mem.readInt(u32, png_data[offset..][0..4], .big);
        const chunk_type = png_data[offset + 4 ..][0..4];
        offset += 8;

        if (offset + chunk_len + 4 > png_data.len) return Error.InvalidChunk;

        const chunk_data = png_data[offset..][0..chunk_len];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len < 13) return Error.InvalidChunk;
            width = std.mem.readInt(u32, chunk_data[0..4], .big);
            height = std.mem.readInt(u32, chunk_data[4..8], .big);
            bit_depth = chunk_data[8];
            color_type = chunk_data[9];
            ihdr_found = true;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            idat_list.appendSlice(allocator, chunk_data) catch return Error.OutOfMemory;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        offset += chunk_len + 4; // skip data + CRC
    }

    if (!ihdr_found) return Error.MissingIhdr;
    if (width == 0 or height == 0) return Error.InvalidDimensions;
    if (bit_depth != 8) return Error.UnsupportedBitDepth;

    const bpp: u32 = switch (color_type) {
        2 => 3, // RGB
        6 => 4, // RGBA
        else => return Error.UnsupportedColorType,
    };

    // 3. Decompress IDAT data (zlib format)
    const idat_data = idat_list.items;
    if (idat_data.len == 0) return Error.DataTooShort;

    var reader: std.io.Reader = .fixed(idat_data);
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&reader, .zlib, &decomp_buf);

    // Read all decompressed data
    const raw_size = (width * bpp + 1) * height; // +1 for filter byte per row
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    _ = decomp.reader.streamRemaining(&aw.writer) catch return Error.DecompressError;
    const raw_data = aw.toOwnedSlice() catch return Error.OutOfMemory;
    defer allocator.free(raw_data);

    if (raw_data.len < raw_size) return Error.DataTooShort;

    // 4. Apply row filters and convert to RGBA
    const pixel_count = width * height;
    const pixels = allocator.alloc(u8, pixel_count * 4) catch return Error.OutOfMemory;
    errdefer allocator.free(pixels);

    const stride = width * bpp; // bytes per row (without filter byte)

    // First pass: reconstruct filtered data in-place
    // We need a separate buffer for the reconstructed scanlines
    const recon = allocator.alloc(u8, stride * height) catch return Error.OutOfMemory;
    defer allocator.free(recon);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const raw_row_offset = y * (stride + 1);
        const filter_byte = raw_data[raw_row_offset];
        const raw_row = raw_data[raw_row_offset + 1 ..][0..stride];
        const recon_row = recon[y * stride ..][0..stride];
        const prev_row: ?[]const u8 = if (y > 0) recon[(y - 1) * stride ..][0..stride] else null;

        try reconstructRow(filter_byte, raw_row, recon_row, prev_row, bpp);
    }

    // 5. Convert to RGBA
    y = 0;
    while (y < height) : (y += 1) {
        const recon_row = recon[y * stride ..][0..stride];
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const dst_offset = (y * width + x) * 4;
            if (color_type == 6) {
                // RGBA - copy directly
                const src_offset = x * 4;
                pixels[dst_offset] = recon_row[src_offset];
                pixels[dst_offset + 1] = recon_row[src_offset + 1];
                pixels[dst_offset + 2] = recon_row[src_offset + 2];
                pixels[dst_offset + 3] = recon_row[src_offset + 3];
            } else {
                // RGB - add alpha=255
                const src_offset = x * 3;
                pixels[dst_offset] = recon_row[src_offset];
                pixels[dst_offset + 1] = recon_row[src_offset + 1];
                pixels[dst_offset + 2] = recon_row[src_offset + 2];
                pixels[dst_offset + 3] = 255;
            }
        }
    }

    return Image{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

fn reconstructRow(filter_byte: u8, raw: []const u8, recon: []u8, prev_row: ?[]const u8, bpp: u32) Error!void {
    switch (filter_byte) {
        0 => { // None
            @memcpy(recon, raw);
        },
        1 => { // Sub
            for (recon, 0..) |*out, i| {
                const a: u8 = if (i >= bpp) recon[i - bpp] else 0;
                out.* = raw[i] +% a;
            }
        },
        2 => { // Up
            for (recon, 0..) |*out, i| {
                const b: u8 = if (prev_row) |pr| pr[i] else 0;
                out.* = raw[i] +% b;
            }
        },
        3 => { // Average
            for (recon, 0..) |*out, i| {
                const a: u16 = if (i >= bpp) recon[i - bpp] else 0;
                const b: u16 = if (prev_row) |pr| pr[i] else 0;
                out.* = raw[i] +% @as(u8, @intCast((a + b) / 2));
            }
        },
        4 => { // Paeth
            for (recon, 0..) |*out, i| {
                const a: u8 = if (i >= bpp) recon[i - bpp] else 0;
                const b: u8 = if (prev_row) |pr| pr[i] else 0;
                const c: u8 = if (i >= bpp and prev_row != null) prev_row.?[i - bpp] else 0;
                out.* = raw[i] +% paethPredictor(a, b, c);
            }
        },
        else => return Error.InvalidFilterType,
    }
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ============================================================================
// PNG Encoder
// ============================================================================

pub fn encode(allocator: Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    if (width == 0 or height == 0) return Error.InvalidDimensions;
    const expected_size = @as(usize, width) * height * 4;
    if (pixels.len < expected_size) return Error.DataTooShort;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    // PNG Signature
    try result.appendSlice(allocator, &png_signature);

    // IHDR chunk
    var ihdr_data: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
    std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
    ihdr_data[8] = 8; // bit depth
    ihdr_data[9] = 6; // color type: RGBA
    ihdr_data[10] = 0; // compression method
    ihdr_data[11] = 0; // filter method
    ihdr_data[12] = 0; // interlace method
    try writeChunk(allocator, &result, "IHDR", &ihdr_data);

    // Build raw scanline data: filter_byte(0) + RGBA per row
    const stride = width * 4;
    const raw_size = (stride + 1) * height;
    const raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_offset = y * (stride + 1);
        raw_data[row_offset] = 0; // filter: None
        const src_offset = y * stride;
        @memcpy(raw_data[row_offset + 1 ..][0..stride], pixels[src_offset..][0..stride]);
    }

    // Compress raw data with zlib (using stored blocks)
    const compressed = try zlibCompress(allocator, raw_data);
    defer allocator.free(compressed);

    // IDAT chunk
    try writeChunk(allocator, &result, "IDAT", compressed);

    // IEND chunk
    try writeChunk(allocator, &result, "IEND", &.{});

    return result.toOwnedSlice(allocator);
}

/// Compress data using zlib format with stored (uncompressed) blocks.
/// This produces valid zlib that any decoder can read, just without compression.
fn zlibCompress(allocator: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // Zlib header: CMF=0x78 (deflate, window=32K), FLG=0x01 (no dict, level=0)
    // FCHECK must make (CMF*256 + FLG) % 31 == 0
    // 0x78 * 256 + 0x01 = 30721, 30721 % 31 = 0. Good.
    try out.appendSlice(allocator, &[_]u8{ 0x78, 0x01 });

    // Write stored blocks (max 65535 bytes each)
    const max_block: usize = 65535;
    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data.len - offset;
        const block_size: u16 = @intCast(@min(remaining, max_block));
        const is_final: bool = (offset + block_size >= data.len);

        // Block header: BFINAL(1 bit) + BTYPE=00(2 bits) + padding(5 bits)
        try out.append(allocator, if (is_final) 0x01 else 0x00);

        // LEN (little-endian u16)
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, block_size, .little);
        try out.appendSlice(allocator, &len_buf);

        // NLEN (one's complement)
        std.mem.writeInt(u16, &len_buf, ~block_size, .little);
        try out.appendSlice(allocator, &len_buf);

        // Data
        try out.appendSlice(allocator, data[offset..][0..block_size]);
        offset += block_size;
    }

    // Handle empty data edge case
    if (data.len == 0) {
        try out.appendSlice(allocator, &[_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff });
    }

    // Adler32 checksum (big-endian)
    const adler = std.hash.Adler32.hash(data);
    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, adler, .big);
    try out.appendSlice(allocator, &adler_buf);

    return out.toOwnedSlice(allocator);
}

fn writeChunk(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    // Length (4 bytes, big-endian)
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try list.appendSlice(allocator, &len_buf);

    // Type (4 bytes)
    try list.appendSlice(allocator, chunk_type);

    // Data
    if (data.len > 0) {
        try list.appendSlice(allocator, data);
    }

    // CRC32 over type + data
    var crc = std.hash.crc.Crc32.init();
    crc.update(chunk_type);
    if (data.len > 0) {
        crc.update(data);
    }
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try list.appendSlice(allocator, &crc_buf);
}

// ============================================================================
// Screenshot Diff
// ============================================================================

pub const DiffResult = struct {
    match: bool,
    total_pixels: u32,
    different_pixels: u32,
    mismatch_percentage: f64,
    diff_image: ?[]u8, // encoded PNG, caller must free
    allocator: Allocator,

    pub fn deinit(self: *DiffResult) void {
        if (self.diff_image) |img| {
            self.allocator.free(img);
        }
    }
};

pub fn diffScreenshots(allocator: Allocator, baseline_data: []const u8, current_data: []const u8, threshold: f64) !DiffResult {
    var img1 = try decode(allocator, baseline_data);
    defer img1.deinit();
    var img2 = try decode(allocator, current_data);
    defer img2.deinit();

    // Use smaller dimensions for comparison
    const w = @min(img1.width, img2.width);
    const h = @min(img1.height, img2.height);

    // Diff image uses the larger dimensions
    const max_w = @max(img1.width, img2.width);
    const max_h = @max(img1.height, img2.height);

    const total_pixels = max_w * max_h;
    var different_pixels: u32 = 0;

    // Build diff image pixels
    const diff_pixels = try allocator.alloc(u8, @as(usize, max_w) * max_h * 4);
    defer allocator.free(diff_pixels);

    const max_distance = threshold * 255.0 * @sqrt(3.0);

    var y: u32 = 0;
    while (y < max_h) : (y += 1) {
        var x: u32 = 0;
        while (x < max_w) : (x += 1) {
            const diff_offset = (y * max_w + x) * 4;

            if (x >= w or y >= h or x >= img1.width or y >= img1.height or x >= img2.width or y >= img2.height) {
                // Out of bounds for one image — mark as different
                diff_pixels[diff_offset] = 255; // R
                diff_pixels[diff_offset + 1] = 0; // G
                diff_pixels[diff_offset + 2] = 0; // B
                diff_pixels[diff_offset + 3] = 255; // A
                different_pixels += 1;
                continue;
            }

            const off1 = (y * img1.width + x) * 4;
            const off2 = (y * img2.width + x) * 4;

            const dr = @as(f64, @floatFromInt(@as(i16, img1.pixels[off1]))) - @as(f64, @floatFromInt(@as(i16, img2.pixels[off2])));
            const dg = @as(f64, @floatFromInt(@as(i16, img1.pixels[off1 + 1]))) - @as(f64, @floatFromInt(@as(i16, img2.pixels[off2 + 1])));
            const db = @as(f64, @floatFromInt(@as(i16, img1.pixels[off1 + 2]))) - @as(f64, @floatFromInt(@as(i16, img2.pixels[off2 + 2])));

            const distance = @sqrt(dr * dr + dg * dg + db * db);

            if (distance > max_distance) {
                // Different — red
                diff_pixels[diff_offset] = 255;
                diff_pixels[diff_offset + 1] = 0;
                diff_pixels[diff_offset + 2] = 0;
                diff_pixels[diff_offset + 3] = 255;
                different_pixels += 1;
            } else {
                // Same — dimmed gray
                const avg = (@as(u16, img1.pixels[off1]) + @as(u16, img1.pixels[off1 + 1]) + @as(u16, img1.pixels[off1 + 2])) / 3;
                const gray: u8 = @intCast(avg / 3);
                diff_pixels[diff_offset] = gray;
                diff_pixels[diff_offset + 1] = gray;
                diff_pixels[diff_offset + 2] = gray;
                diff_pixels[diff_offset + 3] = 255;
            }
        }
    }

    // Encode diff image as PNG
    const diff_png = encode(allocator, max_w, max_h, diff_pixels) catch null;

    const mismatch_pct = if (total_pixels > 0)
        @as(f64, @floatFromInt(different_pixels)) / @as(f64, @floatFromInt(total_pixels)) * 100.0
    else
        0.0;

    return DiffResult{
        .match = different_pixels == 0,
        .total_pixels = total_pixels,
        .different_pixels = different_pixels,
        .mismatch_percentage = mismatch_pct,
        .diff_image = diff_png,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "PNG signature validation" {
    const allocator = std.testing.allocator;

    // Too short
    try std.testing.expectError(Error.InvalidSignature, decode(allocator, "short"));

    // Wrong signature
    try std.testing.expectError(Error.InvalidSignature, decode(allocator, "12345678"));

    // Valid signature but no IHDR
    const sig_only = png_signature ++ [_]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0, 0, 0, 0 };
    try std.testing.expectError(Error.MissingIhdr, decode(allocator, &sig_only));
}

test "PNG encode then decode roundtrip" {
    const allocator = std.testing.allocator;

    // Create a small 2x2 RGBA image
    const pixels = [_]u8{
        255, 0,   0,   255, // red
        0,   255, 0,   255, // green
        0,   0,   255, 255, // blue
        255, 255, 255, 255, // white
    };

    const encoded = try encode(allocator, 2, 2, &pixels);
    defer allocator.free(encoded);

    // Verify PNG signature
    try std.testing.expectEqualSlices(u8, &png_signature, encoded[0..8]);

    // Decode it back
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.pixels);
}

test "PNG encode then decode roundtrip - larger image" {
    const allocator = std.testing.allocator;

    // Create 8x8 gradient image
    const w: u32 = 8;
    const h: u32 = 8;
    var pixels: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const offset = (y * w + x) * 4;
            pixels[offset] = @intCast(x * 32); // R
            pixels[offset + 1] = @intCast(y * 32); // G
            pixels[offset + 2] = @intCast((x + y) * 16); // B
            pixels[offset + 3] = 255; // A
        }
    }

    const encoded = try encode(allocator, w, h, &pixels);
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(w, decoded.width);
    try std.testing.expectEqual(h, decoded.height);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.pixels);
}

test "PNG filter reconstruction - Sub" {
    // Sub filter: pixel[i] += pixel[i - bpp]
    var raw = [_]u8{ 10, 20, 30, 40, 5, 6, 7, 8 };
    var recon: [8]u8 = undefined;
    try reconstructRow(1, &raw, &recon, null, 4);
    // First 4 bytes: 10, 20, 30, 40 (no prior pixel)
    // Next 4 bytes: 5+10, 6+20, 7+30, 8+40 = 15, 26, 37, 48
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 40, 15, 26, 37, 48 }, &recon);
}

test "PNG filter reconstruction - Up" {
    var raw = [_]u8{ 1, 2, 3, 4 };
    var prev = [_]u8{ 10, 20, 30, 40 };
    var recon: [4]u8 = undefined;
    try reconstructRow(2, &raw, &recon, &prev, 4);
    // Up: pixel[i] += prev_row[i]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 11, 22, 33, 44 }, &recon);
}

test "PNG filter reconstruction - Average" {
    var raw = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var prev = [_]u8{ 20, 40, 60, 80, 100, 120, 140, 160 };
    var recon: [8]u8 = undefined;
    try reconstructRow(3, &raw, &recon, &prev, 4);
    // First 4: floor((0 + prev[i]) / 2) = 10, 20, 30, 40
    // Next 4: floor((recon[i-4] + prev[i]) / 2) = floor((10+100)/2), floor((20+120)/2), ...
    try std.testing.expectEqual(@as(u8, 10), recon[0]);
    try std.testing.expectEqual(@as(u8, 20), recon[1]);
    try std.testing.expectEqual(@as(u8, 30), recon[2]);
    try std.testing.expectEqual(@as(u8, 40), recon[3]);
    try std.testing.expectEqual(@as(u8, 55), recon[4]); // floor((10+100)/2)
    try std.testing.expectEqual(@as(u8, 70), recon[5]); // floor((20+120)/2)
    try std.testing.expectEqual(@as(u8, 85), recon[6]); // floor((30+140)/2)
    try std.testing.expectEqual(@as(u8, 100), recon[7]); // floor((40+160)/2)
}

test "PNG filter reconstruction - Paeth" {
    var raw = [_]u8{ 0, 0, 0, 0 };
    var prev = [_]u8{ 10, 20, 30, 40 };
    var recon: [4]u8 = undefined;
    try reconstructRow(4, &raw, &recon, &prev, 4);
    // Paeth with a=0, b=prev[i], c=0: p = 0+prev[i]-0 = prev[i]
    // pa=|prev[i]-0|=prev[i], pb=|prev[i]-prev[i]|=0, pc=|prev[i]-0|=prev[i]
    // pb <= pc, so return b = prev[i]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 40 }, &recon);
}

test "PNG filter reconstruction - None" {
    var raw = [_]u8{ 1, 2, 3, 4 };
    var recon: [4]u8 = undefined;
    try reconstructRow(0, &raw, &recon, null, 4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &recon);
}

test "PNG filter reconstruction - invalid filter type" {
    var raw = [_]u8{ 1, 2, 3, 4 };
    var recon: [4]u8 = undefined;
    try std.testing.expectError(Error.InvalidFilterType, reconstructRow(5, &raw, &recon, null, 4));
}

test "paethPredictor" {
    // When a=0, b=10, c=0: p=10, pa=10, pb=0, pc=10 → return b=10
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(0, 10, 0));
    // When a=10, b=10, c=10: p=10, pa=0, pb=0, pc=0 → return a=10
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(10, 10, 10));
    // When a=0, b=0, c=0: p=0, pa=0, pb=0, pc=0 → return a=0
    try std.testing.expectEqual(@as(u8, 0), paethPredictor(0, 0, 0));
    // When a=255, b=0, c=0: p=255, pa=0, pb=255, pc=255 → return a=255
    try std.testing.expectEqual(@as(u8, 255), paethPredictor(255, 0, 0));
}

test "PNG encode - invalid dimensions" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.InvalidDimensions, encode(allocator, 0, 10, &.{}));
    try std.testing.expectError(Error.InvalidDimensions, encode(allocator, 10, 0, &.{}));
}

test "PNG encode - data too short" {
    const allocator = std.testing.allocator;
    const small_buf = [_]u8{0} ** 4;
    try std.testing.expectError(Error.DataTooShort, encode(allocator, 2, 2, &small_buf));
}

test "PNG diff - identical images" {
    const allocator = std.testing.allocator;

    const pixels = [_]u8{
        100, 150, 200, 255,
        50,  100, 150, 255,
    };

    const png1 = try encode(allocator, 1, 2, &pixels);
    defer allocator.free(png1);

    var result = try diffScreenshots(allocator, png1, png1, 0.1);
    defer result.deinit();

    try std.testing.expect(result.match);
    try std.testing.expectEqual(@as(u32, 0), result.different_pixels);
    try std.testing.expectEqual(@as(f64, 0.0), result.mismatch_percentage);
}

test "PNG diff - completely different images" {
    const allocator = std.testing.allocator;

    const black = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255 };
    const white = [_]u8{ 255, 255, 255, 255, 255, 255, 255, 255 };

    const png1 = try encode(allocator, 1, 2, &black);
    defer allocator.free(png1);
    const png2 = try encode(allocator, 1, 2, &white);
    defer allocator.free(png2);

    var result = try diffScreenshots(allocator, png1, png2, 0.1);
    defer result.deinit();

    try std.testing.expect(!result.match);
    try std.testing.expectEqual(@as(u32, 2), result.different_pixels);
    try std.testing.expectEqual(@as(f64, 100.0), result.mismatch_percentage);
}

test "PNG diff - within threshold" {
    const allocator = std.testing.allocator;

    const pixels1 = [_]u8{ 100, 100, 100, 255 };
    // Slightly different — distance = sqrt(1+1+1) ≈ 1.73
    // max_distance at threshold 0.1 = 0.1 * 255 * sqrt(3) ≈ 44.17
    const pixels2 = [_]u8{ 101, 101, 101, 255 };

    const png1 = try encode(allocator, 1, 1, &pixels1);
    defer allocator.free(png1);
    const png2 = try encode(allocator, 1, 1, &pixels2);
    defer allocator.free(png2);

    var result = try diffScreenshots(allocator, png1, png2, 0.1);
    defer result.deinit();

    try std.testing.expect(result.match);
    try std.testing.expectEqual(@as(u32, 0), result.different_pixels);
}

test "PNG diff - generates diff image" {
    const allocator = std.testing.allocator;

    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };

    const png1 = try encode(allocator, 1, 1, &red);
    defer allocator.free(png1);
    const png2 = try encode(allocator, 1, 1, &blue);
    defer allocator.free(png2);

    var result = try diffScreenshots(allocator, png1, png2, 0.1);
    defer result.deinit();

    try std.testing.expect(!result.match);
    try std.testing.expect(result.diff_image != null);

    // Verify diff image is valid PNG
    if (result.diff_image) |diff_png| {
        var diff_img = try decode(allocator, diff_png);
        defer diff_img.deinit();
        try std.testing.expectEqual(@as(u32, 1), diff_img.width);
        try std.testing.expectEqual(@as(u32, 1), diff_img.height);
    }
}

test "zlibCompress and decompress roundtrip" {
    const allocator = std.testing.allocator;

    const data = "Hello, this is a test of zlib compression with stored blocks!";
    const compressed = try zlibCompress(allocator, data);
    defer allocator.free(compressed);

    // Decompress
    var reader: std.io.Reader = .fixed(compressed);
    var dbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&reader, .zlib, &dbuf);

    var out: [256]u8 = undefined;
    const n = decomp.reader.readSliceShort(&out) catch return error.DecompressError;
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, out[0..n]);
}

test "zlibCompress - empty data" {
    const allocator = std.testing.allocator;

    const compressed = try zlibCompress(allocator, "");
    defer allocator.free(compressed);

    // Should at least have zlib header + empty stored block + adler32
    try std.testing.expect(compressed.len > 0);
    try std.testing.expectEqual(@as(u8, 0x78), compressed[0]);
}

test "zlibCompress - large data spanning multiple blocks" {
    const allocator = std.testing.allocator;

    // Create data larger than 65535 to test multi-block
    const size = 70000;
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const compressed = try zlibCompress(allocator, data);
    defer allocator.free(compressed);

    // Decompress and verify
    var reader: std.io.Reader = .fixed(compressed);
    var dbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&reader, .zlib, &dbuf);

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    _ = decomp.reader.streamRemaining(&aw.writer) catch return error.DecompressError;
    const decompressed = aw.written();

    try std.testing.expectEqual(size, decompressed.len);
    try std.testing.expectEqualSlices(u8, data, decompressed);
}

test "PNG chunk CRC verification" {
    const allocator = std.testing.allocator;

    // Encode a small image and verify IHDR CRC
    const pixels = [_]u8{ 0, 0, 0, 255 };
    const encoded = try encode(allocator, 1, 1, &pixels);
    defer allocator.free(encoded);

    // IHDR chunk starts at offset 8
    // Length(4) + Type(4) + Data(13) + CRC(4) = 25 bytes
    const ihdr_type = encoded[12..16];
    try std.testing.expectEqualSlices(u8, "IHDR", ihdr_type);

    const ihdr_data = encoded[12..29]; // type + data
    var crc = std.hash.crc.Crc32.init();
    crc.update(ihdr_data);
    const expected_crc = crc.final();

    const stored_crc = std.mem.readInt(u32, encoded[29..33], .big);
    try std.testing.expectEqual(expected_crc, stored_crc);
}

test "PNG 1x1 white pixel" {
    const allocator = std.testing.allocator;

    const white = [_]u8{ 255, 255, 255, 255 };
    const encoded = try encode(allocator, 1, 1, &white);
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 1), decoded.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.height);
    try std.testing.expectEqualSlices(u8, &white, decoded.pixels);
}

test "PNG diff - different dimensions" {
    const allocator = std.testing.allocator;

    const pixels_1x1 = [_]u8{ 0, 0, 0, 255 };
    const pixels_2x1 = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255 };

    const png1 = try encode(allocator, 1, 1, &pixels_1x1);
    defer allocator.free(png1);
    const png2 = try encode(allocator, 2, 1, &pixels_2x1);
    defer allocator.free(png2);

    var result = try diffScreenshots(allocator, png1, png2, 0.1);
    defer result.deinit();

    // 2x1 = 2 total, 1 pixel is out-of-bounds different
    try std.testing.expectEqual(@as(u32, 2), result.total_pixels);
    try std.testing.expectEqual(@as(u32, 1), result.different_pixels);
    try std.testing.expect(!result.match);
}
