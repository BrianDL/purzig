//! The `addLibrary` fixture root (issue #10): proof that the helper can hand
//! out the compiled PureScript module without also deciding that there is a
//! `main`.
//!
//! This is a consumer's root, not purzig's entry. It does what any such
//! consumer does -- bind the library module and the runtime, then run
//! `@"ps.main"` -- and `zig build test-library` asserts its stdout is exactly
//! `Hello, Zig`.
//!
//! Native only on purpose: `test-library` RUNS the artifact, so a freestanding
//! target could not execute it. The entry's comptime branch has no counterpart
//! here, which is the point: a library does not decide how a host starts.
//!
//! Both imports are bindings the caller makes, not files this file reaches for:
//! `purs_main` is `LibraryArtifacts.module` (the module over
//! `output-zig/Main.zig`) and `runtime` is `LibraryArtifacts.runtime`.

const rt = @import("runtime");
const purs_main = @import("purs_main");

pub fn main(init: rt.ProcessInit) !void {
    rt.init(init.io, init.arena.allocator());
    _ = try rt.runEffect(try purs_main.@"ps.main"());
}
