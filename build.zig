//! purzig's own build. Deliberately thin: everything about turning PureScript
//! into a binary lives in `build/purzig.zig`, and this file consumes it exactly
//! as a downstream user's `build.zig` does. That is the point -- the example is
//! the first client of the published API rather than a privileged special case,
//! so a break in the helper shows up in `zig build test` here.

const std = @import("std");
const purzig = @import("build/purzig.zig");

// `@import("purzig")` in a consumer's build.zig resolves to THIS file, so the
// public API is re-exported here. The implementation stays in build/purzig.zig
// so it can be read on its own.
pub const Options = purzig.Options;
pub const Artifacts = purzig.Artifacts;
pub const addExecutable = purzig.addExecutable;
pub const addRuntimeTests = purzig.addRuntimeTests;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Asserted behaviour of the example. Checked as output rather than as a
    // diff of the generated Zig, which broke on comments and on any edit to
    // Main.purs.
    const expected_output = "Hello, Zig\n";

    // The runtime module is exported so `zig build` in a dependent project can
    // reach it by name if it ever wants to; the helper creates its own.
    _ = b.addModule("runtime", .{ .root_source_file = b.path("runtime/root.zig") });

    // A consumer's `b.dependency("purzig", .{})` RUNS this function, and the
    // published tarball carries no `example/` or `tools/`. Everything below is
    // development wiring, so it is skipped unless the fixture is present. The
    // check is a file test rather than an inspection of builder internals
    // because it stays true across Zig versions and explains itself.
    b.build_root.handle.access(b.graph.io, "example/spago.yaml", .{}) catch return;

    // -----------------------------------------------------------------
    // The backend itself: PureScript -> JavaScript, run on node.
    //
    // `spago bundle`, not `spago build` -- only bundle produces the file the
    // shim execs. A release tag ships this prebuilt, so a downstream user never
    // runs this step and never fetches the optimizer's git dependency.
    // -----------------------------------------------------------------

    const build_compiler = b.addSystemCommand(&.{ "spago", "bundle" });
    build_compiler.setCwd(b.path("compiler"));
    build_compiler.has_side_effects = true;

    const compiler_step = b.step("compiler", "Build the PureScript->Zig backend itself");
    compiler_step.dependOn(&build_compiler.step);

    // -----------------------------------------------------------------
    // The example, through the public helper.
    // -----------------------------------------------------------------

    const opts: purzig.Options = .{
        .name = "example",
        .main_module = "Main",
        .project = b.path("example"),
        .target = target,
        .optimize = optimize,
        // .purzig stays null: here, b IS purzig.
    };

    const app = purzig.addExecutable(b, opts);

    // The one thing a downstream build does not need: our bundle is built from
    // source, so codegen has to wait for it.
    app.codegen.step.dependOn(&build_compiler.step);

    b.installArtifact(app.exe);

    const codegen_step = b.step("codegen", "Generate Zig from PureScript, stopping before compilation");
    codegen_step.dependOn(&app.codegen.step);

    const run = b.addRunArtifact(app.exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Build and run the example through the full pipeline");
    run_step.dependOn(&run.step);

    // -----------------------------------------------------------------
    // Checks.
    // -----------------------------------------------------------------

    const check_generated = b.addRunArtifact(app.exe);
    check_generated.expectStdOutEqual(expected_output);
    const e2e_step = b.step("test-e2e", "Run the full pipeline and check the output");
    e2e_step.dependOn(&check_generated.step);

    const run_runtime_tests = purzig.addRuntimeTests(b, opts);
    const runtime_step = b.step("test-runtime", "Test the hand-written Zig runtime");
    runtime_step.dependOn(&run_runtime_tests.step);

    const all_tests = b.step("test", "Run every check");
    all_tests.dependOn(&run_runtime_tests.step);
    all_tests.dependOn(&check_generated.step);

    // -----------------------------------------------------------------
    // The package set. Regenerate and commit whenever `packages/` changes,
    // because the set is what a downstream user resolves against.
    // -----------------------------------------------------------------

    const mkset = b.addSystemCommand(&.{"tools/mkpackageset.sh"});
    mkset.has_side_effects = true;
    if (b.args) |args| mkset.addArgs(args);
    const set_step = b.step("packageset", "Regenerate packages.json from packages/");
    set_step.dependOn(&mkset.step);

    // -----------------------------------------------------------------
    // Housekeeping.
    // -----------------------------------------------------------------

    const clean = b.addSystemCommand(&.{
        "rm",                  "-rf",
        "compiler/output",     "compiler/.spago",
        "compiler/dist/bundle.js", "example/output",
        "example/output-zig",  "example/.spago",
    });
    const clean_step = b.step("clean-purs", "Remove PureScript build artefacts");
    clean_step.dependOn(&clean.step);
}
