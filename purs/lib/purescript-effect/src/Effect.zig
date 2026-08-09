//! Zig side of `Effect.purs`, transcribed from `Effect.js` at tag v4.0.0.
//!
//! `Effect a` is a thunk: a closure that ignores a unit argument. That falls
//! out of the one-argument-closure rule and needs no representation of its own
//! -- an Effect is just a `Value` that happens to be a closure. `rt.runEffect`
//! forces one by applying unit.
//!
//! Every function here that runs an inner Effect is fallible, because the
//! Effect it runs may reach `Effect.Exception.throw`.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

// -- pureE :: forall a. a -> Effect a ---------------------------------------
// `rt.effect` supplies the trailing unit thunk, so the body runs on force
// rather than on application -- which is the whole content of `pure` here.

fn pureE(a: Value) Value {
    return a;
}

pub const @"ps.pureE" = rt.effect(pureE);

// -- bindE :: forall a b. Effect a -> (a -> Effect b) -> Effect b ------------
// JS: `f(a())()` -- run `a`, apply `f`, run the result.

fn bindE(a: Value, f: Value) Error!Value {
    return rt.runEffect(try rt.apply(f, try rt.runEffect(a)));
}

pub const @"ps.bindE" = rt.effect(bindE);

// -- untilE :: Effect Boolean -> Effect Unit ---------------------------------
// Repeat until the action returns true. The action is re-run, not re-applied:
// an Effect is a value, and forcing it twice performs it twice.

fn untilE(f: Value) Error!Value {
    while (!(try rt.runEffect(f)).asBool()) {}
    return Value.mkUnit();
}

pub const @"ps.untilE" = rt.effect(untilE);

// -- whileE :: forall a. Effect Boolean -> Effect a -> Effect Unit -----------

fn whileE(cond: Value, act: Value) Error!Value {
    while ((try rt.runEffect(cond)).asBool()) {
        _ = try rt.runEffect(act);
    }
    return Value.mkUnit();
}

pub const @"ps.whileE" = rt.effect(whileE);

// -- forE :: Int -> Int -> (Int -> Effect Unit) -> Effect Unit ---------------
// Half-open, ascending, and does nothing when `hi <= lo`, matching the JS
// `for (var i = lo; i < hi; i++)`.
//
// The counter is i64 rather than i32 deliberately. PureScript's Int is 32-bit
// wrapping and this backend uses `+%` everywhere else, but a wrapping counter
// here would spin forever when `hi` is `top`: the increment past maxInt wraps
// to minInt and the loop condition is true again. JavaScript's Number has no
// such edge, so a wider counter is what actually matches.

fn forE(lo: Value, hi: Value, f: Value) Error!Value {
    var i: i64 = lo.asInt();
    const stop: i64 = hi.asInt();
    while (i < stop) : (i += 1) {
        _ = try rt.runEffect(try rt.apply(f, Value.mkInt(@intCast(i))));
    }
    return Value.mkUnit();
}

pub const @"ps.forE" = rt.effect(forE);

// -- foreachE :: forall a. Array a -> (a -> Effect Unit) -> Effect Unit ------

fn foreachE(as: Value, f: Value) Error!Value {
    for (as.asArray()) |x| {
        _ = try rt.runEffect(try rt.apply(f, x));
    }
    return Value.mkUnit();
}

pub const @"ps.foreachE" = rt.effect(foreachE);
