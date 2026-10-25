//! The byte-ABI fixture root (issue #15): proof that a Zig root can call a
//! compiled PureScript function through `rt.abi.callBytes`.
//!
//! Unlike `example/library/libmain.zig`, nothing here constructs or applies a
//! `rt.Value` itself: the whole call crosses the bytes boundary. `rt.abi` takes
//! the closure and an input slice and hands back a `Reply` -- a status and a
//! byte slice -- so the caller needs no knowledge of tags, closures or the
//! runtime's representation.
//!
//! `ps.echo` is `\s -> s <> "!"` in `example/src/Main.purs`, and
//! `zig build test-abi` asserts this program's stdout is exactly `hi!`.
//!
//! Both imports are bindings the build makes, not files this file reaches for:
//! `purs_main` is `LibraryArtifacts.module` (over `output-zig/Main.zig`) and
//! `runtime` is `LibraryArtifacts.runtime`.
//!
//! Native only: the step RUNS it, and it writes to stdout.
//!
//! The reply's bytes are NOT copied and NOT freed here -- they come from the
//! runtime's allocator and are valid for the life of the runtime. See the
//! "Byte entry point" section of `docs/codegen.md`.

const rt = @import("runtime");
const purs_main = @import("purs_main");

pub fn main(init: rt.ProcessInit) !void {
    rt.init(init.io, init.arena.allocator());
    const reply = rt.abi.callBytes(purs_main.@"ps.echo", "hi");
    rt.writeLine(reply.bytes);
}
