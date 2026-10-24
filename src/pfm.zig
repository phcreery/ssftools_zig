//! Portable Float Map reader.
//!
//! PFM is a deliberately tiny format — no compression, no directory, one sample
//! type, with no compression and no directory to walk:
//!
//!     PF\n<width> <height>\n<scale>\n<width*height*channels float32 samples>
//!
//! * `PF` is three channels, `Pf` is one.
//! * the scale's *sign* selects the byte order: negative is little-endian,
//!   positive is big-endian. Its magnitude is not applied; writers put ±1.0
//!   there and readers in the wild only look at the sign.
//! * exactly one whitespace byte ends the header. It is not "skip whitespace":
//!   the first sample's first byte can itself be whitespace, so consuming more
//!   than one would corrupt the raster.
//! * samples are float32 and the rows are stored bottom-up, which this reader
//!   normalises to top-down.
//!
//! Verified against ImageMagick's writer: its PFM round-trips to the exact
//! 16-bit samples it was made from (see the fixture test below).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Not a PFM, or the header could not be read.
    NotPfm,
    /// The raster is shorter than the header claims.
    Truncated,
} || Allocator.Error;

pub const Image = struct {
    width: u32,
    height: u32,
    /// 1 for `Pf`, 3 for `PF`.
    channels: u8,
    /// Row-major, top-down, `channels` samples per pixel.
    samples: []const f32,

    pub fn deinit(self: Image, a: Allocator) void {
        a.free(self.samples);
    }

    /// One pixel's RGB; only meaningful when `channels == 3`.
    pub fn rgb(self: Image, x: u32, y: u32) [3]f32 {
        std.debug.assert(self.channels == 3);
        const i = (@as(usize, y) * self.width + x) * 3;
        return .{ self.samples[i], self.samples[i + 1], self.samples[i + 2] };
    }
};

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c;
}

/// Next whitespace-delimited token, leaving `pos` on the whitespace after it.
fn nextToken(data: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < data.len and isSpace(data[pos.*])) pos.* += 1;
    const start = pos.*;
    while (pos.* < data.len and !isSpace(data[pos.*])) pos.* += 1;
    return if (pos.* == start) null else data[start..pos.*];
}

pub fn read(a: Allocator, data: []const u8) Error!Image {
    var pos: usize = 0;

    const magic = nextToken(data, &pos) orelse return error.NotPfm;
    const channels: u8 = if (std.mem.eql(u8, magic, "PF"))
        3
    else if (std.mem.eql(u8, magic, "Pf"))
        1
    else
        return error.NotPfm;

    const width = std.fmt.parseInt(u32, nextToken(data, &pos) orelse return error.NotPfm, 10) catch
        return error.NotPfm;
    const height = std.fmt.parseInt(u32, nextToken(data, &pos) orelse return error.NotPfm, 10) catch
        return error.NotPfm;
    const scale = std.fmt.parseFloat(f32, nextToken(data, &pos) orelse return error.NotPfm) catch
        return error.NotPfm;
    if (width == 0 or height == 0) return error.NotPfm;

    // One whitespace byte, and only one.
    if (pos >= data.len or !isSpace(data[pos])) return error.NotPfm;
    pos += 1;

    const order: std.builtin.Endian = if (scale < 0) .little else .big;
    const per_row = @as(usize, width) * channels;
    const count = per_row * height;
    if (data.len - pos < count * 4) return error.Truncated;

    const samples = try a.alloc(f32, count);
    errdefer a.free(samples);
    for (0..height) |y| {
        // PFM stores rows bottom-up.
        const src_row = @as(usize, height) - 1 - y;
        for (0..per_row) |i| {
            const at = pos + (src_row * per_row + i) * 4;
            const bits = std.mem.readInt(u32, data[at..][0..4], order);
            samples[y * per_row + i] = @bitCast(bits);
        }
    }

    return .{ .width = width, .height = height, .channels = channels, .samples = samples };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a PFM in memory; `big_endian` sets the scale's sign.
fn build(a: Allocator, width: u32, height: u32, channels: u8, big_endian: bool, pixels: []const f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.fixed(try a.alloc(u8, 4096));
    w.print("{s}\n{d} {d}\n{d}.0\n", .{
        if (channels == 3) "PF" else "Pf",
        width,
        height,
        if (big_endian) @as(i32, 1) else @as(i32, -1),
    }) catch unreachable;
    try out.appendSlice(a, w.buffered());

    const order: std.builtin.Endian = if (big_endian) .big else .little;
    for (pixels) |v| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @bitCast(v), order);
        try out.appendSlice(a, &buf);
    }
    return out.toOwnedSlice(a);
}

test "reads both byte orders and flips bottom-up rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 2x2 RGB. PFM stores the bottom row first, so the raster is written in the
    // order: row 1, then row 0.
    const top = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const bottom = [_]f32{ 7, 8, 9, 10, 11, 12 };
    var raster: [12]f32 = undefined;
    @memcpy(raster[0..6], &bottom);
    @memcpy(raster[6..12], &top);

    for ([_]bool{ false, true }) |big_endian| {
        const bytes = try build(a, 2, 2, 3, big_endian, &raster);
        const img = try read(a, bytes);
        try testing.expectEqual(@as(u32, 2), img.width);
        try testing.expectEqual(@as(u32, 2), img.height);
        try testing.expectEqual(@as(u8, 3), img.channels);
        try testing.expectEqualSlices(f32, &top, img.samples[0..6]);
        try testing.expectEqualSlices(f32, &bottom, img.samples[6..12]);
        try testing.expectEqual(@as(f32, 1), img.rgb(0, 0)[0]);
        try testing.expectEqual(@as(f32, 12), img.rgb(1, 1)[2]);
    }
}

test "single channel images" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raster = [_]f32{ 0.5, 0.25 };
    const bytes = try build(a, 2, 1, 1, false, &raster);
    const img = try read(a, bytes);
    try testing.expectEqual(@as(u8, 1), img.channels);
    try testing.expectEqualSlices(f32, &raster, img.samples);
}

test "rejects malformed input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.NotPfm, read(a, ""));
    try testing.expectError(error.NotPfm, read(a, "PX\n2 2\n-1.0\n"));
    try testing.expectError(error.NotPfm, read(a, "PF\n2 two\n-1.0\n"));
    try testing.expectError(error.NotPfm, read(a, "PF\n0 2\n-1.0\n"));
    // Header promises 2x2 RGB but the raster is one sample short.
    const short = try build(a, 2, 2, 3, false, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 });
    try testing.expectError(error.Truncated, read(a, short));
}

test "decodes the recorded ImageMagick fixture exactly" {
    const a = testing.allocator;
    const img = try read(a, @embedFile("testdata/spectrum16.pfm"));
    defer img.deinit(a);

    try testing.expectEqual(@as(u32, 16), img.width);
    try testing.expectEqual(@as(u32, 120), img.height);
    try testing.expectEqual(@as(u8, 3), img.channels);

    // The fixture was made by ImageMagick from a 16-bit source, which scales
    // integers by 1/65535, so multiplying back must give the original integers.
    const cases = [_]struct { x: u32, y: u32, want: [3]u16 }{
        // pixel(x, y) = 60000 * lit * (0.10 + 0.010x, 0.80 + 0.005x, 0.05 + 0.020x)
        .{ .x = 0, .y = 0, .want = .{ 480, 3840, 240 } }, // unlit row
        .{ .x = 3, .y = 50, .want = .{ 7800, 48900, 6600 } }, // lit row
        .{ .x = 15, .y = 79, .want = .{ 15000, 52500, 21000 } }, // last lit row
        .{ .x = 15, .y = 119, .want = .{ 1200, 4200, 1680 } }, // bottom, unlit
        // The band is off-centre, so these two only hold if the rows were
        // flipped out of PFM's bottom-up order.
        .{ .x = 0, .y = 20, .want = .{ 6000, 48000, 3000 } }, // first lit row
        .{ .x = 0, .y = 100, .want = .{ 480, 3840, 240 } }, // past the band
    };
    for (cases) |c| {
        const got = img.rgb(c.x, c.y);
        for (0..3) |i| {
            const back = @round(got[i] * 65535.0);
            try testing.expectEqual(@as(f32, @floatFromInt(c.want[i])), back);
        }
    }
}
