//! FFI for Data.Functor.

const rt = @import("runtime");
const Value = rt.Value;

/// Fallible: `f` is arbitrary PureScript code. Note the `try` goes on the
/// assignment inside the loop rather than around the call, since the error
/// union has to be unwrapped before it can be stored in a `Value` slot.
fn arrayMap(f: Value, xs: Value) rt.Error!Value {
    const a = xs.asArray();
    const out = rt.alloc().alloc(Value, a.len) catch @panic("runtime: out of memory");
    for (a, out) |x, *slot| slot.* = try rt.apply(f, x);
    return Value.mkArray(out);
}

pub const @"ps.arrayMap" = rt.curry(arrayMap);
