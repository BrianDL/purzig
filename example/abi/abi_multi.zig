//! The k-argument, any-module byte-ABI fixture root (issue #21).
//!
//! Two things `example/abi/abi_probe.zig` could not show:
//!
//!   1. the callee lives in `Api`, a module that is NOT `Main`. The import
//!      below is `addLibrary.module("Api")`, resolved by PureScript module name
//!      at configure time -- nothing in `Main` is involved;
//!   2. the callee takes TWO arguments. `rt.abi.call` copies each element of
//!      `ins` into the runtime's allocator and applies `f` left to right, so a
//!      `String -> String -> String` is callable at all. `callBytes` -- the
//!      one-slice wrapper kept for existing callers -- could not.
//!
//! As in the single-argument probe, the decl `@"ps.pair"` is a THUNK
//! `fn () rt.Error!rt.Value`, so it must be CALLED to obtain the value; passing
//! the name itself would pass a function, not a `Value`. Applying the
//! arguments is `rt.abi.call`'s job.
//!
//! `pair` is `a <> b` in `example/src/Api.purs`, so with `ab` then `cd` the
//! reply is `abcd` and `zig build test-abi-multi` asserts stdout is exactly
//! `abcd\n`. The reply is read out of a caller-owned `rt.abi.Reader`, which is
//! the out-sink `call` writes into: no runtime memory is handed to this root.
//!
//! Both imports are bindings the build makes, not files this file reaches for:
//! `api` is `LibraryArtifacts.module("Api")` and `runtime` is
//! `LibraryArtifacts.runtime`.
//!
//! Native only: the step RUNS it, and it writes to stdout.

const rt = @import("runtime");
const api = @import("api");

pub fn main(init: rt.ProcessInit) !void {
    rt.init(init.io, init.arena.allocator());

    const f = try api.@"ps.pair"();

    // Sized by the caller: `call` never returns runtime memory, it writes into
    // this buffer and reports the length. `pair`'s reply is `ab` <> `cd`.
    var buf: [64]u8 = undefined;
    var out: rt.abi.Reader = .{ .buf = &buf };

    const reply = rt.abi.call(f, &.{ "ab", "cd" }, &out);
    switch (reply.status) {
        // Transport said the call crossed; the bytes are ours.
        .ok => rt.writeLine(rt.abi.bytes(reply, &out)),
        // Transport said it did not cross: `reply.bytes` is the reason. A
        // fixture cannot fail this way, but the branch keeps the status
        // impossible to ignore.
        .error => rt.writeLineErr(reply.bytes),
    }
}
