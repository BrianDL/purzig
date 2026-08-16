//! Mutable arrays, backing `Data.Array.ST`'s `STArray`.
//!
//! A separate file for the same reason `lazy.zig` is one: it is a small,
//! self-contained piece of state with an invariant worth stating in one place,
//! rather than another handful of functions in `apply.zig`.
//!
//! The public surface is deliberately one function. Everything else an
//! `STArray` needs -- append, poke, pop, sort -- is an operation on
//! `std.ArrayList(Value)` that `Data/Array/ST.zig` performs directly through
//! `Value.asMutArray()`, because hand-written FFI may import `std` and may
//! allocate from `rt.alloc()`. Wrapping each of those in a runtime function
//! would widen the surface generated code is allowed to see for no benefit:
//! generated code never touches an `STArray` at all, since `Data.Array.ST` is
//! reached only through its FFI.

const std = @import("std");

const value = @import("value.zig");
const apply_mod = @import("apply.zig");

const Value = value.Value;

/// A new `STArray` holding a copy of `items`.
///
/// The list header itself is allocated in the arena rather than living in the
/// caller's frame: the `Value` holds a pointer to it and outlives whatever
/// created it. `items` is copied, so callers may pass a slice they still own --
/// which is what makes `thaw` a one-liner.
pub fn newMutArray(items: []const Value) Value {
    const gpa = apply_mod.alloc();

    const cell = gpa.create(std.ArrayList(Value)) catch @panic("runtime: out of memory");
    cell.* = .empty;
    cell.appendSlice(gpa, items) catch @panic("runtime: out of memory");

    return Value.mkMutArray(cell);
}

test "newMutArray copies its input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    var source = [_]Value{ Value.mkInt(1), Value.mkInt(2) };
    const arr = newMutArray(&source);

    // Mutating the source must not be visible through the STArray.
    source[0] = Value.mkInt(99);
    try std.testing.expectEqual(@as(i32, 1), arr.asMutArray().items[0].asInt());
    try std.testing.expectEqual(@as(usize, 2), arr.asMutArray().items.len);
}

test "an empty mutable array can grow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    apply_mod.init(std.testing.io, arena.allocator());

    const arr = newMutArray(&.{});
    try std.testing.expectEqual(@as(usize, 0), arr.asMutArray().items.len);

    try arr.asMutArray().append(apply_mod.alloc(), Value.mkInt(7));
    try std.testing.expectEqual(@as(i32, 7), arr.asMutArray().items[0].asInt());
}
