//! The public build API of purzig. This is the only file a downstream user's
//! `build.zig` imports, and everything it needs to know about how a PureScript
//! program becomes a native binary is here.
//!
//! Three things have to happen, in order:
//!
//!   1. A `purzig` executable must exist on PATH, because the user's
//!      `spago.yaml` says `backend: { cmd: purzig }` and spago resolves that
//!      name itself. `spago.yaml` is static text and cannot interpolate a path
//!      that only the Zig build knows, so a one-line shim is generated into the
//!      cache and that directory is prepended to PATH for the spago step alone.
//!      Nothing is installed anywhere the user can see, and there is no global.
//!
//!   2. `spago build` runs, which compiles PureScript to corefn and then execs
//!      the shim once per build. The backend writes `output-zig/<Module>.zig`
//!      beside the project, and copies each package's `<Module>.zig` FFI in as
//!      `<Module>.ffi.zig` itself -- the build system is not involved in that.
//!
//!   3. The generated root module is compiled as an ordinary Zig executable
//!      with `runtime` bound as an import.
//!
//! Step 3 depends on step 2 explicitly. The root source file does not exist on
//! a clean checkout, so without that edge the first build races.
//!
//! POSIX only: the shim is `/bin/sh`. Windows would need a `.cmd` variant.

const std = @import("std");

pub const Options = struct {
    /// Name of the produced binary.
    name: []const u8,

    /// PureScript module holding `main`. Its generated Zig is the root source.
    main_module: []const u8 = "Main",

    /// Directory containing `spago.yaml`. Defaults to the build root.
    project: ?std.Build.LazyPath = null,

    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    /// The purzig dependency, from `b.dependency("purzig", .{})`.
    /// Leave null only when `b` *is* purzig -- i.e. from purzig's own build.zig.
    purzig: ?*std.Build.Dependency = null,
};

pub const Artifacts = struct {
    /// The linked executable. Usually all a caller wants.
    exe: *std.Build.Step.Compile,

    /// The `spago build` invocation. Exposed so an in-repo build can make it
    /// depend on building the backend bundle from source; a downstream user
    /// gets the bundle prebuilt and never needs this.
    codegen: *std.Build.Step.Run,

    /// The Zig runtime module, in case hand-written Zig wants to link against
    /// the same one the generated code uses.
    runtime: *std.Build.Module,
};

pub fn addExecutable(b: *std.Build, opts: Options) Artifacts {
    // Paths to purzig's own files resolve against purzig's builder; paths to
    // the user's project resolve against theirs. Getting this backwards is the
    // one mistake that makes the helper work in-repo and fail downstream.
    const pb = if (opts.purzig) |dep| dep.builder else b;

    const project = opts.project orelse b.path(".");

    const runtime = pb.createModule(.{
        .root_source_file = pb.path("runtime/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    // ---- 1. the shim -------------------------------------------------------

    // Absolute, because the spago step runs with a different cwd.
    const bundle = absFromRoot(pb, "compiler/dist/bundle.js");
    const bin_dir = absFromRoot(b, ".zig-cache/purzig-bin");

    const shim = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "set -e; mkdir -p '{s}'; " ++
                "printf '#!/bin/sh\\nexec node \"{s}\" \"$@\"\\n' > '{s}/purzig'; " ++
                "chmod +x '{s}/purzig'",
            .{ bin_dir, bundle, bin_dir, bin_dir },
        ),
    });
    shim.has_side_effects = true;

    // The set ships inside the dependency, so it is by construction the one
    // belonging to the tag the user pinned in build.zig.zon. Copying it next to
    // their spago.yaml means their config names a fixed path and the tag appears
    // in exactly one place. Tolerates a missing set so the in-repo fixture,
    // which resolves packages by path instead, still builds.
    const set = b.addSystemCommand(&.{
        "sh", "-c",
        "mkdir -p .purzig && cp \"$1\" .purzig/packages.json 2>/dev/null || true",
        "sh", absFromRoot(pb, "packages.json"),
    });
    set.setCwd(project);
    set.has_side_effects = true;

    // ---- 2. codegen -------------------------------------------------------

    // `has_side_effects` because spago writes into its own project tree rather
    // than anywhere Zig models. Spago does its own caching.
    const codegen = b.addSystemCommand(&.{ "spago", "build" });
    codegen.setCwd(project);
    codegen.has_side_effects = true;
    codegen.step.dependOn(&shim.step);
    codegen.step.dependOn(&set.step);

    codegen.addPathDir(bin_dir);

    // ---- 3. compile the generated Zig -------------------------------------

    const root = project.path(b, b.fmt("output-zig/{s}.zig", .{opts.main_module}));

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });
    exe.root_module.addImport("runtime", runtime);
    exe.step.dependOn(&codegen.step);

    return .{ .exe = exe, .codegen = codegen, .runtime = runtime };
}

/// Tests for the hand-written Zig runtime. Needs no purs, spago or node, so it
/// is worth having downstream too: it isolates "the runtime is broken" from
/// "my PureScript is broken".
pub fn addRuntimeTests(b: *std.Build, opts: Options) *std.Build.Step.Run {
    const pb = if (opts.purzig) |dep| dep.builder else b;

    const tests = b.addTest(.{
        .root_module = pb.createModule(.{
            .root_source_file = pb.path("runtime/root.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });
    return b.addRunArtifact(tests);
}

/// An absolute path to a file inside a builder's source tree. `pathFromRoot`
/// can return a relative path when the build root is relative, and the spago
/// step changes cwd, so resolve against the process cwd here at configure time.
fn absFromRoot(b: *std.Build, sub_path: []const u8) []const u8 {
    const joined = b.pathFromRoot(sub_path);
    if (std.fs.path.isAbsolute(joined)) return joined;
    const cwd = std.process.currentPathAlloc(b.graph.io, b.allocator) catch
        @panic("purzig: cannot resolve the current directory");
    return std.fs.path.join(b.allocator, &.{ cwd, joined }) catch @panic("OOM");
}
