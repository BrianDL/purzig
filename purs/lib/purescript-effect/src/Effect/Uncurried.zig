//! Zig side of `Effect/Uncurried.purs`, transcribed from
//! `Effect/Uncurried.js` at tag v4.0.0.
//!
//! An `EffectFnN` exists in the JavaScript backend because JS has real N-ary
//! functions and calling one beats walking a chain of N closures. This backend
//! has no N-ary function value -- everything is a one-argument closure -- so an
//! `EffectFnN` is represented as an ordinary curried chain that performs its
//! effect once saturated, with no trailing unit thunk. That single difference
//! is what distinguishes the two families below:
//!
//!   * `mkEffectFnN` takes a curried `a -> ... -> Effect r` and produces the
//!     immediate form, so it forces the Effect: `rt.curry` plus `rt.runEffect`.
//!   * `runEffectFnN` takes the immediate form and produces `a -> ... ->
//!     Effect r`, so it defers: `rt.effect`, whose trailing unit thunk is the
//!     deferral.
//!
//! Because everything is curried anyway, `mkEffectFnN` is just a function of
//! N+1 arguments, and `rt.curry` derives the whole chain from that signature.
//! So this file buys nothing in performance here -- it exists so that code
//! written against the JavaScript backend's idiom still compiles.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;


// -- mkEffectFnN :: (a -> ... -> Effect r) -> EffectFnN a ... r -------------

fn mkEffectFn1(func: Value, a: Value) Error!Value {
    return rt.runEffect(try rt.apply(func, a));
}

pub const @"ps.mkEffectFn1" = rt.effect(mkEffectFn1);

fn mkEffectFn2(func: Value, a: Value, b: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(func, a), b));
}

pub const @"ps.mkEffectFn2" = rt.effect(mkEffectFn2);

fn mkEffectFn3(func: Value, a: Value, b: Value, c: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(func, a), b), c));
}

pub const @"ps.mkEffectFn3" = rt.effect(mkEffectFn3);

fn mkEffectFn4(func: Value, a: Value, b: Value, c: Value, d: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d));
}

pub const @"ps.mkEffectFn4" = rt.effect(mkEffectFn4);

fn mkEffectFn5(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e));
}

pub const @"ps.mkEffectFn5" = rt.effect(mkEffectFn5);

fn mkEffectFn6(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f));
}

pub const @"ps.mkEffectFn6" = rt.effect(mkEffectFn6);

fn mkEffectFn7(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g));
}

pub const @"ps.mkEffectFn7" = rt.effect(mkEffectFn7);

fn mkEffectFn8(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h));
}

pub const @"ps.mkEffectFn8" = rt.effect(mkEffectFn8);

fn mkEffectFn9(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i));
}

pub const @"ps.mkEffectFn9" = rt.effect(mkEffectFn9);

fn mkEffectFn10(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value, j: Value) Error!Value {
    return rt.runEffect(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i), j));
}

pub const @"ps.mkEffectFn10" = rt.effect(mkEffectFn10);


// -- runEffectFnN :: EffectFnN a ... r -> a -> ... -> Effect r ---------------

fn runEffectFn1(func: Value, a: Value) Error!Value {
    return rt.apply(func, a);
}

pub const @"ps.runEffectFn1" = rt.curry(runEffectFn1);

fn runEffectFn2(func: Value, a: Value, b: Value) Error!Value {
    return rt.apply(try rt.apply(func, a), b);
}

pub const @"ps.runEffectFn2" = rt.curry(runEffectFn2);

fn runEffectFn3(func: Value, a: Value, b: Value, c: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(func, a), b), c);
}

pub const @"ps.runEffectFn3" = rt.curry(runEffectFn3);

fn runEffectFn4(func: Value, a: Value, b: Value, c: Value, d: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d);
}

pub const @"ps.runEffectFn4" = rt.curry(runEffectFn4);

fn runEffectFn5(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e);
}

pub const @"ps.runEffectFn5" = rt.curry(runEffectFn5);

fn runEffectFn6(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f);
}

pub const @"ps.runEffectFn6" = rt.curry(runEffectFn6);

fn runEffectFn7(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g);
}

pub const @"ps.runEffectFn7" = rt.curry(runEffectFn7);

fn runEffectFn8(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h);
}

pub const @"ps.runEffectFn8" = rt.curry(runEffectFn8);

fn runEffectFn9(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i);
}

pub const @"ps.runEffectFn9" = rt.curry(runEffectFn9);

fn runEffectFn10(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value, j: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i), j);
}

pub const @"ps.runEffectFn10" = rt.curry(runEffectFn10);
