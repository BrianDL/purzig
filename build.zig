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
pub const LibraryArtifacts = purzig.LibraryArtifacts;
pub const addExecutable = purzig.addExecutable;
pub const addLibrary = purzig.addLibrary;
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

    // -----------------------------------------------------------------
    // The second shape: `addLibrary`, proved in-tree.
    //
    // The same codegen as the program above, minus the decision that the
    // output IS a program. The fixture root in `example/library/` is an
    // ordinary consumer: it binds the returned module as `purs_main`, binds
    // the returned runtime, and runs `@"ps.main"` through `rt.runEffect`.
    // Asserted as OUTPUT, like the program, so this gate is that the library
    // actually runs rather than merely compiles.
    // -----------------------------------------------------------------

    const lib = purzig.addLibrary(b, opts);

    // Our bundle is built from source, so library codegen waits for it as the
    // program's does -- and for the program's codegen, because both run
    // `spago build` in the same project directory and the build runner would
    // otherwise start the two in parallel.
    lib.codegen.step.dependOn(&build_compiler.step);
    lib.codegen.step.dependOn(&app.codegen.step);

    const lib_root = b.createModule(.{
        .root_source_file = b.path("example/library/libmain.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_root.addImport("runtime", lib.runtime);
    lib_root.addImport("purs_main", lib.module_main);

    const lib_probe = b.addExecutable(.{
        .name = "library-probe",
        .root_module = lib_root,
    });
    lib_probe.step.dependOn(&lib.codegen.step);

    // Not installed: `addLibrary` installs nothing, and this probe is a check,
    // not an artifact. It only has to run.
    const check_library = b.addRunArtifact(lib_probe);
    check_library.expectStdOutEqual(expected_output);

    const library_step = b.step("test-library", "Compile the example as a library and check the output");
    library_step.dependOn(&check_library.step);

    // -----------------------------------------------------------------
    // The byte ABI, proved in-tree (issue #15).
    //
    // Same `addLibrary` codegen as `test-library`, but the fixture root in
    // `example/abi/` never touches a `rt.Value`: it hands `@"ps.echo"` and the
    // bytes `hi` to `rt.abi.callBytes` and prints the bytes that come back.
    // That is the whole point -- a host outside Zig's type system (a wasm
    // embedder, another language) can call compiled PureScript through this
    // one entry point, and this step is the gate that it works at all.
    // -----------------------------------------------------------------

    const abi_lib = purzig.addLibrary(b, opts);

    // Same ordering as `test-library`: our bundle is built from source, and
    // both library-shaped runs `spago build` in `example/`, so they are
    // serialised behind the program's codegen as well.
    abi_lib.codegen.step.dependOn(&build_compiler.step);
    abi_lib.codegen.step.dependOn(&app.codegen.step);

    const abi_root = b.createModule(.{
        .root_source_file = b.path("example/abi/abi_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_root.addImport("purs_main", abi_lib.module_main);
    abi_root.addImport("runtime", abi_lib.runtime);

    const abi_probe = b.addExecutable(.{
        .name = "abi-probe",
        .root_module = abi_root,
    });
    abi_probe.step.dependOn(&abi_lib.codegen.step);

    // Not installed: it is a check, not an artifact.
    const check_abi = b.addRunArtifact(abi_probe);
    check_abi.expectStdOutEqual("hi!\n");

    const abi_step = b.step("test-abi", "Call a compiled PureScript function through the byte ABI and check the output");
    abi_step.dependOn(&check_abi.step);

    // -----------------------------------------------------------------
    // The byte ABI with k arguments, from a non-`Main` module (issue #21).
    //
    // Same codegen, but the root asks `addLibrary` for the `Api` module BY
    // NAME -- the module lookup half of #21 -- and calls `ps.pair`, a
    // TWO-argument function, through `rt.abi.call` with two buffers. Nothing
    // in `Main` is involved, and `test-abi` above is untouched.
    // -----------------------------------------------------------------

    const multi_lib = purzig.addLibrary(b, .{
        .name = opts.name,
        .main_module = opts.main_module,
        .extra_modules = &.{"Api"},
        .project = opts.project,
        .target = target,
        .optimize = optimize,
    });

    // Same ordering as the other library-shaped runs: the bundle first, then
    // behind the program's codegen, because all of them run `spago build` in
    // the one `example/` project directory.
    multi_lib.codegen.step.dependOn(&build_compiler.step);
    multi_lib.codegen.step.dependOn(&app.codegen.step);

    // The consumer-side lookup: `Api` by PureScript module name, over
    // `output-zig/Api.zig` with the runtime already bound. The name is
    // declared in `extra_modules` -- the build script reads nothing at
    // configure time, so a module is a name it was told, not one it found.
    const api_module = multi_lib.module("Api");

    const multi_root = b.createModule(.{
        .root_source_file = b.path("example/abi/abi_multi.zig"),
        .target = target,
        .optimize = optimize,
    });
    multi_root.addImport("api", api_module);
    multi_root.addImport("runtime", multi_lib.runtime);

    const multi_probe = b.addExecutable(.{
        .name = "abi-multi-probe",
        .root_module = multi_root,
    });
    multi_probe.step.dependOn(&multi_lib.codegen.step);

    // Not installed: it is a check, not an artifact.
    const check_multi = b.addRunArtifact(multi_probe);
    check_multi.expectStdOutEqual("abcd\n");

    const multi_step = b.step("test-abi-multi", "Call a two-argument function in a non-Main module through the byte ABI");
    multi_step.dependOn(&check_multi.step);

    const run_runtime_tests = purzig.addRuntimeTests(b, opts);
    const runtime_step = b.step("test-runtime", "Test the hand-written Zig runtime");
    runtime_step.dependOn(&run_runtime_tests.step);

    const all_tests = b.step("test", "Run every check");
    all_tests.dependOn(&run_runtime_tests.step);
    all_tests.dependOn(&check_generated.step);
    all_tests.dependOn(&check_library.step);
    all_tests.dependOn(&check_abi.step);
    all_tests.dependOn(&check_multi.step);

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
