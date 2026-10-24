//! Differential test: runs the port and the reference C++ binary over the same
//! arguments and stdin and compares the data they write to stdout, byte for
//! byte. Exit statuses, error messages and usage text are not compared: this
//! checks value processing.
//!
//!     compat <zig-ssftool> <zig-pfm2specdata> <c-checkout-dir>
//!
//! Fixtures are written under `zig-out/compat/`. Argument paths prefixed with
//! '@' are resolved against that directory.
//!
//! The cases whose upstream behaviour is a crash are deliberately absent; they
//! are listed in `KNOWN_DEVIATIONS` so the gap stays visible.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Fixture = struct { path: []const u8, data: []const u8 };

/// Inputs shared by the cases.
const fixtures = [_]Fixture{
    // rawproc-style export: metadata lines, then one labelled row per channel.
    .{ .path = "rawproc.csv", .data =
    \\width: 8
    \\height: 3
    \\rawproc-0.9.1Dev DSG_4684.NEF:rawdata=crop;  demosaic:half rotate:hmirror crop:0.000000,0.427027,1.000000,0.497297 
    \\x,0,1,2,3,4,5,6,7
    \\red,0.000071,0.000069,0.000068,0.000123,0.000456,0.000789,0.001234,0.002345
    \\green,0.000150,0.000147,0.000150,0.000321,0.000654,0.000987,0.001567,0.002678
    \\blue,0.000200,0.000197,0.000189,0.000456,0.000789,0.001234,0.001890,0.003210
    \\
    },
    // A small spectrum, wavelengths 400..455 in 5 nm steps.
    .{ .path = "spectrum.csv", .data =
    \\400,0.000071,0.000150,0.000200
    \\405,0.000069,0.000147,0.000197
    \\410,0.000068,0.000150,0.000189
    \\415,0.000123,0.000321,0.000456
    \\420,0.000456,0.000654,0.000789
    \\425,0.000789,0.000987,0.001234
    \\430,0.001234,0.001567,0.001890
    \\435,0.001890,0.002345,0.002678
    \\440,0.002678,0.003456,0.003210
    \\445,0.003210,0.004567,0.002987
    \\450,0.002987,0.005678,0.002345
    \\455,0.002345,0.006789,0.001890
    \\
    },
    // Channel maxima at rows 2 (blue), 5 (green) and 8 (red).
    .{ .path = "calib.csv", .data =
    \\400,0.000100,0.000200,0.097665
    \\405,0.000110,0.000220,0.050000
    \\410,0.000120,0.000240,0.010000
    \\415,0.000130,0.000260,0.005000
    \\420,0.000140,0.000280,0.004000
    \\425,0.000150,0.159703,0.003000
    \\430,0.000160,0.080000,0.002000
    \\435,0.000170,0.040000,0.001000
    \\440,0.000180,0.020000,0.000500
    \\445,0.154049,0.010000,0.000400
    \\450,0.000200,0.005000,0.000300
    \\455,0.000210,0.002500,0.000200
    \\
    },
    // Power calibration, 380..470 in 5 nm steps.
    .{ .path = "power.csv", .data =
    \\380,0.001559
    \\385,0.001695
    \\390,0.001880
    \\395,0.002049
    \\400,0.002224
    \\405,0.002371
    \\410,0.002527
    \\415,0.002686
    \\420,0.002851
    \\425,0.003021
    \\430,0.003198
    \\435,0.003381
    \\440,0.003571
    \\445,0.003768
    \\450,0.003972
    \\455,0.004184
    \\460,0.004404
    \\465,0.004632
    \\470,0.004868
    \\
    },
    // Comments, blank lines, whitespace-only lines, tabs, CRLF, trailing text.
    .{
        .path = "commenty.csv",
        .data = "# a comment line\n400,1,2,3\r\n#interior comment\n\n   \n\t\n405 4 5 6\n410,7,8,9 # trailing comment\n415,1\n",
    },
    // All zero: normalize and smooth divide by zero.
    .{ .path = "zeros.csv", .data = "400,0,0,0\n405,0,0,0\n410,0,0,0\n" },
    // Values well above 83, where std.fmt's decimal padding would differ.
    .{ .path = "big.csv", .data = "400,295334.84375,0.0078125,123456.789\n405,83.5,100.00000762939453,2.5\n410,0.1,0.2,0.3\n" },
    // Negative and exponential notations.
    .{ .path = "neg.csv", .data = "400,-1.5,-0.25,1e-3\n405,-2.5,3.5e2,-0.0\n410,+4,5.,.5\n" },
    // Rows with one and two channels.
    .{ .path = "ch1.csv", .data = "400,1\n405,2\n410,3\n" },
    .{ .path = "ch2.csv", .data = "400,1,2\n405,3,4\n410,5,6\n" },
    // Ragged: the original aborts on transpose, so only other operators use it.
    .{ .path = "ragged.csv", .data = "a,b,c\n1,2\n" },
    // Single column: not enough values.
    // Identical files for averagefiles (see KNOWN_DEVIATIONS).
    .{ .path = "avg1.csv", .data = "400,1,2,3\n405,4,5,6\n410,7,8,9\n" },
    .{ .path = "avg2.csv", .data = "400,1,2,3\n405,4,5,6\n410,7,8,9\n" },
    // Different values, to separate the documented per-channel average from
    // upstream's one-channel-per-row accumulation.
    .{ .path = "avg3.csv", .data = "400,10,20,30\n405,40,50,60\n410,70,80,90\n" },
    // Smoothing input.
    .{ .path = "smoothme.csv", .data = "400,1,2,3\n405,4,5,6\n410,7,8,9\n415,10,11,12\n420,13,14,15\n425,16,17,18\n" },
    // Empty file.
    // A blank line in the middle: get_Data skips it, but it becomes a zero row
    // for anything that does not (the original keeps the empty string record).
    .{ .path = "blank.csv", .data = "400,1,2,3\n\n405,4,5,6\n" },
    // All channels negative: channelMaxes keeps its zero-initialised marker.
    .{ .path = "allneg.csv", .data = "400,-1,-2,-3\n405,-4,-5,-6\n410,-7,-8,-9\n" },
    // The calibration table with its rows reversed: a mirrored capture, where
    // the channel maxima no longer ascend by column.
    .{ .path = "mirror_calib.csv", .data =
    \\455,0.000210,0.002500,0.000200
    \\450,0.000200,0.005000,0.000300
    \\445,0.154049,0.010000,0.000400
    \\440,0.000180,0.020000,0.000500
    \\435,0.000170,0.040000,0.001000
    \\430,0.000160,0.080000,0.002000
    \\425,0.000150,0.159703,0.003000
    \\420,0.000140,0.000280,0.004000
    \\415,0.000130,0.000260,0.005000
    \\410,0.000120,0.000240,0.010000
    \\405,0.000110,0.000220,0.050000
    \\400,0.000100,0.000200,0.097665
    \\
    },
    // Wavelengths that never coincide with the data, forcing the interpolation
    // branch of powercalibrate.
    .{ .path = "power_odd.csv", .data =
    \\382,0.001600
    \\394,0.002000
    \\406,0.002500
    \\418,0.002800
    \\430,0.003200
    \\442,0.003600
    \\454,0.004100
    \\466,0.004600
    \\
    },
};

/// A case where the port is meant to produce different values than the
/// reference. Verified, not compared.
const Deviation = struct {
    reason: []const u8,
    stdout: []const u8,
};

const Case = struct {
    name: []const u8,
    argv: []const []const u8,
    stdin: []const u8 = "",
    /// Set when upstream aborts or segfaults: the port must differ, and must
    /// match the behaviour recorded here.
    deviation: ?Deviation = null,
};

const cases = [_]Case{
    .{ .name = "list-file", .argv = &.{ "list", "@spectrum.csv" } },
    .{ .name = "list-stdin", .argv = &.{"list"}, .stdin = "1,2,3\n4,5,6\n" },
    .{ .name = "list-wavelengths-stdin", .argv = &.{ "list", "wavelengths" }, .stdin = "400,1\n405,2\n" },
    .{ .name = "list-wavelengths-file", .argv = &.{ "list", "@spectrum.csv", "wavelengths" } },
    .{ .name = "list-comments", .argv = &.{ "list", "@commenty.csv" } },

    .{ .name = "extract-rawproc", .argv = &.{ "extract", "@rawproc.csv" } },
    .{ .name = "extract-stdin", .argv = &.{"extract"}, .stdin = "x,0,1\nred,1,2\ngreen,3,4\nblue,5,6\nother,7,8\n" },

    .{ .name = "transpose-file", .argv = &.{ "transpose", "@rawproc.csv" } },
    .{ .name = "transpose-stdin", .argv = &.{"transpose"}, .stdin = "x,0,1,2\nred,1,2,3\ngreen,4,5,6\n" },
    .{ .name = "transpose-ragged", .argv = &.{ "transpose", "@ragged.csv" }, .deviation = .{
        .reason = "upstream aborts: it reads past the end of the short row",
        .stdout = "a,1\nb,2\nc,\n",
    } },

    .{ .name = "channelmaxes", .argv = &.{ "channelmaxes", "@calib.csv" } },
    .{ .name = "channelmaxes-stdin", .argv = &.{"channelmaxes"}, .stdin = "1,2,3\n4,9,5\n6,7,8\n" },
    .{ .name = "channelmaxes-ch2", .argv = &.{ "channelmaxes", "@ch2.csv" } },

    // wavelengthcalibrate: all four argument shapes.
    .{ .name = "wavelengthcalibrate-rgb-5", .argv = &.{ "wavelengthcalibrate", "@spectrum.csv", "blue=410,green=425,red=445", "@calib.csv" } },
    .{ .name = "wavelengthcalibrate-rgb-stdin", .argv = &.{ "wavelengthcalibrate", "blue=410,green=425,red=445", "@calib.csv" }, .stdin =
    \\400,0.000071,0.000150,0.000200
    \\405,0.000069,0.000147,0.000197
    \\410,0.000068,0.000150,0.000189
    \\415,0.000123,0.000321,0.000456
    \\420,0.000456,0.000654,0.000789
    \\425,0.000789,0.000987,0.001234
    \\430,0.001234,0.001567,0.001890
    \\435,0.001890,0.002345,0.002678
    \\440,0.002678,0.003456,0.003210
    \\445,0.003210,0.004567,0.002987
    \\450,0.002987,0.005678,0.002345
    \\455,0.002345,0.006789,0.001890
    \\
    },
    .{ .name = "wavelengthcalibrate-rgb-one-channel", .argv = &.{ "wavelengthcalibrate", "@spectrum.csv", "green=425,red=445", "@calib.csv" } },
    .{ .name = "wavelengthcalibrate-position", .argv = &.{ "wavelengthcalibrate", "@spectrum.csv", "2=410,5=425,8=445" } },

    .{ .name = "powercalibrate-4", .argv = &.{ "powercalibrate", "@spectrum.csv", "@power.csv" } },
    .{ .name = "powercalibrate-3", .argv = &.{ "powercalibrate", "@power.csv" }, .stdin =
    \\400,0.000071,0.000150,0.000200
    \\405,0.000069,0.000147,0.000197
    \\410,0.000068,0.000150,0.000189
    \\
    },

    .{ .name = "normalize", .argv = &.{ "normalize", "@spectrum.csv" } },
    .{ .name = "normalize-stdin", .argv = &.{"normalize"}, .stdin = "400,1,2,4\n405,8,16,32\n" },
    .{ .name = "normalize-zeros", .argv = &.{ "normalize", "@zeros.csv" } },
    .{ .name = "normalize-negatives", .argv = &.{ "normalize", "@neg.csv" } },

    .{ .name = "averagechannels", .argv = &.{ "averagechannels", "@spectrum.csv" } },
    .{ .name = "averagechannels-ch1", .argv = &.{ "averagechannels", "@ch1.csv" } },
    .{ .name = "averagechannels-stdin", .argv = &.{"averagechannels"}, .stdin = "400,1,2,3\n405,4,5,6\n" },

    .{ .name = "averagefiles-one", .argv = &.{ "averagefiles", "@avg1.csv" } },
    .{ .name = "averagefiles-two", .argv = &.{ "averagefiles", "@avg1.csv", "@avg2.csv" } },
    .{ .name = "averagefiles-stdin-and-file", .argv = &.{ "averagefiles", "@avg1.csv" }, .stdin = "400,1,2,3\n405,4,5,6\n410,7,8,9\n" },
    .{ .name = "averagefiles-differing-files", .argv = &.{ "averagefiles", "@avg1.csv", "@avg3.csv" }, .deviation = .{
        .reason = "upstream sums one channel per row (row 0's red, row 1's green, ...); the port averages every channel",
        .stdout =
        \\400.00,5.500000,11.000000,16.500000
        \\405.00,22.000000,27.500000,33.000000
        \\410.00,38.500000,44.000000,49.500000
        \\
        ,
    } },

    .{ .name = "intervalize-4", .argv = &.{ "intervalize", "@spectrum.csv", "402,447,15" } },
    .{ .name = "intervalize-3", .argv = &.{ "intervalize", "402,447,15" }, .stdin =
    \\400,0.000071,0.000150,0.000200
    \\405,0.000069,0.000147,0.000197
    \\410,0.000068,0.000150,0.000189
    \\415,0.000123,0.000321,0.000456
    \\420,0.000456,0.000654,0.000789
    \\425,0.000789,0.000987,0.001234
    \\430,0.001234,0.001567,0.001890
    \\435,0.001890,0.002345,0.002678
    \\440,0.002678,0.003456,0.003210
    \\445,0.003210,0.004567,0.002987
    \\450,0.002987,0.005678,0.002345
    \\455,0.002345,0.006789,0.001890
    \\
    },
    .{ .name = "intervalize-float-range", .argv = &.{ "intervalize", "@spectrum.csv", "401.7,446.2,15.9" } },
    // A grid step landing exactly on a measurement: upstream takes the *next*
    // measurement, this port takes the one it landed on.
    .{ .name = "intervalize-exact-hit", .argv = &.{ "intervalize", "@spectrum.csv", "400,450,50" }, .deviation = .{
        .reason = "upstream divides by a zero interval and takes the following measurement",
        .stdout =
        \\400.00,0.000071,0.000150,0.000200
        \\450.00,0.002987,0.005678,0.002345
        \\
        ,
    } },
    .{ .name = "intervalize-one-step", .argv = &.{ "intervalize", "@spectrum.csv", "400,400,5" } },
    .{ .name = "intervalize-exact", .argv = &.{ "intervalize", "@spectrum.csv", "400,455,5" } },

    .{ .name = "format-4", .argv = &.{ "format", "@spectrum.csv", "3" } },
    .{ .name = "format-3", .argv = &.{ "format", "0" }, .stdin = "400,1.2345,2.3456,3.4567\n405.9,4.5678,5.6789,6.789\n" },
    .{ .name = "format-negative", .argv = &.{ "format", "@spectrum.csv", "-3" } },
    .{ .name = "format-large", .argv = &.{ "format", "@spectrum.csv", "12" } },
    .{ .name = "format-big", .argv = &.{ "format", "@big.csv", "6" } },

    .{ .name = "smooth-default", .argv = &.{ "smooth", "@smoothme.csv" } },
    .{ .name = "smooth-lookback-1", .argv = &.{ "smooth", "@smoothme.csv", "1" } },
    .{ .name = "smooth-lookback-4", .argv = &.{ "smooth", "@smoothme.csv", "4" } },
    .{ .name = "smooth-lookback-0", .argv = &.{ "smooth", "@smoothme.csv", "0" } },
    .{ .name = "smooth-lookback-negative", .argv = &.{ "smooth", "@smoothme.csv", "-2" } },
    .{ .name = "smooth-lookback-stdin", .argv = &.{ "smooth", "3" }, .stdin = "400,1,2,3\n405,4,5,6\n410,7,8,9\n415,10,11,12\n" },
    .{ .name = "smooth-stdin", .argv = &.{"smooth"}, .stdin = "400,1,2,3\n405,4,5,6\n410,7,8,9\n" },

    .{ .name = "linearpower", .argv = &.{ "linearpower", "400,500,50,0,1" } },
    .{ .name = "linearpower-fractional", .argv = &.{ "linearpower", "380,730,5,0.001,0.999" } },
    .{ .name = "linearpower-no-steps", .argv = &.{ "linearpower", "400,401,50,0,1" } },

    .{ .name = "multiply-4", .argv = &.{ "multiply", "@spectrum.csv", "1000" } },
    .{ .name = "multiply-3", .argv = &.{ "multiply", "0.5" }, .stdin = "400,1,2,3\n405,4,5,6\n" },
    .{ .name = "multiply-big", .argv = &.{ "multiply", "@big.csv", "100000" } },

    .{ .name = "ragged-normalize", .argv = &.{ "normalize", "@ragged.csv" } },
    .{ .name = "ch1-normalize", .argv = &.{ "normalize", "@ch1.csv" } },
    .{ .name = "ch1-format", .argv = &.{ "format", "@ch1.csv", "3" } },

    // Blank lines become zero-valued records.
    .{ .name = "blank-list", .argv = &.{ "list", "@blank.csv" } },
    .{ .name = "blank-normalize", .argv = &.{ "normalize", "@blank.csv" } },
    .{ .name = "blank-channelmaxes", .argv = &.{ "channelmaxes", "@blank.csv" } },
    .{ .name = "blank-intervalize", .argv = &.{ "intervalize", "@blank.csv", "400,405,5" } },
    // Whitespace-only lines survive as zero-valued records with one field per
    // separator character. Only transpose can read them: the tab-only line
    // reduces to a single field, which every operator rejects.
    .{ .name = "commenty-transpose", .argv = &.{ "transpose", "@commenty.csv" }, .deviation = .{
        .reason = "upstream aborts: the whitespace records make the input ragged",
        .stdout =
        \\400,,,,405,410,415
        \\1,,,,4,7,1
        \\2,,,,5,8,
        \\3,,,,6,9,
        \\
        ,
    } },

    // powercalibrate: interpolation between keys, and repeated keys.
    .{ .name = "powercalibrate-interpolate", .argv = &.{ "powercalibrate", "@spectrum.csv", "@power_odd.csv" } },

    // channelMaxes with nothing above zero.
    .{ .name = "channelmaxes-all-negative", .argv = &.{ "channelmaxes", "@allneg.csv" } },
    .{ .name = "normalize-all-negative", .argv = &.{ "normalize", "@allneg.csv" } },
    .{ .name = "smooth-all-negative", .argv = &.{ "smooth", "@allneg.csv", "2" } },

    // Markers on the first and last row, exercising the head and tail walks.
    .{ .name = "wavelengthcalibrate-ends", .argv = &.{ "wavelengthcalibrate", "@spectrum.csv", "0=400,11=455" } },
    .{ .name = "wavelengthcalibrate-unsorted", .argv = &.{ "wavelengthcalibrate", "@spectrum.csv", "8=445,2=410,5=425" }, .deviation = .{
        .reason = "upstream's unsigned marker arithmetic silently collapses the wavelengths; the port requires ascending markers",
        .stdout = "",
    } },
    .{ .name = "wavelengthcalibrate-mirrored", .argv = &.{ "wavelengthcalibrate", "@spectrum.csv", "blue=410,green=425,red=445", "@mirror_calib.csv" }, .deviation = .{
        .reason = "a mirrored capture: upstream's unsigned marker arithmetic gives every row the last marker's wavelength",
        .stdout =
        \\455.00,0.000071,0.000150,0.000200
        \\450.00,0.000069,0.000147,0.000197
        \\445.00,0.000068,0.000150,0.000189
        \\440.00,0.000123,0.000321,0.000456
        \\435.00,0.000456,0.000654,0.000789
        \\430.00,0.000789,0.000987,0.001234
        \\425.00,0.001234,0.001567,0.001890
        \\422.00,0.001890,0.002345,0.002678
        \\419.00,0.002678,0.003456,0.003210
        \\416.00,0.003210,0.004567,0.002987
        \\413.00,0.002987,0.005678,0.002345
        \\410.00,0.002345,0.006789,0.001890
        \\
        ,
    } },

    // Smoothing with a lookback longer than the data.
    .{ .name = "smooth-lookback-past-end", .argv = &.{ "smooth", "@smoothme.csv", "99" } },
};

const Outcome = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runBinary(
    a: Allocator,
    io: Io,
    dir: []const u8,
    exe: []const u8,
    argv: []const []const u8,
    tag: []const u8,
    stdin_data: []const u8,
) !Outcome {
    const stdin_path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "stdin-{s}", .{tag}) });
    const out_path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "out-{s}", .{tag}) });
    const err_path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "err-{s}", .{tag}) });

    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = stdin_path, .data = stdin_data });
    const stdin_file = try cwd.openFile(io, stdin_path, .{});
    defer stdin_file.close(io);
    const out_file = try cwd.createFile(io, out_path, .{ .truncate = true });
    const err_file = try cwd.createFile(io, err_path, .{ .truncate = true });

    const full_argv = try a.alloc([]const u8, argv.len + 1);
    full_argv[0] = exe;
    @memcpy(full_argv[1..], argv);

    var child = try std.process.spawn(io, .{
        .argv = full_argv,
        .stdin = .{ .file = stdin_file },
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = err_file },
    });
    defer child.kill(io);
    const term = try child.wait(io);

    out_file.close(io);
    err_file.close(io);

    return .{
        .term = term,
        .stdout = try readFile(a, io, out_path),
        .stderr = try readFile(a, io, err_path),
    };
}

fn readFile(a: Allocator, io: Io, path: []const u8) ![]u8 {
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = Io.File.Reader.init(f, io, &buf);
    return fr.interface.allocRemaining(a, .unlimited);
}

/// Resolves '@name' against the fixture directory.
fn resolve(a: Allocator, dir: []const u8, arg: []const u8) ![]const u8 {
    if (arg.len == 0 or arg[0] != '@') return arg;
    return std.fs.path.join(a, &.{ dir, arg[1..] });
}

fn firstDiffLine(x: []const u8, y: []const u8) ?usize {
    var line: usize = 1;
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        if (x[i] != y[j]) return line;
        if (x[i] == '\n') line += 1;
        i += 1;
        j += 1;
    }
    if (i == x.len and j == y.len) return null;
    return line;
}

fn describe(label: []const u8, c: []const u8, z: []const u8, w: *Io.Writer) !void {
    const at = firstDiffLine(c, z) orelse return;
    var c_lines = std.mem.splitScalar(u8, c, '\n');
    var z_lines = std.mem.splitScalar(u8, z, '\n');
    var n: usize = 1;
    var c_line: []const u8 = "";
    var z_line: []const u8 = "";
    while (n <= at) : (n += 1) {
        c_line = c_lines.next() orelse "";
        z_line = z_lines.next() orelse "";
    }
    try w.print("    {s} first differs at line {d} ({d} vs {d} bytes)\n", .{ label, at, c.len, z.len });
    try w.print("      C: {s}\n", .{c_line});
    try w.print("      Z: {s}\n", .{z_line});
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);

    if (args.len < 4) {
        std.debug.print("usage: compat <zig-ssftool> <zig-pfm2specdata> <c-checkout-dir>\n", .{});
        return 2;
    }
    const zig_exe = args[1];
    const zig_spec = args[2];
    const c_dir = args[3];
    const c_exe = try std.fs.path.join(a, &.{ c_dir, "ssftool" });
    const demodata = try std.fs.path.join(a, &.{ c_dir, "demodata" });

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const dir = "zig-out/compat";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);

    for (fixtures) |f| {
        const path = try std.fs.path.join(a, &.{ dir, f.path });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = f.data });
    }

    // Sanity check that all four binaries exist and are executable.
    for ([_][]const u8{ zig_exe, zig_spec, c_exe }) |exe| {
        const f = Io.Dir.cwd().openFile(io, exe, .{}) catch {
            std.debug.print("compat: cannot open {s}\n", .{exe});
            return 2;
        };
        f.close(io);
    }

    var failures: usize = 0;
    var deviations: usize = 0;

    for (cases) |case| {
        const argv = try a.alloc([]const u8, case.argv.len);
        for (case.argv, argv) |arg, *dst| dst.* = try resolve(a, dir, arg);

        const oc = try runBinary(a, io, dir, c_exe, argv, "c", case.stdin);
        const oz = try runBinary(a, io, dir, zig_exe, argv, "z", case.stdin);

        // Only the data each tool writes is compared: no exit statuses, no
        // messages, no usage text.
        const same = std.mem.eql(u8, oc.stdout, oz.stdout);

        if (case.deviation) |dev| {
            deviations += 1;
            if (!same and std.mem.eql(u8, oz.stdout, dev.stdout)) continue;
            failures += 1;
            try out.print("FAIL(deviation) {s}: {s}\n", .{ case.name, dev.reason });
            try describe("stdout", dev.stdout, oz.stdout, out);
            continue;
        }

        // A case where neither tool wrote anything compares nothing.
        if (oc.stdout.len == 0 and oz.stdout.len == 0) {
            failures += 1;
            try out.print("FAIL {s}: neither tool produced data\n", .{case.name});
            continue;
        }

        if (!same) {
            failures += 1;
            try out.print("FAIL {s}\n", .{case.name});
            try describe("stdout", oc.stdout, oz.stdout, out);
        }
    }

    failures += try pipelineCheck(a, io, dir, zig_exe, c_exe, demodata, out);
    failures += try pfmCheck(a, io, dir, zig_spec, out);

    try out.print("\nssftool: {d} cases, {d} value-identical, {d} verified value deviations\n", .{
        cases.len + 1, cases.len - deviations, deviations,
    });
    try out.print("pfm2specdata: detection and readout match the reference\n", .{});
    try out.print("{d} failures\n", .{failures});
    return if (failures == 0) 0 else 1;
}

/// Runs the README pipeline (extract|transpose|wavelengthcalibrate|intervalize|
/// powercalibrate|normalize|format) through both binaries on the original's
/// demo data and compares every stage.
fn pipelineCheck(
    a: Allocator,
    io: Io,
    dir: []const u8,
    zig_exe: []const u8,
    c_exe: []const u8,
    demodata: []const u8,
    out: *Io.Writer,
) !usize {
    const spectrum = std.fs.path.join(a, &.{ demodata, "D7000_spectrum.dat" }) catch return 0;
    const calibration = std.fs.path.join(a, &.{ demodata, "D7000_calibration.dat" }) catch return 0;
    const power = std.fs.path.join(a, &.{ demodata, "Dedolight_5nm.csv" }) catch return 0;

    for ([_][]const u8{ spectrum, calibration, power }) |p| {
        const f = Io.Dir.cwd().openFile(io, p, .{}) catch {
            try out.print("SKIP demo pipeline: {s} not found\n", .{p});
            return 0;
        };
        f.close(io);
    }

    const c_stages = try runPipeline(a, io, dir, c_exe, "c", spectrum, calibration, power);
    const z_stages = try runPipeline(a, io, dir, zig_exe, "z", spectrum, calibration, power);

    const names = [_][]const u8{ "spectrum.csv", "calibration.csv", "wavelength.csv", "interval.csv", "power.csv", "normalized.csv", "format.csv" };
    var failures: usize = 0;
    for (c_stages, z_stages, names) |c, z, name| {
        if (std.mem.eql(u8, c, z)) continue;
        failures += 1;
        try out.print("FAIL pipeline:{s}\n", .{name});
        try describe("stdout", c, z, out);
    }
    if (failures == 0) try out.print("demo pipeline: 7 stages match\n", .{});
    return failures;
}

fn runPipeline(
    a: Allocator,
    io: Io,
    dir: []const u8,
    exe: []const u8,
    tag: []const u8,
    spectrum: []const u8,
    calibration: []const u8,
    power: []const u8,
) ![][]u8 {
    var results: std.ArrayList([]u8) = .empty;

    // extract | transpose
    const spec_raw = try runStage(a, io, dir, exe, tag, &.{ "extract", spectrum }, "");
    const spec = try runStage(a, io, dir, exe, tag, &.{"transpose"}, spec_raw);
    try results.append(a, spec);
    const spec_path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "spec-{s}.csv", .{tag}) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = spec_path, .data = spec });

    const calib_raw = try runStage(a, io, dir, exe, tag, &.{ "extract", calibration }, "");
    const calib = try runStage(a, io, dir, exe, tag, &.{"transpose"}, calib_raw);
    try results.append(a, calib);
    const calib_path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "calib-{s}.csv", .{tag}) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = calib_path, .data = calib });

    const wavelength = try runStage(a, io, dir, exe, tag, &.{
        "wavelengthcalibrate", spec_path, "blue=437,green=546,red=611", calib_path,
    }, "");
    try results.append(a, wavelength);

    const interval = try runStage(a, io, dir, exe, tag, &.{ "intervalize", "400,715,5" }, wavelength);
    try results.append(a, interval);

    const powercal = try runStage(a, io, dir, exe, tag, &.{ "powercalibrate", power }, interval);
    try results.append(a, powercal);

    const normalized = try runStage(a, io, dir, exe, tag, &.{"normalize"}, powercal);
    try results.append(a, normalized);

    const formatted = try runStage(a, io, dir, exe, tag, &.{ "format", "2" }, normalized);
    try results.append(a, formatted);

    return results.toOwnedSlice(a);
}

fn runStage(
    a: Allocator,
    io: Io,
    dir: []const u8,
    exe: []const u8,
    tag: []const u8,
    argv: []const []const u8,
    stdin_data: []const u8,
) ![]u8 {
    const r = try runBinary(a, io, dir, exe, argv, tag, stdin_data);
    if (!r.term.success()) {
        std.debug.print("compat: pipeline stage '{s} {s}' failed: {f}\n{s}", .{ exe, argv[0], r.term, r.stderr });
        return error.StageFailed;
    }
    return r.stdout;
}

/// pfm2specdata: the port reads a Portable Float Map, the reference reads the
/// equivalent 16-bit capture, so the numbers must be related by 65535.
/// Detection (brightest green, crop box) must match outright; the readout must
/// match under that scale and the documented one-column shift.
///
/// The reference's numbers are recorded in `testdata/spectrum16.reference.txt`,
/// captured once from the C++ tool (see tools/gen_spectrum_fixture.py), so
/// checking them needs neither that binary nor a 16-bit fixture.
fn pfmCheck(a: Allocator, io: Io, dir: []const u8, zig_exe: []const u8, out: *Io.Writer) !usize {
    const recorded = @embedFile("testdata/spectrum16.reference.txt");
    const split = std.mem.indexOf(u8, recorded, "\n---\n") orelse return error.MissingReference;
    const reference_debug = recorded[0 .. split + 1];
    const reference_readout = recorded[split + 5 ..];

    const pfm_path = "src/testdata/spectrum16.pfm";
    const z_debug = try runBinary(a, io, dir, zig_exe, &.{ pfm_path, "debug" }, "z", "");
    const z_read = try runBinary(a, io, dir, zig_exe, &.{pfm_path}, "z", "");

    var failures: usize = 0;
    if (!(try debugMatches(a, reference_debug, z_debug.stdout))) {
        failures += 1;
        try out.print("FAIL pfm2specdata detection\n", .{});
        try describe("stdout", reference_debug, z_debug.stdout, out);
    }
    if (!(try readoutMatches(a, reference_readout, z_read.stdout))) {
        failures += 1;
        try out.print("FAIL pfm2specdata readout\n", .{});
        try describe("stdout", reference_readout, z_read.stdout, out);
    }
    return failures;
}

/// The reference's debug lines are 16-bit integers; the port's are floats that
/// must scale back to them. The pixel and the crop box are integers in both.
fn debugMatches(a: Allocator, c: []const u8, z: []const u8) !bool {
    var c_lines = std.mem.splitScalar(u8, c, '\n');
    var z_lines = std.mem.splitScalar(u8, z, '\n');
    const labels = [_][3][]const u8{
        .{ "rmax:", "gmax:", "bmax:" },
        .{ "rthreshold:", "gthreshold:", "bthreshold:" },
    };
    for (labels) |group| {
        const c_line = c_lines.next() orelse return false;
        const z_line = z_lines.next() orelse return false;
        var c_fields = std.mem.tokenizeScalar(u8, c_line, ' ');
        var z_fields = std.mem.tokenizeScalar(u8, z_line, ' ');
        for (group) |label| {
            if (!std.mem.eql(u8, label, c_fields.next() orelse return false)) return false;
            if (!std.mem.eql(u8, label, z_fields.next() orelse return false)) return false;
            const reference = std.fmt.parseInt(u32, c_fields.next() orelse return false, 10) catch return false;
            const port = std.fmt.parseFloat(f32, z_fields.next() orelse return false) catch return false;
            const scaled: u32 = @intFromFloat(@round(@as(f64, port) * 65535.0));
            // The fixture is 16-bit integers scaled to float by ImageMagick, so
            // the two agree to the nearest unit.
            if (scaled + 1 < reference or scaled > reference + 1) return false;
        }
    }
    _ = a;
    // "largest green" and the crop box are printed the same way by both.
    if (!std.mem.eql(u8, c_lines.next() orelse return false, z_lines.next() orelse return false)) return false;
    if (!std.mem.eql(u8, c_lines.next() orelse return false, z_lines.next() orelse return false)) return false;
    return true;
}

/// Reference row k carries the column this port prints for row k-1, scaled by
/// 65535 (the reference reads 16-bit integers, the port reads 0..1 floats) and
/// rounded to the nearest unit.
fn readoutMatches(a: Allocator, c: []const u8, z: []const u8) !bool {
    const c_rows = try parseReadout(a, c);
    const z_rows = try parseReadout(a, z);
    if (c_rows.len == 0 or c_rows.len != z_rows.len) return false;

    for (c_rows[1..], z_rows[0 .. z_rows.len - 1]) |reference, port| {
        if (reference.index != port.index + 1) return false;
        for (0..3) |i| {
            const scaled: u32 = @intFromFloat(@round(@as(f64, port.values[i]) * 65535.0));
            const want: u32 = @intFromFloat(@round(@as(f64, reference.values[i])));
            if (scaled + 1 < want or scaled > want + 1) return false;
        }
    }
    return true;
}

const ReadoutRow = struct { index: u32, values: [3]f32 };

fn parseReadout(a: Allocator, text: []const u8) ![]ReadoutRow {
    var rows: std.ArrayList(ReadoutRow) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ',');
        var row: ReadoutRow = .{ .index = 0, .values = .{ 0, 0, 0 } };
        row.index = try std.fmt.parseInt(u32, fields.next() orelse return error.BadReadout, 10);
        for (&row.values) |*v| {
            v.* = try std.fmt.parseFloat(f32, fields.next() orelse return error.BadReadout);
        }
        try rows.append(a, row);
    }
    return rows.toOwnedSlice(a);
}
