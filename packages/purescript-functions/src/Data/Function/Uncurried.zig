//! Zig side of `Data/Function/Uncurried.purs`, transcribed from
//! `Data/Function/Uncurried.js` at tag v6.0.0.
//!
//! Compare `Effect/Uncurried.zig`, which this mirrors. There, `mkEffectFnN` and
//! `runEffectFnN` differ: an `EffectFnN` performs on saturation while
//! `a -> ... -> Effect r` waits for a unit thunk, so one forces and the other
//! defers. Here there is no such distinction. `Fn2 a b r` and `a -> b -> r` are
//! both just curried chains in this runtime, so `mkFnN` and `runFnN` have
//! identical bodies -- each is `func` applied to its arguments in turn.
//!
//! Every one of these is dead code. All twenty are in the optimizer's
//! `coreForeignSemantics`, so `runFn3 f a b c` is rewritten into an
//! `UncurriedApp` and emitted as nested `rt.apply` calls long before anything
//! could reach this file. It exists so the module compiles when something
//! imports it, and so the FFI is correct if the filter ever changes.
//!
//! There is no `Fn1`: a one-argument uncurried function is just a function.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;


// -- mkFnN :: (a -> ... -> r) -> FnN a ... r --------------------------------
//
// `Fn0 a` is represented as a closure over one ignored argument, matching how
// the emitter lowers a nullary `UncurriedAbs`, so applying unit runs it.

fn mkFn0(func: Value, unit_arg: Value) Error!Value {
    return rt.apply(func, unit_arg);
}

pub const @"ps.mkFn0" = rt.curry(mkFn0);

fn mkFn2(func: Value, a: Value, b: Value) Error!Value {
    return rt.apply(try rt.apply(func, a), b);
}

pub const @"ps.mkFn2" = rt.curry(mkFn2);

fn mkFn3(func: Value, a: Value, b: Value, c: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(func, a), b), c);
}

pub const @"ps.mkFn3" = rt.curry(mkFn3);

fn mkFn4(func: Value, a: Value, b: Value, c: Value, d: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d);
}

pub const @"ps.mkFn4" = rt.curry(mkFn4);

fn mkFn5(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e);
}

pub const @"ps.mkFn5" = rt.curry(mkFn5);

fn mkFn6(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f);
}

pub const @"ps.mkFn6" = rt.curry(mkFn6);

fn mkFn7(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g);
}

pub const @"ps.mkFn7" = rt.curry(mkFn7);

fn mkFn8(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h);
}

pub const @"ps.mkFn8" = rt.curry(mkFn8);

fn mkFn9(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i);
}

pub const @"ps.mkFn9" = rt.curry(mkFn9);

fn mkFn10(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value, j: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i), j);
}

pub const @"ps.mkFn10" = rt.curry(mkFn10);


// -- runFnN :: FnN a ... r -> a -> ... -> r ---------------------------------

fn runFn0(func: Value) Error!Value {
    return rt.apply(func, Value.mkUnit());
}

pub const @"ps.runFn0" = rt.curry(runFn0);

fn runFn2(func: Value, a: Value, b: Value) Error!Value {
    return rt.apply(try rt.apply(func, a), b);
}

pub const @"ps.runFn2" = rt.curry(runFn2);

fn runFn3(func: Value, a: Value, b: Value, c: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(func, a), b), c);
}

pub const @"ps.runFn3" = rt.curry(runFn3);

fn runFn4(func: Value, a: Value, b: Value, c: Value, d: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d);
}

pub const @"ps.runFn4" = rt.curry(runFn4);

fn runFn5(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e);
}

pub const @"ps.runFn5" = rt.curry(runFn5);

fn runFn6(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f);
}

pub const @"ps.runFn6" = rt.curry(runFn6);

fn runFn7(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g);
}

pub const @"ps.runFn7" = rt.curry(runFn7);

fn runFn8(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h);
}

pub const @"ps.runFn8" = rt.curry(runFn8);

fn runFn9(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i);
}

pub const @"ps.runFn9" = rt.curry(runFn9);

fn runFn10(func: Value, a: Value, b: Value, c: Value, d: Value, e: Value, f: Value, g: Value, h: Value, i: Value, j: Value) Error!Value {
    return rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(try rt.apply(func, a), b), c), d), e), f), g), h), i), j);
}

pub const @"ps.runFn10" = rt.curry(runFn10);
