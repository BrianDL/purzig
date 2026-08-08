//! Zig side of the `foreign import` declarations in the zig-prelude package.
//!
//! Naming rule: a `foreign import f` in PureScript module `M` of package `P`
//! becomes `ffi.<P with dashes as underscores>.<last segment of M, lowercased>
//! .@"ps.f"`. The generated module for `M` re-exports it under `@"ps.f"`, so
//! generated code never reaches into `ffi` directly.
//!
//! Every foreign value is a `Value`, not a Zig function: generated code applies
//! it through `rt.apply` like anything else. An n-argument PureScript function
//! is n nested one-argument closures, each capturing what came before.

const rt = @import("runtime");
const Value = rt.Value;

// -- concatString :: String -> String -> String ------------------------------

pub const @"ps.concatString" = Value.mkClosure(concatTakeFirst, rt.no_env);

fn concatTakeFirst(env: []const Value, a: Value) Value {
    _ = env;
    return Value.mkClosure(concatTakeSecond, rt.copyValues(&.{a}));
}

fn concatTakeSecond(env: []const Value, b: Value) Value {
    return Value.mkString(rt.concatString(env[0].asString(), b.asString()));
}

// -- log :: String -> Effect Unit --------------------------------------------
//
// Two closures deep for different reasons: the first consumes the String, the
// second is the Effect thunk itself, which only runs when `rt.runEffect`
// applies unit to it. Nothing is written until then.

pub const @"ps.log" = Value.mkClosure(logTakeString, rt.no_env);

fn logTakeString(env: []const Value, msg: Value) Value {
    _ = env;
    return Value.mkClosure(logPerform, rt.copyValues(&.{msg}));
}

fn logPerform(env: []const Value, unit: Value) Value {
    _ = unit;
    rt.writeLine(env[0].asString());
    return Value.mkUnit();
}

// -- pureUnit :: Effect Unit -------------------------------------------------
// The simplest possible Effect, useful as a codegen smoke test.

pub const @"ps.pureUnit" = Value.mkClosure(pureUnitPerform, rt.no_env);

fn pureUnitPerform(env: []const Value, unit: Value) Value {
    _ = env;
    _ = unit;
    return Value.mkUnit();
}
