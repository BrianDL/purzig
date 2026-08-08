//! Application, allocation, and process lifecycle.
//!
//! Zig 0.16 made all I/O go through an `Io` instance, and added "juicy main":
//! `pub fn main(init: std.process.Init)` hands you an `Io`, a gpa, and an
//! arena described as "permanent storage for the entire process, cleaned
//! automatically on exit". That arena is exactly the allocation strategy this
//! backend wants -- PureScript is garbage-collected and this backend is not --
//! so the runtime borrows both from `main` rather than building its own.

const std = @import("std");
const value = @import("value.zig");

const Value = value.Value;

var io_inst: ?std.Io = null;
var alloc_inst: ?std.mem.Allocator = null;

/// Called once, at the top of generated `main`, with the `Io` and arena
/// allocator handed over by `std.process.Init`.
///
/// Parameters are suffixed because Zig forbids a parameter from shadowing a
/// container-level declaration, and `io` is the accessor below.
pub fn init(io_value: std.Io, allocator: std.mem.Allocator) void {
    io_inst = io_value;
    alloc_inst = allocator;
}

/// The one allocator generated code and FFI are allowed to use. Never frees;
/// the process arena is reclaimed on exit.
pub fn alloc() std.mem.Allocator {
    return alloc_inst orelse @panic("runtime: alloc() before init()");
}

pub fn io() std.Io {
    return io_inst orelse @panic("runtime: io() before init()");
}

/// Apply a one-argument closure. The hot path of the entire backend.
pub fn apply(f: Value, argument: Value) Value {
    return switch (f) {
        .closure => |c| c.func(c.env, argument),
        else => @panic("runtime: applied a non-function"),
    };
}

pub fn apply2(f: Value, a: Value, b: Value) Value {
    return apply(apply(f, a), b);
}

pub fn apply3(f: Value, a: Value, b: Value, c: Value) Value {
    return apply(apply(apply(f, a), b), c);
}

/// Run an `Effect a`. An Effect is a thunk, which in a one-argument-closure
/// world means a closure that ignores a unit argument.
pub fn runEffect(eff: Value) Value {
    return apply(eff, Value.mkUnit());
}

/// Copy values into the arena. This is how a lambda's captured environment is
/// built: `rt.copyValues(&.{ a, b })`.
pub fn copyValues(items: []const Value) []const Value {
    if (items.len == 0) return value.no_env;
    const out = alloc().alloc(Value, items.len) catch @panic("runtime: out of memory");
    @memcpy(out, items);
    return out;
}

/// Concatenate two strings into the arena. Backs `Semigroup String`.
pub fn concatString(a: []const u8, b: []const u8) []const u8 {
    const out = alloc().alloc(u8, a.len + b.len) catch @panic("runtime: out of memory");
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// Write bytes plus a newline to stdout. Backs `Effect.Console.log`.
pub fn writeLine(bytes: []const u8) void {
    const out = std.Io.File.stdout();
    out.writeStreamingAll(io(), bytes) catch @panic("runtime: write failed");
    out.writeStreamingAll(io(), "\n") catch @panic("runtime: write failed");
}

// --- tests -----------------------------------------------------------------
// These exercise the pure parts only. Anything touching `io()` needs a real
// `Io`, which tests get from `std.testing.io`.

fn incBody(env: []const Value, argument: Value) Value {
    _ = env;
    return Value.mkInt(argument.asInt() + 1);
}

test "apply calls through a closure" {
    init(std.testing.io, std.testing.allocator);
    const inc = Value.mkClosure(incBody, value.no_env);
    try std.testing.expectEqual(@as(i32, 6), apply(inc, Value.mkInt(5)).asInt());
}

fn addFirst(env: []const Value, b: Value) Value {
    return Value.mkInt(env[0].asInt() + b.asInt());
}

fn addTakeFirst(env: []const Value, a: Value) Value {
    _ = env;
    return Value.mkClosure(addFirst, copyValues(&.{a}));
}

test "currying through a captured environment" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());

    const add = Value.mkClosure(addTakeFirst, value.no_env);
    const result = apply2(add, Value.mkInt(2), Value.mkInt(3));
    try std.testing.expectEqual(@as(i32, 5), result.asInt());
}

test "string concatenation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());
    try std.testing.expectEqualStrings("ab", concatString("a", "b"));
}
