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
pub const ToolOptions = purzig.ToolOptions;
pub const ToolArtifacts = purzig.ToolArtifacts;
pub const addExecutable = purzig.addExecutable;
pub const addLibrary = purzig.addLibrary;
pub const addTool = purzig.addTool;
pub const addRuntimeTests = purzig.addRuntimeTests;
pub const version = purzig.version;

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

    // Wrapped in purzig's failure reporter, so a bundle that fails to build
    // prints the compiler's own output rather than only `failed command`. It
    // is the same helper a consumer gets: `spago bundle`, not `spago build`,
    // because only bundle produces the file the shim execs.
    const build_compiler = purzig.addReportedCommand(b, .{
        .label = "spago bundle",
        .project = b.path("compiler"),
        .argv = &.{ "spago", "bundle" },
    });

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

    // -----------------------------------------------------------------
    // The byte-exact call path (issue #27).
    //
    // Same codegen, another module: `Bytes` is in `extra_modules`, so it is
    // reachable by name like `Api` above. Its two declarations traffic in
    // `Array Int` -- bytes -- rather than `String`, and `example/abi/abi_raw.zig`
    // calls them through `rt.abi.callRaw` with `[0xff, 0x00, 0xfe]`: input that
    // is not text at all, which is what `call`/`callBytes` cannot carry.
    // Asserted as OUTPUT, so the gate is that the bytes came back changed by
    // nothing -- not merely that the call type-checked.
    // -----------------------------------------------------------------

    const raw_lib = purzig.addLibrary(b, .{
        .name = opts.name,
        .main_module = opts.main_module,
        .extra_modules = &.{"Bytes"},
        .project = opts.project,
        .target = target,
        .optimize = optimize,
    });

    // Same ordering as every other library-shaped run: the bundle first, then
    // behind the program's codegen, because all of them run `spago build` in the
    // one `example/` project directory.
    raw_lib.codegen.step.dependOn(&build_compiler.step);
    raw_lib.codegen.step.dependOn(&app.codegen.step);

    const raw_root = b.createModule(.{
        .root_source_file = b.path("example/abi/abi_raw.zig"),
        .target = target,
        .optimize = optimize,
    });
    raw_root.addImport("bytes", raw_lib.module("Bytes"));
    raw_root.addImport("runtime", raw_lib.runtime);

    const raw_probe = b.addExecutable(.{
        .name = "abi-raw-probe",
        .root_module = raw_root,
    });
    raw_probe.step.dependOn(&raw_lib.codegen.step);

    // Not installed: it is a check, not an artifact. Hex for the round trip and
    // a decimal for the byte the callee read out of the same input.
    const abi_raw = b.addRunArtifact(raw_probe);
    abi_raw.expectStdOutEqual("ff 00 fe\n255\n");

    const abi_raw_step = b.step("test-abi-raw", "Call a compiled PureScript function with non-text bytes through the byte ABI");
    abi_raw_step.dependOn(&abi_raw.step);

    // -----------------------------------------------------------------
    // The published export shapes (issue #33).
    //
    // `Zig.Abi` turns each exported value's `docs.json` type into one shape from
    // a fixed, width-agnostic vocabulary and `Main` writes them as `exports` in
    // the manifest. The gate is a Zig probe reading that manifest, in the style
    // of `abi_probe.zig`: no python, no node, no JSON parser -- it asserts the
    // exact row text, so a row that is missing OR shaped differently fails.
    //
    // One codegen run is enough: `spago build` in `example/` compiles every
    // module in `src/`, so `Shapes` is in this manifest. The probe `@embedFile`s
    // the manifest, so it must be COMPILED after that run -- hence the step
    // dependency, which is also the only ordering it needs.
    // -----------------------------------------------------------------

    const exports_root = b.createModule(.{
        .root_source_file = b.path("example/exports_probe.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exports_probe = b.addExecutable(.{
        .name = "exports-probe",
        .root_module = exports_root,
    });
    exports_probe.step.dependOn(&app.codegen.step);

    // Not installed: it is a check, not an artifact.
    const check_exports = b.addRunArtifact(exports_probe);
    check_exports.expectStdOutEqual("ok 6 Shapes export rows\n");

    const exports_step = b.step("test-exports", "Assert the export shapes published in the manifest");
    exports_step.dependOn(&check_exports.step);

    // -----------------------------------------------------------------
    // Diagnostics (issue #31): a failing build must print the compiler's own
    // output, and name the phase.
    //
    // `run spago failure` plus `process exited with error code 1` conflated
    // three different failures and threw away the one thing that says what to
    // fix -- purs's error block. Each fixture below is a real `spago build`
    // against a project in `example/diagnostics/`, run through the SAME
    // reporter the build uses (`purzig.addReportedCommand`), in its assertion
    // mode: the command is expected to fail, and the report -- markers, phase
    // sentence, and the child's untruncated output -- must contain every
    // needle listed here. So this gate fails if the text ever goes back to a
    // bare `run spago failure`, and it asserts on the FAIL path rather than
    // by eye.
    //
    // One fixture per phase the issue asks to be named, because the fix
    // differs per phase:
    //
    //   missing-import    type-check failure: purs rejected the source. Purposely
    //                     imports `Data.Array` without declaring `arrays`.
    //   backend-ffi       backend failure: purs type-checked, the backend could
    //                     not emit Zig. A foreign import with no Zig FFI.
    //   missing-artifact  missing artifact: nothing failed, but
    //                     `output-zig/Main.zig` is not there to compile.
    //
    // A fourth failure -- `backend unavailable`, the shim not being on PATH,
    // which is what a hand `spago build` hits -- cannot be provoked from here
    // without breaking the shim on purpose, so it is asserted by construction
    // instead: `purzig.addProjectSetup` writes the `.purzig/spago` wrapper that
    // makes a hand run agree, and the reporter names it. See
    // `docs/handoff-purzig-build-diagnostics-2026-11-03.md`.
    // -----------------------------------------------------------------

    const diag_step = b.step("test-diagnostics", "Assert a failing build prints the compiler's output and names the phase");

    const Fixture = struct {
        dir: []const u8,
        main_module: ?[]const u8,
        require: []const []const u8,
        require_re: []const []const u8,
    };

    const fixture_list = [_]Fixture{
        .{
            .dir = "example/diagnostics/missing-import",
            .main_module = null,
            .require = &.{
                "--- purzig: `spago build` failed (exit ",
                "--- end of `spago build` output ---",
                "type-check failure",
                "ModuleNotFound",
                "Module Data.Array was not found",
            },
            // The file and the line:column, as purs printed them. A regex so
            // the assertion is on the SHAPE (file:line:column), not on the
            // column purs happens to choose.
            .require_re = &.{"src/Main\\.purs:9:[0-9]+"},
        },
        .{
            .dir = "example/diagnostics/backend-ffi",
            .main_module = null,
            .require = &.{
                "--- purzig: `spago build` exited 0, but the purzig backend",
                "--- end of `spago build` output ---",
                "backend failure",
                "MISSING FFI",
                "src/Ffi.zig",
            },
            .require_re = &.{},
        },
        .{
            .dir = "example/diagnostics/missing-artifact",
            .main_module = "Main",
            .require = &.{
                "--- purzig: `spago build` exited 0, but output-zig/Main.zig is missing",
                "--- end of `spago build` output ---",
                "missing artifact",
                "Options.main_module",
            },
            .require_re = &.{},
        },
    };

    for (fixture_list) |fixture| {
        const project = b.path(fixture.dir);

        // The same preparation a real codegen run gets: the package set, the
        // backend shim, and `.purzig/spago`. Without it `spago build` here
        // would be exactly the hand run that fails with no backend.
        const fixture_setup = purzig.addProjectSetup(b, .{
            .name = "diagnostics",
            .project = project,
            .target = target,
            .optimize = optimize,
        });

        const probe = purzig.addReportedCommand(b, .{
            .label = "spago build",
            .project = project,
            .main_module = fixture.main_module,
            .argv = &.{ "spago", "build" },
            .expect_failure = true,
            .require = fixture.require,
            .require_re = fixture.require_re,
        });
        probe.step.dependOn(fixture_setup);

        // The shim execs the bundle, which this repository builds from source
        // (`zig build compiler`), exactly as `app.codegen` waits for it.
        probe.step.dependOn(&build_compiler.step);

        diag_step.dependOn(&probe.step);
    }

    // -----------------------------------------------------------------
    // The canonical value codec (issue #45).
    //
    // `runtime/valuecodec.zig` is the byte form of `rt.Value`, moved here from
    // the consumer that used to carry the only copy. Its tests are pure Zig:
    // no purs, spago, node, wasm runtime or `std.Io`, so this step is the cheap
    // one to run while editing the codec, and the one that says the wire format
    // still is what the format's docs say it is.
    //
    // `test-runtime` runs the SAME tests as well: `runtime/root.zig` imports
    // the codec in its `test` block, so `zig build test` (which depends on
    // `addRuntimeTests`) cannot go green without them. This step adds the
    // narrower entry point, not a second copy of the coverage.
    // -----------------------------------------------------------------

    const codec_root = b.createModule(.{
        .root_source_file = b.path("runtime/valuecodec.zig"),
        .target = target,
        .optimize = optimize,
    });

    const codec_tests = b.addTest(.{ .root_module = codec_root });
    const run_codec_tests = b.addRunArtifact(codec_tests);

    const valuecodec_step = b.step("test-valuecodec", "Test the canonical value codec alone (no purs, spago or node)");
    valuecodec_step.dependOn(&run_codec_tests.step);

    const run_runtime_tests = purzig.addRuntimeTests(b, opts);
    const runtime_step = b.step("test-runtime", "Test the hand-written Zig runtime");
    runtime_step.dependOn(&run_runtime_tests.step);

    // -----------------------------------------------------------------
    // The tool (issue #45, part 2): a compiled export, run from a shell.
    //
    // Same codegen as the library above, plus `entry/tool.zig`: a CLI that
    // takes `<export> [<infile>]`, codec-decodes the input into a `rt.Value`,
    // applies the export and codec-encodes the result to stdout. The gate runs
    // the binary from THIS build graph and asserts the exact bytes on stdout,
    // because "the tool works" means the pipe does -- the codec's own tests
    // already say the codec does -- and a byte vector that is wrong by one is
    // the failure mode a compile check cannot see.
    //
    // `seed` and `greet` are `Main`'s: one zero-argument export (no input bytes
    // at all means no arguments) and one one-argument export, so the gate
    // covers both halves of the arity rule. Nothing else in `Main` changes, so
    // `test-e2e`'s `Hello, Zig` is unaffected.
    // -----------------------------------------------------------------

    const tool = purzig.addTool(b, .{
        .name = "example-tool",
        .project = b.path("example"),
        .main_module = "Main",
        .exports = &.{ "seed", "greet" },
        .optimize = optimize,
        // .purzig stays null: here, b IS purzig.
    });

    // Same ordering as every other codegen run in this file: our bundle is
    // built from source, and all of them run `spago build` in the one
    // `example/` project directory.
    tool.codegen.step.dependOn(&build_compiler.step);
    tool.codegen.step.dependOn(&app.codegen.step);

    const tool_step = b.step("test-tool", "Run the example through the tool CLI and check its stdout bytes");

    // `list`: the `.exports` names, one per line, in the order they were given.
    const tool_list = b.addRunArtifact(tool.exe);
    tool_list.addArg("list");
    tool_list.expectStdOutEqual("seed\ngreet\n");
    tool_step.dependOn(&tool_list.step);

    // `--version`: the name and purzig's version, nothing else.
    const tool_version = b.addRunArtifact(tool.exe);
    tool_version.addArg("--version");
    tool_version.expectStdOutEqual(b.fmt("example-tool {s}\n", .{purzig.version}));
    tool_step.dependOn(&tool_version.step);

    // `run seed` with no input at all: zero arguments, so the export's VALUE is
    // the output. `seed :: Unit` is the codec's `0x01` version byte and `0x00`
    // for the unit tag -- two bytes out of an empty stdin, which is what "this
    // pipeline ran" looks like as a file.
    const tool_seed = b.addRunArtifact(tool.exe);
    tool_seed.addArgs(&.{ "run", "seed" });
    tool_seed.expectStdOutEqual("\x01\x00");
    tool_step.dependOn(&tool_seed.step);

    // `run greet <infile>`: one codec value in, one codec value out. The infile
    // is the codec's own bytes for the string `hi` -- version, string tag, a
    // 4-byte little-endian length, then UTF-8 -- and `greet` returns
    // `Hello, hi`, so the expectation is the same shape with a longer payload.
    // Written through `addWriteFiles`, so the fixture bytes come from this file
    // rather than from a checked-in binary.
    const greet_in = b.addWriteFiles().add("greet-arg.bin", "\x01\x04\x02\x00\x00\x00hi");
    const tool_greet = b.addRunArtifact(tool.exe);
    tool_greet.addArgs(&.{ "run", "greet" });
    tool_greet.addFileArg(greet_in);
    tool_greet.expectStdOutEqual("\x01\x04\x09\x00\x00\x00Hello, hi");
    tool_step.dependOn(&tool_greet.step);

    // A name that `.exports` does not contain is exit 2, and stderr names it.
    // The exit code is what a shell script branches on; the text is asserted by
    // the consumer-side fixture, which is where a tool's stderr is read.
    const tool_unknown = b.addRunArtifact(tool.exe);
    tool_unknown.addArgs(&.{ "run", "nonexistent" });
    tool_unknown.expectExitCode(2);
    tool_step.dependOn(&tool_unknown.step);

    // A buffer whose first byte is not the codec's `0x01` is a refusal, not a
    // wrong answer: exit 1, and nothing on stdout.
    const stale_in = b.addWriteFiles().add("stale-version.bin", "\x02\x00");
    const tool_stale = b.addRunArtifact(tool.exe);
    tool_stale.addArgs(&.{ "run", "greet" });
    tool_stale.addFileArg(stale_in);
    tool_stale.expectExitCode(1);
    tool_step.dependOn(&tool_stale.step);

    const all_tests = b.step("test", "Run every check");
    all_tests.dependOn(&run_runtime_tests.step);
    all_tests.dependOn(&check_generated.step);
    all_tests.dependOn(&check_library.step);
    all_tests.dependOn(&check_abi.step);
    all_tests.dependOn(&check_multi.step);
    all_tests.dependOn(&check_exports.step);
    // The diagnostics gate is part of `test` as well as its own step: a gate
    // nobody runs is the complaint that produced it.
    all_tests.dependOn(diag_step);
    all_tests.dependOn(&abi_raw.step);
    all_tests.dependOn(tool_step);

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
