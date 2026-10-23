//! Zig port of `ssftool` (https://github.com/butcherg/ssftool).
//!
//! The port reproduces the original C++ program's stdout, stderr and exit
//! status, including its idiosyncrasies:
//!
//!   * `getFile()` drops everything from the first '#' on, turns spaces and
//!     tabs into field separators, trims trailing whitespace, and skips a line
//!     only when the text before '#' is empty. A whitespace-only line is
//!     therefore *not* skipped: it becomes one empty field per separator
//!     character, i.e. a zero-valued row.
//!   * wavelengths are read with `atoi` (truncated to int) and channels with
//!     `atof`.
//!   * a trailing empty field is not produced by the split (`"1,2,"` has two
//!     fields), but interior ones are.
//!   * output uses `%0.2f` for wavelengths and `%f` (six decimals) for
//!     channels, byte-for-byte via `cformat`.
//!   * every failure prints one line to stderr and exits 1; an unrecognized
//!     operation prints a message and exits 0.
//!
//! Four upstream defects are deliberately *not* reproduced, because the
//! original crashes, aborts or reads out of bounds; each is marked DEVIATION
//! at its site and summarised in README.md:
//!
//!   1. `averagefiles` summed only `left[i].d[i]`, one channel per row, and
//!      walked past the end of the row vector for more than three rows (the
//!      original aborts on `_GLIBCXX_ASSERTIONS` builds). The documented
//!      per-channel average is implemented instead.
//!   2. `transpose` of ragged input read past the end of short rows (aborts
//!      upstream); short rows yield empty fields here.
//!   3. `averagefiles` with files of differing length read out of bounds.
//!   4. `multiply <missing file>` dereferenced a null `FILE*` (SIGSEGV).
//!
//! `metadata` is also dead code upstream: `getFile()` has already removed the
//! comment lines it looks for, so it prints nothing. That behaviour is kept.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cformat = @import("cformat.zig");

pub const Error = error{ Ssftool, StreamTooLong } || Allocator.Error || Io.Reader.Error || Io.Writer.Error;

/// `struct ssf_data`: a wavelength and up to three channel values.
pub const Row = struct {
    w: f32 = 0,
    d: [3]f32 = .{ 0, 0, 0 },
    /// Number of valid entries in `d` (1..3), as `d.size()` upstream.
    n: u3 = 0,
};

/// `struct channeldata`.
pub const Marker = struct {
    p: u32 = 0,
    v: f32 = 0,
    w: f32 = 0,
    s: f32 = 0,
};

/// Per-invocation plumbing: allocator plus the two output streams.
///
/// Every allocation is made with `gpa`; callers are expected to pass an arena,
/// since the operators build throwaway line/token tables.
pub const Ctx = struct {
    gpa: Allocator,
    out: *Io.Writer,
    errw: *Io.Writer,

    /// `err()`: message + newline to stderr, then a non-zero exit.
    pub fn fail(c: Ctx, comptime fmt: []const u8, args: anytype) Error {
        c.errw.print(fmt ++ "\n", args) catch {};
        return error.Ssftool;
    }

    /// `err()` for failures the front end detects itself.
    pub fn failCode(c: Ctx, comptime fmt: []const u8, args: anytype) u8 {
        c.errw.print(fmt ++ "\n", args) catch {};
        return 1;
    }
};

/// f32 division whose operands the optimizer cannot see through.
///
/// `smooth` divides 0.0 by 0.0 on its first row and `normalize` divides by 0.0
/// when every channel is zero. On x86-64 the hardware returns the indefinite
/// QNaN, whose sign bit is set, so glibc prints "-nan"; LLVM folds constant
/// `fdiv` to its own (positive) NaN. The volatile load keeps the hardware
/// result, which is what the C build produces.
fn div(a: f32, b: f32) f32 {
    var x = a;
    var y = b;
    const px: *volatile f32 = &x;
    const py: *volatile f32 = &y;
    return px.* / py.*;
}

// ---------------------------------------------------------------------------
// C library string/number primitives
// ---------------------------------------------------------------------------

fn isSpaceC(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == 0x0b or ch == 0x0c or ch == '\r';
}

/// `atoi`: skip whitespace, take an optional sign and decimal digits, ignore
/// the rest. Overflow saturates like `strtol` before the truncation to `int`.
pub fn cAtoi(s: []const u8) i32 {
    var i: usize = 0;
    while (i < s.len and isSpaceC(s[i])) i += 1;
    var negative = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        negative = s[i] == '-';
        i += 1;
    }
    var v: i64 = 0;
    var saturated = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        const digit: i64 = s[i] - '0';
        if (saturated) continue;
        if (v > @divTrunc(std.math.maxInt(i64) - digit, 10)) {
            saturated = true;
        } else {
            v = v * 10 + digit;
        }
    }
    if (saturated) {
        v = if (negative) std.math.minInt(i64) else std.math.maxInt(i64);
    } else if (negative) {
        v = -v;
    }
    return @truncate(v);
}

fn isDigitC(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn matchNoCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, haystack[0..needle.len]) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// Length of the prefix `strtod` would consume, or 0 when there is no number.
/// Leading whitespace is excluded from the result (see `cAtof`).
fn scanFloat(s: []const u8) struct { start: usize, end: usize } {
    var i: usize = 0;
    while (i < s.len and isSpaceC(s[i])) i += 1;
    const start = i;

    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    if (matchNoCase(s[i..], "infinity")) return .{ .start = start, .end = i + 8 };
    if (matchNoCase(s[i..], "inf")) return .{ .start = start, .end = i + 3 };
    if (matchNoCase(s[i..], "nan")) return .{ .start = start, .end = i + 3 };

    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        // Hexadecimal significand, as strtod accepts.
        var j = i + 2;
        var any = false;
        while (j < s.len and std.ascii.isHex(s[j])) : (j += 1) any = true;
        if (j < s.len and s[j] == '.') {
            j += 1;
            while (j < s.len and std.ascii.isHex(s[j])) : (j += 1) any = true;
        }
        if (!any) return .{ .start = start, .end = 0 };
        if (j < s.len and (s[j] == 'p' or s[j] == 'P')) {
            var k = j + 1;
            if (k < s.len and (s[k] == '+' or s[k] == '-')) k += 1;
            if (k < s.len and isDigitC(s[k])) {
                while (k < s.len and isDigitC(s[k])) k += 1;
                j = k;
            }
        }
        return .{ .start = start, .end = j };
    }

    var digits = false;
    while (i < s.len and isDigitC(s[i])) : (i += 1) digits = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and isDigitC(s[i])) : (i += 1) digits = true;
    }
    if (!digits) return .{ .start = start, .end = 0 };

    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and isDigitC(s[j])) {
            while (j < s.len and isDigitC(s[j])) j += 1;
            i = j;
        }
    }
    return .{ .start = start, .end = i };
}

/// `atof`: the longest numeric prefix of `s`, as a float. Anything unparsable
/// (including an empty string) is 0.0, as in C.
pub fn cAtof(s: []const u8) f32 {
    const span = scanFloat(s);
    if (span.end <= span.start) return 0;
    const v = std.fmt.parseFloat(f64, s[span.start..span.end]) catch return 0;
    return @floatCast(v);
}

/// `(int)` cast of a float as x86-64 `cvttss2si` performs it: truncation
/// towards zero, and INT_MIN for NaN or anything out of range.
pub fn floatToIntTrunc(v: f32) i32 {
    if (!(v >= -2147483648.0) or v >= 2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// The original's `split()`: one field per delimiter, and no trailing empty
/// field after a final delimiter (`"a,b,"` -> `["a","b"]`).
pub fn split(a: Allocator, s: []const u8, delim: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (std.mem.indexOf(u8, s, delim) == null) {
        try out.append(a, s);
        return out.toOwnedSlice(a);
    }
    var pos: usize = 0;
    while (pos < s.len) {
        const start = pos;
        pos = std.mem.indexOfPos(u8, s, pos, delim) orelse {
            try out.append(a, s[start..]);
            return out.toOwnedSlice(a);
        };
        try out.append(a, s[start..pos]);
        pos += delim.len;
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// `fgets(buffer, 256000, f)`: at most 255999 bytes, ending after a newline
/// when one is in reach. Longer lines are therefore split into several records.
const Fgets = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *Fgets) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const avail = self.data[self.pos..];
        const take = @min(avail.len, 255999);
        const end = if (std.mem.indexOfScalar(u8, avail[0..take], '\n')) |i| i + 1 else take;
        defer self.pos += end;
        return avail[0..end];
    }
};

/// `getFile()`: the file's records with comments removed and separators
/// normalised, ready for `parseData`/`list`.
pub fn readLines(a: Allocator, reader: *Io.Reader) Error![]const []const u8 {
    const data = try reader.allocRemaining(a, .unlimited);
    var lines: std.ArrayList([]const u8) = .empty;
    var it: Fgets = .{ .data = data };
    while (it.next()) |chunk| {
        // fgets fills a byte buffer, but the original wraps it in std::string,
        // which stops at the first NUL byte.
        const raw = if (std.mem.indexOfScalar(u8, chunk, 0)) |i| chunk[0..i] else chunk;
        const prefix = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        if (prefix.len == 0) continue;

        const line = try a.dupe(u8, prefix);
        for (line) |*ch| {
            if (ch.* == ' ' or ch.* == '\t') ch.* = ',';
        }
        var end = line.len;
        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\n' or
            line[end - 1] == '\r' or line[end - 1] == '\t')) end -= 1;
        try lines.append(a, line[0..end]);
    }
    return lines.toOwnedSlice(a);
}

/// `get_Data()`.
pub fn parseData(a: Allocator, c: Ctx, lines: []const []const u8) Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    for (lines) |line| {
        if (line.len == 0) continue; // blank lines, usually at the end of a file
        if (line[0] == '#') continue; // comments (already removed by readLines)
        const tok = try split(a, line, ",");
        if (tok.len < 2) {
            return c.fail("get_Data error: line does not contain sufficient number of values ({s})", .{line});
        }
        var r: Row = .{};
        r.w = @floatFromInt(cAtoi(tok[0]));
        r.d[0] = cAtof(tok[1]);
        if (tok.len >= 3) r.d[1] = cAtof(tok[2]);
        if (tok.len >= 4) r.d[2] = cAtof(tok[3]);
        r.n = @intCast(@min(tok.len - 1, 3));
        try rows.append(a, r);
    }
    return rows.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

fn printRow(c: Ctx, r: Row) Error!void {
    try cformat.fixed(c.gpa, c.out, r.w, 2);
    for (r.d[0..r.n]) |v| {
        try c.out.writeByte(',');
        try cformat.fixed(c.gpa, c.out, v, 6);
    }
    try c.out.writeByte('\n');
}

pub fn printRows(c: Ctx, rows: []const Row) Error!void {
    for (rows) |r| try printRow(c, r);
}

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

pub fn list(c: Ctx, reader: *Io.Reader, wavelengths: bool) Error!void {
    const a = c.gpa;
    const lines = try readLines(a, reader);
    if (lines.len == 0) return c.fail("list error: no data.", .{});
    if (wavelengths) {
        for (lines, 0..) |line, i| {
            const tok = try split(a, line, ",");
            if (i != 0) try c.out.writeByte(',');
            try c.out.writeAll(tok[0]);
        }
        try c.out.writeByte('\n');
    } else {
        for (lines) |line| {
            try c.out.writeAll(line);
            try c.out.writeByte('\n');
        }
    }
}

fn channelExtract(a: Allocator, lines: []const []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        const keep = std.mem.startsWith(u8, line, "x") or
            std.mem.startsWith(u8, line, "red") or
            std.mem.startsWith(u8, line, "green") or
            std.mem.startsWith(u8, line, "blue");
        if (!keep) continue;
        // erase(0, find_first_of(',') + 1): drop the field label.
        const comma = std.mem.indexOfScalar(u8, line, ',') orelse {
            try out.append(a, line);
            continue;
        };
        try out.append(a, line[comma + 1 ..]);
    }
    return out.toOwnedSlice(a);
}

pub fn extract(c: Ctx, reader: *Io.Reader) Error!void {
    const lines = try readLines(c.gpa, reader);
    if (lines.len == 0) return c.fail("extract error: no data.", .{});
    for (try channelExtract(c.gpa, lines)) |line| {
        try c.out.writeAll(line);
        try c.out.writeByte('\n');
    }
}

pub fn transpose(c: Ctx, reader: *Io.Reader) Error!void {
    const a = c.gpa;
    const lines = try readLines(a, reader);
    if (lines.len == 0) return c.fail("transpose error: no data.", .{});

    const matrix = try a.alloc([]const []const u8, lines.len);
    for (lines, matrix) |line, *tokens| tokens.* = try split(a, line, ",");

    const cols = matrix[0].len;
    for (0..cols) |i| {
        for (matrix, 0..) |tokens, j| {
            if (j != 0) try c.out.writeByte(',');
            // DEVIATION: the original reads past the end of shorter rows here
            // (and aborts on hardened builds); empty fields are emitted.
            if (i < tokens.len) try c.out.writeAll(tokens[i]);
        }
        try c.out.writeByte('\n');
    }
}

/// `channelMaxes()`, returned as [blue, green, red].
pub fn channelMaxes(rows: []const Row) [3]Marker {
    var bmax: Marker = .{};
    var gmax: Marker = .{};
    var rmax: Marker = .{};
    for (rows, 0..) |r, i| {
        if (r.n >= 1 and r.d[0] > rmax.v) {
            rmax.v = r.d[0];
            rmax.p = @intCast(i);
        }
        if (r.n >= 2 and r.d[1] > gmax.v) {
            gmax.v = r.d[1];
            gmax.p = @intCast(i);
        }
        if (r.n >= 3 and r.d[2] > bmax.v) {
            bmax.v = r.d[2];
            bmax.p = @intCast(i);
        }
    }
    return .{ bmax, gmax, rmax };
}

pub fn channelMaxesOp(c: Ctx, reader: *Io.Reader) Error!void {
    const a = c.gpa;
    const lines = try readLines(a, reader);
    if (lines.len == 0) return c.fail("channelmaxes error: no data.", .{});
    const m = channelMaxes(try parseData(a, c, lines));
    try c.out.writeAll("blue:");
    try cformat.fixed(a, c.out, m[0].v, 6);
    try c.out.print(",{d};green:", .{m[0].p});
    try cformat.fixed(a, c.out, m[1].v, 6);
    try c.out.print(",{d};red:", .{m[1].p});
    try cformat.fixed(a, c.out, m[2].v, 6);
    try c.out.print(",{d}\n", .{m[2].p});
}

/// `wavelengthcalibrate()`: anchor the markers, then walk the wavelength
/// outwards from them at the local slope.
pub fn wavelengthCalibrate(c: Ctx, rows: []Row, markers: []Marker) Error!void {
    if (markers.len < 2) {
        return c.fail("wavelengthcalibrate error: need at least two markers", .{});
    }

    // 1. slope between consecutive markers.
    for (0..markers.len - 1) |i| {
        const dw = markers[i + 1].w - markers[i].w;
        // The original subtracts the unsigned positions, so a wrapped
        // difference is reproduced with the same wrapping.
        const dp: f32 = @floatFromInt(markers[i + 1].p -% markers[i].p);
        markers[i].s = div(dw, dp);
    }
    markers[markers.len - 1].s = markers[markers.len - 2].s;

    // 2. the markers' own wavelengths.
    for (markers) |mk| {
        if (mk.p >= rows.len) {
            return c.fail("wavelengthcalibrate error: marker position {d} is past the end of the data ({d} rows)", .{ mk.p, rows.len });
        }
        rows[mk.p].w = mk.w;
    }

    // 3. between markers.
    for (0..markers.len - 1) |i| {
        var j: u32 = markers[i].p;
        while (j < markers[i + 1].p) : (j += 1) rows[j + 1].w = rows[j].w + markers[i].s;
    }

    // 4. from the highest marker to the end of the spectrum.
    if (rows.len >= 2) {
        const s = markers[markers.len - 1].s;
        var j: u32 = markers[markers.len - 1].p;
        while (j < rows.len - 1) : (j += 1) rows[j + 1].w = rows[j].w + s;
        rows[rows.len - 1].w = rows[rows.len - 2].w + s;
    }

    // 5. from the lowest marker down to the start of the spectrum.
    var j: u32 = markers[0].p;
    while (j > 0) : (j -= 1) rows[j - 1].w = rows[j].w - markers[0].s;
}

/// `wavelengthcalibrate <file> red=..,green=..,blue=.. <calibfile>`: the
/// markers are the channel maxima of the calibration spectrum.
pub fn wavelengthCalibrateRgb(
    c: Ctx,
    reader: *Io.Reader,
    calib_reader: *Io.Reader,
    bluew: i32,
    greenw: i32,
    redw: i32,
) Error!void {
    const a = c.gpa;
    const calib_rows = try parseData(a, c, try readLines(a, calib_reader));
    var markers = channelMaxes(calib_rows);
    markers[0].w = @floatFromInt(bluew);
    markers[1].w = @floatFromInt(greenw);
    markers[2].w = @floatFromInt(redw);

    var used: [3]Marker = undefined;
    var n: usize = 0;
    for (markers) |mk| {
        if (mk.w != 0) {
            used[n] = mk;
            n += 1;
        }
    }
    if (n < 2) return c.fail("wavelengthcalibrate (RGB) error: need at least two channels", .{});

    const rows = try parseData(a, c, try readLines(a, reader));
    if (rows.len == 0) return c.fail("wavelengthcalibrate error: no data.", .{});

    try wavelengthCalibrate(c, rows, used[0..n]);
    try printRows(c, rows);
}

/// Sums `other` into `data`, channel by channel.
///
/// DEVIATION: upstream accumulated `data[i].d[i] += other[i].d[i]`, which sums
/// one channel per row (row 0's red, row 1's green, row 2's blue, ...) and,
/// from the fourth row on, indexes past the end of a three-channel row, which
/// aborts on a hardened build.
fn addRows(data: []Row, other: []const Row) void {
    for (data, other) |*left, right| {
        for (0..@min(left.n, right.n)) |j| left.d[j] += right.d[j];
    }
}

const PowerEntry = struct { w: i32, v: f32 };

/// `getPowerData()`: a map keyed by integer wavelength; a repeated wavelength
/// keeps the last value, and the result is ordered by wavelength.
fn powerData(a: Allocator, c: Ctx, lines: []const []const u8) Error![]PowerEntry {
    var entries: std.ArrayList(PowerEntry) = .empty;
    for (lines) |line| {
        // Note: unlike get_Data, blank lines are not skipped here.
        const tok = try split(a, line, ",");
        if (tok.len < 2) {
            return c.fail("getPowerData error: line does not contain sufficient number of values ({s})", .{line});
        }
        const w = cAtoi(tok[0]);
        const v = cAtof(tok[1]);
        var replaced = false;
        for (entries.items) |*e| {
            if (e.w == w) {
                e.v = v;
                replaced = true;
                break;
            }
        }
        if (!replaced) try entries.append(a, .{ .w = w, .v = v });
    }
    std.mem.sort(PowerEntry, entries.items, {}, struct {
        fn lt(_: void, x: PowerEntry, y: PowerEntry) bool {
            return x.w < y.w;
        }
    }.lt);
    return entries.toOwnedSlice(a);
}

pub fn powerCalibrate(c: Ctx, io: Io, reader: *Io.Reader, calib_path: []const u8) Error!void {
    const a = c.gpa;
    const rows = try parseData(a, c, try readLines(a, reader));
    if (rows.len == 0) return c.fail("powercalibrate error: no data.", .{});

    // Opened only after the data has been read, as upstream does.
    const file = Io.Dir.cwd().openFile(io, calib_path, .{}) catch return c.fail(
        "powercalibrate error: power calibration file {s} not found.",
        .{calib_path},
    );
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = Io.File.Reader.init(file, io, &buf);

    const calib = try powerData(a, c, try readLines(a, &fr.interface));

    for (rows) |*r| {
        const key = floatToIntTrunc(r.w);
        var factor: f32 = undefined;

        var exact: ?usize = null;
        for (calib, 0..) |e, i| {
            if (e.w == key) {
                exact = i;
                break;
            }
        }

        if (exact) |i| {
            factor = calib[i].v;
        } else {
            // lower_bound: first entry at or above the wavelength.
            var hi: usize = 0;
            while (hi < calib.len and calib[hi].w < key) hi += 1;
            // DEVIATION: the original dereferences the end/begin iterators
            // here, reading uninitialised memory.
            if (hi == 0 or hi >= calib.len) {
                try c.errw.writeAll("powercalibrate error: wavelength ");
                try cformat.fixed(a, c.errw, r.w, 2);
                try c.errw.writeAll(" is outside the power calibration range\n");
                return error.Ssftool;
            }
            const lo = hi - 1;
            const mult = div(
                r.w - @as(f32, @floatFromInt(calib[hi].w)),
                @as(f32, @floatFromInt(calib[lo].w - calib[hi].w)),
            );
            factor = calib[hi].v + (calib[lo].v - calib[hi].v) * mult;
        }

        for (r.d[0..r.n]) |*d| d.* = div(d.*, factor);
    }
    try printRows(c, rows);
}

pub fn normalize(c: Ctx, reader: *Io.Reader) Error!void {
    const rows = try parseData(c.gpa, c, try readLines(c.gpa, reader));
    if (rows.len == 0) return c.fail("normalize error: no data.", .{});

    var maxval: f32 = 0.0;
    for (rows) |r| {
        for (r.d[0..r.n]) |v| {
            if (v > maxval) maxval = v;
        }
    }
    for (rows) |*r| {
        for (r.d[0..r.n]) |*d| d.* = div(d.*, maxval);
    }
    try printRows(c, rows);
}

pub fn multiply(c: Ctx, reader: *Io.Reader, m: f32) Error!void {
    const rows = try parseData(c.gpa, c, try readLines(c.gpa, reader));
    if (rows.len == 0) return c.fail("normalize error: no data.", .{});
    for (rows) |*r| {
        for (r.d[0..r.n]) |*d| d.* *= m;
    }
    try printRows(c, rows);
}

/// `averagechannels`: the mean of a row's channels, one value per row.
pub fn averageChannels(c: Ctx, reader: *Io.Reader) Error!void {
    const rows = try parseData(c.gpa, c, try readLines(c.gpa, reader));
    if (rows.len == 0) return c.fail("average error: no data.", .{});
    for (rows) |r| {
        var sum: f32 = 0.0;
        for (r.d[0..r.n]) |v| sum += v;
        try cformat.fixed(c.gpa, c.out, r.w, 2);
        try c.out.writeByte(',');
        try cformat.fixed(c.gpa, c.out, div(sum, @floatFromInt(r.n)), 6);
        try c.out.writeByte('\n');
    }
}

/// `averagefiles`: the per-channel mean across every input file.
///
/// DEVIATION: the original accumulated `left[i].d[i] += right[i].d[i]`, which
/// mixes channels within a row and walks off the end of the row's channel
/// vector after the third row (SIGABRT on a hardened build). The documented
/// per-channel average is implemented instead.
pub fn averageFiles(c: Ctx, io: Io, stdin_reader: *Io.Reader, paths: []const []const u8) Error!void {
    const a = c.gpa;
    var data = try parseData(a, c, try readLines(a, stdin_reader));
    var count: usize = if (data.len > 0) 1 else 0;

    for (paths) |path| {
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch {
            return c.fail("averagefiles error: data file not found: {s}", .{path});
        };
        defer file.close(io);

        var buf: [64 * 1024]u8 = undefined;
        var fr = Io.File.Reader.init(file, io, &buf);
        const other = try parseData(a, c, try readLines(a, &fr.interface));

        if (data.len == 0) {
            data = other;
        } else {
            // DEVIATION: the original reads out of bounds when the files differ
            // in length.
            if (other.len != data.len) {
                return c.fail("averagefiles error: data files have different numbers of lines", .{});
            }
            addRows(data, other);
        }
        count += 1;
    }

    const divisor: f32 = @floatFromInt(count);
    for (data) |*r| {
        for (r.d[0..r.n]) |*d| d.* = div(d.*, divisor);
    }
    try printRows(c, data);
}

/// `linearpower <lower,upper,interval,lowvalue,highvalue>`.
pub fn linearPower(c: Ctx, lower: f32, upper: f32, interval: f32, lowval: f32, hival: f32) Error!void {
    const increment = div(hival - lowval, div(upper - lower, interval));
    try cformat.fixed(c.gpa, c.out, lower, 2);
    try c.out.writeByte(',');
    try cformat.fixed(c.gpa, c.out, lowval, 6);
    try c.out.writeByte('\n');

    var prev = lowval;
    var step = lower + interval;
    while (step < upper) : (step += interval) {
        try cformat.fixed(c.gpa, c.out, step, 2);
        try c.out.writeByte(',');
        try cformat.fixed(c.gpa, c.out, prev + increment, 6);
        try c.out.writeByte('\n');
        prev += increment;
    }

    try cformat.fixed(c.gpa, c.out, upper, 2);
    try c.out.writeByte(',');
    try cformat.fixed(c.gpa, c.out, hival, 6);
    try c.out.writeByte('\n');
}

/// `intervalize`: resample onto a fixed wavelength grid, choosing the nearest
/// neighbouring measurement (the interpolation is left as a TODO upstream).
pub fn intervalize(c: Ctx, reader: *Io.Reader, lower: f32, upper: f32, interval: f32) Error!void {
    const a = c.gpa;
    const rows = try parseData(a, c, try readLines(a, reader));
    if (rows.len == 0) return c.fail("intervalize error: no data.", .{});

    if (rows[0].w > lower) {
        try c.errw.writeAll("intervalize error: data doesn't cover lower bound: ");
        try cformat.fixed(a, c.errw, rows[0].w, 2);
        try c.errw.writeByte('\n');
        return error.Ssftool;
    }
    if (rows[rows.len - 1].w < upper) {
        try c.errw.writeAll("intervalize error: data doesn't cover upper bound: ");
        try cformat.fixed(a, c.errw, rows[rows.len - 1].w, 2);
        try c.errw.writeByte('\n');
        return error.Ssftool;
    }

    const last = rows.len - 1;
    var i: usize = 0;
    var step = lower;
    while (step <= upper) : (step += interval) {
        // Walk up to the lower bound.
        while (i < last and rows[i].w < lower) i += 1;

        if (rows[i].w == step) { // exact hit: use the measurement as-is
            try printRow(c, rows[i]);
            i += 1;
            continue;
        }
        while (i < last and rows[i].w < step) i += 1;

        var out: Row = .{ .w = step };
        if (i == last) {
            // Past the end of the data: take the last measurement.
            out.n = rows[i].n;
            out.d = rows[i].d;
            try printRow(c, out);
            return;
        }
        // Nearest neighbour: `interp` is the fraction of the interval between
        // this measurement and the next.
        const interp = div(rows[i + 1].w - rows[i].w, rows[i].w - step);
        out.n = rows[i].n;
        for (0..rows[i].n) |j| {
            out.d[j] = if (interp > 0.5) rows[i + 1].d[j] else rows[i].d[j];
        }
        try printRow(c, out);
        i += 1;
    }
}

/// `format`: integer wavelengths and channels rounded to `precision` decimals.
pub fn formatOp(c: Ctx, reader: *Io.Reader, precision: i32) Error!void {
    const a = c.gpa;
    const rows = try parseData(a, c, try readLines(a, reader));
    if (rows.len == 0) return c.fail("ssfformat error: no data.", .{});
    for (rows) |r| {
        try cformat.int(c.out, floatToIntTrunc(r.w));
        for (r.d[0..r.n]) |v| {
            try c.out.writeByte(',');
            try cformat.fixed(a, c.out, v, precision);
        }
        try c.out.writeByte('\n');
    }
}

/// `smooth`: a trailing moving average over up to `lookback` samples. The first
/// row averages zero samples, i.e. 0.0/0.0, which prints as "-nan".
pub fn smooth(c: Ctx, reader: *Io.Reader, lookback: i32) Error!void {
    const rows = try parseData(c.gpa, c, try readLines(c.gpa, reader));
    if (rows.len == 0) return c.fail("smooth error: no data.", .{});

    for (rows, 0..) |r, i| {
        const lb: usize = if (lookback < 0) i else @min(i, @as(usize, @intCast(lookback)));
        var out: Row = .{ .w = r.w, .n = r.n };
        for (0..r.n) |j| {
            var sum: f32 = 0.0;
            var k: usize = 0;
            while (k < lb) : (k += 1) sum += rows[i - k].d[j];
            out.d[j] = div(sum, @floatFromInt(lb));
        }
        try printRow(c, out);
    }
}

/// `metadata`: prints nothing, and never has.
///
/// The original reads through `getFile()`, which already truncates every line
/// at the first '#' and drops the ones that become empty, so the `line[0] ==
/// '#'` test in `getMetadata()` can never be true. The operator is dead code
/// upstream; this port keeps the observable behaviour (no output, status 0)
/// rather than inventing a different one.
pub fn metadata(c: Ctx, reader: *Io.Reader) Error!void {
    _ = try readLines(c.gpa, reader);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "cAtoi matches atoi" {
    try testing.expectEqual(@as(i32, 0), cAtoi(""));
    try testing.expectEqual(@as(i32, 0), cAtoi("x"));
    try testing.expectEqual(@as(i32, 42), cAtoi("42"));
    try testing.expectEqual(@as(i32, 42), cAtoi("  42abc"));
    try testing.expectEqual(@as(i32, -42), cAtoi("-42"));
    try testing.expectEqual(@as(i32, 42), cAtoi("+42"));
    try testing.expectEqual(@as(i32, 12), cAtoi("12.9")); // atoi stops at '.'
    try testing.expectEqual(@as(i32, 400), cAtoi("400\n"));
}

test "cAtof matches atof" {
    try testing.expectEqual(@as(f32, 0), cAtof(""));
    try testing.expectEqual(@as(f32, 0), cAtof("x"));
    try testing.expectEqual(@as(f32, 1.5), cAtof("1.5"));
    try testing.expectEqual(@as(f32, 0.000071), cAtof("0.000071"));
    try testing.expectEqual(@as(f32, 1.5), cAtof("1.5x"));
    try testing.expectEqual(@as(f32, -1.5), cAtof(" -1.5e0"));
    try testing.expectEqual(@as(f32, 150), cAtof("1.5e2"));
    try testing.expectEqual(@as(f32, 0.5), cAtof(".5"));
    try testing.expect(std.math.isInf(cAtof("inf")));
    try testing.expect(std.math.isNan(cAtof("nan")));
}

test "split drops a trailing empty field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try split(a, "a", ",");
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("a", one[0]);

    const two = try split(a, "a,b", ",");
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("a", two[0]);
    try testing.expectEqualStrings("b", two[1]);

    const trailing = try split(a, "a,b,", ",");
    try testing.expectEqual(@as(usize, 2), trailing.len);

    const empty = try split(a, ",", ",");
    try testing.expectEqual(@as(usize, 1), empty.len);
    try testing.expectEqualStrings("", empty[0]);

    const four = try split(a, ",,,", ",");
    try testing.expectEqual(@as(usize, 3), four.len);
}

test "readLines reproduces getFile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reader = Io.Reader.fixed("width: 2474\r\n1,2,3 # trailing comment\n\n   \n\t\n#only comment\n4 5\t6");
    const lines = try readLines(a, &reader);
    try testing.expectEqual(@as(usize, 6), lines.len);
    try testing.expectEqualStrings("width:,2474", lines[0]);
    try testing.expectEqualStrings("1,2,3,", lines[1]); // space before '#' became ','
    try testing.expectEqualStrings("", lines[2]); // blank line survives
    try testing.expectEqualStrings(",,,", lines[3]); // "   " -> three empty fields
    try testing.expectEqualStrings(",", lines[4]);
    try testing.expectEqualStrings("4,5,6", lines[5]); // no trailing newline
}

test "parseData reads wavelengths with atoi and channels with atof" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&sink);
    var err_buf: [1024]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);
    const c: Ctx = .{ .gpa = a, .out = &out, .errw = &errw };

    var reader = Io.Reader.fixed("400.7,1,2,3\n405,4,5\n\n");
    const rows = try parseData(a, c, try readLines(a, &reader));
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(f32, 400), rows[0].w);
    try testing.expectEqual(@as(u3, 3), rows[0].n);
    try testing.expectEqual(@as(f32, 2), rows[0].d[1]);
    try testing.expectEqual(@as(u3, 2), rows[1].n);
}

test "parseData rejects a short line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&sink);
    var err_buf: [1024]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);
    const c: Ctx = .{ .gpa = a, .out = &out, .errw = &errw };

    var reader = Io.Reader.fixed("400\n");
    try testing.expectError(error.Ssftool, parseData(a, c, try readLines(a, &reader)));
    try testing.expectEqualStrings(
        "get_Data error: line does not contain sufficient number of values (400)\n",
        errw.buffered(),
    );
}

test "averagefiles sums every channel of every row" {
    var left = [_]Row{
        .{ .w = 400, .d = .{ 1, 2, 3 }, .n = 3 },
        .{ .w = 405, .d = .{ 4, 5, 6 }, .n = 3 },
        .{ .w = 410, .d = .{ 7, 8, 9 }, .n = 3 },
        .{ .w = 415, .d = .{ 10, 11, 12 }, .n = 3 },
    };
    const right = [_]Row{
        .{ .w = 400, .d = .{ 10, 20, 30 }, .n = 3 },
        .{ .w = 405, .d = .{ 40, 50, 60 }, .n = 3 },
        .{ .w = 410, .d = .{ 70, 80, 90 }, .n = 3 },
        .{ .w = 415, .d = .{ 100, 110, 120 }, .n = 3 },
    };
    addRows(&left, &right);

    try testing.expectEqual(@as(f32, 11), left[0].d[0]);
    try testing.expectEqual(@as(f32, 22), left[0].d[1]);
    try testing.expectEqual(@as(f32, 33), left[0].d[2]);
    // Rows past the third are the ones upstream reads out of bounds on.
    try testing.expectEqual(@as(f32, 110), left[3].d[0]);
    try testing.expectEqual(@as(f32, 121), left[3].d[1]);
    try testing.expectEqual(@as(f32, 132), left[3].d[2]);
}

test "channelMaxes picks the first maximum and orders blue,green,red" {
    var rows = [_]Row{
        .{ .w = 0, .d = .{ 1, 9, 3 }, .n = 3 },
        .{ .w = 1, .d = .{ 9, 9, 3 }, .n = 3 },
        .{ .w = 2, .d = .{ 4, 5, 8 }, .n = 3 },
    };
    const m = channelMaxes(&rows);
    try testing.expectEqual(@as(u32, 2), m[0].p); // blue
    try testing.expectEqual(@as(f32, 8), m[0].v);
    try testing.expectEqual(@as(u32, 0), m[1].p); // green: ties keep the first
    try testing.expectEqual(@as(f32, 9), m[1].v);
    try testing.expectEqual(@as(u32, 1), m[2].p); // red
    try testing.expectEqual(@as(f32, 9), m[2].v);
}
