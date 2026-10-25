//! The bytes call path: compiled PureScript functions, bytes in, bytes out.
//!
//! A compiled PureScript module exports plain Zig functions over `Value`, which
//! is not a boundary another consumer wants to cross: `Value` is an untyped
//! union with a panicking accessor per shape and no ownership story. `call` is
//! the smallest honest crossing -- a compiled function in, k byte slices in, a
//! `Reply` out, and an explicit transport status instead of a trap.
//!
//! Deliberately absent: any description of what the bytes MEAN. The layout
//! inside each input and inside the reply is the consumer's business, so this
//! file has no schema, no registry and no knowledge of any host.
//!
//! ## Status is transport, never application meaning
//!
//! `Status.ok` says only that the call crossed: the callee returned a `String`
//! and `Reply.bytes` is it. `Status.error` says the call did not cross: the
//! callee raised, or it returned something that is not a `String`. Neither
//! status says anything about what the bytes SAY -- a reply of `"no"` is `ok`,
//! and an error reason is not an error code. Whatever a consumer wants its
//! payload to mean, it decides on its side of the boundary. purzig does not
//! know what "valid" is.
//!
//! ## Memory
//!
//! No allocator is created here. `apply_mod.alloc()` is the one `initAlloc`
//! already stored, which is what keeps this module analysable on a target with
//! no process underneath it (`wasm32-freestanding`): a host that owns the memory
//! binds it once through `initAlloc`, and nothing in this file reaches for an
//! `Io` instance, the console or the panic printer.
//!
//! - each element of `ins` is COPIED into that allocator before the callee sees
//!   it. The callee is untyped -- it may keep the string in a ref, a record or a
//!   captured environment -- and an element may be a temporary in the caller's
//!   frame. After the copy the caller may drop every element immediately.
//! - `out.buf` is the caller's: written, never freed, never retained.
//! - Nothing else here is ever freed: a reply's `bytes` are valid for the life
//!   of the runtime. They point at the string the callee returned, at a copy of
//!   a thrown string, or at a comptime literal.
//!
//! ## Never a trap for callee-refused input
//!
//! Input the callee refuses is a RESULT, not a panic. `error` comes from exactly
//! two things, and both leave a reason in `bytes`:
//!
//! 1. the callee raised a PureScript exception (`Effect.Exception.throw`);
//! 2. the callee returned something that is not a `String`.
//!
//! An `f` that is not applicable with `ins.len` arguments -- an `Int`, or a
//! two-argument function applied once -- panics inside `rt.apply`. That is a
//! caller bug in the Zig program linking this module, not input a callee can
//! reject, so there is no bytes-shaped answer to give. So does an `out.buf` too
//! small for the result: sizes are the caller's business here, and the reply is
//! never silently truncated.

const std = @import("std");

const value = @import("value.zig");
const apply_mod = @import("apply.zig");

const Value = value.Value;
const Error = value.Error;

/// How a call crossed. Transport only: `ok` means the callee produced a
/// `String`, `error` means it did not. Neither says what the bytes MEAN.
pub const Status = enum { ok, error };

/// Where a successful call's bytes go: a caller-owned buffer and the length
/// actually written, so `out.buf[0..out.len]` is the result.
///
/// An out-sink rather than a returned slice because a consumer that owns its
/// own buffer (a wasm host's linear memory, a C struct field) should not have to
/// receive memory it can neither free nor size. The runtime still allocates for
/// its own uses; it just does not hand the result out that way.
pub const Reader = struct { buf: []u8, len: usize = 0 };

/// The bytes of `reply`: the buffer when `ok`, the reason when `error`.
/// The one place a caller should ask, so a status check cannot be forgotten.
pub fn bytes(reply: Reply, out: *const Reader) []const u8 {
    return switch (reply.status) {
        .ok => out.buf[0..out.len],
        .error => reply.bytes,
    };
}

pub const Reply = struct {
    status: Status,
    /// `ok`: empty -- the bytes are in the `Reader` that was passed in.
    /// `error`: a human-readable reason, allocated from the runtime's
    /// already-initialised allocator or a comptime literal; never freed here,
    /// valid for the life of the runtime.
    bytes: []const u8,
};

/// The two reasons that do not come from the callee. Literals rather than
/// formatted text, so reporting a failure can never itself fail for want of
/// memory.
const threw_non_string = "PureScript exception with a non-String value";
const returned_non_string = "PureScript function returned a non-String value";

/// Apply `f` to `ins` IN ORDER, then read the result with `out`.
///
/// Each element is one argument: `ins.len` is the arity, applied left to right
/// through `rt.apply`, so this is exactly the nested-`apply` chain the
/// generated code writes for an application node.
///
/// - `ins.len == 0`: `f` is used as the result (`f` is then a `String`, e.g. a
///   `String`-valued definition such as a top-level constant);
/// - `ins.len == 1`: `f` is applied once;
/// - `ins.len == k`: `f` is applied k times, in order.
///
/// A successful result is written into `out.buf` and `out.len` is set. A result
/// longer than `out.buf` panics -- see the module docs.
///
/// Panics only when `f` is not applicable with `ins.len` arguments, or when
/// `out.buf` cannot hold the result; every other failure is `Status.error`.
pub fn call(f: Value, ins: []const []const u8, out: *Reader) Reply {
    var current = f;

    for (ins) |in| {
        // Copy first: the callee may keep the argument, and `in` is the
        // caller's -- possibly a temporary that dies at the end of this loop.
        const argument = copyOf(in);

        current = apply_mod.apply(current, Value.mkString(argument)) catch {
            // `apply` fails only with `error.PsException`, which always carries
            // the thrown value in the runtime's side channel. Consuming it here
            // is what keeps a later catch from seeing a stale one.
            return .{ .status = .error, .bytes = exceptionBytes(apply_mod.takeError()) };
        };
    }

    return switch (current) {
        .string => |s| {
            if (out.buf.len < s.len) @panic("runtime: abi.Reader too small for the reply");
            @memcpy(out.buf[0..s.len], s);
            out.len = s.len;
            return .{ .status = .ok, .bytes = "" };
        },
        else => .{ .status = .error, .bytes = returned_non_string },
    };
}

/// Call `f`, a one-argument compiled PureScript function, with `in` as its one
/// argument. A thin wrapper over `call`, kept so existing callers compile and
/// read unchanged.
pub fn callBytes(f: Value, in: []const u8) Reply {
    // Sized to `in` is wrong in general (the reply may be longer), so the
    // wrapper gives one ample buffer rather than a growing one: a one-argument
    // call's reply is bounded by what the callee builds, and 64 KiB per call is
    // cheaper than a reallocating out-sink for callers that only want a slice.
    const buf = apply_mod.alloc().alloc(u8, callBytes_buffer) catch
        @panic("runtime: out of memory");
    var out: Reader = .{ .buf = buf };
    const reply = call(f, &.{in}, &out);
    if (reply.status == .error) return reply;
    // Re-point at the runtime's copy so the returned slice outlives `buf`'s
    // role as a plain buffer: `ok` always answers with allocated bytes here.
    return .{ .status = .ok, .bytes = copyOf(out.buf[0..out.len]) };
}

/// The buffer `callBytes` hands to `call`. Not a promise about the callee: a
/// longer reply panics, which is why new code should size its own `Reader`.
const callBytes_buffer = 64 * 1024;

/// A thrown `String` is the callee's own reason, so report it verbatim -- copied
/// into the runtime allocator, so an `error` reply obeys the same lifetime rule
/// as an `ok` one. Anything else has no bytes to report, so say that instead of
/// inventing a rendering for arbitrary `Value`s.
fn exceptionBytes(err: Value) []const u8 {
    return switch (err) {
        .string => |s| copyOf(s),
        else => threw_non_string,
    };
}

/// Copy bytes into the runtime's allocator. The only allocation this file
/// makes besides `callBytes`'s fixed buffer.
fn copyOf(bytes: []const u8) []const u8 {
    const out = apply_mod.alloc().dupe(u8, bytes) catch
        @panic("runtime: out of memory");
    return out;
}

// --- tests -----------------------------------------------------------------
// No PureScript needed: a closure built with the runtime's own constructors
// stands in for a compiled function. The allocator is a fixed buffer, so a test
// leaks nothing it has to clean up -- the runtime never frees, by design -- and
// nothing here needs a process or an `Io`.
//
// Each test installs its own `FixedBufferAllocator` through
// `apply_mod.initAlloc` rather than sharing a helper, because `fba` must outlive
// the allocator it hands out: a helper returning it by value would leave the
// installed allocator pointing at a dead stack frame.

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

/// `\a -> \b -> a <> b`, i.e. `pair a b = a <> b`. Two applications, so it
/// exercises `ins.len == 2` and the ORDER of application.
fn pairBody(env: []const Value, first: Value) Error!Value {
    _ = env;
    const captured = Value.mkClosure(pairSecond, apply_mod.copyValues(&.{first}));
    return captured;
}

fn pairSecond(env: []const Value, second: Value) Error!Value {
    return Value.mkString(apply_mod.concatString(env[0].asString(), second.asString()));
}

/// A closure that records the address and bytes of its argument, so a test can
/// prove the callee saw a COPY rather than the caller's buffer.
var seen: []const u8 = &.{};

fn recordBody(env: []const Value, argument: Value) Error!Value {
    _ = env;
    seen = argument.asString();
    return argument;
}


test "call answers ok: one argument, two arguments, zero arguments" {
    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    var out_buf: [256]u8 = undefined;

    // 1 argument: applied once.
    var one: Reader = .{ .buf = &out_buf };
    const single = call(Value.mkClosure(echoBody, value.no_env), &.{"hello"}, &one);
    try std.testing.expectEqual(Status.ok, single.status);
    try std.testing.expectEqualStrings("hello", bytes(single, &one));

    // 2 arguments: applied left to right, so ORDER is visible in the result.
    var two: Reader = .{ .buf = &out_buf };
    const paired = call(Value.mkClosure(pairBody, value.no_env), &.{ "ab", "cd" }, &two);
    try std.testing.expectEqual(Status.ok, paired.status);
    try std.testing.expectEqualStrings("abcd", bytes(paired, &two));

    // 0 arguments: `f` IS the result, e.g. a `String`-valued constant. No
    // `apply` happens, so nothing can be non-applicable.
    var zero: Reader = .{ .buf = &out_buf };
    const constant = call(Value.mkString("hi!"), &.{}, &zero);
    try std.testing.expectEqual(Status.ok, constant.status);
    try std.testing.expectEqualStrings("hi!", bytes(constant, &zero));
}

test "call answers error when the callee throws" {
    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    var out_buf: [256]u8 = undefined;

    // A thrown String is reported verbatim.
    var one: Reader = .{ .buf = &out_buf };
    const thrown = call(Value.mkClosure(throwStringBody, value.no_env), &.{"in"}, &one);
    try std.testing.expectEqual(Status.error, thrown.status);
    try std.testing.expectEqualStrings("rejected", thrown.bytes);

    // A thrown non-String still answers error, with a fixed reason.
    var two: Reader = .{ .buf = &out_buf };
    const other = call(Value.mkClosure(throwIntBody, value.no_env), &.{"in"}, &two);
    try std.testing.expectEqual(Status.error, other.status);
    try std.testing.expectEqualStrings(threw_non_string, other.bytes);
}

test "call answers error when the callee returns a non-String" {
    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    var out_buf: [256]u8 = undefined;
    var out: Reader = .{ .buf = &out_buf };
    const reply = call(Value.mkClosure(intBody, value.no_env), &.{"in"}, &out);
    try std.testing.expectEqual(Status.error, reply.status);
    try std.testing.expectEqualStrings(returned_non_string, reply.bytes);
}

test "call copies every input, so the caller may drop them" {
    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    // Two SEPARATE caller-owned temporaries, both scribbled on after the call.
    // If either argument had been retained by reference, `abcd` would be `zzzz`
    // or worse.
    var first = [_]u8{ 'a', 'b' };
    var second = [_]u8{ 'c', 'd' };

    var out_buf: [256]u8 = undefined;
    var out: Reader = .{ .buf = &out_buf };
    const reply = call(Value.mkClosure(pairBody, value.no_env), &.{ &first, &second }, &out);
    @memset(&first, 'z');
    @memset(&second, 'z');

    try std.testing.expectEqual(Status.ok, reply.status);
    try std.testing.expectEqualStrings("abcd", bytes(reply, &out));
}

test "call copies its input, and the callee sees the copy" {
    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    var input = [_]u8{ 'a', 'b', 'c' };
    seen = &.{};

    var out_buf: [256]u8 = undefined;
    var out: Reader = .{ .buf = &out_buf };
    const reply = call(Value.mkClosure(recordBody, value.no_env), &.{&input}, &out);

    // The callee's view is not the caller's buffer.
    try std.testing.expect(seen.ptr != input[0..].ptr);
    try std.testing.expectEqualStrings("abc", seen);

    @memset(&input, 'z');

    // And what it read survived the scribble.
    try std.testing.expectEqual(Status.ok, reply.status);
    try std.testing.expectEqualStrings("abc", bytes(reply, &out));
    try std.testing.expectEqualStrings("abc", seen);
}

test "callBytes is call with one buffer" {
    var buffer: [1024 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    apply_mod.initAlloc(fba.allocator());

    const reply = callBytes(Value.mkClosure(echoBody, value.no_env), "hello");
    try std.testing.expectEqual(Status.ok, reply.status);
    try std.testing.expectEqualStrings("hello", reply.bytes);

    // An error passes through unchanged: same reason, same status.
    const refused = callBytes(Value.mkClosure(intBody, value.no_env), "in");
    try std.testing.expectEqual(Status.error, refused.status);
    try std.testing.expectEqualStrings(returned_non_string, refused.bytes);
}
