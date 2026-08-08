//! Zig side of the `foreign import` declarations in `Zig/Prelude.purs`.
//!
//! This file sits beside its PureScript source, exactly as `Foo/Bar.js` sits
//! beside `Foo/Bar.purs` for the JavaScript backend and `Foo/Bar.erl` does for
//! purerl. The backend reads `modulePath` from corefn.json, finds this file,
//! and copies it into the output directory as `Zig.Prelude.ffi.zig`. Nothing
//! registers it anywhere: a package ships its own FFI.
//!
//! Write foreign functions as ordinary Zig functions taking and returning
//! `rt.Value`, then wrap them:
//!
//!   * `rt.curry(f)`  -- a pure function of one or more arguments.
//!   * `rt.effect(f)` -- an `Effect`. Adds the trailing unit thunk, so nothing
//!                       runs until `rt.runEffect` forces it. Works for
//!                       nullary `f` too.
//!
//! Both generate the chain of one-argument closures from the signature at
//! comptime, so there are no hand-managed `env` indices to keep in sync.

const rt = @import("runtime");
const Value = rt.Value;

// -- concatString :: String -> String -> String ------------------------------

fn concatString(a: Value, b: Value) Value {
    return Value.mkString(rt.concatString(a.asString(), b.asString()));
}

pub const @"ps.concatString" = rt.curry(concatString);

// -- log :: String -> Effect Unit --------------------------------------------

fn log(msg: Value) Value {
    rt.writeLine(msg.asString());
    return Value.mkUnit();
}

pub const @"ps.log" = rt.effect(log);

// -- pureUnit :: Effect Unit -------------------------------------------------
// The simplest possible Effect, useful as a codegen smoke test.

fn pureUnit() Value {
    return Value.mkUnit();
}

pub const @"ps.pureUnit" = rt.effect(pureUnit);
