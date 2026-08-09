//! Lazy initialisation for recursive bindings, as required of any backend
//! whose target language is call-by-value.
//!
//! PureScript allows a recursive `let` group whose members are not functions:
//!
//!     fix f = go
//!       where
//!       go = defer \_ -> f go
//!
//! Under strict evaluation `go` would have to be evaluated while it is being
//! defined. The compiler's answer is a laziness transform, offered to backends
//! as `Language.PureScript.CoreFn.Laziness.applyLazinessTransform` -- but that
//! is a Haskell API available only to backends embedding the compiler as a
//! library, and this one reads `corefn.json` instead. The 0.15.0 release notes
//! spell out the alternative: ensure recursive bindings are lazy, optionally
//! skipping the machinery when every initialiser in the group is an `Abs`.
//! That skip is what the emitter already does; this file is the fallback for
//! when it does not apply.
//!
//! The contract is the compiler's, restated: a three-state cell that runs its
//! initialiser at most once, caches the result, and raises rather than looping
//! if it is re-entered while still initialising. The notes explicitly invite
//! backends to make that error appropriate for the target language, so this
//! panics rather than throwing a catchable PureScript exception -- a cycle here
//! is a defect in the program's definitions, not a condition to recover from.
//!
//! The cell is a `ref` holding a tagged `data`, so it needs no representation
//! outside the existing `Value` union. Transitions replace the whole `Value`
//! rather than mutating in place, which keeps every other variant immutable.

const std = @import("std");
const value = @import("value.zig");
const apply_mod = @import("apply.zig");

const Value = value.Value;
const Error = value.Error;

/// Cell states. Fields differ per state, which is why these are tags rather
/// than a field: `waiting` and `forcing` carry only the diagnostics, `pending`
/// adds the initialiser, and `done` replaces all of it with the value.
const waiting = "Lazy.waiting"; // name, module -- initialiser not yet attached
const pending = "Lazy.pending"; // name, module, init
const forcing = "Lazy.forcing"; // name, module -- currently running
const done = "Lazy.done"; // value

/// A cell that does not yet know how to compute its value.
///
/// Creation is separate from attaching the initialiser because the two are
/// mutually dependent: the initialiser closes over an environment that has to
/// contain the cells, so the cells must exist first.
pub fn newLazy(name: []const u8, module_name: []const u8) Value {
    const cell = apply_mod.alloc().create(Value) catch @panic("runtime: out of memory");
    cell.* = Value.mkData(waiting, apply_mod.copyValues(&.{
        Value.mkString(name),
        Value.mkString(module_name),
    }));
    return Value.mkRef(cell);
}

/// Attach the initialiser, a closure of one ignored argument.
pub fn setLazyInit(cell_value: Value, init: Value) void {
    const cell = cell_value.asRef();
    cell.* = Value.mkData(pending, apply_mod.copyValues(&.{
        cell.*.arg(0),
        cell.*.arg(1),
        init,
    }));
}

/// Read the cell, running the initialiser on first demand.
pub fn forceLazy(cell_value: Value) Error!Value {
    const cell = cell_value.asRef();

    if (cell.*.hasTag(done)) return cell.*.arg(0);
    if (cell.*.hasTag(forcing)) cycle(cell.*);
    if (cell.*.hasTag(waiting)) {
        @panic("runtime: a lazy binding was forced before its initialiser was attached");
    }

    const name = cell.*.arg(0);
    const module_name = cell.*.arg(1);
    const init = cell.*.arg(2);

    // Mark before running, so a self-reference reached through the initialiser
    // lands in the branch above rather than recursing forever.
    cell.* = Value.mkData(forcing, apply_mod.copyValues(&.{ name, module_name }));

    const v = try apply_mod.apply(init, Value.mkUnit());
    cell.* = Value.mkData(done, apply_mod.copyValues(&.{v}));
    return v;
}

/// Built by concatenation rather than `std.fmt`, to keep this off the parts of
/// std that 0.16 reshaped.
fn cycle(cell: Value) noreturn {
    const a = apply_mod.concatString("runtime: ", cell.arg(0).asString());
    const b = apply_mod.concatString(a, " was needed before it finished initializing (module ");
    const c = apply_mod.concatString(b, cell.arg(1).asString());
    @panic(apply_mod.concatString(c, ")"));
}

// --- tests -----------------------------------------------------------------

var init_runs: u32 = 0;

fn constantBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    _ = argument;
    init_runs += 1;
    return Value.mkInt(42);
}

test "a lazy cell runs its initialiser once and caches the result" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    init_runs = 0;
    const cell = newLazy("go", "Test.Module");

    // Creating the cell must not run anything -- that is the whole point.
    try std.testing.expectEqual(@as(u32, 0), init_runs);

    setLazyInit(cell, Value.mkClosure(constantBody, value.no_env));
    try std.testing.expectEqual(@as(u32, 0), init_runs);

    try std.testing.expectEqual(@as(i32, 42), (try forceLazy(cell)).asInt());
    try std.testing.expectEqual(@as(u32, 1), init_runs);

    // Forcing again returns the cached value without re-running.
    try std.testing.expectEqual(@as(i32, 42), (try forceLazy(cell)).asInt());
    try std.testing.expectEqual(@as(u32, 1), init_runs);
}

fn throwingBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    _ = argument;
    return apply_mod.throwValue(Value.mkString("from init"));
}

test "an exception raised by an initialiser propagates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    const cell = newLazy("bad", "Test.Module");
    setLazyInit(cell, Value.mkClosure(throwingBody, value.no_env));

    try std.testing.expectError(error.PsException, forceLazy(cell));
    try std.testing.expectEqualStrings("from init", apply_mod.takeError().asString());
}
