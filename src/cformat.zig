//! Byte-exact reimplementation of the C `printf` conversions ssftool relies on.
//!
//! Zig's `std.fmt` float formatting cannot be used for this: it renders the
//! *shortest decimal that round-trips* and then pads or cuts to the requested
//! precision, and its rounding is half-up. C's `%f` renders the *exact* binary
//! value, correctly rounded, with ties to even. The two disagree for ordinary
//! values:
//!
//!     f32 295334.84375  ->  %f      "295334.843750"
//!                           {d:.6}  "295334.840000"
//!     f32 0.0078125     ->  %.6f    "0.007812"   (tie to even)
//!                           {d:.6}  "0.007813"   (half up)
//!
//! ssftool's whole job is emitting numeric columns, so the port reproduces
//! glibc exactly instead. A binary float is exactly `m * 2^e`, so the scaled
//! integer `round_half_even(value * 10^precision)` is computed with exact
//! big-integer arithmetic and then the decimal point is inserted.
//!
//! Verified against glibc for 50k random f32 bit patterns plus the special
//! cases (see `src/cformat_test.zig`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const big = std.math.big;

pub const Error = Allocator.Error || Io.Writer.Error;

/// `printf("%.*f", precision, value)`, including the C rule that a negative
/// precision behaves as if the precision were omitted (C11 7.21.6.1p5).
pub fn fixed(a: Allocator, w: *Io.Writer, value: anytype, precision: i64) Error!void {
    const T = @TypeOf(value);
    comptime std.debug.assert(@typeInfo(T) == .float);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const frac_bits = comptime std.math.floatFractionalBits(T);
    const exp_bits = comptime std.math.floatExponentBits(T);
    const bias = comptime (@as(i32, 1) << (exp_bits - 1)) - 1;

    const bits: U = @bitCast(value);
    const frac_mask: U = (@as(U, 1) << frac_bits) - 1;
    const exp_mask: U = (@as(U, 1) << exp_bits) - 1;
    const sign = (bits >> (frac_bits + exp_bits)) != 0;
    const exp_field: U = (bits >> frac_bits) & exp_mask;
    const frac: U = bits & frac_mask;

    if (exp_field == exp_mask) { // infinity or NaN; glibc keeps the sign
        if (sign) try w.writeByte('-');
        try w.writeAll(if (frac != 0) "nan" else "inf");
        return;
    }
    if (sign) try w.writeByte('-');

    // Exact value: m * 2^e, m != 0 unless the value is zero.
    var m: u64 = undefined;
    var e: i32 = undefined;
    if (exp_field == 0) {
        m = frac;
        e = 1 - bias - frac_bits;
    } else {
        m = frac | (@as(U, 1) << frac_bits);
        e = @as(i32, @intCast(exp_field)) - bias - frac_bits;
    }

    const p: usize = if (precision < 0) 6 else @intCast(precision);
    if (m == 0) {
        try w.writeAll("0");
        if (p != 0) {
            try w.writeByte('.');
            try w.splatByteAll('0', p);
        }
        return;
    }

    // The exact decimal expansion terminates after `cap` fractional digits
    // (value = m * 5^-e / 10^-e for e < 0). Rounding beyond that is a no-op, so
    // a huge precision only appends zeros.
    const cap: usize = if (e < 0) @intCast(-e) else 0;
    const n = @min(p, cap);

    // scaled = round_half_even(m * 10^n * 2^e)
    var scaled = try big.int.Managed.initSet(a, m);
    defer scaled.deinit();

    if (n != 0) {
        const pow10 = try a.alloc(u8, n + 1);
        defer a.free(pow10);
        pow10[0] = '1';
        @memset(pow10[1..], '0');

        var p10 = try big.int.Managed.init(a);
        defer p10.deinit();
        p10.setString(10, pow10) catch unreachable; // "1" + zeros is valid decimal

        var prod = try big.int.Managed.init(a);
        defer prod.deinit();
        try prod.mul(&scaled, &p10);
        scaled.swap(&prod);
    }

    if (e >= 0) {
        var shifted = try big.int.Managed.init(a);
        defer shifted.deinit();
        try shifted.shiftLeft(&scaled, @intCast(e));
        scaled.swap(&shifted);
    } else {
        // scaled = m*10^n / 2^k, exactly, rounded half to even.
        var den = try big.int.Managed.initSet(a, 1);
        defer den.deinit();
        try den.shiftLeft(&den, @intCast(-e));

        var q = try big.int.Managed.init(a);
        defer q.deinit();
        var r = try big.int.Managed.init(a);
        defer r.deinit();
        try big.int.Managed.divTrunc(&q, &r, &scaled, &den);

        var twice_r = try big.int.Managed.init(a);
        defer twice_r.deinit();
        try twice_r.shiftLeft(&r, 1);

        switch (big.int.Managed.order(twice_r, den)) {
            .gt => try big.int.Managed.addScalar(&q, &q, 1),
            .eq => if (q.isOdd()) try big.int.Managed.addScalar(&q, &q, 1),
            .lt => {},
        }
        try scaled.copy(q.toConst());
    }

    const digits = scaled.toString(a, 10, .lower) catch unreachable; // base 10 is valid
    defer a.free(digits);

    if (n == 0) {
        // An exact integer (e >= 0): no rounding, just the requested zeros.
        try w.writeAll(digits);
        if (p != 0) {
            try w.writeByte('.');
            try w.splatByteAll('0', p);
        }
    } else {
        if (digits.len <= n) {
            try w.writeAll("0.");
            try w.splatByteAll('0', n - digits.len);
            try w.writeAll(digits);
        } else {
            try w.writeAll(digits[0 .. digits.len - n]);
            try w.writeByte('.');
            try w.writeAll(digits[digits.len - n ..]);
        }
        // Precision beyond the exact expansion: pad with zeros.
        if (p > n) try w.splatByteAll('0', p - n);
    }
}

/// `printf("%d", value)` for a signed integer.
pub fn int(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    try w.printInt(value, 10, .lower, .{});
}

test "fixed matches glibc printf on the recorded corpus" {
    const t = std.testing;
    var lines = std.mem.splitScalar(u8, @embedFile("testdata/printf_f32.txt"), '\n');
    var checked: usize = 0;
    var buf: [1024]u8 = undefined;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const hex = fields.next().?;
        const precision_text = fields.next().?;
        const want = fields.next().?;

        const bits = try std.fmt.parseInt(u32, hex, 16);
        const value: f32 = @bitCast(bits);
        const precision = try std.fmt.parseInt(i64, precision_text, 10);

        var w: Io.Writer = .fixed(&buf);
        try fixed(t.allocator, &w, value, precision);
        if (!std.mem.eql(u8, want, w.buffered())) {
            std.debug.print(
                "corpus mismatch: bits=0x{x} value={d} precision={d}: want '{s}', got '{s}'\n",
                .{ bits, value, precision, want, w.buffered() },
            );
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    // Regenerate with tools/gen_printf_golden.c if this ever changes.
    try t.expectEqual(@as(usize, 3006), checked);
}

test "fixed matches glibc for the cases std.fmt gets wrong" {
    const t = std.testing;
    var buf: [64]u8 = undefined;

    const cases = [_]struct { v: f32, p: i64, want: []const u8 }{
        .{ .v = 295334.84375, .p = 6, .want = "295334.843750" },
        .{ .v = 295334.84375, .p = 2, .want = "295334.84" },
        .{ .v = 0.0078125, .p = 6, .want = "0.007812" },
        .{ .v = 0.0078125, .p = 2, .want = "0.01" },
        .{ .v = 0.5, .p = 0, .want = "0" },
        .{ .v = 1.5, .p = 0, .want = "2" },
        .{ .v = 2.5, .p = 0, .want = "2" },
        .{ .v = -0.0, .p = 2, .want = "-0.00" },
        .{ .v = 380.0, .p = 2, .want = "380.00" },
        .{ .v = 0.000071, .p = 6, .want = "0.000071" },
        .{ .v = 1.0, .p = 3, .want = "1.000" },
        .{ .v = -1.0, .p = 0, .want = "-1" },
        .{ .v = 0.0, .p = 0, .want = "0" },
        .{ .v = 29533485056.0, .p = 6, .want = "29533485056.000000" },
        .{ .v = 12345678848.0, .p = 6, .want = "12345678848.000000" },
        .{ .v = 380.0, .p = 0, .want = "380" },
    };
    for (cases) |c| {
        var w: Io.Writer = .fixed(&buf);
        try fixed(t.allocator, &w, c.v, c.p);
        try t.expectEqualStrings(c.want, w.buffered());
    }
}
