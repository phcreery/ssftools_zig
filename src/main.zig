//! Command line front end for the ssftool port.
//!
//! Argument handling for the ssftool operators: which argument shapes each one
//! accepts, the message each failure produces, and the exit statuses — 1 for a
//! reported error or for no arguments at all, and 0 for an unrecognized
//! operation, which is reported but not treated as an error.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const ssftool = @import("ssftool.zig");

/// std.posix declares `pollfd` as `void` where poll() is unavailable.
const has_poll = @typeInfo(std.posix.pollfd) != .void;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var stderr_buffer: [8 * 1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const errw = &stderr_file_writer.interface;

    const ctx: ssftool.Ctx = .{ .gpa = arena, .out = out, .errw = errw };

    const code: u8 = run(ctx, io, args) catch |err| blk: {
        // error.Ssftool has already written its message.
        if (err != error.Ssftool) errw.print("ssftool: {s}\n", .{@errorName(err)}) catch {};
        break :blk 1;
    };

    // Flush before exiting, so no buffered output is lost.
    out.flush() catch {};
    errw.flush() catch {};
    return code;
}

/// A data input: a named file, or stdin.
const Input = struct {
    file: ?Io.File = null,
    fr: Io.File.Reader = undefined,
    empty: Io.Reader = Io.Reader.fixed(""),
    buf: [64 * 1024]u8 = undefined,

    /// `fopen(path, "r")`; the caller reports the operator-specific message.
    fn open(self: *Input, io: Io, path: []const u8) !void {
        self.file = try Io.Dir.cwd().openFile(io, path, .{});
        self.fr = Io.File.Reader.init(self.file.?, io, &self.buf);
    }

    /// stdin, if it has data waiting.
    fn useStdin(self: *Input, io: Io) !void {
        if (!stdinHasData()) return;
        self.file = Io.File.stdin();
        self.fr = Io.File.Reader.init(self.file.?, io, &self.buf);
    }

    fn reader(self: *Input) *Io.Reader {
        return if (self.file == null) &self.empty else &self.fr.interface;
    }
};

/// Waits up to a second for stdin to have data, so that an idle terminal is
/// reported as "no data" rather than hanging the tool. A regular file is always
/// ready, so this only matters for pipes and terminals.
fn stdinHasData() bool {
    if (comptime !has_poll) return true;
    var fds = [_]std.posix.pollfd{.{
        .fd = Io.File.stdin().handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&fds, 1000) catch return true;
    return n != 0;
}

/// Up to `N` comma-separated fields, with the count found.
fn commaFields(comptime N: usize, text: []const u8) struct { fields: [N][]const u8, count: usize } {
    var out: [N][]const u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (count < N) {
        out[count] = parts.next() orelse break;
        count += 1;
    }
    return .{ .fields = out, .count = count };
}

fn run(ctx: ssftool.Ctx, io: Io, args: []const [:0]const u8) ssftool.Error!u8 {
    const arena = ctx.gpa;

    if (args.len <= 1) {
        try ctx.out.writeAll(usage);
        return 1;
    }

    const op = args[1];
    var input: Input = .{};

    if (std.mem.eql(u8, op, "list")) {
        if (args.len <= 2 or std.mem.eql(u8, args[2], "wavelengths")) {
            try input.useStdin(io);
        } else input.open(io, args[2]) catch return ctx.failCode("Error: data file not found.", .{});
        const wavelengths = std.mem.eql(u8, args[args.len - 1], "wavelengths");
        try ssftool.list(ctx, input.reader(), wavelengths);
    } else if (std.mem.eql(u8, op, "extract")) {
        if (args.len <= 2) try input.useStdin(io) else input.open(io, args[2]) catch
            return ctx.failCode("extract error: data file not found: {s}", .{args[2]});
        try ssftool.extract(ctx, input.reader());
    } else if (std.mem.eql(u8, op, "transpose")) {
        if (args.len <= 2) try input.useStdin(io) else input.open(io, args[2]) catch
            return ctx.failCode("transpose error: data file not found: {s}", .{args[2]});
        try ssftool.transpose(ctx, input.reader());
    } else if (std.mem.eql(u8, op, "channelmaxes")) {
        if (args.len <= 2) try input.useStdin(io) else input.open(io, args[2]) catch
            return ctx.failCode("channelmaxes error: data file not found: {s}", .{args[2]});
        try ssftool.channelMaxesOp(ctx, input.reader());
    } else if (std.mem.eql(u8, op, "wavelengthcalibrate")) {
        var markerstring: []const u8 = undefined;
        var calibfile: ?[]const u8 = null;
        if (args.len == 3) {
            try input.useStdin(io);
            markerstring = args[2];
        } else if (args.len == 4) {
            if (std.mem.indexOfScalar(u8, args[2], '=') != null) {
                // | ssftool wavelengthcalibrate markerstring calibrationfile
                try input.useStdin(io);
                markerstring = args[2];
                calibfile = args[3];
            } else {
                // ssftool wavelengthcalibrate spectrumfile markerstring
                input.open(io, args[2]) catch return ctx.failCode(
                    "wavelengthcalibrate error: data file not found: {s}",
                    .{args[2]},
                );
                markerstring = args[3];
            }
        } else if (args.len == 5) {
            input.open(io, args[2]) catch return ctx.failCode(
                "wavelengthcalibrate error: data file not found: {s}",
                .{args[2]},
            );
            markerstring = args[3];
            calibfile = args[4];
        } else {
            return ctx.failCode("wavelengthcalibrate error: wrong number of parameters: {d}", .{args.len});
        }

        var markers = std.mem.splitScalar(u8, markerstring, ',');
        const rgb_mode = std.mem.indexOf(u8, markerstring, "red") != null or
            std.mem.indexOf(u8, markerstring, "green") != null or
            std.mem.indexOf(u8, markerstring, "blue") != null;

        if (rgb_mode) {
            // "blue=437,green=546,red=611": markers are the calibration
            // spectrum's channel maxima.
            var redw: i32 = 0;
            var greenw: i32 = 0;
            var bluew: i32 = 0;
            while (markers.next()) |marker| {
                var nameval = std.mem.splitScalar(u8, marker, '=');
                const name = nameval.next() orelse continue;
                const value = nameval.next() orelse return ctx.failCode(bad_marker, .{});
                if (std.mem.eql(u8, name, "red")) {
                    redw = ssftool.intField(value);
                } else if (std.mem.eql(u8, name, "green")) {
                    greenw = ssftool.intField(value);
                } else if (std.mem.eql(u8, name, "blue")) {
                    bluew = ssftool.intField(value);
                } else return ctx.failCode(bad_marker, .{});
            }

            const path = calibfile orelse "";
            var calib: Input = .{};
            calib.open(io, path) catch return ctx.failCode(
                "wavelength_callibrate error: wavelength calibration file {s} not found.",
                .{path},
            );
            try ssftool.wavelengthCalibrateRgb(ctx, input.reader(), calib.reader(), bluew, greenw, redw);
        } else {
            // "position=wavelength,...": explicit pixel positions.
            var markerdat: std.ArrayList(ssftool.Marker) = .empty;
            while (markers.next()) |marker| {
                var nameval = std.mem.splitScalar(u8, marker, '=');
                const column = nameval.next() orelse continue;
                const wavelength = nameval.next() orelse return ctx.failCode(
                    "wavelengthcalibrate error: bad marker parameter: {s}",
                    .{marker},
                );
                try markerdat.append(arena, .{
                    // A negative column wraps to a large unsigned value.
                    .column = @bitCast(ssftool.intField(column)),
                    .wavelength = @floatFromInt(ssftool.intField(wavelength)),
                });
            }
            const rows = try ssftool.parseData(arena, ctx, try ssftool.readLines(arena, input.reader()));
            if (rows.len == 0) return ctx.failCode("wavelengthcalibrate error: no data.", .{});
            try ssftool.wavelengthCalibrate(ctx, rows, markerdat.items);
            try ssftool.printRows(ctx, rows);
        }
    } else if (std.mem.eql(u8, op, "powercalibrate")) {
        var calibfile: []const u8 = undefined;
        if (args.len == 3) {
            try input.useStdin(io);
            calibfile = args[2];
        } else if (args.len == 4) {
            input.open(io, args[2]) catch return ctx.failCode(
                "powercalibrate error: data file not found: {s}",
                .{args[2]},
            );
            calibfile = args[3];
        } else {
            return ctx.failCode("powercalibrate error: wrong number of parameters: {d}", .{args.len});
        }
        try ssftool.powerCalibrate(ctx, io, input.reader(), calibfile);
    } else if (std.mem.eql(u8, op, "normalize")) {
        if (args.len <= 2) try input.useStdin(io) else input.open(io, args[2]) catch
            return ctx.failCode("normalize error: data file not found: {s}", .{args[2]});
        try ssftool.normalize(ctx, input.reader());
    } else if (std.mem.eql(u8, op, "averagechannels")) {
        if (args.len <= 2) try input.useStdin(io) else input.open(io, args[2]) catch
            return ctx.failCode("average error: data file not found: {s}", .{args[2]});
        try ssftool.averageChannels(ctx, input.reader());
    } else if (std.mem.eql(u8, op, "averagefiles")) {
        try input.useStdin(io);
        try ssftool.averageFiles(ctx, io, input.reader(), args[2..]);
    } else if (std.mem.eql(u8, op, "intervalize")) {
        var range: []const u8 = undefined;
        if (args.len == 3) {
            try input.useStdin(io);
            range = args[2];
        } else if (args.len == 4) {
            input.open(io, args[2]) catch return ctx.failCode("Error: data file not found.", .{});
            range = args[3];
        } else {
            return ctx.failCode("intervalize error: wrong number of parameters: {d}", .{args.len});
        }
        const bounds = commaFields(3, range);
        if (bounds.count < 3) return ctx.failCode(
            "intervalize error: not enough parameters in the range specification:{s}",
            .{range},
        );
        // Read as integers, so a fractional bound is truncated.
        const lower: f32 = @floatFromInt(ssftool.intField(bounds.fields[0]));
        const upper: f32 = @floatFromInt(ssftool.intField(bounds.fields[1]));
        const interval: f32 = @floatFromInt(ssftool.intField(bounds.fields[2]));
        try ssftool.intervalize(ctx, input.reader(), lower, upper, interval);
    } else if (std.mem.eql(u8, op, "format")) {
        var precision: i32 = 2;
        if (args.len == 3) {
            try input.useStdin(io);
            precision = ssftool.intField(args[2]);
        } else if (args.len == 4) {
            input.open(io, args[2]) catch return ctx.failCode("format error: file not found: {s}", .{args[2]});
            precision = ssftool.intField(args[3]);
        } else {
            return ctx.failCode("format error: wrong number of parameters: {d}", .{args.len});
        }
        try ssftool.formatOp(ctx, input.reader(), precision);
    } else if (std.mem.eql(u8, op, "smooth")) {
        var lookback: i32 = 2;
        if (args.len == 2) {
            try input.useStdin(io);
        } else if (args.len == 3) {
            input.open(io, args[2]) catch {
                // Not a file: it is the lookback, and the data comes from stdin.
                try input.useStdin(io);
                lookback = ssftool.intField(args[2]);
            };
        } else if (args.len == 4) {
            input.open(io, args[2]) catch return ctx.failCode("smooth error: file not found: {s}", .{args[2]});
            lookback = ssftool.intField(args[3]);
        } else {
            return ctx.failCode("smooth error: wrong number of parameters: {d}", .{args.len});
        }
        try ssftool.smooth(ctx, input.reader(), lookback);
    } else if (std.mem.eql(u8, op, "linearpower")) {
        if (args.len != 3) {
            return ctx.failCode("linearpower error: wrong number of parameters: {d}", .{args.len});
        }
        const p = commaFields(5, args[2]);
        if (p.count < 5) return ctx.failCode(
            "linearpower error: not enough parameters in the range specification:{s}",
            .{args[2]},
        );
        try ssftool.linearPower(
            ctx,
            ssftool.floatField(p.fields[0]),
            ssftool.floatField(p.fields[1]),
            ssftool.floatField(p.fields[2]),
            ssftool.floatField(p.fields[3]),
            ssftool.floatField(p.fields[4]),
        );
    } else if (std.mem.eql(u8, op, "multiply")) {
        var m: f32 = 1.0;
        if (args.len == 3) {
            try input.useStdin(io);
            m = ssftool.floatField(args[2]);
        } else if (args.len == 4) {
            input.open(io, args[2]) catch return ctx.failCode(
                "multiply error: data file not found: {s}",
                .{args[2]},
            );
            m = ssftool.floatField(args[3]);
        } else {
            return ctx.failCode("multiply error: wrong number of parameters: {d}", .{args.len});
        }
        try ssftool.multiply(ctx, input.reader(), m);
    } else if (std.mem.eql(u8, op, "metadata")) {
        if (args.len <= 2) try input.useStdin(io) else input.open(io, args[2]) catch
            return ctx.failCode("metadata error: data file not found: {s}", .{args[2]});
        try ssftool.metadata(ctx, input.reader());
    } else {
        // Reported on stdout, and not treated as an error.
        try ctx.out.print("ssf error: unrecognized operation: {s}.\n", .{op});
    }
    return 0;
}

const bad_marker = "wavelengthcalibrate error: bad marker parameter:";

const usage =
    "Usage:\n\n" ++
    "ssftool list [<datafile>] ['wavelengths']  - prints the data file. \n'wavelengths' prints just the wavelenghts as a comma-separated list\n\n" ++
    "ssftool extract [<datafile>] - extracts data from a rawproc data file.\n\n" ++
    "ssftool transpose [<datafile>] - turns a row-major file into column-major.\n\n" ++
    "ssftool channelmaxes [<datafile>] - calculates the pixel locations of each of \nthe channel maximum values.\n\n" ++
    "ssftool wavelengthcalibrate [<datafile>] markerstring [<calibrationfile>] -  \ncalibrate either using a markerstring of \"red=www,green=www,blue=www\" to a \ncalibration file or \"position=wavelength...\"\n\n" ++
    "ssftool powercalibrate [<datafile>] [<calibrationfile]> - divide each value in \nthe datafile by the corresponding value from the calibration file.\n\n" ++
    "ssftool normalize [<datafile>] - normalizes the data to the range 0.0-1.0 based \non the largest channel maximum.\n\n" ++
    "ssftool intervalize [<datafile>] <lowerbound>,<upperbound>,<interval> [<datafile>] - \ncollapses the data to the range specified by lowerbound, upperbound, \nand interval.\n\n" ++
    "ssftool averagechannels [<datafile>] - averages the r, g, and b values of \neach line to produce a single value for the line.\n\n" ++
    "ssftool averagefiles [<datafile>][...] - averages the r, g, and b values \nfrom each file to form a single r, g, and b for each line.\n\n" ++
    "ssftool format [<datafile>] <precision> - formats the w,r,g,b file to \ninteger-ize the w, and round each r, g, and b to the specified precision.\n\n" ++
    "ssftool [smooth <datafile>] - applies a moving average smoothing to the data.\n\n" ++
    "ssftool linearpower <lower,upper,interval,lowvalue,highvalue> - builds a \ndataset that starts with lowvalue, then proceeds \nto the highvalue over the lower-to-upper interval in the specified interval.\n\n" ++
    "ssftool multiply <number> - multiplies each data value by the specified number.\n\n" ++
    "ssftool metadata <datafile> - prints name=val pairs from comments formatted \n'#name=val'.  Use in scripts as 'eval export `ssftool metadata <ssffile>`'\n\n" ++
    "\n";

test "usage text lists every operator" {
    // Guards against accidental edits; the compat harness compares it against
    // the C program byte for byte.
    try std.testing.expectEqual(@as(usize, 1956), usage.len);
    try std.testing.expect(std.mem.endsWith(u8, usage, "<ssffile>`'\n\n\n"));
    try std.testing.expect(std.mem.startsWith(u8, usage, "Usage:\n\nssftool list"));
}
