//! FFI for Data.Symbol.
//!
//! `unsafeCoerce` is the identity. Every PureScript value is an `rt.Value`
//! here, so there is genuinely nothing to do -- the same reason the JavaScript
//! implementation just returns its argument.

const rt = @import("runtime");
const Value = rt.Value;

fn unsafeCoerce(a: Value) Value {
    return a;
}

pub const @"ps.unsafeCoerce" = rt.curry(unsafeCoerce);
