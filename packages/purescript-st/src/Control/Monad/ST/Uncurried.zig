//! FFI for Control.Monad.ST.Uncurried.
//!
//! The `ST` counterpart of `Effect/Uncurried.zig`, and structurally identical
//! to it -- `ST` and `Effect` are the same thunk at runtime, so `mkSTFnN`
//! forces and `runSTFnN` defers for exactly the reasons set out there.
//!
//! NOT dead code. The optimizer's `coreForeignSemantics` covers these, but it
//! only fires when the call is syntactically saturated. `Data.Array.ST` defines
//! `splice = runSTFn4 spliceImpl` -- a partial application -- so the generated
//! `ps.splice` calls `runSTFn4` here at runtime.
//!
//! ## Which wrapper goes on which family
//!
//! The two are opposites, and getting it backwards costs a thunk level in one
//! direction or the other:
//!
//!   * `runSTFnN` FORWARDS a thunk. Its argument is an `STFnN`, which in this
//!     runtime is a chain that yields an unforced action once saturated -- so
//!     applying the arguments already produces the `ST` value the caller wants,
//!     and `rt.curry` hands it straight back. `rt.effect` here would wrap a
//!     second thunk around it: `rt.runEffect` peels the outer one, the body
//!     returns the inner one, and a closure escapes where a result was
//!     expected. Nothing forces it, so the effect silently never happens.
//!   * `mkSTFnN` CREATES one. Its argument is an ordinary curried
//!     `a -> ... -> ST h o`, and the `STFnN` it returns must wait for the force
//!     rather than run on saturation -- which is exactly `rt.effect`'s trailing
//!     unit thunk.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;


// -- mkSTFnN :: (a -> ... -> ST r o) -> STFnN a ... o -----------------------
//
// Forces: an `STFnN` performs as soon as it is saturated, with no trailing
// unit thunk, so the curried action it is handed has to be run.

fn mkSTFn1(func: Value, a: Value) Error!Value {
    return rt.runEffect(try rt.apply(func, a));
}

pub const @"ps.mkSTFn1" = rt.effect(mkSTFn1);

fn mkSTFn2(func: Value, a: Value, b: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(func, a), b));
}

pub const @"ps.mkSTFn2" = rt.effect(mkSTFn2);

fn mkSTFn3(func: Value, a: Value, b: Value, c: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(func, a), b), c));
}

pub const @"ps.mkSTFn3" = rt.effect(mkSTFn3);

fn mkSTFn4(func: Value, a: Value, b: Value, c: Value, d: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d));
}

pub const @"ps.mkSTFn4" = rt.effect(mkSTFn4);

fn mkSTFn5(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e));
}

pub const @"ps.mkSTFn5" = rt.effect(mkSTFn5);

fn mkSTFn6(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f));
}

pub const @"ps.mkSTFn6" = rt.effect(mkSTFn6);

fn mkSTFn7(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g));
}

pub const @"ps.mkSTFn7" = rt.effect(mkSTFn7);

fn mkSTFn8(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h));
}

pub const @"ps.mkSTFn8" = rt.effect(mkSTFn8);

fn mkSTFn9(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i));
}

pub const @"ps.mkSTFn9" = rt.effect(mkSTFn9);

fn mkSTFn10(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value, j: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i), j));
}

pub const @"ps.mkSTFn10" = rt.effect(mkSTFn10);


// -- runSTFnN :: STFnN a ... o -> a -> ... -> ST r o ------------------------
//
// Defers: the result is an ordinary `ST` action, and `rt.effect`'s trailing
// unit thunk is the deferral.

fn runSTFn1(func: Value, a: Value) Error!Value {
    return rt.apply(func, a);
}

pub const @"ps.runSTFn1" = rt.curry(runSTFn1);

fn runSTFn2(func: Value, a: Value, b: Value) Error!Value {
    return rt.apply(try rt.apply(func, a), b);
}

pub const @"ps.runSTFn2" = rt.curry(runSTFn2);

fn runSTFn3(func: Value, a: Value, b: Value, c: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(func, a), b), c);
}

pub const @"ps.runSTFn3" = rt.curry(runSTFn3);

fn runSTFn4(func: Value, a: Value, b: Value, c: Value, d: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d);
}

pub const @"ps.runSTFn4" = rt.curry(runSTFn4);

fn runSTFn5(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e);
}

pub const @"ps.runSTFn5" = rt.curry(runSTFn5);

fn runSTFn6(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f);
}

pub const @"ps.runSTFn6" = rt.curry(runSTFn6);

fn runSTFn7(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g);
}

pub const @"ps.runSTFn7" = rt.curry(runSTFn7);

fn runSTFn8(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h);
}

pub const @"ps.runSTFn8" = rt.curry(runSTFn8);

fn runSTFn9(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i);
}

pub const @"ps.runSTFn9" = rt.curry(runSTFn9);

fn runSTFn10(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value, j: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i), j);
}

pub const @"ps.runSTFn10" = rt.curry(runSTFn10);
