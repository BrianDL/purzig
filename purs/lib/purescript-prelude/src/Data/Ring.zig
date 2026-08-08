//! FFI for Data.Ring. See Data/Semiring.zig on wrapping Int arithmetic.

const rt = @import("runtime");
const Value = rt.Value;

fn intSub(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() -% y.asInt());
}

fn numSub(x: Value, y: Value) Value {
    return Value.mkNumber(x.asNumber() - y.asNumber());
}

pub const @"ps.intSub" = rt.curry(intSub);
pub const @"ps.numSub" = rt.curry(numSub);
