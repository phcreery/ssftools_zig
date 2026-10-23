//! Reads a Portable Float Map of a spectrum and prints one `x,r,g,b` row per
//! column, right to left.
//!
//! The pipeline is the reference tiff2specdata's: find the brightest green pixel
//! that is not dominated by red or blue, walk that column to locate the
//! illuminated band, centre a 100 row crop on it, then average each column of
//! the crop.
//!
//! Three things differ from the C++ original, all deliberate:
//!
//! * **float samples, not 16-bit integers.** PFM's native type is float32, so
//!   the maxes and thresholds stay in float; there is no `unsigned gthreshold =
//!   gmax * 0.7` truncation to reproduce.
//! * **a true mean over the crop.** Upstream divides by the constant `band`
//!   (100) even when the crop was clamped to a shorter image, which under-reports
//!   those columns. This divides by the crop's actual height; for a crop of 100
//!   rows the two agree exactly. It is a single global factor, so nothing
//!   downstream (normalise, powercalibrate) sees a difference.
//! * **float output.** Channels print with `%f`; upstream's `%0.0f` would
//!   quantise a 0..1 measurement to zero.
//!
//! The readout is still right to left: index 0 is the rightmost column, so the
//! wavelengths increase with the row index for a capture whose long wavelengths
//! are on the left.

const std = @import("std");
const Io = std.Io;
const ssftool = @import("ssftool.zig");
const pfm = @import("pfm.zig");
const cformat = @import("cformat.zig");

/// Rows averaged per column, as upstream's `band`.
const band: u32 = 100;

/// The readout: `index,r,g,b` per column of the crop.
pub fn process(c: ssftool.Ctx, img: pfm.Image, debug: bool) ssftool.Error!void {
    if (img.channels != 3) return c.fail("Error: image not RGB.", .{});
    const a = c.gpa;
    const width = img.width;
    const height = img.height;

    var rmax: f32 = 0;
    var gmax: f32 = 0;
    var bmax: f32 = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const p = img.rgb(@intCast(x), @intCast(y));
            if (p[0] > rmax) rmax = p[0];
            if (p[1] > gmax) gmax = p[1];
            if (p[2] > bmax) bmax = p[2];
        }
    }

    const gthreshold = gmax * 0.7;
    const rthreshold = rmax * 0.5;
    const bthreshold = bmax * 0.5;

    if (debug) {
        try c.out.writeAll("rmax: ");
        try cformat.fixed(a, c.out, rmax, 6);
        try c.out.writeAll(" gmax: ");
        try cformat.fixed(a, c.out, gmax, 6);
        try c.out.writeAll(" bmax: ");
        try cformat.fixed(a, c.out, bmax, 6);
        try c.out.writeByte('\n');
        try c.out.writeAll("rthreshold: ");
        try cformat.fixed(a, c.out, rthreshold, 6);
        try c.out.writeAll(" gthreshold: ");
        try cformat.fixed(a, c.out, gthreshold, 6);
        try c.out.writeAll(" bthreshold: ");
        try cformat.fixed(a, c.out, bthreshold, 6);
        try c.out.writeByte('\n');
    }

    // Brightest green that is not swamped by the other two channels.
    var bg: f32 = 0.0;
    var bg_x: u32 = 0;
    var bg_y: u32 = 0;
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            const p = img.rgb(x, y);
            if (p[1] > bg and p[0] < rthreshold and p[2] < bthreshold) {
                bg = p[1];
                bg_x = x;
                bg_y = y;
            }
        }
    }
    if (debug) try c.out.print("largest green: {d},{d}\n", .{ bg_x, bg_y });

    // Walk that column to find the illuminated band.
    var gtop: u32 = 0;
    var gbottom: u32 = 0;
    {
        var inband = false;
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            const g = img.rgb(bg_x, y)[1];
            if (g > gthreshold and !inband) {
                gtop = y;
                inband = true;
            } else if (g < gthreshold and inband) {
                gbottom = y;
                break;
            }
        }
        // A crop that is entirely spectrum has no lower edge, and one with no
        // pixels above threshold has no band at all; fall back to the column.
        if (!inband) {
            gtop = 0;
            gbottom = height;
        } else if (gbottom <= gtop) {
            gbottom = height;
        }
    }

    // Centre the band in a `band`-row crop, clamped to the image.
    const bandcenter = gtop + (gbottom - gtop) / 2;
    var top: u32 = if (bandcenter > band / 2) bandcenter - band / 2 else 0;
    if (top + band > height) top = if (height > band) height - band else 0;
    const bottom: u32 = if (top + band < height) top + band else height;
    const left: u32 = 0;
    const right: u32 = width;
    if (debug) try c.out.print("left,top,right,bottom: {d},{d},{d},{d}\n", .{ left, top, right, bottom });

    if (debug) return;

    const divisor: f32 = @floatFromInt(bottom - top);
    var index: u32 = 0;
    while (index < right - left) : (index += 1) {
        const column = right - 1 - index;
        var rsum: f32 = 0;
        var gsum: f32 = 0;
        var bsum: f32 = 0;
        var y: u32 = top;
        while (y < bottom) : (y += 1) {
            const p = img.rgb(column, y);
            rsum += p[0];
            gsum += p[1];
            bsum += p[2];
        }
        try cformat.int(c.out, index);
        try c.out.writeByte(',');
        try cformat.fixed(a, c.out, rsum / divisor, 6);
        try c.out.writeByte(',');
        try cformat.fixed(a, c.out, gsum / divisor, 6);
        try c.out.writeByte(',');
        try cformat.fixed(a, c.out, bsum / divisor, 6);
        try c.out.writeByte('\n');
    }
}

/// Reads `path` and prints its spectrum.
pub fn run(c: ssftool.Ctx, io: Io, path: []const u8, debug: bool) ssftool.Error!void {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch {
        return c.fail("Error: file failed to open.", .{});
    };
    defer file.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = Io.File.Reader.init(file, io, &read_buffer);
    const data = try reader.interface.allocRemaining(c.gpa, .unlimited);

    const img = pfm.read(c.gpa, data) catch {
        return c.fail("Error: not a Portable Float Map.", .{});
    };
    defer img.deinit(c.gpa);

    try process(c, img, debug);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var stderr_buffer: [4 * 1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const errw = &stderr_file_writer.interface;

    const ctx: ssftool.Ctx = .{ .gpa = arena, .out = out, .errw = errw };

    const code: u8 = blk: {
        if (args.len < 2) break :blk ctx.failCode("Error: no file specified.", .{});
        const debug = args.len == 3 and std.mem.eql(u8, args[2], "debug");
        run(ctx, io, args[1], debug) catch |err| {
            if (err != error.Ssftool) errw.print("pfm2specdata: {s}\n", .{@errorName(err)}) catch {};
            break :blk 1;
        };
        break :blk 0;
    };

    out.flush() catch {};
    errw.flush() catch {};
    return code;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Runs the readout over a synthetic image and returns the stdout.
fn readout(a: std.mem.Allocator, img: pfm.Image, debug: bool) ![]u8 {
    var sink: std.ArrayList(u8) = .empty;
    var err_buf: [1024]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);

    var buf: [8192]u8 = undefined;
    var fixed: Io.Writer = .fixed(&buf);
    const c: ssftool.Ctx = .{ .gpa = a, .out = &fixed, .errw = &errw };
    try process(c, img, debug);
    try sink.appendSlice(a, fixed.buffered());
    return sink.toOwnedSlice(a);
}

test "finds the band and averages the columns, right to left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 4x4: a bright band on rows 1..2, each column carrying a distinct value.
    const pixels = [_][3]f32{
        .{ 0.1, 0.1, 0.2 }, .{ 0.3, 0.1, 0.4 }, .{ 0.5, 0.1, 0.6 }, .{ 0.7, 0.1, 0.8 },
        .{ 0.1, 0.9, 0.2 }, .{ 0.3, 0.9, 0.4 }, .{ 0.5, 0.9, 0.6 }, .{ 0.7, 0.9, 0.8 },
        .{ 0.1, 0.9, 0.2 }, .{ 0.3, 0.9, 0.4 }, .{ 0.5, 0.9, 0.6 }, .{ 0.7, 0.9, 0.8 },
        .{ 0.1, 0.1, 0.2 }, .{ 0.3, 0.1, 0.4 }, .{ 0.5, 0.1, 0.6 }, .{ 0.7, 0.1, 0.8 },
    };
    var flat: [48]f32 = undefined;
    for (pixels, 0..) |p, i| {
        flat[i * 3] = p[0];
        flat[i * 3 + 1] = p[1];
        flat[i * 3 + 2] = p[2];
    }
    const img: pfm.Image = .{ .width = 4, .height = 4, .channels = 3, .samples = &flat };

    // gmax = 0.9 -> gthreshold = 0.63, so the band is rows 1..2 and the crop is
    // the whole image (centred at 2, then clamped). Every column is averaged
    // over all four rows: column 3 is (0.7+0.7+0.7+0.7)/4 = 0.7 red, 0.1/0.9
    // mix -> 0.5 green, 0.8 blue.
    const got = try readout(a, img, false);
    try testing.expectEqualStrings(
        \\0,0.700000,0.500000,0.800000
        \\1,0.500000,0.500000,0.600000
        \\2,0.300000,0.500000,0.400000
        \\3,0.100000,0.500000,0.200000
        \\
    , got);
}

test "single channel images are rejected, not misread" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat = [_]f32{ 1, 2, 3, 4 };
    const img: pfm.Image = .{ .width = 2, .height = 2, .channels = 1, .samples = &flat };

    var out_buf: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);
    const c: ssftool.Ctx = .{ .gpa = a, .out = &out, .errw = &errw };

    try testing.expectError(error.Ssftool, process(c, img, false));
    try testing.expectEqualStrings("Error: image not RGB.\n", errw.buffered());
}

test "debug mode reports the detection instead of the readout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat = [_]f32{
        0.01, 0.02, 0.03, 0.01, 0.02, 0.03,
        0.01, 0.90, 0.03, 0.01, 0.80, 0.03,
        0.01, 0.02, 0.03, 0.01, 0.02, 0.03,
    };
    // rmax is 0.01, so rthreshold is 0.005 and no pixel can be below it: the
    // brightest green stays at its initial 0,0 and the band comes from column 0.
    const img: pfm.Image = .{ .width = 2, .height = 3, .channels = 3, .samples = &flat };
    const got = try readout(a, img, true);
    try testing.expectEqualStrings(
        \\rmax: 0.010000 gmax: 0.900000 bmax: 0.030000
        \\rthreshold: 0.005000 gthreshold: 0.630000 bthreshold: 0.015000
        \\largest green: 0,0
        \\left,top,right,bottom: 0,0,2,3
        \\
    , got);
}

test "detects the recorded fixture the way the reference does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const img = try pfm.read(a, @embedFile("testdata/spectrum16.pfm"));
    const got = try readout(a, img, true);

    // The reference C++ tool, run on the equivalent 16-bit TIFF, reports
    // rmax/gmax/bmax 15000/52500/21000, the brightest green at 2,20 and the
    // crop 0,0,16,100. ImageMagick scales 16-bit to float by multiplying by a
    // float reciprocal of 65535, so the maxima are compared after scaling back
    // and rounding rather than as decimal strings.
    var lines = std.mem.splitScalar(u8, got, '\n');
    try expectScaledLine(lines.next().?, .{ "rmax:", "gmax:", "bmax:" }, .{ 15000, 52500, 21000 });
    try expectScaledLine(lines.next().?, .{ "rthreshold:", "gthreshold:", "bthreshold:" }, .{ 7500, 36750, 10500 });
    try testing.expectEqualStrings("largest green: 2,20", lines.next().?);
    try testing.expectEqualStrings("left,top,right,bottom: 0,0,16,100", lines.next().?);
}

/// Asserts a "label: value" line of float maxima against the 16-bit integers
/// the reference reports for the same image.
fn expectScaledLine(line: []const u8, labels: [3][]const u8, want: [3]u16) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    for (labels, want) |label, expected| {
        try testing.expectEqualStrings(label, fields.next().?);
        const value = try std.fmt.parseFloat(f32, fields.next().?);
        const scaled: u16 = @intFromFloat(@round(value * 65535.0));
        try testing.expectEqual(expected, scaled);
    }
}
