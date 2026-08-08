//! FILE: purs/lib/purescript-prelude/src/Data/Reflectable.zig
//!
//! FFI for Data.Reflectable.
//!
//! `unsafeCoerce` is the identity, exactly as in Data.Symbol: every PureScript
//! value is an `rt.Value` here, so there is nothing to convert.

const rt = @import("runtime");
const Value = rt.Value;

fn unsafeCoerce(a: Value) Value {
    return a;
}

pub const @"ps.unsafeCoerce" = rt.curry(unsafeCoerce);
