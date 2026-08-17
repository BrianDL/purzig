//! FFI for Data.FunctorWithIndex.

const rt = @import("runtime");
const Value = rt.Value;

fn mapWithIndexArray(f: Value, xs: Value) rt.Error!Value {
    const items = xs.asArray();
    const out = rt.alloc().alloc(Value, items.len) catch @panic("runtime: out of memory");

    for (items, out, 0..) |x, *slot, i| {
        slot.* = try rt.apply2(f, Value.mkInt(@intCast(i)), x);
    }
    return Value.mkArray(out);
}

pub const @"ps.mapWithIndexArray" = rt.curry(mapWithIndexArray);
