//! Zig side of `Effect/Exception.purs`, transcribed from
//! `Effect/Exception.js` at tag v6.1.0.
//!
//! Zig has no stack unwinding: errors are values in the return type and every
//! call site decides explicitly what to do with them. So a PureScript exception
//! travels as `error.PsException` through the fallible `Fn1` that all generated
//! code and all FFI is compiled against, and `try` at every application is what
//! propagates it.
//!
//! Zig error values carry no payload, so the `Error` itself travels in a side
//! channel: `rt.throwValue` stashes it and returns the error; `rt.takeError`
//! retrieves it in the handler. This is the ordinary Zig pattern for errors
//! that need diagnostics attached, and it is sound here because the runtime is
//! single-threaded and at most one exception is ever in flight.
//!
//! An `Error` is `mkData("Error", &.{ message, name, cause })`, with `cause`
//! unit when absent. A data constructor rather than a record because nothing
//! in PureScript ever projects it structurally -- `message` and `name` are
//! foreign imports, which is to say they are these functions.
//!
//! Divergences from the JavaScript backend:
//!
//!   * There is no stack trace. `stackImpl` always yields `Nothing`, and
//!     `showErrorImpl` falls back to the `toString` form, which is what the JS
//!     does when `err.stack` is absent.
//!   * JS `catchException` wraps a non-`Error` throw in a new `Error`. Nothing
//!     here can throw a non-`Error`: `throwException` takes one, and
//!     `Effect.Exception.throw` is `throwException <<< error`.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

/// Field order for the `Error` data constructor.
const message_field = 0;
const name_field = 1;
const cause_field = 2;

fn mkError(msg: Value, nm: Value, cause: Value) Value {
    return Value.mkData("Error", rt.copyValues(&.{ msg, nm, cause }));
}

// -- construction -----------------------------------------------------------

// `error :: String -> Error`. Named `errorImpl` because `error` is a Zig
// keyword; only the exported `@"ps.error"` has to match the PureScript name.
fn errorImpl(msg: Value) Value {
    return mkError(msg, Value.mkString("Error"), Value.mkUnit());
}

pub const @"ps.error" = rt.curry(errorImpl);

// `errorWithCause :: String -> Error -> Error`
fn errorWithCause(msg: Value, cause: Value) Value {
    return mkError(msg, Value.mkString("Error"), cause);
}

pub const @"ps.errorWithCause" = rt.curry(errorWithCause);

// `errorWithName :: String -> String -> Error`
fn errorWithName(msg: Value, nm: Value) Value {
    return mkError(msg, nm, Value.mkUnit());
}

pub const @"ps.errorWithName" = rt.curry(errorWithName);

// -- projection -------------------------------------------------------------

fn message(e: Value) Value {
    return e.arg(message_field);
}

pub const @"ps.message" = rt.curry(message);

// `name :: Error -> String`. JS falls back to "Error" when the field is
// missing; here it is always populated by construction.
fn name(e: Value) Value {
    return e.arg(name_field);
}

pub const @"ps.name" = rt.curry(name);

// `showErrorImpl :: Error -> String`. JS prefers `err.stack` and falls back to
// `err.toString()`, which formats as "Name: message".
fn showErrorImpl(e: Value) Value {
    const prefix = rt.concatString(e.arg(name_field).asString(), ": ");
    return Value.mkString(rt.concatString(prefix, e.arg(message_field).asString()));
}

pub const @"ps.showErrorImpl" = rt.curry(showErrorImpl);

// `stackImpl :: (String -> Maybe String) -> Maybe String -> Error -> Maybe String`
//
// Takes `Just` and `Nothing` as arguments rather than constructing them,
// because the FFI cannot name a constructor from another package. No stack
// traces here, so the answer is always `Nothing`.
fn stackImpl(just: Value, nothing: Value, e: Value) Value {
    _ = just;
    _ = e;
    return nothing;
}

pub const @"ps.stackImpl" = rt.curry(stackImpl);

// -- throwing and catching --------------------------------------------------

// `throwException :: forall a. Error -> Effect a`
//
// `rt.throwValue` returns the error rather than taking it, so the stash and the
// raise cannot get out of step. Zig coerces the bare error into `Error!Value`.
fn throwException(e: Value) Error!Value {
    return rt.throwValue(e);
}

pub const @"ps.throwException" = rt.effect(throwException);

// `catchException :: forall a. (Error -> Effect a) -> Effect a -> Effect a`
//
// The `if (...) |v| ... else |_| ...` form is needed rather than `catch`,
// because the recovery branch is itself fallible -- the handler may throw
// again, and that must propagate.
fn catchException(handler: Value, action: Value) Error!Value {
    if (rt.runEffect(action)) |v| {
        return v;
    } else |_| {
        return rt.runEffect(try rt.apply(handler, rt.takeError()));
    }
}

pub const @"ps.catchException" = rt.effect(catchException);
