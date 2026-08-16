//! FFI for Data.Array.ST.Partial.
//!
//! The unchecked versions of `peek` and `poke`. Both are `STFnN`, so both are
//! `rt.effect` rather than `rt.curry`: a saturated `STFnN` yields a thunk that
//! `rt.runEffect` forces. See the header of `Data/Array/ST.zig`.
//!
//! JavaScript returns `undefined` for an out-of-range peek and silently grows
//! the array on an out-of-range poke. Neither is available here, and neither is
//! desirable: the slice index panics instead, which is what the `Partial`
//! constraint on the PureScript side is warning about.

const rt = @import("runtime");
const Value = rt.Value;

fn peekImpl(index: Value, xs: Value) Value {
    return xs.asMutArray().items[@intCast(index.asInt())];
}

fn pokeImpl(index: Value, a: Value, xs: Value) Value {
    xs.asMutArray().items[@intCast(index.asInt())] = a;
    return Value.mkUnit();
}

pub const @"ps.peekImpl" = rt.effect(peekImpl);
pub const @"ps.pokeImpl" = rt.effect(pokeImpl);
