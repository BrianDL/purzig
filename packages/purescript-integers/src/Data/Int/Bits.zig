//! FFI for Data.Int.Bits.
//!
//! Four of these seven are dead code. `and`, `or`, `xor` and `complement` are
//! in the optimizer's `coreForeignSemantics`, so every call site is rewritten
//! into `OpIntBitAnd`/`OpIntBitOr`/`OpIntBitXor`/`OpIntBitNot` before emission
//! and these bodies are compiled but never reached. They are written correctly
//! anyway, cheaply, because the filter could change.
//!
//! The three shifts are different: the driver removes them from
//! `coreForeignSemantics`, so calls stay ordinary FFI applications and these
//! bodies DO run. The reason is that JavaScript's shift operators coerce the
//! count with `ToUint32` and then mask it to five bits, so `1 << 32` is `1` and
//! not `0`. Zig has no such rule -- a shift count wider than the type is
//! illegal behaviour -- so the masking has to be explicit, and doing it here
//! keeps the emitter from having to know about a JavaScript quirk.

const rt = @import("runtime");
const Value = rt.Value;

/// The shift count, masked exactly as `ToUint32(n) & 31` does.
fn shiftCount(y: Value) u5 {
    return @truncate(@as(u32, @bitCast(y.asInt())));
}

fn bitAnd(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() & y.asInt());
}

fn bitOr(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() | y.asInt());
}

fn bitXor(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() ^ y.asInt());
}

fn complement(x: Value) Value {
    return Value.mkInt(~x.asInt());
}

/// Shifting is done on the unsigned bit pattern so that bits leaving the top
/// are discarded rather than overflowing a signed type.
fn shl(x: Value, y: Value) Value {
    const bits: u32 = @bitCast(x.asInt());
    return Value.mkInt(@bitCast(bits << shiftCount(y)));
}

/// Arithmetic shift: the sign bit is replicated, matching JavaScript's `>>`.
fn shr(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() >> shiftCount(y));
}

/// Logical shift: zeroes are shifted in, matching JavaScript's `>>>`. Note the
/// result is still reinterpreted as a signed Int, so `-1 >>> 0` is `-1` here
/// exactly as `zshr (-1) 0` is in PureScript -- the unsigned intermediate is
/// not observable.
fn zshr(x: Value, y: Value) Value {
    const bits: u32 = @bitCast(x.asInt());
    return Value.mkInt(@bitCast(bits >> shiftCount(y)));
}

pub const @"ps.and" = rt.curry(bitAnd);
pub const @"ps.or" = rt.curry(bitOr);
pub const @"ps.xor" = rt.curry(bitXor);
pub const @"ps.complement" = rt.curry(complement);
pub const @"ps.shl" = rt.curry(shl);
pub const @"ps.shr" = rt.curry(shr);
pub const @"ps.zshr" = rt.curry(zshr);
