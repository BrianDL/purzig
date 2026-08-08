//! FFI for Data.Semigroup.

const rt = @import("runtime");
const Value = rt.Value;

fn concatString(a: Value, b: Value) Value {
    return Value.mkString(rt.concatString(a.asString(), b.asString()));
}

fn concatArray(xs: Value, ys: Value) Value {
    const a = xs.asArray();
    const b = ys.asArray();
    if (a.len == 0) return ys;
    if (b.len == 0) return xs;

    const out = rt.alloc().alloc(Value, a.len + b.len) catch @panic("runtime: out of memory");
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return Value.mkArray(out);
}

pub const @"ps.concatString" = rt.curry(concatString);
pub const @"ps.concatArray" = rt.curry(concatArray);
