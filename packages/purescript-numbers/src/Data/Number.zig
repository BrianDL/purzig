//! FFI for Data.Number.
//!
//! Mostly a thin layer over Zig's float builtins, but four of these are NOT the
//! builtin that shares their name, and those four are the whole reason this
//! file needs reading rather than skimming:
//!
//!   * `max`/`min` propagate NaN. Zig's `@max`/`@min` return the non-NaN
//!     operand instead, which is the IEEE-754 recommendation and the opposite
//!     of what `Math.max` does.
//!   * `round` breaks ties towards positive infinity, so `round (-2.5)` is
//!     `-2.0`. Zig's `@round` breaks ties away from zero and gives `-3.0`.
//!   * `sign` returns NaN for NaN and preserves the sign of zero.
//!   * `fromStringImpl` follows `parseFloat`, which reads the longest valid
//!     prefix and ignores the rest. Zig's `parseFloat` requires the whole
//!     string, so the prefix scan is written out below.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

// ---- classification ---------------------------------------------------

fn isNaNImpl(x: Value) Value {
    return Value.mkBool(std.math.isNan(x.asNumber()));
}

fn isFiniteImpl(x: Value) Value {
    return Value.mkBool(std.math.isFinite(x.asNumber()));
}

// ---- unary ------------------------------------------------------------

fn abs(x: Value) Value {
    return Value.mkNumber(@abs(x.asNumber()));
}

fn acos(x: Value) Value {
    return Value.mkNumber(std.math.acos(x.asNumber()));
}

fn asin(x: Value) Value {
    return Value.mkNumber(std.math.asin(x.asNumber()));
}

fn atan(x: Value) Value {
    return Value.mkNumber(std.math.atan(x.asNumber()));
}

fn ceil(x: Value) Value {
    return Value.mkNumber(@ceil(x.asNumber()));
}

fn cos(x: Value) Value {
    return Value.mkNumber(@cos(x.asNumber()));
}

fn exp(x: Value) Value {
    return Value.mkNumber(@exp(x.asNumber()));
}

fn floor(x: Value) Value {
    return Value.mkNumber(@floor(x.asNumber()));
}

fn log(x: Value) Value {
    return Value.mkNumber(@log(x.asNumber()));
}

fn sin(x: Value) Value {
    return Value.mkNumber(@sin(x.asNumber()));
}

fn sqrt(x: Value) Value {
    return Value.mkNumber(@sqrt(x.asNumber()));
}

fn tan(x: Value) Value {
    return Value.mkNumber(@tan(x.asNumber()));
}

fn trunc(x: Value) Value {
    return Value.mkNumber(@trunc(x.asNumber()));
}

/// `Math.round` is `floor(x + 0.5)`, not round-half-away-from-zero: the tie at
/// `-2.5` goes to `-2`, where `@round` would give `-3`.
///
/// The guard above 2^52 is from the specification and is not pedantry: at that
/// magnitude every f64 is already an integer, and adding 0.5 would round the
/// value itself rather than resolve a tie.
fn round(x: Value) Value {
    const n = x.asNumber();
    if (!std.math.isFinite(n)) return Value.mkNumber(n);
    if (@abs(n) >= 4503599627370496.0) return Value.mkNumber(n);
    return Value.mkNumber(@floor(n + 0.5));
}

/// NaN in, NaN out; `-0.0` and `0.0` are returned unchanged rather than
/// collapsed to a positive zero.
fn sign(x: Value) Value {
    const n = x.asNumber();
    if (std.math.isNan(n) or n == 0) return Value.mkNumber(n);
    return Value.mkNumber(if (n < 0) -1.0 else 1.0);
}

// ---- binary -----------------------------------------------------------

fn atan2(y: Value, x: Value) Value {
    return Value.mkNumber(std.math.atan2(y.asNumber(), x.asNumber()));
}

fn pow(n: Value, p: Value) Value {
    return Value.mkNumber(std.math.pow(f64, n.asNumber(), p.asNumber()));
}

/// JavaScript's `%` on Numbers is the truncated remainder -- `@rem`, not
/// `@mod`. Unlike the Int case there is no divide-by-zero problem: the answer
/// is NaN and NaN is a perfectly good Number.
fn remainder(n: Value, m: Value) Value {
    return Value.mkNumber(@rem(n.asNumber(), m.asNumber()));
}

fn max(a: Value, b: Value) Value {
    const x = a.asNumber();
    const y = b.asNumber();
    if (std.math.isNan(x) or std.math.isNan(y)) return Value.mkNumber(std.math.nan(f64));
    return Value.mkNumber(if (x > y) x else y);
}

fn min(a: Value, b: Value) Value {
    const x = a.asNumber();
    const y = b.asNumber();
    if (std.math.isNan(x) or std.math.isNan(y)) return Value.mkNumber(std.math.nan(f64));
    return Value.mkNumber(if (x < y) x else y);
}

// ---- parsing ----------------------------------------------------------

/// The length of the longest prefix of `s` that `parseFloat` would consume, or
/// null if there is none. Leading whitespace is skipped, `Infinity` is a
/// literal, and a trailing `e` with no exponent digits is not part of the
/// number -- `parseFloat("1e")` is 1, not NaN.
fn floatPrefix(s: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
    const start = i;

    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;

    if (std.mem.startsWith(u8, s[i..], "Infinity")) {
        return .{ .start = start, .end = i + "Infinity".len };
    }

    const digits_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }
    // A bare "." or a bare sign is not a number.
    if (i == digits_start or (i == digits_start + 1 and s[digits_start] == '.')) return null;

    var end = i;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        const exp_start = j;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {}
        if (j > exp_start) end = j;
    }

    return .{ .start = start, .end = end };
}

/// `fromStringImpl(str, isFinite, just, nothing)`.
///
/// The `isFinite` predicate is passed in from PureScript rather than applied
/// here, exactly as in the original -- it is the foreign `isFinite` above,
/// arriving as an ordinary function Value. Keeping the call means the NaN and
/// Infinity policy lives in one place.
fn fromStringImpl(str: Value, isFinite: Value, just: Value, nothing: Value) rt.Error!Value {
    const s = str.asString();

    const parsed: f64 = blk: {
        const span = floatPrefix(s) orelse break :blk std.math.nan(f64);
        break :blk std.fmt.parseFloat(f64, s[span.start..span.end]) catch std.math.nan(f64);
    };

    if (!(try rt.apply(isFinite, Value.mkNumber(parsed))).asBool()) return nothing;
    return try rt.apply(just, Value.mkNumber(parsed));
}

// ---- exports ----------------------------------------------------------
//
// `nan` and `infinity` are foreign VALUES, not functions. A foreign import is
// re-exported by the emitter as a nullary function returning whatever this
// declaration holds, so these are plain `Value`s with no `rt.curry` around
// them -- currying a non-function would not compile.

pub const @"ps.nan" = Value.mkNumber(std.math.nan(f64));
pub const @"ps.infinity" = Value.mkNumber(std.math.inf(f64));

pub const @"ps.isNaN" = rt.curry(isNaNImpl);
pub const @"ps.isFinite" = rt.curry(isFiniteImpl);
pub const @"ps.fromStringImpl" = rt.curry(fromStringImpl);

pub const @"ps.abs" = rt.curry(abs);
pub const @"ps.acos" = rt.curry(acos);
pub const @"ps.asin" = rt.curry(asin);
pub const @"ps.atan" = rt.curry(atan);
pub const @"ps.atan2" = rt.curry(atan2);
pub const @"ps.ceil" = rt.curry(ceil);
pub const @"ps.cos" = rt.curry(cos);
pub const @"ps.exp" = rt.curry(exp);
pub const @"ps.floor" = rt.curry(floor);
pub const @"ps.log" = rt.curry(log);
pub const @"ps.max" = rt.curry(max);
pub const @"ps.min" = rt.curry(min);
pub const @"ps.pow" = rt.curry(pow);
pub const @"ps.remainder" = rt.curry(remainder);
pub const @"ps.round" = rt.curry(round);
pub const @"ps.sign" = rt.curry(sign);
pub const @"ps.sin" = rt.curry(sin);
pub const @"ps.sqrt" = rt.curry(sqrt);
pub const @"ps.tan" = rt.curry(tan);
pub const @"ps.trunc" = rt.curry(trunc);
