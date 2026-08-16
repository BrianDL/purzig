//! FFI for Control.Monad.ST.Internal.
//!
//! `ST` and `Effect` are the same thing at runtime -- a thunk forced by
//! `rt.runEffect` -- and an `STRef` is the same `ref` cell an `Effect.Ref` is.
//! The type-level region parameter is erased before emission, so nothing here
//! distinguishes them, and this file is `Effect/Ref.zig` plus the four
//! combinators with a different module name on top.
//!
//! Every one of these is dead code. All eleven are in the optimizer's
//! `coreForeignSemantics`, which is what let the twelve `Control.Monad.ST`
//! entries come out of the driver's `unsupported` list when the effect nodes
//! landed: `ST.new` becomes an `EffectRefNew` node and a read becomes a pointer
//! dereference, with no call into this file. It exists so the module compiles
//! and so the semantics are right if the filter ever changes.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

// -- the monad ---------------------------------------------------------------

fn map_(f: Value, a: Value) Error!Value {
    return rt.apply(f, try rt.runEffect(a));
}

fn pure_(a: Value) Value {
    return a;
}

fn bind_(a: Value, f: Value) Error!Value {
    return rt.runEffect(try rt.apply(f, try rt.runEffect(a)));
}

/// `run` is NOT an effect: it discharges one. `ST r a -> a`, so it forces the
/// thunk immediately and is wrapped with `rt.curry` rather than `rt.effect`.
fn run(f: Value) Error!Value {
    return rt.runEffect(f);
}

// -- loops -------------------------------------------------------------------

fn whileST(f: Value, a: Value) Error!Value {
    while ((try rt.runEffect(f)).asBool()) {
        _ = try rt.runEffect(a);
    }
    return Value.mkUnit();
}

/// The counter is `i64`, not a wrapping `i32`. With `i32` a loop whose `hi` is
/// `top` never terminates, because the increment wraps to `bottom` instead of
/// exceeding the bound -- JavaScript's Number has no such edge, so the original
/// does not guard against it. Same reasoning as `Effect.forE`.
fn forST(lo: Value, hi: Value, f: Value) Error!Value {
    var i: i64 = lo.asInt();
    const limit: i64 = hi.asInt();
    while (i < limit) : (i += 1) {
        _ = try rt.runEffect(try rt.apply(f, Value.mkInt(@intCast(i))));
    }
    return Value.mkUnit();
}

fn foreachST(as: Value, f: Value) Error!Value {
    for (as.asArray()) |x| {
        _ = try rt.runEffect(try rt.apply(f, x));
    }
    return Value.mkUnit();
}

// -- references --------------------------------------------------------------

fn newSTRef(val: Value) Value {
    return rt.newRef(val);
}

fn read(ref: Value) Value {
    return ref.asRef().*;
}

/// `f` returns a `{ state, value }` record: the new contents and what the
/// action yields. `Control.Monad.ST.Ref.modify` is defined in terms of this
/// with both fields the same, so only this one primitive is foreign.
fn modifyImpl(f: Value, ref: Value) Error!Value {
    const cell = ref.asRef();
    const result = try rt.apply(f, cell.*);
    cell.* = result.field("state");
    return result.field("value");
}

/// Returns the written value, because the original is `return ref.value = a`
/// and an assignment expression evaluates to its right-hand side. The
/// PureScript type says `ST r a`, not `ST r Unit`, so this is observable.
fn write(a: Value, ref: Value) Value {
    ref.asRef().* = a;
    return a;
}

pub const @"ps.map_" = rt.effect(map_);
pub const @"ps.pure_" = rt.effect(pure_);
pub const @"ps.bind_" = rt.effect(bind_);
pub const @"ps.run" = rt.curry(run);
pub const @"ps.while" = rt.effect(whileST);
pub const @"ps.for" = rt.effect(forST);
pub const @"ps.foreach" = rt.effect(foreachST);
pub const @"ps.new" = rt.effect(newSTRef);
pub const @"ps.read" = rt.effect(read);
pub const @"ps.modifyImpl" = rt.effect(modifyImpl);
pub const @"ps.write" = rt.effect(write);
