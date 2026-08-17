//! Zig side of `Unsafe/Coerce.purs`, transcribed from `Unsafe/Coerce.js` at
//! tag v6.0.0.
//!
//! Reached via `newtype` -> `safe-coerce`, which `maybe` depends on and
//! therefore `Effect.Exception` does too.
//!
//! The identity function, exactly as in JavaScript. It is sound for the same
//! reason: every PureScript value is one boxed `Value`, so a coercion the type
//! checker has sanctioned needs no representation change at all.

const rt = @import("runtime");
const Value = rt.Value;

fn unsafeCoerce(x: Value) Value {
    return x;
}

pub const @"ps.unsafeCoerce" = rt.curry(unsafeCoerce);
