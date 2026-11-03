//! The public build API of purzig. This is the only file a downstream user's
//! `build.zig` imports, and everything it needs to know about how a PureScript
//! program becomes a native binary is here.
//!
//! There are two shapes and they share their first steps:
//!
//!   * `addExecutable` -- a whole program. Codegen, then the shipped entry text
//!     `entry/entry.zig` rooted as an executable that imports the module
//!     exporting `main` under the fixed name `purs_main`.
//!   * `addLibrary` -- the same codegen, with no decision about a program. It
//!     hands back the generated module `output-zig/<main_module>.zig` with the
//!     runtime bound, and the caller decides what to root at it: its own
//!     `main`, a test harness, a wasm host, or nothing at all.
//!
//! Both shapes start here:
//!
//!   1. A `purzig` executable must exist on PATH, because the user's
//!      `spago.yaml` says `backend: { cmd: purzig }` and spago resolves that
//!      name itself. `spago.yaml` is static text and cannot interpolate a path
//!      that only the Zig build knows, so a one-line shim is generated into the
//!      cache and that directory is prepended to PATH for the spago step alone.
//!      Nothing is installed anywhere the user can see, and there is no global.
//!
//!   2. `spago build` runs, which compiles PureScript to corefn and then execs
//!      the shim once per build. It runs through `build/purzig-run.sh`, which
//!      captures the command's stdout and stderr MERGED and prints all of it,
//!      between markers, when the step fails -- and names the phase: a
//!      type-check failure, a backend failure, a backend that could not be
//!      reached at all, or a missing artifact (issue #31). A successful run
//!      prints nothing, so a green build's log is as quiet as it was. The
//!      backend writes `output-zig/<Module>.zig` beside the project, and copies
//!      each package's `<Module>.zig` FFI in as `<Module>.ffi.zig` itself -- the
//!      build system is not involved in that. It also writes
//!      `output-zig/manifest.json`, describing the modules it produced. It
//!      writes no program.
//!
//!   3. `output-zig/<main_module>.zig` is wrapped in a Zig module with
//!      `runtime` bound, so that a root importing it needs no other wiring.
//!      That module is `LibraryArtifacts.module`, and it is the module
//!      `addExecutable` imports under the fixed name `purs_main`. Every OTHER
//!      module the run emitted is reachable the same way through
//!      `LibraryArtifacts.module(name)`, for the names the caller listed in
//!      `Options.extra_modules` (see `LibraryArtifacts`). Names are supplied,
//!      not discovered: Zig 0.16 has no build-script filesystem, so nothing is
//!      read at configure time.
//!
//! Only `addExecutable` goes further: it writes the entry text (a file shipped
//! in this package, `entry/entry.zig`, embedded at build-script compile time)
//! into the build cache with `b.addWriteFiles()`, roots an executable at it and
//! installs it. The entry is not a template: no substitution happens, so the
//! file is the program, byte for byte. `addLibrary` writes no entry file and
//! installs nothing.
//!
//! Step 2 depends on step 1 explicitly. The modules do not exist on a clean
//! checkout, so without that edge the first build races.
//!
//! POSIX only: the shim is `/bin/sh`. Windows would need a `.cmd` variant.

const std = @import("std");

pub const Options = struct {
    /// Name of the produced binary. `addLibrary` ignores it: a library installs
    /// nothing.
    name: []const u8,

    /// PureScript module that exports `main`. It does not name the root source
    /// file: `addExecutable` roots the executable at the shipped entry, and
    /// `addLibrary` uses the name only to pick which generated module becomes
    /// `LibraryArtifacts.module`. Either way the module is reached through an
    /// import, under whatever name the importing root chooses -- `purs_main` in
    /// the entry.
    main_module: []const u8 = "Main",

    /// `addLibrary` only: further PureScript modules of the package to expose
    /// by name through `LibraryArtifacts.module(name)`, on top of
    /// `main_module`. `Example`: `&.{ "Api", "Data.Maybe" }`.
    ///
    /// Explicit, because the build script must not read `output-zig/` at
    /// configure time: Zig 0.16 removed `std.fs.cwd()`, so there is no
    /// supported way for a build script to read a generated file, and a
    /// configure-time read of a codegen output is a race anyway. A name whose
    /// file does not exist is a COMPILE error when something compiles the
    /// module, which is both later and more accurate. `addExecutable` ignores
    /// this field.
    extra_modules: []const []const u8 = &.{},

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

/// What `addLibrary` hands back. No executable, no entry file, nothing
/// installed: a caller compiles its own root against `module`.
pub const LibraryArtifacts = struct {
    // Zig requires every container FIELD before any DECLARATION, so the order
    // below is: fields (`modules`, `codegen`, `runtime`, `module_main`), then
    // `module`. Moving `module` up between two fields is exactly the error
    // "declarations are not allowed between container fields".

    /// The generated modules of the package, keyed by PureScript module name
    /// (`main_module`, `Api`, `Data.Maybe`, ...) and owned by this struct.
    modules: Modules,

    /// The `spago build` invocation, exactly as `Artifacts.codegen`. A caller
    /// rooting its own artifact at `module` has to order that artifact after
    /// this step itself (`artifact.step.dependOn(&lib.codegen.step)`), because
    /// the generated modules do not exist on a clean checkout.
    codegen: *std.Build.Step.Run,

    /// The Zig runtime module the generated code is compiled against, already
    /// bound as `runtime` on `module`. Exposed so a caller can bind the same
    /// one, rather than a second copy built with the same options, on its own
    /// root.
    runtime: *std.Build.Module,

    /// A module over `output-zig/<opts.main_module>.zig` with `runtime` bound.
    /// This is the library: `@import("purs_main")` in a root that binds it
    /// under that name, or any other name the caller prefers. It exports the
    /// compiled PureScript module and nothing else -- no `main` decl, so a root
    /// that wants a program supplies its own.
    ///
    /// Kept as a field, not looked up by name, so existing callers (and
    /// `addExecutable`, which needs it before any module list exists) compile
    /// unchanged. Never null, and always over `opts.main_module`, whether or
    /// not that name also appears in `extra_modules`.
    module_main: *std.Build.Module,

    /// The Zig module over `output-zig/<name>.zig` with `runtime` bound. A
    /// `name` not listed in `Options.extra_modules` is a caller bug and panics
    /// at configure time -- callers only ever ask for names they listed.
    ///
    /// ```zig
    /// const lib = purzig.addLibrary(b, .{ ..., extra_modules = &.{"Api"} });
    /// const api = lib.module("Api");
    /// root.addImport("api", api);
    /// ```
    ///
    /// The file is resolved when the build RUNS, so a listed name that no
    /// codegen produced fails at compile time with a missing-file error -- not
    /// here, and not as a wrong build. That is why the names are supplied
    /// rather than discovered.
    pub fn module(self: LibraryArtifacts, name: []const u8) *std.Build.Module {
        return self.modules.get(name) orelse @panic("purzig: module not listed in Options.extra_modules");
    }
};

/// The modules the caller asked for, by PureScript module name. A flat list
/// rather than a map: a package has tens of modules, lookups happen once per
/// consumer at configure time, and a list keeps the type printable.
///
/// The names are `Options.extra_modules` verbatim -- nothing is discovered, so
/// nothing can disagree with what the codegen will emit.
pub const Modules = struct {
    names: []const []const u8,
    mods: []const *std.Build.Module,

    pub fn get(self: Modules, name: []const u8) ?*std.Build.Module {
        for (self.names, self.mods) |n, m| {
            if (std.mem.eql(u8, n, name)) return m;
        }
        return null;
    }
};

/// The program, as source text.
///
/// This is the driver the PureScript emitter used to append to the module that
/// exports `main`, moved out of this build script into a shipped file and
/// embedded here at build-script compile time: same `main` signature, same
/// runtime init call, same `runEffect` calls, same comptime freestanding branch
/// with its `@trap()` fallback, byte for byte. Nothing observable changes: same
/// stdout, same exit status, same artifacts. A downstream project's `test-e2e`
/// asserts the program's exact stdout, so this text is not to be "improved".
///
/// Nothing is substituted into it. `addExecutable` writes these bytes into the
/// build cache as `purzig_entry.zig`; the file, not a template, is the program.
///
/// The path is `../entry/entry.zig` rather than `entry/entry.zig` because Zig
/// resolves `@embedFile` against the directory of the file that contains the
/// call (`build/`), not against the build root where `entry/` sits.
///
/// Why the file exists at all: the driver is a convention -- how a compiled
/// `main` is invoked -- and a convention buried in a build script cannot be
/// read, reviewed or reused. `entry/entry.zig` is readable on its own.
const entry_source = @embedFile("../entry/entry.zig");

/// The steps `addExecutable` and `addLibrary` share: the shim, the package set,
/// `spago build`, and the module over `output-zig/<main_module>.zig`.
const Codegen = struct {
    /// The `spago build` run step.
    codegen: *std.Build.Step.Run,

    /// The runtime module built for `opts.target` / `opts.optimize`.
    runtime: *std.Build.Module,

    /// The module exporting `main` (`opts.main_module`), `runtime` bound. No
    /// program: a root that imports it decides what, if anything, to call.
    main: *std.Build.Module,

    /// Every emitted module, by PureScript module name, `runtime` bound.
    modules: Modules,
};

fn addCodegen(b: *std.Build, opts: Options) Codegen {
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

    // ---- 1. the shim, the set, and the manual-run wrapper ------------------

    const setup = addProjectSetup(b, opts);

    // ---- 2. codegen -------------------------------------------------------

    // Wrapped in `addReportedCommand`, so a FAILED `spago build` prints purs's
    // (or the backend's) own output in full and says which phase failed. A
    // successful one prints nothing: the quiet-on-success rule is what lets a
    // green build's log stay as it is.
    const codegen = addReportedCommand(b, .{
        .label = "spago build",
        .project = project,
        .main_module = opts.main_module,
        .argv = &.{ "spago", "build" },
        .purzig = opts.purzig,
    });
    codegen.step.dependOn(setup);

    // ---- 3. the generated modules ----------------------------------------

    // No generated file is read here. Zig 0.16 has no build-script filesystem
    // (`std.fs.cwd()` is gone), so module names cannot be discovered at
    // configure time; the caller names them in `opts.extra_modules`. Creating
    // a module never touches the generated sources, so a missing file is a
    // compile error where the module is actually compiled -- never a
    // build-script one.
    const mods = b.allocator.alloc(*std.Build.Module, opts.extra_modules.len) catch
        @panic("purzig: out of memory");
    for (opts.extra_modules, 0..) |name, i| mods[i] = moduleFor(b, project, opts, runtime, name);

    const main = moduleFor(b, project, opts, runtime, opts.main_module);

    return .{
        .codegen = codegen,
        .runtime = runtime,
        .main = main,
        .modules = .{ .names = opts.extra_modules, .mods = mods },
    };
}

/// The module over `output-zig/<name>.zig` with `runtime` bound. Creating a
/// module never reads the generated sources; only COMPILING it does, so a
/// missing file is a compile error at that point and never a build-script one.
/// `name` is a PureScript module name and the file is named after it verbatim
/// (`Data.Maybe` -> `Data.Maybe.zig`), so this is the whole mapping.
fn moduleFor(
    b: *std.Build,
    project: std.Build.LazyPath,
    opts: Options,
    runtime: *std.Build.Module,
    name: []const u8,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = project.path(b, b.fmt("output-zig/{s}.zig", .{name})),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    m.addImport("runtime", runtime);
    return m;
}

/// The absolute directory the generated `purzig` shim is written to. Absolute
/// because the shim is reached through `PATH` from a step whose cwd is the
/// user's project, not this build root.
fn shimDir(b: *std.Build) []const u8 {
    return absFromRoot(b, ".zig-cache/purzig-bin");
}

/// Everything that has to be true on disk before `spago build` can run, as one
/// step -- exported so a check can PREPARE a project without running the build
/// (`build.zig`'s `test-diagnostics` does exactly that for its fixtures).
///
/// Three things, all regenerated on every build:
///
///   * `.zig-cache/purzig-bin/purzig` -- the one-line shim that execs the
///     bundle. `spago.yaml` says `backend: { cmd: purzig }` and cannot
///     interpolate a path only the Zig build knows, so the shim is found by
///     NAME, through a `PATH` entry added to the `spago build` step alone;
///   * `<project>/.purzig/packages.json` -- purzig's package set, copied from
///     the dependency, so the set belongs to the tag pinned in
///     `build.zig.zon` and the user's config names one fixed path. A missing
///     set is tolerated (`|| true`): the in-repo fixture resolves packages by
///     path instead;
///   * `<project>/.purzig/purzig` and `<project>/.purzig/spago` -- the same
///     shim again, and a wrapper that puts its directory on `PATH` and then
///     runs the real `spago`. This is the answer to "a hand run disagrees with
///     a purzig run on the same tree" (issue #31, part 3):
///     `<project>/.purzig/spago build` is the manual invocation that matches,
///     and the failure reporter NAMES this wrapper when `spago build` failed
///     because no backend was reachable at all -- which an unexplained
///     `Failed to build with backend purzig` never did.
///
/// `packages.json` comes from purzig's own tree (`pb`), the shim directory from
/// the caller's (`b`): the set must be the pinned one, the cache is the
/// caller's.
pub fn addProjectSetup(b: *std.Build, opts: Options) *std.Build.Step {
    const pb = if (opts.purzig) |dep| dep.builder else b;
    const project = opts.project orelse b.path(".");
    const bin_dir = shimDir(b);
    const bundle = absFromRoot(pb, "compiler/dist/bundle.js");

    // Both of these run through the same reporter as every other command
    // purzig runs: a shim that cannot be written, or a package set that cannot
    // be copied, prints what `sh` said instead of only "failed command".
    //
    // Written to a temporary name and renamed: every codegen run in a build
    // shares this directory, so two steps may write the shim at the same time.
    // A rename is never observed half-written; a `>` in place can be.
    const shim = addReportedCommand(b, .{
        .label = "purzig backend shim",
        .project = project,
        .argv = &.{
            "sh", "-c",
            b.fmt(
                "set -e; mkdir -p '{s}'; " ++
                    "printf '#!/bin/sh\\nexec node \"{s}\" \"$@\"\\n' > '{s}/purzig.tmp'; " ++
                    "chmod +x '{s}/purzig.tmp'; mv -f '{s}/purzig.tmp' '{s}/purzig'",
                .{ bin_dir, bundle, bin_dir, bin_dir, bin_dir, bin_dir },
            ),
            "sh",
        },
        .purzig = opts.purzig,
    });

    // POSIX sh only, positional arguments only: the project directory is this
    // step's cwd, so `$1` is purzig's `packages.json` and `$2` the bundle, and
    // no path has to be quoted into the script text.
    const setup_script: []const u8 =
        \\set -e
        \\mkdir -p .purzig
        \\cp "$1" .purzig/packages.json 2>/dev/null || true
        \\printf '#!/bin/sh\\nexec node "%s" "$@"\\n' "$2" > .purzig/purzig.tmp
        \\chmod +x .purzig/purzig.tmp
        \\mv -f .purzig/purzig.tmp .purzig/purzig
        \\printf '#!/bin/sh\\nPATH="%s:$PATH"\\nexport PATH\\nexec spago "$@"\\n' "$(pwd -P)/.purzig" > .purzig/spago.tmp
        \\chmod +x .purzig/spago.tmp
        \\mv -f .purzig/spago.tmp .purzig/spago
    ;

    const set = addReportedCommand(b, .{
        .label = "purzig project setup",
        .project = project,
        .argv = &.{
            "sh", "-c", setup_script, "sh",
            absFromRoot(pb, "packages.json"),
            bundle,
        },
        .purzig = opts.purzig,
    });
    set.step.dependOn(&shim.step);
    return &set.step;
}

/// How to run an external command so that a failure explains itself. See
/// `addReportedCommand`.
pub const ReportedCommand = struct {
    /// Name used in the markers and in the phase sentence: `spago build`.
    label: []const u8,

    /// Directory the command runs in, as for `Options.project`.
    project: std.Build.LazyPath,

    /// The command and its arguments, e.g. `&.{ "spago", "build" }`.
    argv: []const []const u8,

    /// When set, a run that EXITS 0 must still have produced
    /// `output-zig/<main_module>.zig`. The `missing artifact` phase exists
    /// because a backend that finishes cleanly can leave the build with
    /// nothing to compile, and the Zig error that follows names a file inside
    /// generated code rather than the cause.
    main_module: ?[]const u8 = null,

    /// Assertion mode, for a gate: the command is EXPECTED to fail, every
    /// `require` string and `require_re` expression must appear in the report,
    /// and the step succeeds only then. `build.zig`'s `test-diagnostics` uses
    /// it, so the text the gate asserts is the text a user reads -- same
    /// script, same phase names, same markers.
    expect_failure: bool = false,
    require: []const []const u8 = &.{},
    require_re: []const []const u8 = &.{},

    /// As `Options.purzig`: purzig's own tree is where the reporter and the
    /// bundle live, and a downstream caller's builder cannot see them.
    purzig: ?*std.Build.Dependency = null,
};

/// Run an external command through purzig's failure reporter
/// (`build/purzig-run.sh`).
///
/// The reporter merges the child's stdout and stderr -- in the order the child
/// wrote them -- into one file, and on failure prints the whole thing between
/// markers:
///
/// ```
/// --- purzig: `spago build` failed (exit 1) — output follows ---
/// purzig: type-check failure — purs rejected the source, ...
/// --- `spago build` output ---
/// [ERROR 1/1 ModuleNotFound] src/Main.purs:8:1
/// ...
/// --- end of `spago build` output ---
/// ```
///
/// Nothing is truncated. On success nothing is printed at all, which is the
/// other half of the contract: a green build's log does not change.
pub fn addReportedCommand(b: *std.Build, cmd: ReportedCommand) *std.Build.Step.Run {
    const pb = if (cmd.purzig) |dep| dep.builder else b;
    const reporter = absFromRoot(pb, "build/purzig-run.sh");

    const run = b.addSystemCommand(&.{ "sh", reporter });
    run.addArgs(&.{ "--label", cmd.label, "--shim-dir", shimDir(b) });
    if (cmd.main_module) |m| run.addArgs(&.{ "--main-module", m });
    if (cmd.expect_failure) run.addArg("--expect-failure");
    for (cmd.require) |needle| run.addArgs(&.{ "--require", needle });
    for (cmd.require_re) |re| run.addArgs(&.{ "--require-re", re });
    run.addArg("--");
    run.addArgs(cmd.argv);

    run.setCwd(cmd.project);
    // The shim is reached by NAME, because `spago.yaml` says `cmd: purzig`.
    run.addPathDir(shimDir(b));
    // spago writes into its own project tree, which Zig does not model.
    run.has_side_effects = true;
    // The build summary should name what failed (`run spago build`), not
    // `run sh`: a summary line is part of the diagnostic.
    run.setName(b.fmt("run {s}", .{cmd.label}));
    return run;
}

pub fn addExecutable(b: *std.Build, opts: Options) Artifacts {
    const gen = addCodegen(b, opts);

    // The program is written HERE, not by the emitter: `output-zig/` holds
    // modules only, and a module that also had to be the executable's root
    // would have to know which of them exports `main`. Written into the build
    // cache, so a codegen run leaves nothing in the project but modules. The
    // bytes are `entry/entry.zig` verbatim.
    const write_program = b.addWriteFiles();
    const program = write_program.add("purzig_entry.zig", entry_source);

    const root = b.createModule(.{
        .root_source_file = program,
        .target = opts.target,
        .optimize = opts.optimize,
    });
    root.addImport("runtime", gen.runtime);
    root.addImport("purs_main", gen.main);

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = root,
    });
    exe.step.dependOn(&gen.codegen.step);

    return .{ .exe = exe, .codegen = gen.codegen, .runtime = gen.runtime };
}

/// The same codegen path, minus the program: no entry file, no
/// `addExecutable`, nothing installed. The caller gets every generated module
/// with the runtime bound -- by PureScript name, through `module(name)` -- and
/// roots whatever it likes at it.
pub fn addLibrary(b: *std.Build, opts: Options) LibraryArtifacts {
    const gen = addCodegen(b, opts);
    return .{
        .codegen = gen.codegen,
        .runtime = gen.runtime,
        .modules = gen.modules,
        .module_main = gen.main,
    };
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
