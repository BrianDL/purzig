const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // What the example is expected to print. Both the hand-written target and
    // the generated code are checked against this, so the two are kept honest
    // by behaviour rather than by text -- a diff would break on comments,
    // whitespace, and any edit to Main.purs.
    const expected_output = "Hello, Zig\n";

    // -----------------------------------------------------------------
    // 1. Hand-written Zig modules. No PureScript dependency at all, so
    //    they build and test in parallel with everything else.
    // -----------------------------------------------------------------

    const runtime = b.createModule(.{
        .root_source_file = b.path("runtime/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ffi = b.createModule(.{
        .root_source_file = b.path("ffi/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi.addImport("runtime", runtime);

    // -----------------------------------------------------------------
    // 2. The hand-written reference implementation. Buildable with no
    //    spago, purs or node present -- it is what validated the runtime
    //    API before codegen existed, and it stays as a fallback way to
    //    exercise the runtime when the PureScript side is broken.
    // -----------------------------------------------------------------

    const expected_exe = b.addExecutable(.{
        .name = "example-expected",
        .root_module = b.createModule(.{
            .root_source_file = b.path("purs/example/expected/Main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    expected_exe.root_module.addImport("runtime", runtime);
    expected_exe.root_module.addImport("ffi", ffi);

    const run_expected = b.addRunArtifact(expected_exe);
    const run_expected_step = b.step("run-expected", "Build and run the hand-written reference Zig");
    run_expected_step.dependOn(&run_expected.step);

    const check_expected = b.addRunArtifact(expected_exe);
    check_expected.expectStdOutEqual(expected_output);
    const check_expected_step = b.step("test-expected", "Check the hand-written reference output");
    check_expected_step.dependOn(&check_expected.step);

    // -----------------------------------------------------------------
    // 3. Build the backend compiler: PureScript -> JavaScript, run on Node.
    //
    //    `spago bundle`, not `spago build`: the example's spago.yaml points
    //    backend.cmd at ../compiler/bundle.js, and only `bundle` produces it.
    //
    //    `has_side_effects` because spago writes into its own project tree
    //    rather than somewhere Zig controls; spago does its own caching.
    // -----------------------------------------------------------------

    const build_compiler = b.addSystemCommand(&.{ "spago", "bundle" });
    build_compiler.setCwd(b.path("purs/compiler"));
    build_compiler.has_side_effects = true;

    const compiler_step = b.step("compiler", "Build the PureScript->Zig backend itself");
    compiler_step.dependOn(&build_compiler.step);

    // -----------------------------------------------------------------
    // 4. Compile the example through that backend.
    // -----------------------------------------------------------------

    const codegen = b.addSystemCommand(&.{ "spago", "build" });
    codegen.setCwd(b.path("purs/example"));
    codegen.has_side_effects = true;
    codegen.step.dependOn(&build_compiler.step);

    const codegen_step = b.step("codegen", "Generate Zig from PureScript, stopping before compilation");
    codegen_step.dependOn(&codegen.step);

    // -----------------------------------------------------------------
    // 5. Compile the GENERATED Zig.
    //
    //    The root source file does not exist on a clean checkout. The explicit
    //    dependOn is what guarantees codegen has run before the compiler tries
    //    to read it -- without it you race on first build.
    // -----------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("purs/example/output-zig/Main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("runtime", runtime);
    exe.root_module.addImport("ffi", ffi);
    exe.step.dependOn(&codegen.step);

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Build and run the example through the full pipeline");
    run_step.dependOn(&run.step);

    // -----------------------------------------------------------------
    // 6. End-to-end check: does PureScript source, run through the whole
    //    pipeline, behave the same as the hand-written reference?
    //
    //    Requires purs/example/src/Main.purs to be the unmodified example.
    // -----------------------------------------------------------------

    const check_generated = b.addRunArtifact(exe);
    check_generated.expectStdOutEqual(expected_output);
    const e2e_step = b.step("test-e2e", "Run the full pipeline and check the output");
    e2e_step.dependOn(&check_generated.step);

    // -----------------------------------------------------------------
    // 7. Runtime tests. Independent of the PureScript pipeline:
    //    works with no spago, purs or node present.
    // -----------------------------------------------------------------

    const runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_runtime_tests = b.addRunArtifact(runtime_tests);
    const test_step = b.step("test-runtime", "Test the hand-written Zig runtime");
    test_step.dependOn(&run_runtime_tests.step);

    // -----------------------------------------------------------------
    // 8. Everything.
    // -----------------------------------------------------------------

    const all_tests = b.step("test", "Run every check");
    all_tests.dependOn(&run_runtime_tests.step);
    all_tests.dependOn(&check_expected.step);
    all_tests.dependOn(&check_generated.step);

    // -----------------------------------------------------------------
    // 9. Housekeeping.
    // -----------------------------------------------------------------

    const clean = b.addSystemCommand(&.{
        "rm",                       "-rf",
        "purs/compiler/output",     "purs/compiler/.spago",
        "purs/compiler/bundle.js",  "purs/example/output",
        "purs/example/output-zig",  "purs/example/.spago",
    });
    const clean_step = b.step("clean-purs", "Remove PureScript build artefacts");
    clean_step.dependOn(&clean.step);
}
