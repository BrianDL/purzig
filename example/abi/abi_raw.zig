//! The raw-bytes ABI fixture root (issue #27).
//!
//! `rt.abi.call`/`callBytes` walk every input through `Value.mkString`, so the
//! callee sees PureScript `String`s -- and a `[]const u8` is not text in
//! general. `rt.abi.callRaw` is the same call with exactly one step removed:
//! each input slice becomes an `Array Int` of its bytes instead of a `String`,
//! so no byte on the way in is ever read as anything but a byte, and the reply
//! is read back the same way.
//!
//! The input below is `[0xff, 0x00, 0xfe]`: a NUL and two bytes no text decoder
//! would accept at those positions. It is not text, it is not a `String`, and
//! it has to survive -- which is the whole point of the path.
//!
//! Two calls, both on that input:
//!
//!   1. `ps.echoByte` (`\xs -> xs` in `example/src/Bytes.purs`) through
//!      `rt.abi.callRaw`, printed as hex, so the reply is visibly the input;
//!   2. `ps.firstByte` on the same bytes, printed in decimal: `255`. That call
//!      is deliberately NOT made through `callRaw`, because `firstByte` returns
//!      an `Int` and the byte path refuses a result that is not byte-like --
//!      "an `Int` is not a byte" is a tested refusal, not an oversight. The
//!      argument is `rt.abi.byteArray(&input)`, the very `Value` `callRaw`
//!      passes, and the result is read with `asInt`.
//!
//! Every generated module decl `@"ps.<name>"` is a THUNK
//! `fn () rt.Error!rt.Value`, so it must be CALLED (`try bytes.@"ps.echoByte"()`)
//! to obtain the value; passing the name itself would pass a function.
//!
//! `zig build test-abi-raw` asserts stdout is exactly:
//!
//!     ff 00 fe
//!     255
//!
//! Both imports are bindings the build makes, not files this file reaches for:
//! `bytes` is `LibraryArtifacts.module("Bytes")` and `runtime` is
//! `LibraryArtifacts.runtime`.
//!
//! Native only: the step RUNS it, and it writes to stdout.

const rt = @import("runtime");
const bytes = @import("bytes");

pub fn main(init: rt.ProcessInit) !void {
    rt.init(init.io, init.arena.allocator());

    const input = [_]u8{ 0xff, 0x00, 0xfe };

    // 1. Bytes in, the same bytes out. `callRaw` writes into this Reader and
    //    hands back a transport status; the reply is the caller's own buffer,
    //    not runtime memory.
    var hex_buf: [64]u8 = undefined;
    var out_buf: [64]u8 = undefined;
    var out: rt.abi.Reader = .{ .buf = &out_buf };
    const reply = rt.abi.callRaw(try bytes.@"ps.echoByte"(), &.{&input}, &out);
    switch (reply.status) {
        .ok => rt.writeLine(formatHex(out.buf[0..out.len], &hex_buf)),
        // Unreachable for this fixture, but the status is not optional: a
        // failure carries its reason in `reply.bytes`.
        .failed => rt.writeLineErr(reply.bytes),
    }

    // 2. A compiled PureScript function reading a byte out of those bytes.
    var dec_buf: [32]u8 = undefined;
    const read = try rt.apply(try bytes.@"ps.firstByte"(), rt.abi.byteArray(&input));
    rt.writeLine(formatInt(read.asInt(), &dec_buf));
}

/// `ff 00 fe`: each byte as two lowercase hex digits, space separated.
fn formatHex(in: []const u8, buf: []u8) []const u8 {
    const digits = "0123456789abcdef";
    var n: usize = 0;
    for (in, 0..) |byte, i| {
        if (i != 0) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = digits[@as(usize, byte >> 4)];
        buf[n + 1] = digits[@as(usize, byte & 0x0f)];
        n += 2;
    }
    return buf[0..n];
}

/// A decimal `Int`, written backwards into the tail of `buf`.
fn formatInt(value: i32, buf: []u8) []const u8 {
    const digits = "0123456789";
    var x: i64 = value;
    var negative = false;
    if (x < 0) {
        negative = true;
        x = -x;
    }
    var start: usize = buf.len;
    if (x == 0) {
        start -= 1;
        buf[start] = '0';
    }
    while (x > 0) {
        start -= 1;
        buf[start] = digits[@as(usize, @intCast(@rem(x, 10)))];
        x = @divTrunc(x, 10);
    }
    if (negative) {
        start -= 1;
        buf[start] = '-';
    }
    return buf[start..];
}
