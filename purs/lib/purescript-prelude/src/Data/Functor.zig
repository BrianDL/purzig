//! FFI for Data.Functor.

const rt = @import("runtime");
const Value = rt.Value;

fn arrayMap(f: Value, xs: Value) Value {
    const a = xs.asArray();
    const out = rt.alloc().alloc(Value, a.len) catch @panic("runtime: out of memory");
    for (a, out) |x, *slot| slot.* = rt.apply(f, x);
    return Value.mkArray(out);
}

pub const @"ps.arrayMap" = rt.curry(arrayMap);
