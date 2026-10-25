//! The bytes call path: one `String -> String` function, bytes in, bytes out.
//!
//! A compiled PureScript module exports plain Zig functions over `Value`, which
//! is not a boundary another consumer wants to cross: `Value` is an untyped
//! union with a panicking accessor per shape and no ownership story. `callBytes`
//! is the smallest honest crossing -- a compiled function in, bytes in, a
//! `Reply` out, and an explicit error channel instead of a trap.
//!
//! Deliberately absent: any description of what the bytes MEAN. The layout
//! inside `in` and inside the reply is the consumer's business, so this file has
//! no schema, no registry and no knowledge of any host.
//!
//! ## Memory
//!
//! No allocator is created here. `apply_mod.alloc()` is the one `initAlloc`
//! already stored, which is what keeps this module analysable on a target with
//! no process underneath it (`wasm32-freestanding`): a host that owns the memory
//! binds it once through `initAlloc`, and nothing in this file reaches for an
//! `Io` instance, the console or the panic printer.
//!
//! - `in` is COPIED into that allocator before the callee sees it. The callee is
//!   untyped -- it may keep the string in a ref, a record or a captured
//!   environment -- and `in` may be a temporary in the caller's frame. After the
//!   copy the caller may drop `in` immediately.
//! - Nothing here is ever freed: a reply's `bytes` are valid for the life of the
//!   runtime. They point at the string the callee returned, at a copy of a
//!   thrown string, or at a comptime literal.
//!
//! ## Never a trap
//!
//! Input the callee refuses is a RESULT, not a panic. `invalid` comes from
//! exactly two things, and both leave a reason in `bytes`:
//!
//! 1. the callee raised a PureScript exception (`Effect.Exception.throw`);
//! 2. the callee returned something that is not a `String`.
//!
//! Only an `f` that is not applicable at all -- not a closure -- panics, and it
//! panics inside `rt.apply`: there is no bytes-shaped answer for "you handed me
//! an `Int` instead of a function", and that is a caller bug rather than input a
//! callee can reject.

const std = @import("std");

const value = @import("value.zig");
const apply_mod = @import("apply.zig");

const Value = value.Value;
const Error = value.Error;

/// How a call ended. Never a trap: `invalid` is how the callee -- or the shape
/// of its result -- says "no result", with the reason in `Reply.bytes`.
pub const Status = enum { ok, invalid };

pub const Reply = struct {
    status: Status,
    /// `ok`: the bytes the callee returned. `invalid`: a human-readable reason.
    /// Allocated from the runtime's already-initialised allocator, or a comptime
    /// literal; never freed here, valid for the life of the runtime.
    bytes: []const u8,
};

/// The two reasons that do not come from the callee. Literals rather than
/// formatted text, so reporting a failure can never itself fail for want of
/// memory.
const threw_non_string = "PureScript exception with a non-String value";
const returned_non_string = "PureScript function returned a non-String value";

/// Call `f`, a compiled PureScript function of type `String -> String`, with
/// `in` as its one argument.
///
/// Panics only when `f` is not applicable at all (see the module docs); every
/// other failure is `Status.invalid`.
pub fn callBytes(f: Value, in: []const u8) Reply {
    // Copy first: the callee may keep the argument, and `in` is the caller's.
    const argument = copyOf(in);

    const result = apply_mod.apply(f, Value.mkString(argument)) catch {
        // `apply` fails only with `error.PsException`, which always carries the
        // thrown value in the runtime's side channel. Consuming it here is what
        // keeps a later catch from seeing a stale one.
        return .{ .status = .invalid, .bytes = exceptionBytes(apply_mod.takeError()) };
    };

    return switch (result) {
        .string => |s| .{ .status = .ok, .bytes = s },
        else => .{ .status = .invalid, .bytes = returned_non_string },
    };
}

/// A thrown `String` is the callee's own reason, so report it verbatim -- copied
/// into the runtime allocator, so an `invalid` reply obeys the same lifetime
/// rule as an `ok` one. Anything else has no bytes to report, so say that
/// instead of inventing a rendering for arbitrary `Value`s.
fn exceptionBytes(err: Value) []const u8 {
    return switch (err) {
        .string => |s| copyOf(s),
        else => threw_non_string,
    };
}

/// Copy bytes into the runtime's allocator. The only allocation this file
/// makes, and the reason a reply outlives the call: everything returned points
/// at memory the runtime owns.
fn copyOf(bytes: []const u8) []const u8 {
    const out = apply_mod.alloc().dupe(u8, bytes) catch
        @panic("runtime: out of memory");
    return out;
}

// --- tests -----------------------------------------------------------------
// No PureScript needed: a closure built with the runtime's own constructors
// stands in for a compiled `String -> String`. The allocator is a fixed buffer,
// so a test leaks nothing it has to clean up -- the runtime never frees, by
// design -- and nothing here needs a process or an `Io`.

fn echoBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    return argument;
}

fn constBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    _ = argument;
    return Value.mkString("hi!");
}

fn intBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    _ = argument;
    return Value.mkInt(0);
}

fn throwStringBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    _ = argument;
    return apply_mod.throwValue(Value.mkString("rejected"));
}

fn throwIntBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    _ = argument;
    return apply_mod.throwValue(Value.mkInt(7));
}

test "callBytes answers ok with the bytes the callee returned" {
    var buffer: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    const reply = callBytes(Value.mkClosure(echoBody, value.no_env), "hello");
    try std.testing.expectEqual(Status.ok, reply.status);
    try std.testing.expectEqualStrings("hello", reply.bytes);

    // A callee that ignores its argument still answers ok: the shape of the
    // reply depends on the result, not on the input.
    const fixed = callBytes(Value.mkClosure(constBody, value.no_env), "");
    try std.testing.expectEqual(Status.ok, fixed.status);
    try std.testing.expectEqualStrings("hi!", fixed.bytes);
}

test "callBytes answers invalid when the callee throws" {
    var buffer: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    // A thrown String is reported verbatim.
    const thrown = callBytes(Value.mkClosure(throwStringBody, value.no_env), "in");
    try std.testing.expectEqual(Status.invalid, thrown.status);
    try std.testing.expectEqualStrings("rejected", thrown.bytes);

    // A thrown non-String still answers invalid, with a fixed reason.
    const other = callBytes(Value.mkClosure(throwIntBody, value.no_env), "in");
    try std.testing.expectEqual(Status.invalid, other.status);
    try std.testing.expectEqualStrings(threw_non_string, other.bytes);
}

test "callBytes answers invalid when the callee returns a non-String" {
    var buffer: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    const reply = callBytes(Value.mkClosure(intBody, value.no_env), "in");
    try std.testing.expectEqual(Status.invalid, reply.status);
    try std.testing.expectEqualStrings(returned_non_string, reply.bytes);
}

test "callBytes copies its input, so the caller may drop it" {
    var buffer: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    var input = [_]u8{ 'a', 'b', 'c' };
    const reply = callBytes(Value.mkClosure(echoBody, value.no_env), &input);
    @memset(&input, 'z');

    // The echo read its own copy, not the buffer we just scribbled on.
    try std.testing.expectEqual(Status.ok, reply.status);
    try std.testing.expectEqualStrings("abc", reply.bytes);
}
