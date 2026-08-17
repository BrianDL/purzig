//! FFI for Data.Eq.
//!
//! JavaScript uses `===` for every scalar, which is content equality for
//! strings and identity for everything else it is applied to here. Our Values
//! are tagged, so each type gets its own accessor.

const rt = @import("runtime");
const Value = rt.Value;

fn eqBooleanImpl(x: Value, y: Value) Value {
    return Value.mkBool(x.asBool() == y.asBool());
}

fn eqIntImpl(x: Value, y: Value) Value {
    return Value.mkBool(x.asInt() == y.asInt());
}

fn eqNumberImpl(x: Value, y: Value) Value {
    return Value.mkBool(x.asNumber() == y.asNumber());
}

fn eqCharImpl(x: Value, y: Value) Value {
    return Value.mkBool(x.asChar() == y.asChar());
}

fn eqStringImpl(x: Value, y: Value) Value {
    return Value.mkBool(x.stringEq(y.asString()));
}

/// `f` is the element-wise equality from the Eq dictionary, so it is applied
/// through `rt.apply2` like any other PureScript function -- and like any other
/// PureScript function it may throw, which is why this one alone returns
/// `rt.Error!Value`. `rt.curry` coerces a plain `Value` return, so the scalar
/// comparisons above need no annotation.
fn eqArrayImpl(f: Value, xs: Value, ys: Value) rt.Error!Value {
    const a = xs.asArray();
    const b = ys.asArray();
    if (a.len != b.len) return Value.mkBool(false);
    for (a, b) |x, y| {
        if (!(try rt.apply2(f, x, y)).asBool()) return Value.mkBool(false);
    }
    return Value.mkBool(true);
}

pub const @"ps.eqBooleanImpl" = rt.curry(eqBooleanImpl);
pub const @"ps.eqIntImpl" = rt.curry(eqIntImpl);
pub const @"ps.eqNumberImpl" = rt.curry(eqNumberImpl);
pub const @"ps.eqCharImpl" = rt.curry(eqCharImpl);
pub const @"ps.eqStringImpl" = rt.curry(eqStringImpl);
pub const @"ps.eqArrayImpl" = rt.curry(eqArrayImpl);
