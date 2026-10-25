//! The byte-ABI fixture root (issue #15): proof that a Zig root can call a
//! compiled PureScript function through `rt.abi.callBytes`.
//!
//! Unlike `example/library/libmain.zig`, nothing here constructs an argument
//! `rt.Value` or applies a closure: the whole call crosses the bytes boundary.
//! `rt.abi` takes the function value and an input slice and hands back a
//! `Reply` -- a status and a byte slice -- so the caller needs no knowledge of
//! tags, closures or the runtime's representation.
//!
//! Note the one step that is still the caller's: every generated module decl
//! `@"ps.<name>"` is a THUNK `fn () rt.Error!rt.Value`, not a `Value`. It must
//! be called (`try purs_main.@"ps.echo"()`) to obtain the value; passing the
//! function name itself would pass a function, not a `Value`. Applying the
//! arguments stays the runtime's job (`callBytes` does that).
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
    const f = try purs_main.@"ps.echo"();
    const reply = rt.abi.callBytes(f, "hi");
    rt.writeLine(reply.bytes);
}
