//! Comptime currying, so FFI authors write ordinary Zig functions.
//!
//! Every PureScript function is a chain of one-argument closures, which is
//! painful to write by hand: an n-argument foreign import needs n functions
//! plus hand-managed `env` indices that the compiler cannot check. These
//! helpers generate that chain from the function's own signature.
//!
//! purerl solves the same problem by parsing arity out of the Erlang export
//! list, because Erlang gives it no other option. Zig has comptime reflection,
//! so the backend never has to learn about arity at all -- it still emits
//! `pub const @"ps.f" = <whatever the FFI file exports>`.

const std = @import("std");
const value = @import("value.zig");
const apply_mod = @import("apply.zig");

const Value = value.Value;

/// A pure foreign function: `fn (Value, Value) Value` becomes two nested
/// closures.
///
///     fn add(a: Value, b: Value) Value { ... }
///     pub const @"ps.add" = rt.curry(add);
pub fn curry(comptime f: anytype) Value {
    return chain(f, false);
}

/// An effectful foreign function. `Effect a` is a thunk, so this is `curry`
/// plus one extra closure that swallows the unit argument -- nothing runs
/// until `rt.runEffect` applies it.
///
///     fn printHello() Value { ... }             // Effect Unit
///     fn greet(a: Value, b: Value) Value { ... } // String -> String -> Effect Unit
///     pub const @"ps.printHello" = rt.effect(printHello);
///     pub const @"ps.greet" = rt.effect(greet);
pub fn effect(comptime f: anytype) Value {
    return chain(f, true);
}

fn chain(comptime f: anytype, comptime is_effect: bool) Value {
    const info = @typeInfo(@TypeOf(f));
    if (info != .@"fn") @compileError("curry/effect expect a function");

    const arity = info.@"fn".params.len;
    const levels = arity + @as(usize, if (is_effect) 1 else 0);
    if (levels == 0) {
        @compileError("a pure foreign function needs at least one parameter");
    }
    return Step(f, 0, levels, arity).mk(value.no_env);
}

/// One link in the closure chain. Level `i` holds the first `i` arguments in
/// its environment; the last level spreads them into a real call.
fn Step(
    comptime f: anytype,
    comptime i: usize,
    comptime levels: usize,
    comptime arity: usize,
) type {
    return struct {
        fn mk(env: []const Value) Value {
            return Value.mkClosure(run, env);
        }

        fn run(env: []const Value, arg: Value) value.Error!Value {
            // A nullary effect uses neither; the branch below is comptime-dead.
            // if (comptime arity == 0) {
            //     _ = env;
            //     _ = arg;
            // }

            if (comptime i + 1 < levels) {
                var buf: [i + 1]Value = undefined;
                inline for (0..i) |j| buf[j] = env[j];
                buf[i] = arg;
                return Step(f, i + 1, levels, arity).mk(apply_mod.copyValues(&buf));
            }

            // Final level. For an effect the incoming `arg` is the unit the
            // thunk was forced with, and is discarded: `j < i` is false only
            // for the genuine last argument of a pure function.
            //
            // No `try` and no comptime branch on `f`'s return type: Zig coerces
            // `Value` to `Error!Value`, so this one call site accepts both a
            // plain FFI function and one that can throw. Only the handful of
            // foreign imports that actually raise need `Error!Value` in their
            // own signature.
            var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
            inline for (0..arity) |j| {
                args[j] = if (comptime j < i) env[j] else arg;
            }
            return @call(.auto, f, args);
        }
    };
}

// --- tests -----------------------------------------------------------------

fn add(a: Value, b: Value) Value {
    return Value.mkInt(a.asInt() +% b.asInt());
}

fn negate(a: Value) Value {
    return Value.mkInt(-a.asInt());
}

fn three(a: Value, b: Value, c: Value) Value {
    return Value.mkInt(a.asInt() +% b.asInt() +% c.asInt());
}

test "curry over arity 1" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    const f = curry(negate);
    try std.testing.expectEqual(@as(i32, -5), (try apply_mod.apply(f, Value.mkInt(5))).asInt());
}

test "curry over arity 2, applied one argument at a time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    const f = curry(add);
    const partial = try apply_mod.apply(f, Value.mkInt(2));

    // A partial application is reusable: currying must not mutate shared state.
    try std.testing.expectEqual(@as(i32, 5), (try apply_mod.apply(partial, Value.mkInt(3))).asInt());
    try std.testing.expectEqual(@as(i32, 12), (try apply_mod.apply(partial, Value.mkInt(10))).asInt());
}

test "curry over arity 3 keeps argument order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    const f = curry(three);
    const r = try apply_mod.apply3(f, Value.mkInt(100), Value.mkInt(20), Value.mkInt(3));
    try std.testing.expectEqual(@as(i32, 123), r.asInt());
}

var effect_runs: u32 = 0;

fn bumpCounter() Value {
    effect_runs += 1;
    return Value.mkUnit();
}

test "a nullary effect does not run until forced" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    effect_runs = 0;
    const eff = effect(bumpCounter);
    try std.testing.expectEqual(@as(u32, 0), effect_runs);

    _ = try apply_mod.runEffect(eff);
    try std.testing.expectEqual(@as(u32, 1), effect_runs);

    // Effects are values: running twice runs the body twice.
    _ = try apply_mod.runEffect(eff);
    try std.testing.expectEqual(@as(u32, 2), effect_runs);
}

var last_sum: i32 = 0;

fn recordSum(a: Value, b: Value) Value {
    last_sum = a.asInt() +% b.asInt();
    return Value.mkUnit();
}

test "an effect of arity 2 waits for the unit argument" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    last_sum = 0;
    const eff = effect(recordSum);

    // Both arguments supplied, but this is still an unforced Effect.
    const saturated = try apply_mod.apply2(eff, Value.mkInt(40), Value.mkInt(2));
    try std.testing.expectEqual(@as(i32, 0), last_sum);

    _ = try apply_mod.runEffect(saturated);
    try std.testing.expectEqual(@as(i32, 42), last_sum);
}
