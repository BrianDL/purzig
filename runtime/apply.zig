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
const Field = value.Field;
const Error = value.Error;

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
///
/// Fallible: any application may reach `Effect.Exception.throw`. Applying a
/// non-function stays a panic, because that is a backend bug rather than
/// something a PureScript program can express.
pub fn apply(f: Value, argument: Value) Error!Value {
    return switch (f) {
        .closure => |c| c.func(c.env, argument),
        else => @panic("runtime: applied a non-function"),
    };
}

pub fn apply2(f: Value, a: Value, b: Value) Error!Value {
    return apply(try apply(f, a), b);
}

pub fn apply3(f: Value, a: Value, b: Value, c: Value) Error!Value {
    return apply(try apply(try apply(f, a), b), c);
}

/// Run an `Effect a`. An Effect is a thunk, which in a one-argument-closure
/// world means a closure that ignores a unit argument.
pub fn runEffect(eff: Value) Error!Value {
    return apply(eff, Value.mkUnit());
}

// --- exceptions ------------------------------------------------------------

/// The value belonging to the `error.PsException` currently in flight.
///
/// A side channel because Zig error values are bare tags and cannot carry a
/// payload. Single-threaded and arena-backed, so there is no ownership question
/// -- the slot holds a `Value` like any other.
var pending_error: ?Value = null;

/// Raise a PureScript exception. Backs `Effect.Exception.throwException`.
///
/// Returns the error rather than taking it, so a caller writes
/// `return rt.throwValue(e)` and Zig's own checking guarantees the stash and
/// the raise cannot get out of step.
pub fn throwValue(err: Value) Error {
    pending_error = err;
    return error.PsException;
}

/// Retrieve the in-flight exception value and clear the slot. Backs
/// `Effect.Exception.catchException`; call exactly once per caught error.
pub fn takeError() Value {
    const err = pending_error orelse
        @panic("runtime: caught PsException with no value in flight");
    pending_error = null;
    return err;
}

// --- references ------------------------------------------------------------

/// Allocate a mutable cell in the arena. Backs `Effect.Ref.new`.
///
/// `newWithSelf` does not go through here: it needs to publish the reference
/// before computing the contents, so it allocates and calls `Value.mkRef`
/// itself.
pub fn newRef(initial: Value) Value {
    const cell = alloc().create(Value) catch @panic("runtime: out of memory");
    cell.* = initial;
    return Value.mkRef(cell);
}

/// Copy values into the arena. This is how a lambda's captured environment is
/// built: `rt.copyValues(&.{ a, b })`.
pub fn copyValues(items: []const Value) []const Value {
    if (items.len == 0) return value.no_env;
    const out = alloc().alloc(Value, items.len) catch @panic("runtime: out of memory");
    @memcpy(out, items);
    return out;
}

/// Copy record fields into the arena. The emitter's field slices are struct
/// literals -- field NAMES are comptime-known, but the VALUES are not, so
/// `&.{ ... }` points at a temporary in the enclosing stack frame. Anything
/// storing that slice in a returned Value must copy it first.
pub fn copyFields(fields: []const Field) []const Field {
    if (fields.len == 0) return &.{};
    const out = alloc().alloc(Field, fields.len) catch @panic("runtime: out of memory");
    @memcpy(out, fields);
    return out;
}

/// CoreFn `ObjectUpdate`: a fresh record with some fields replaced.
///
/// Copy-on-write over the field slice, preserving the base record's field
/// order. PureScript's record update syntax is type-checked, so every update
/// key must already exist in the base -- a miss is a backend bug, and panics
/// like the accessors do rather than silently adding or dropping a field.
///
/// Quadratic in field count, which is fine: records are small, and the inner
/// loop is over the updates, which are usually one.
pub fn updateRecord(base: Value, updates: []const Field) Value {
    const fields = base.asRecord();
    const out = alloc().alloc(Field, fields.len) catch @panic("runtime: out of memory");

    var matched: usize = 0;
    for (fields, out) |f, *slot| {
        slot.* = f;
        for (updates) |u| {
            if (std.mem.eql(u8, u.name, f.name)) {
                slot.* = u;
                matched += 1;
                break;
            }
        }
    }
    if (matched != updates.len) @panic("runtime: record update names a field the record does not have");

    return Value.mkRecord(out);
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

/// Write bytes plus a newline to stderr. Backs `Effect.Console.warn` and
/// `Effect.Console.error`, which go to stderr in Node exactly as they do here.
pub fn writeLineErr(bytes: []const u8) void {
    const out = std.Io.File.stderr();
    out.writeStreamingAll(io(), bytes) catch @panic("runtime: write failed");
    out.writeStreamingAll(io(), "\n") catch @panic("runtime: write failed");
}

// --- tests -----------------------------------------------------------------
// These exercise the pure parts only. Anything touching `io()` needs a real
// `Io`, which tests get from `std.testing.io`.

fn incBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    return Value.mkInt(argument.asInt() + 1);
}

test "apply calls through a closure" {
    init(std.testing.io, std.testing.allocator);
    const inc = Value.mkClosure(incBody, value.no_env);
    try std.testing.expectEqual(@as(i32, 6), (try apply(inc, Value.mkInt(5))).asInt());
}

fn addFirst(env: []const Value, b: Value) Error!Value {
    return Value.mkInt(env[0].asInt() + b.asInt());
}

fn addTakeFirst(env: []const Value, a: Value) Error!Value {
    _ = env;
    return Value.mkClosure(addFirst, copyValues(&.{a}));
}

test "currying through a captured environment" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());

    const add = Value.mkClosure(addTakeFirst, value.no_env);
    const result = try apply2(add, Value.mkInt(2), Value.mkInt(3));
    try std.testing.expectEqual(@as(i32, 5), result.asInt());
}

fn throwBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    return throwValue(argument);
}

test "a thrown value propagates and is recoverable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());

    const thrower = Value.mkClosure(throwBody, value.no_env);
    const result = apply(thrower, Value.mkString("boom"));
    try std.testing.expectError(error.PsException, result);
    try std.testing.expectEqualStrings("boom", takeError().asString());
}

test "a throw propagates through nested application" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());

    // apply2 must not swallow an error raised by the inner application.
    const thrower = Value.mkClosure(throwBody, value.no_env);
    try std.testing.expectError(
        error.PsException,
        apply2(thrower, Value.mkString("inner"), Value.mkUnit()),
    );
    try std.testing.expectEqualStrings("inner", takeError().asString());
}

test "a ref is mutable through every copy of the reference" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());

    const r = newRef(Value.mkInt(1));
    const alias = r;
    r.asRef().* = Value.mkInt(2);
    try std.testing.expectEqual(@as(i32, 2), alias.asRef().*.asInt());
}

test "string concatenation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());
    try std.testing.expectEqualStrings("ab", concatString("a", "b"));
}

test "copyFields survives its source going out of scope" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());

    const rec = blk: {
        // A stack temporary, exactly like the emitter's `&.{ ... }`.
        const literal = [_]Field{.{ .name = "x", .value = Value.mkInt(1) }};
        break :blk Value.mkRecord(copyFields(&literal));
    };
    try std.testing.expectEqual(@as(i32, 1), rec.field("x").asInt());
    try std.testing.expectEqual(@as(usize, 0), copyFields(&.{}).len);
}

test "updateRecord overrides in place and leaves the base alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    init(std.testing.io, arena.allocator());

    const base = Value.mkRecord(&[_]Field{
        .{ .name = "x", .value = Value.mkInt(1) },
        .{ .name = "y", .value = Value.mkInt(2) },
        .{ .name = "z", .value = Value.mkInt(3) },
    });
    const updated = updateRecord(base, &.{.{ .name = "y", .value = Value.mkInt(20) }});

    try std.testing.expectEqual(@as(i32, 1), updated.field("x").asInt());
    try std.testing.expectEqual(@as(i32, 20), updated.field("y").asInt());
    try std.testing.expectEqual(@as(i32, 3), updated.field("z").asInt());
    try std.testing.expectEqual(@as(i32, 2), base.field("y").asInt());

    // Field order is the base's, not the update's.
    try std.testing.expectEqualStrings("y", updated.asRecord()[1].name);
}
