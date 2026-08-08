//! FFI for Data.EuclideanRing.
//!
//! Int division is EUCLIDEAN, not truncating, and division by zero returns
//! zero rather than trapping. Zig's `@divTrunc` and `@rem` give different
//! answers for negative operands, so the JavaScript definitions are followed
//! exactly rather than mapped onto the nearest Zig builtin.
//!
//! Arithmetic goes through i64 because the edge cases overflow i32:
//! `abs(minInt)` and `minInt / -1` both do.

const rt = @import("runtime");
const Value = rt.Value;

fn intDegree(x: Value) Value {
    const v: i64 = x.asInt();
    const magnitude = if (v < 0) -v else v;
    return Value.mkInt(@intCast(@min(magnitude, 2147483647)));
}

fn intDiv(x: Value, y: Value) Value {
    const a: i64 = x.asInt();
    const b: i64 = y.asInt();
    if (b == 0) return Value.mkInt(0);
    // JS: y > 0 ? floor(x / y) : -floor(x / -y). This is NOT @divFloor for a
    // negative divisor: @divFloor(7, -2) is -4, this is -3.
    const q = if (b > 0) @divFloor(a, b) else -@divFloor(a, -b);
    return Value.mkInt(@truncate(q));
}

fn intMod(x: Value, y: Value) Value {
    const a: i64 = x.asInt();
    const b: i64 = y.asInt();
    if (b == 0) return Value.mkInt(0);
    const magnitude = if (b < 0) -b else b;
    // JS: ((x % yy) + yy) % yy -- the Euclidean modulus, which is what @mod
    // computes for a positive divisor.
    return Value.mkInt(@truncate(@mod(a, magnitude)));
}

fn numDiv(x: Value, y: Value) Value {
    return Value.mkNumber(x.asNumber() / y.asNumber());
}

pub const @"ps.intDegree" = rt.curry(intDegree);
pub const @"ps.intDiv" = rt.curry(intDiv);
pub const @"ps.intMod" = rt.curry(intMod);
pub const @"ps.numDiv" = rt.curry(numDiv);
