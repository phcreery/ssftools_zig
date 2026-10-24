//! Operators that turn w,r,g,b spectrum rows into profile data.
//!
//! Input is comma-separated: one record per row, `#` starts a comment, spaces
//! and tabs separate fields as commas do, and trailing whitespace is trimmed. A
//! record whose text before `#` is empty is dropped, so a blank line vanishes
//! while a whitespace-only one survives as empty fields.
//!
//! Wavelengths are read as leading integers and channel values as leading
//! decimals, so a field may carry a unit ("400nm"). Output writes wavelengths
//! with two decimals and channels with six.
//!
//! A failure prints one line to stderr and exits 1; an unrecognized operator is
//! reported but exits 0.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cformat = @import("cformat.zig");

pub const Error = error{ Ssftool, StreamTooLong } || Allocator.Error || Io.Reader.Error || Io.Writer.Error;

pub const Row = struct {
    /// Wavelength in nanometres.
    wavelength: f32 = 0,
    /// One to three channel values.
    values: [3]f32 = .{ 0, 0, 0 },
    /// How many entries of `values` are set.
    count: u3 = 0,
};

/// A wavelength reference: a column in the calibration data, its channel value,
/// the wavelength that column is known to carry, and the local slope.
pub const Marker = struct {
    column: u32 = 0,
    value: f32 = 0,
    wavelength: f32 = 0,
    slope: f32 = 0,
};

/// Per-invocation plumbing: allocator plus the two output streams.
///
/// Every allocation is made with `gpa`; callers are expected to pass an arena,
/// since the operators build throwaway line/token tables.
pub const Ctx = struct {
    gpa: Allocator,
    out: *Io.Writer,
    errw: *Io.Writer,

    /// Reports a failure on stderr, one line.
    pub fn fail(c: Ctx, comptime fmt: []const u8, args: anytype) Error {
        c.errw.print(fmt ++ "\n", args) catch {};
        return error.Ssftool;
    }

    /// `fail` for the CLI, whose call sites return an exit code.
    pub fn failCode(c: Ctx, comptime fmt: []const u8, args: anytype) u8 {
        c.fail(fmt, args) catch {};
        return 1;
    }
};

// ---------------------------------------------------------------------------
// Field parsing
// ---------------------------------------------------------------------------
//
// Fields may carry a unit ("400nm"), so a leading number is taken and the rest
// ignored. Anything unparsable is 0.

/// Leading integer: optional sign, then digits.
pub fn intField(text: []const u8) i32 {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    const negative = i < text.len and text[i] == '-';
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    const digits = text[start..i];
    if (digits.len == 0) return 0;
    const magnitude = std.fmt.parseInt(i64, digits, 10) catch std.math.maxInt(i64);
    return std.math.lossyCast(i32, if (negative) -magnitude else magnitude);
}

/// Leading decimal number: optional sign, digits with an optional point and
/// exponent, or `inf`/`nan`.
pub fn floatField(text: []const u8) f32 {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    const start = i;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;

    if (std.ascii.startsWithIgnoreCase(text[i..], "infinity")) {
        i += 8;
    } else if (std.ascii.startsWithIgnoreCase(text[i..], "inf")) {
        i += 3;
    } else if (std.ascii.startsWithIgnoreCase(text[i..], "nan")) {
        i += 3;
    } else {
        var digits = false;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) digits = true;
        if (i < text.len and text[i] == '.') {
            i += 1;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) digits = true;
        }
        if (!digits) return 0;
        if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
            var j = i + 1;
            if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
            if (j < text.len and std.ascii.isDigit(text[j])) {
                while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
                i = j;
            }
        }
    }
    const value = std.fmt.parseFloat(f64, text[start..i]) catch return 0;
    return @floatCast(value);
}

/// The text before the first `delim`, or all of it.
pub fn firstField(text: []const u8, delim: u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, delim) orelse text.len];
}

/// Every field of `text`, including a trailing empty one. Only `transpose`
/// needs the fields addressable, so the allocation is worth it there.
fn fields(a: Allocator, text: []const u8, delim: u8) Error![]const []const u8 {
    var collected: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, delim);
    while (parts.next()) |part| try collected.append(a, part);
    return collected.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// The input as records: everything from a '#' on is dropped, spaces and tabs
/// separate fields, trailing whitespace is trimmed, and a record whose text
/// before '#' is empty is skipped. A blank line therefore vanishes, while a
/// whitespace-only one survives as empty fields.
pub fn readLines(a: Allocator, reader: *Io.Reader) Error![]const []const u8 {
    const data = try reader.allocRemaining(a, .unlimited);
    if (data.len == 0) return &.{};

    // The newline that ends the file ends the last record rather than starting
    // an empty one; every other newline does start one, blank lines included.
    const body = if (data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;

    var lines: std.ArrayList([]const u8) = .empty;
    var records = std.mem.splitScalar(u8, body, '\n');
    while (records.next()) |record| {
        // A comment line is dropped whole; text after '#' on a data line is
        // dropped with it.
        if (std.mem.startsWith(u8, record, "#")) continue;
        const line = try a.dupe(u8, firstField(record, '#'));
        for (line) |*ch| {
            if (ch.* == ' ' or ch.* == '\t') ch.* = ',';
        }
        try lines.append(a, std.mem.trimEnd(u8, line, " \n\r\t"));
    }
    return lines.toOwnedSlice(a);
}

/// Parses records into rows.
pub fn parseData(a: Allocator, c: Ctx, lines: []const []const u8) Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    for (lines) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, ',');
        const wavelength = parts.next() orelse continue;
        const first = parts.next() orelse {
            return c.fail("get_Data error: line does not contain sufficient number of values ({s})", .{line});
        };

        var row: Row = .{ .wavelength = @floatFromInt(intField(wavelength)), .values = .{ floatField(first), 0, 0 }, .count = 1 };
        for (row.values[1..]) |*value| {
            const part = parts.next() orelse break;
            value.* = floatField(part);
            row.count += 1;
        }
        try rows.append(a, row);
    }
    return rows.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

fn printRow(c: Ctx, r: Row) Error!void {
    try cformat.fixed(c.gpa, c.out, r.wavelength, 2);
    for (r.values[0..r.count]) |value| {
        try c.out.writeByte(',');
        // The shortest decimal that reads back to the same float, so a chain of
        // stages loses no digits however small the values get. `format` rounds
        // for the file that leaves the pipeline.
        try c.out.print("{d}", .{value});
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
            if (i != 0) try c.out.writeByte(',');
            try c.out.writeAll(firstField(line, ','));
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
    for (lines, matrix) |line, *row| row.* = try fields(a, line, ',');

    const cols = matrix[0].len;
    for (0..cols) |i| {
        for (matrix, 0..) |tokens, j| {
            if (j != 0) try c.out.writeByte(',');
            // Short rows yield empty fields rather than an error.
            if (i < tokens.len) try c.out.writeAll(tokens[i]);
        }
        try c.out.writeByte('\n');
    }
}

/// The brightest column of each channel, as [blue, green, red].
pub fn channelMaxes(rows: []const Row) [3]Marker {
    var bmax: Marker = .{};
    var gmax: Marker = .{};
    var rmax: Marker = .{};
    for (rows, 0..) |r, i| {
        if (r.count >= 1 and r.values[0] > rmax.value) {
            rmax.value = r.values[0];
            rmax.column = @intCast(i);
        }
        if (r.count >= 2 and r.values[1] > gmax.value) {
            gmax.value = r.values[1];
            gmax.column = @intCast(i);
        }
        if (r.count >= 3 and r.values[2] > bmax.value) {
            bmax.value = r.values[2];
            bmax.column = @intCast(i);
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
    try cformat.fixed(a, c.out, m[0].value, 6);
    try c.out.print(",{d};green:", .{m[0].column});
    try cformat.fixed(a, c.out, m[1].value, 6);
    try c.out.print(",{d};red:", .{m[1].column});
    try cformat.fixed(a, c.out, m[2].value, 6);
    try c.out.print(",{d}\n", .{m[2].column});
}

/// `wavelengthcalibrate()`: anchor the markers, then walk the wavelength
/// outwards from them at the local slope.
///
/// Markers may ascend or descend by column. A descending set — a capture whose
/// long wavelengths sit on the right — is handled by mirroring the rows and the
/// marker columns, running the ascending walk, and mirroring back, so the
/// wavelengths land on the right pixels and descend down the file, which
/// `intervalize` accepts. Upstream instead subtracts the unsigned columns, so a
/// descending pair wraps to about 4e9 and every wavelength collapses onto the
/// last marker.
pub fn wavelengthCalibrate(c: Ctx, rows: []Row, markers: []Marker) Error!void {
    if (markers.len < 2) {
        return c.fail("wavelengthcalibrate error: need at least two markers", .{});
    }

    for (markers) |mk| {
        if (mk.column >= rows.len) {
            return c.fail("wavelengthcalibrate error: marker position {d} is past the end of the data ({d} rows)", .{ mk.column, rows.len });
        }
    }

    var ascending = true;
    var descending = true;
    for (0..markers.len - 1) |i| {
        if (markers[i + 1].column == markers[i].column) {
            return c.fail("wavelengthcalibrate error: two markers share column {d}", .{markers[i].column});
        }
        if (markers[i + 1].column > markers[i].column) descending = false else ascending = false;
    }
    if (!ascending and !descending) {
        return c.fail("wavelengthcalibrate error: markers are in no consistent order", .{});
    }
    // Calibrate a descending capture in mirrored space: the walks below need
    // ascending markers, so reverse the rows and reflect the columns first, then
    // undo it on the way out. `mirror` is its own inverse, and the wavelengths
    // ride along with their rows, so the caller gets its order and markers back
    // with the wavelengths assigned. The `defer` must be at function scope:
    // inside a block it would undo the mirror before the walks run.
    if (descending) mirror(rows, markers);
    defer if (descending) mirror(rows, markers);

    // 1. slope between consecutive markers.
    for (0..markers.len - 1) |i| {
        const dw = markers[i + 1].wavelength - markers[i].wavelength;
        // Markers ascend by column, checked above, so this cannot underflow.
        const dp: f32 = @floatFromInt(markers[i + 1].column - markers[i].column);
        markers[i].slope = dw / dp;
    }
    markers[markers.len - 1].slope = markers[markers.len - 2].slope;

    // 2. the markers' own wavelengths.
    for (markers) |mk| rows[mk.column].wavelength = mk.wavelength;

    // 3. between markers.
    for (0..markers.len - 1) |i| {
        var j: u32 = markers[i].column;
        while (j < markers[i + 1].column) : (j += 1) rows[j + 1].wavelength = rows[j].wavelength + markers[i].slope;
    }

    // 4. from the highest marker to the end of the spectrum.
    if (rows.len >= 2) {
        const s = markers[markers.len - 1].slope;
        var j: u32 = markers[markers.len - 1].column;
        while (j < rows.len - 1) : (j += 1) rows[j + 1].wavelength = rows[j].wavelength + s;
        rows[rows.len - 1].wavelength = rows[rows.len - 2].wavelength + s;
    }

    // 5. from the lowest marker down to the start of the spectrum.
    var j: u32 = markers[0].column;
    while (j > 0) : (j -= 1) rows[j - 1].wavelength = rows[j].wavelength - markers[0].slope;
}

/// Reverses the rows and reflects the marker columns, so a descending capture
/// looks ascending. It is its own inverse: applying it twice restores both,
/// while the wavelengths assigned in between ride along with their rows.
fn mirror(rows: []Row, markers: []Marker) void {
    std.mem.reverse(Row, rows);
    for (markers) |*mk| mk.column = @intCast(rows.len - 1 - mk.column);
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
    markers[0].wavelength = @floatFromInt(bluew);
    markers[1].wavelength = @floatFromInt(greenw);
    markers[2].wavelength = @floatFromInt(redw);

    var used: [3]Marker = undefined;
    var used_count: usize = 0;
    for (markers) |mk| {
        if (mk.wavelength != 0) {
            used[used_count] = mk;
            used_count += 1;
        }
    }
    if (used_count < 2) return c.fail("wavelengthcalibrate (RGB) error: need at least two channels", .{});

    const rows = try parseData(a, c, try readLines(a, reader));
    if (rows.len == 0) return c.fail("wavelengthcalibrate error: no data.", .{});

    try wavelengthCalibrate(c, rows, used[0..used_count]);
    try printRows(c, rows);
}

/// Sums `other` into `data`, channel by channel.
///
fn addRows(data: []Row, other: []const Row) void {
    for (data, other) |*left, right| {
        for (0..@min(left.count, right.count)) |j| left.values[j] += right.values[j];
    }
}

const PowerEntry = struct { wavelength: i32, value: f32 };

/// Power calibration entries, one per integer wavelength, ordered by
/// wavelength. A repeated wavelength keeps the last value.
fn powerData(a: Allocator, c: Ctx, lines: []const []const u8) Error![]PowerEntry {
    var entries: std.ArrayList(PowerEntry) = .empty;
    for (lines) |line| {
        // Note: unlike parseData, blank lines are not skipped here.
        var parts = std.mem.splitScalar(u8, line, ',');
        const wavelength = parts.next() orelse continue;
        const value = parts.next() orelse {
            return c.fail("getPowerData error: line does not contain sufficient number of values ({s})", .{line});
        };
        const w = intField(wavelength);
        const v = floatField(value);
        var replaced = false;
        for (entries.items) |*e| {
            if (e.wavelength == w) {
                e.value = v;
                replaced = true;
                break;
            }
        }
        if (!replaced) try entries.append(a, .{ .wavelength = w, .value = v });
    }
    std.mem.sort(PowerEntry, entries.items, {}, struct {
        fn lt(_: void, x: PowerEntry, y: PowerEntry) bool {
            return x.wavelength < y.wavelength;
        }
    }.lt);
    return entries.toOwnedSlice(a);
}

pub fn powerCalibrate(c: Ctx, io: Io, reader: *Io.Reader, calib_path: []const u8) Error!void {
    const a = c.gpa;
    const rows = try parseData(a, c, try readLines(a, reader));
    if (rows.len == 0) return c.fail("powercalibrate error: no data.", .{});

    // Opened after the data is read, so a bad data file is reported first.
    const file = Io.Dir.cwd().openFile(io, calib_path, .{}) catch return c.fail(
        "powercalibrate error: power calibration file {s} not found.",
        .{calib_path},
    );
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = Io.File.Reader.init(file, io, &buf);

    const calib = try powerData(a, c, try readLines(a, &fr.interface));

    for (rows) |*r| {
        const key = std.math.lossyCast(i32, r.wavelength);
        var factor: f32 = undefined;

        var exact: ?usize = null;
        for (calib, 0..) |e, i| {
            if (e.wavelength == key) {
                exact = i;
                break;
            }
        }

        if (exact) |i| {
            factor = calib[i].value;
        } else {
            // lower_bound: first entry at or above the wavelength.
            var hi: usize = 0;
            while (hi < calib.len and calib[hi].wavelength < key) hi += 1;
            // Outside the calibration range there is nothing to interpolate
            // against.
            if (hi == 0 or hi >= calib.len) {
                try c.errw.writeAll("powercalibrate error: wavelength ");
                try cformat.fixed(a, c.errw, r.wavelength, 2);
                try c.errw.writeAll(" is outside the power calibration range\n");
                return error.Ssftool;
            }
            // Linear interpolation between the keys either side; the two
            // wavelengths are integers, so their difference is exact.
            const lo = hi - 1;
            const above = r.wavelength - @as(f32, @floatFromInt(calib[hi].wavelength));
            const span = @as(f32, @floatFromInt(calib[lo].wavelength - calib[hi].wavelength));
            const fraction = above / span;
            factor = calib[hi].value + (calib[lo].value - calib[hi].value) * fraction;
        }

        for (r.values[0..r.count]) |*d| d.* = d.* / factor;
    }
    try printRows(c, rows);
}

pub fn normalize(c: Ctx, reader: *Io.Reader) Error!void {
    const rows = try parseData(c.gpa, c, try readLines(c.gpa, reader));
    if (rows.len == 0) return c.fail("normalize error: no data.", .{});

    var maxval: f32 = 0.0;
    for (rows) |r| {
        for (r.values[0..r.count]) |v| {
            if (v > maxval) maxval = v;
        }
    }
    for (rows) |*r| {
        for (r.values[0..r.count]) |*d| d.* = d.* / maxval;
    }
    try printRows(c, rows);
}

pub fn multiply(c: Ctx, reader: *Io.Reader, m: f32) Error!void {
    const rows = try parseData(c.gpa, c, try readLines(c.gpa, reader));
    if (rows.len == 0) return c.fail("normalize error: no data.", .{});
    for (rows) |*r| {
        for (r.values[0..r.count]) |*d| d.* *= m;
    }
    try printRows(c, rows);
}

/// `averagechannels`: the mean of a row's channels, one value per row.
pub fn averageChannels(c: Ctx, reader: *Io.Reader) Error!void {
    const rows = try parseData(c.gpa, c, try readLines(c.gpa, reader));
    if (rows.len == 0) return c.fail("average error: no data.", .{});
    for (rows) |r| {
        var sum: f32 = 0.0;
        for (r.values[0..r.count]) |v| sum += v;
        try cformat.fixed(c.gpa, c.out, r.wavelength, 2);
        try c.out.writeByte(',');
        try c.out.print("{d}", .{sum / @as(f32, @floatFromInt(r.count))});
        try c.out.writeByte('\n');
    }
}

/// `averagefiles`: the per-channel mean across every input file.
///
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
            // The files have to line up row for row.
            if (other.len != data.len) {
                return c.fail("averagefiles error: data files have different numbers of lines", .{});
            }
            addRows(data, other);
        }
        count += 1;
    }

    const divisor: f32 = @floatFromInt(count);
    for (data) |*r| {
        for (r.values[0..r.count]) |*d| d.* = d.* / divisor;
    }
    try printRows(c, data);
}

/// `linearpower <lower,upper,interval,lowvalue,highvalue>`.
pub fn linearPower(c: Ctx, lower: f32, upper: f32, interval: f32, lowval: f32, hival: f32) Error!void {
    const increment = (hival - lowval) / ((upper - lower) / interval);
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

/// `intervalize`: resample onto a fixed wavelength grid, taking the nearest
/// measurement to each step. A descending axis is walked the other way.
pub fn intervalize(c: Ctx, reader: *Io.Reader, lower: f32, upper: f32, interval: f32) Error!void {
    const a = c.gpa;
    const rows = try parseData(a, c, try readLines(a, reader));
    if (rows.len == 0) return c.fail("intervalize error: no data.", .{});

    // A descending wavelength axis — a mirrored capture, straight out of
    // wavelengthcalibrate — is walked the other way. The output is still one row
    // per step from `lower` upwards, and the `defer` puts the caller's row order
    // back, including on the error paths below.
    const descending = rows.len >= 2 and rows[0].wavelength > rows[rows.len - 1].wavelength;
    if (descending) std.mem.reverse(Row, rows);
    defer if (descending) std.mem.reverse(Row, rows);

    if (rows[0].wavelength > lower) {
        try c.errw.writeAll("intervalize error: data doesn't cover lower bound: ");
        try cformat.fixed(a, c.errw, rows[0].wavelength, 2);
        try c.errw.writeByte('\n');
        return error.Ssftool;
    }
    if (rows[rows.len - 1].wavelength < upper) {
        try c.errw.writeAll("intervalize error: data doesn't cover upper bound: ");
        try cformat.fixed(a, c.errw, rows[rows.len - 1].wavelength, 2);
        try c.errw.writeByte('\n');
        return error.Ssftool;
    }

    const last = rows.len - 1;
    var i: usize = 0;
    var step = lower;
    while (step <= upper) : (step += interval) {
        // Walk up to the lower bound.
        while (i < last and rows[i].wavelength < lower) i += 1;

        if (rows[i].wavelength == step) { // exact hit: use the measurement as-is
            try printRow(c, rows[i]);
            i += 1;
            continue;
        }
        while (i < last and rows[i].wavelength < step) i += 1;
        // The walk can land exactly on the step, which the test above cannot
        // see because it runs before the walk. Upstream then divides by a zero
        // interval, so `interp` is infinite and it takes the *next*
        // measurement; take this one instead.
        if (rows[i].wavelength == step) {
            try printRow(c, rows[i]);
            i += 1;
            continue;
        }

        var out: Row = .{ .wavelength = step };
        if (i == last) {
            // Past the end of the data: take the last measurement.
            out.count = rows[i].count;
            out.values = rows[i].values;
            try printRow(c, out);
            return;
        }
        // Nearest neighbour: `interp` is the fraction of the interval between
        // this measurement and the next.
        const interp = (rows[i + 1].wavelength - rows[i].wavelength) / (rows[i].wavelength - step);
        out.count = rows[i].count;
        for (0..rows[i].count) |j| {
            out.values[j] = if (interp > 0.5) rows[i + 1].values[j] else rows[i].values[j];
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
        try cformat.int(c.out, std.math.lossyCast(i32, r.wavelength));
        for (r.values[0..r.count]) |v| {
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
        var out: Row = .{ .wavelength = r.wavelength, .count = r.count };
        for (0..r.count) |j| {
            var sum: f32 = 0.0;
            var k: usize = 0;
            while (k < lb) : (k += 1) sum += rows[i - k].values[j];
            out.values[j] = sum / @as(f32, @floatFromInt(lb));
        }
        try printRow(c, out);
    }
}

/// `metadata`: prints nothing. The line reader has already dropped every
/// comment, so there is nothing left to report.
pub fn metadata(c: Ctx, reader: *Io.Reader) Error!void {
    _ = try readLines(c.gpa, reader);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "intField takes a leading integer" {
    try testing.expectEqual(@as(i32, 0), intField(""));
    try testing.expectEqual(@as(i32, 0), intField("x"));
    try testing.expectEqual(@as(i32, 42), intField("42"));
    try testing.expectEqual(@as(i32, 42), intField("  42abc"));
    try testing.expectEqual(@as(i32, -42), intField("-42"));
    try testing.expectEqual(@as(i32, 42), intField("+42"));
    try testing.expectEqual(@as(i32, 12), intField("12.9"));
    try testing.expectEqual(@as(i32, 400), intField("400nm"));
}

test "floatField takes a leading number" {
    try testing.expectEqual(@as(f32, 0), floatField(""));
    try testing.expectEqual(@as(f32, 0), floatField("x"));
    try testing.expectEqual(@as(f32, 1.5), floatField("1.5"));
    try testing.expectEqual(@as(f32, 0.000071), floatField("0.000071"));
    try testing.expectEqual(@as(f32, 1.5), floatField("1.5x"));
    try testing.expectEqual(@as(f32, -1.5), floatField(" -1.5e0"));
    try testing.expectEqual(@as(f32, 150), floatField("1.5e2"));
    try testing.expectEqual(@as(f32, 0.5), floatField(".5"));
    try testing.expect(std.math.isInf(floatField("inf")));
    try testing.expect(std.math.isNan(floatField("nan")));
}

test "fields keep a trailing empty one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try fields(a, "a", ',');
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("a", one[0]);

    const trailing = try fields(a, "a,b,", ',');
    try testing.expectEqual(@as(usize, 3), trailing.len);
    try testing.expectEqualStrings("", trailing[2]);

    const empty = try fields(a, ",", ',');
    try testing.expectEqual(@as(usize, 2), empty.len);

    try testing.expectEqualStrings("a", firstField("a,b,c", ','));
    try testing.expectEqualStrings("a", firstField("a", ','));
    try testing.expectEqualStrings("", firstField(",b", ','));
}

test "readLines applies the field dialect" {
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

test "parseData reads a wavelength and up to three channels" {
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
    try testing.expectEqual(@as(f32, 400), rows[0].wavelength);
    try testing.expectEqual(@as(u3, 3), rows[0].count);
    try testing.expectEqual(@as(f32, 2), rows[0].values[1]);
    try testing.expectEqual(@as(u3, 2), rows[1].count);
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

test "descending markers calibrate a mirrored capture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rows = [_]Row{
        .{ .wavelength = 0, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 1, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 2, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 3, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 4, .values = .{ 1, 2, 3 }, .count = 3 },
    };
    // Column 4 is 400 nm and column 2 is 500 nm, so the capture is mirrored:
    // the wavelengths must descend down the file, 600 at column 0.
    var markers = [_]Marker{
        .{ .column = 4, .wavelength = 400 },
        .{ .column = 2, .wavelength = 500 },
    };

    var sink: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&sink);
    var err_buf: [256]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);
    const c: Ctx = .{ .gpa = a, .out = &out, .errw = &errw };

    try wavelengthCalibrate(c, &rows, &markers);
    const want = [_]f32{ 600, 550, 500, 450, 400 };
    for (rows, want) |row, w| try testing.expectApproxEqAbs(w, row.wavelength, 0.001);
    // The marker columns are restored, so the caller's data is untouched
    // apart from the wavelengths.
    try testing.expectEqual(@as(u32, 4), markers[0].column);
    try testing.expectEqual(@as(u32, 2), markers[1].column);
}

test "intervalize walks a descending wavelength axis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&sink);
    var err_buf: [256]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);
    const c: Ctx = .{ .gpa = a, .out = &out, .errw = &errw };

    var reader = Io.Reader.fixed("500,5\n480,4\n460,3\n440,2\n420,1\n");
    try intervalize(c, &reader, 420, 500, 40);
    try testing.expectEqualStrings(
        \\420.00,1
        \\460.00,3
        \\500.00,5
        \\
    , out.buffered());
}

test "format rounds to the requested precision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&sink);
    var err_buf: [256]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);
    const c: Ctx = .{ .gpa = a, .out = &out, .errw = &errw };

    var reader = Io.Reader.fixed("400,1.234,2.346,3.456\n405.9,4.5,5.25,6.125\n");
    try formatOp(c, &reader, 2);
    try testing.expectEqualStrings(
        \\400,1.23,2.35,3.46
        \\405,4.50,5.25,6.12
        \\
    , out.buffered());
}

test "rejects markers with no consistent order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rows = [_]Row{
        .{ .wavelength = 0, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 1, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 2, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 3, .values = .{ 1, 2, 3 }, .count = 3 },
    };
    var mixed = [_]Marker{
        .{ .column = 3, .wavelength = 400 },
        .{ .column = 1, .wavelength = 500 },
        .{ .column = 2, .wavelength = 600 },
    };
    var duplicate = [_]Marker{
        .{ .column = 1, .wavelength = 400 },
        .{ .column = 1, .wavelength = 500 },
    };

    var sink: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&sink);
    var err_buf: [256]u8 = undefined;
    var errw: Io.Writer = .fixed(&err_buf);
    const c: Ctx = .{ .gpa = a, .out = &out, .errw = &errw };

    try testing.expectError(error.Ssftool, wavelengthCalibrate(c, &rows, &mixed));
    try testing.expectEqualStrings("wavelengthcalibrate error: markers are in no consistent order\n", errw.buffered());

    var sink2: [256]u8 = undefined;
    var out2: Io.Writer = .fixed(&sink2);
    var err_buf2: [256]u8 = undefined;
    var errw2: Io.Writer = .fixed(&err_buf2);
    const c2: Ctx = .{ .gpa = a, .out = &out2, .errw = &errw2 };
    try testing.expectError(error.Ssftool, wavelengthCalibrate(c2, &rows, &duplicate));
    try testing.expectEqualStrings("wavelengthcalibrate error: two markers share column 1\n", errw2.buffered());
}

test "averagefiles sums every channel of every row" {
    var left = [_]Row{
        .{ .wavelength = 400, .values = .{ 1, 2, 3 }, .count = 3 },
        .{ .wavelength = 405, .values = .{ 4, 5, 6 }, .count = 3 },
        .{ .wavelength = 410, .values = .{ 7, 8, 9 }, .count = 3 },
        .{ .wavelength = 415, .values = .{ 10, 11, 12 }, .count = 3 },
    };
    const right = [_]Row{
        .{ .wavelength = 400, .values = .{ 10, 20, 30 }, .count = 3 },
        .{ .wavelength = 405, .values = .{ 40, 50, 60 }, .count = 3 },
        .{ .wavelength = 410, .values = .{ 70, 80, 90 }, .count = 3 },
        .{ .wavelength = 415, .values = .{ 100, 110, 120 }, .count = 3 },
    };
    addRows(&left, &right);

    try testing.expectEqual(@as(f32, 11), left[0].values[0]);
    try testing.expectEqual(@as(f32, 22), left[0].values[1]);
    try testing.expectEqual(@as(f32, 33), left[0].values[2]);
    // Every channel of every row is summed, including rows past the third.
    try testing.expectEqual(@as(f32, 110), left[3].values[0]);
    try testing.expectEqual(@as(f32, 121), left[3].values[1]);
    try testing.expectEqual(@as(f32, 132), left[3].values[2]);
}

test "channelMaxes picks the first maximum and orders blue,green,red" {
    var rows = [_]Row{
        .{ .wavelength = 0, .values = .{ 1, 9, 3 }, .count = 3 },
        .{ .wavelength = 1, .values = .{ 9, 9, 3 }, .count = 3 },
        .{ .wavelength = 2, .values = .{ 4, 5, 8 }, .count = 3 },
    };
    const m = channelMaxes(&rows);
    try testing.expectEqual(@as(u32, 2), m[0].column); // blue
    try testing.expectEqual(@as(f32, 8), m[0].value);
    try testing.expectEqual(@as(u32, 0), m[1].column); // green: ties keep the first
    try testing.expectEqual(@as(f32, 9), m[1].value);
    try testing.expectEqual(@as(u32, 1), m[2].column); // red
    try testing.expectEqual(@as(f32, 9), m[2].value);
}
