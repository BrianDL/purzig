//! FFI for Data.Int.
//!
//! Every one of these is really a transcription of JavaScript's `| 0`, i.e.
//! ECMA-262 `ToInt32`: truncate towards zero, reduce modulo 2^32, reinterpret
//! as signed. `quot` and `pow` are defined in terms of it in the original, and
//! `fromNumberImpl` uses it as its own membership test, so `toInt32` below is
//! the whole module in miniature.
//!
//! `Radix` is a newtype, and newtypes are erased before emission, so a `Radix`
//! argument arrives as a plain integer `Value`.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

const two_32: f64 = 4294967296.0;
const int32_min: f64 = -2147483648.0;
const int32_max: f64 = 2147483647.0;

/// ECMA-262 `ToInt32`. NaN and the infinities become 0; everything else is
/// truncated towards zero and then reduced into the signed 32-bit range.
///
/// The fast path matters: any value already in range is exact in an f64, which
/// is the case for every result of `quot` on real inputs. The slow path exists
/// because JavaScript defines `Math.pow(2, 40) | 0` as 0 rather than as a
/// saturating conversion, and `@intFromFloat` on an out-of-range value is
/// illegal behaviour in Zig rather than a wrap.
fn toInt32(x: f64) i32 {
    if (!std.math.isFinite(x)) return 0;

    const t = @trunc(x);
    if (t >= int32_min and t <= int32_max) return @intFromFloat(t);

    var m = @mod(t, two_32);
    if (m >= two_32 / 2) m -= two_32;
    if (!(m >= int32_min and m <= int32_max)) return 0;
    return @intFromFloat(m);
}

fn toNumber(x: Value) Value {
    return Value.mkNumber(@floatFromInt(x.asInt()));
}

/// `x / y | 0`. Division by zero yields Infinity or NaN in JavaScript, and
/// `ToInt32` maps both to 0 -- so this returns 0 rather than trapping, which is
/// the same divide-by-zero convention `Data.EuclideanRing.intDiv` already uses.
///
/// Going through f64 rather than `@divTrunc` is deliberate: it also gives the
/// right answer for `quot minBound (-1)`, where the true quotient is one past
/// `maxBound` and `@divTrunc` would trap.
fn quot(x: Value, y: Value) Value {
    const a: f64 = @floatFromInt(x.asInt());
    const b: f64 = @floatFromInt(y.asInt());
    return Value.mkInt(toInt32(a / b));
}

/// JavaScript's `%` is the truncated remainder, which is Zig's `@rem` and not
/// `@mod`. `x % 0` is NaN there; the PureScript type says Int, so 0 is the only
/// answer available and it matches what `ToInt32(NaN)` would give.
fn rem(x: Value, y: Value) Value {
    const b = y.asInt();
    if (b == 0) return Value.mkInt(0);
    return Value.mkInt(@rem(x.asInt(), b));
}

/// `Math.pow(x, y) | 0`. Computed in floating point exactly as the original is,
/// so a result beyond 32 bits wraps rather than saturating, and a negative
/// exponent truncates to 0.
fn pow(x: Value, y: Value) Value {
    const base: f64 = @floatFromInt(x.asInt());
    const exponent: f64 = @floatFromInt(y.asInt());
    return Value.mkInt(toInt32(std.math.pow(f64, base, exponent)));
}

/// The digit set `Number.prototype.toString` uses: decimal digits then
/// lowercase letters, up to base 36.
fn digitChar(d: u32) u8 {
    return if (d < 10) '0' + @as(u8, @intCast(d)) else 'a' + @as(u8, @intCast(d - 10));
}

fn toStringAs(radix: Value, x: Value) Value {
    const base: u32 = @intCast(radix.asInt());
    const n = x.asInt();

    // Take the magnitude as u32 so that `minBound` has one, which `-minBound`
    // does not in i32.
    const negative = n < 0;
    var magnitude: u32 = if (negative)
        @as(u32, @intCast(-@as(i64, n)))
    else
        @intCast(n);

    // 32 digits is the widest possible (base 2), plus one for the sign.
    var buf: [33]u8 = undefined;
    var i: usize = buf.len;

    if (magnitude == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (magnitude != 0) {
        i -= 1;
        buf[i] = digitChar(magnitude % base);
        magnitude /= base;
    }
    if (negative) {
        i -= 1;
        buf[i] = '-';
    }

    const out = rt.alloc().dupe(u8, buf[i..]) catch @panic("runtime: out of memory");
    return Value.mkString(out);
}

/// `(n | 0) === n ? just(n) : nothing`.
///
/// The round-trip through `toInt32` is the membership test, and it is exactly
/// the original's: NaN fails it, a fractional value fails it, and anything
/// outside 32 bits fails it. `-0` passes, since `-0 == 0` in both languages.
fn fromNumberImpl(just: Value, nothing: Value, n: Value) rt.Error!Value {
    const x = n.asNumber();
    const i = toInt32(x);
    const round_trip: f64 = @floatFromInt(i);
    if (round_trip != x) return nothing;
    return try rt.apply(just, Value.mkInt(i));
}

/// Is `c` a digit in this base? Case-insensitive, matching the `i` flag on the
/// original's regular expression.
fn digitValue(c: u8, base: u32) ?u32 {
    const v: u32 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => return null,
    };
    return if (v < base) v else null;
}

/// The original builds a regular expression, tests the whole string against it,
/// and only then calls `parseInt`. Validating first is what makes this reject
/// `"12x"` rather than parsing a prefix of it, so the scan below is a single
/// pass that does both and bails on the first character that does not fit.
///
/// A magnitude that leaves the 32-bit range yields `nothing`: `parseInt`
/// returns a Number there, and the original's `(i | 0) === i` test then fails.
fn fromStringAsImpl(just: Value, nothing: Value, radix: Value, str: Value) rt.Error!Value {
    const base: u32 = @intCast(radix.asInt());
    const s = str.asString();

    var i: usize = 0;
    var negative = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        negative = s[0] == '-';
        i = 1;
    }

    // At least one digit is required -- the regex is `digits+`, not `digits*`.
    if (i >= s.len) return nothing;

    var acc: i64 = 0;
    while (i < s.len) : (i += 1) {
        const d = digitValue(s[i], base) orelse return nothing;
        acc = acc * @as(i64, base) + @as(i64, d);
        // Bail as soon as the magnitude cannot be an Int, so a long string of
        // digits cannot overflow the accumulator on the way to the same answer.
        if (acc > 4294967296) return nothing;
    }

    const signed = if (negative) -acc else acc;
    if (signed < -2147483648 or signed > 2147483647) return nothing;
    return try rt.apply(just, Value.mkInt(@intCast(signed)));
}

pub const @"ps.toNumber" = rt.curry(toNumber);
pub const @"ps.quot" = rt.curry(quot);
pub const @"ps.rem" = rt.curry(rem);
pub const @"ps.pow" = rt.curry(pow);
pub const @"ps.toStringAs" = rt.curry(toStringAs);
pub const @"ps.fromNumberImpl" = rt.curry(fromNumberImpl);
pub const @"ps.fromStringAsImpl" = rt.curry(fromStringAsImpl);
