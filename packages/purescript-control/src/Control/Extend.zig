//! Zig side of `Control/Extend.purs`, transcribed from `Control/Extend.js` at
//! tag v6.0.0.
//!
//! `purescript-control` is here only because `Effect.Exception` depends on
//! `either` and `maybe`, which depend on this. It is one function.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

// -- arrayExtend :: forall a b. (Array a -> b) -> Array a -> Array b --------
//
// JS is `xs.map((_, i, xs) => f(xs.slice(i)))`: element i of the result is `f`
// applied to the suffix of `xs` starting at i. The suffixes are subslices of
// the original array rather than copies -- immutable, so sharing is safe -- but
// the result array itself is fresh and must be copied into the arena, since
// `&.{...}` cannot express a runtime-length slice anyway.

fn arrayExtend(f: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    const out = rt.alloc().alloc(Value, items.len) catch @panic("runtime: out of memory");
    for (out, 0..) |*slot, i| {
        slot.* = try rt.apply(f, Value.mkArray(items[i..]));
    }
    return Value.mkArray(out);
}

pub const @"ps.arrayExtend" = rt.curry(arrayExtend);
