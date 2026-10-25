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
//!      the shim once per build. The backend writes `output-zig/<Module>.zig`
//!      beside the project, and copies each package's `<Module>.zig` FFI in as
//!      `<Module>.ffi.zig` itself -- the build system is not involved in that.
//!      It also writes `output-zig/manifest.json`, describing the modules it
//!      produced. It writes no program.
//!
//!   3. `output-zig/<main_module>.zig` is wrapped in a Zig module with
//!      `runtime` bound, so that a root importing it needs no other wiring.
//!      That module is `LibraryArtifacts.module`, and it is the module
//!      `addExecutable` imports under the fixed name `purs_main`. Every OTHER
//!      module the run emitted is reachable the same way through
//!      `LibraryArtifacts.module(name)`, with the name taken from the manifest's
//!      `modules[]` (see `LibraryArtifacts`).
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
    /// The same module as `module(opts.main_module)`, when the manifest already
    /// lists it; kept as a field so existing callers keep compiling. Never
    /// null: `addCodegen` always creates it, manifest or not, because
    /// `addExecutable` needs it on a clean checkout before any manifest exists.
    module_main: *std.Build.Module,

    /// The Zig module for a generated PureScript module, `runtime` bound, or
    /// `null` when the package has no module of that name.
    ///
    /// ```zig
    /// const api = lib.module("Api") orelse @panic("no Api");
    /// root.addImport("api", api);
    /// ```
    ///
    /// Names come from `output-zig/manifest.json`'s `modules[]`, read at
    /// configure time with `std.json` -- not hand-rolled, and not by globbing
    /// `output-zig/`, which does not exist yet on a clean checkout.
    pub fn module(self: LibraryArtifacts, name: []const u8) ?*std.Build.Module {
        return self.modules.get(name);
    }
};

/// Every generated module of one package, by PureScript module name. A flat
/// list rather than a map: a package has tens of modules, lookups happen once
/// per consumer at configure time, and a list keeps the type printable.
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

    // ---- 3. the generated modules ----------------------------------------

    // Every module the run emitted, by PureScript module name, from the
    // manifest's `modules[]`. `std.json`, not a hand-rolled scan: the manifest
    // is the backend's contract and its rows carry strings with escapes
    // (`Data.Maybe`), so a real parser is both shorter and less likely to be
    // wrong. It is read when the build SCRIPT configures, in purzig's own
    // builder `pb` -- not when the user's build runs.
    //
    // A missing manifest means no codegen has run yet, so the names are not
    // known: the list is empty and `module(name)` answers null until the next
    // configure. `main` (below) is still created, because `addExecutable`
    // needs it on a clean checkout before any manifest exists.
    const names = readModuleNames(b, project) orelse &.{};

    const mods = b.allocator.alloc(*std.Build.Module, names.len) catch @panic("purzig: out of memory");
    for (names, 0..) |name, i| mods[i] = moduleFor(b, project, opts, runtime, name);

    const main = moduleFor(b, project, opts, runtime, opts.main_module);

    return .{
        .codegen = codegen,
        .runtime = runtime,
        .main = main,
        .modules = .{ .names = names, .mods = mods },
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

/// The `modules[]` names from `<project>/output-zig/manifest.json`, or null
/// when the file is not there (nothing has run codegen yet).
///
/// Read at the moment this build script is CONFIGURED, which is the only moment
/// a Zig build script can read a file. A manifest written by a later codegen
/// run is therefore not seen until the next configure -- true of any
/// configure-time read of a generated file. That is also why the file is only
/// ever read for the module NAMES: a stale name can at worst name a file that
/// does not exist, and the compile says so.
fn readModuleNames(
    b: *std.Build,
    project: std.Build.LazyPath,
) ?[]const []const u8 {
    const manifest = std.fs.path.join(b.allocator, &.{
        project.getPath(b), "output-zig", "manifest.json",
    }) catch @panic("purzig: out of memory");

    const text = std.fs.cwd().readFileAlloc(
        b.allocator,
        manifest,
        8 * 1024 * 1024,
    ) catch return null;

    const Manifest = struct {
        modules: []const struct { name: []const u8 } = &.{},
    };

    // `std.json`, not a hand-rolled scan: the rows carry strings (`Data.Maybe`)
    // and the shape is the backend's to change, so a real parser is shorter and
    // tells us when it disagrees. Unknown keys (`main_module`, `main_export`,
    // `file`, `ffi`) are ignored: the helper needs the names only.
    const parsed = std.json.parseFromSlice(Manifest, b.allocator, text, .{
        .ignore_unknown_fields = true,
    }) catch @panic("purzig: output-zig/manifest.json is not valid JSON");

    const names = b.allocator.alloc([]const u8, parsed.value.modules.len) catch
        @panic("purzig: out of memory");
    for (parsed.value.modules, 0..) |row, i| names[i] = row.name;
    return names;
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
