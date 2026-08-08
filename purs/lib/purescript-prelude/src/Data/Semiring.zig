//! FFI for Data.Semiring.
//!
//! Int arithmetic in PureScript is 32-bit WRAPPING, because the JavaScript
//! backend forces every result through `| 0`. Zig's `+` and `*` are illegal
//! behaviour on overflow and panic in Debug, so every Int operation here uses
//! the wrapping operators. Getting this wrong is silent divergence from every
//! other backend.

const rt = @import("runtime");
const Value = rt.Value;

fn intAdd(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() +% y.asInt());
}

fn intMul(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() *% y.asInt());
}

fn numAdd(x: Value, y: Value) Value {
    return Value.mkNumber(x.asNumber() + y.asNumber());
}

fn numMul(x: Value, y: Value) Value {
    return Value.mkNumber(x.asNumber() * y.asNumber());
}

pub const @"ps.intAdd" = rt.curry(intAdd);
pub const @"ps.intMul" = rt.curry(intMul);
pub const @"ps.numAdd" = rt.curry(numAdd);
pub const @"ps.numMul" = rt.curry(numMul);
