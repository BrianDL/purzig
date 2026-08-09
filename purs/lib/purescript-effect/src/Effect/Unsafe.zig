//! Zig side of `Effect/Unsafe.purs`, transcribed from `Effect/Unsafe.js` at
//! tag v4.0.0.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

// -- unsafePerformEffect :: forall a. Effect a -> a --------------------------
//
// `rt.curry`, not `rt.effect`: the result is the value itself, not another
// Effect, so there is no trailing unit thunk. Forcing happens as soon as this
// is applied -- which is exactly what makes it unsafe.

fn unsafePerformEffect(eff: Value) Error!Value {
    return rt.runEffect(eff);
}

pub const @"ps.unsafePerformEffect" = rt.curry(unsafePerformEffect);
