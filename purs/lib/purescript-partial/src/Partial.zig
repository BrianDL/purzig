//! FFI for Partial.
//!
//! `_crashWith` throws a JavaScript `Error` in the original. Here it panics,
//! following `Data.String.Unsafe` and `rt.forceLazy`: a `Partial` constraint
//! that reached a crash is a violated precondition the type system was pointing
//! at, not a recoverable condition. The message still travels, so the panic
//! names what went wrong.
//!
//! The consequence is that `crashWith` is not catchable by
//! `Effect.Exception.catchException`, where in JavaScript it would be. Anything
//! wanting a catchable failure should be using `Effect.Exception.throw`, which
//! goes through `rt.throwValue` and is.

const rt = @import("runtime");
const Value = rt.Value;

fn _crashWith(message: Value) Value {
    @panic(message.asString());
}

pub const @"ps._crashWith" = rt.curry(_crashWith);
