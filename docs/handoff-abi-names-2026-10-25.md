# Handoff — abi: named modules, k arguments, `Status.error`

Branch: `agent/01a1757c-…` (from `agent/01a17574-…`). Issue #21, completes **C**.

## The build-script error and why the manifest read was dropped

The branch did not compile:

```
build/purzig.zig:319:24: error: root source file struct 'fs' has no member named 'cwd'
      const text = std.fs.cwd().readFileAlloc(
```

**Zig 0.16 removed `std.fs.cwd()`.** Filesystem and process work moved behind
`std.Io`, and a build script has no convenient `Io` to hand. There is no correct
workaround (`compat_fs`, `@embedFile` of a generated file, an absolute path are
all wrong for one reason or another), so the read is deleted rather than ported:
`build/purzig.zig` now reads **no file at configure time**.

This is not a regression. A configure-time read of a codegen output was already
a race: the manifest is written by *this* build's `spago build` step, i.e.
after configure, so the names a configure ever saw were those of the previous
run — and on a clean checkout there were none at all.

### How module names reach the build helper now: an explicit list

Not JSON, not a generated `modules.zig` — the caller states them:

```zig
const lib = purzig.addLibrary(b, .{
    .name = "example",
    .main_module = "Main",
    .extra_modules = &.{"Api"},   // <-- new
    .project = b.path("example"),
    .target = target,
    .optimize = optimize,
});
const api = lib.module("Api");     // <-- new accessor, non-optional
```

Why this beats generating `output-zig/modules.zig` that the helper `@import`s:
the helper would still have to create a module over that file *before* it
exists, and would then be guessing at names it cannot verify — the same
staleness, one layer down. A declared list cannot disagree with what the caller
imports, needs no new artifact in the emitter's contract (`compiler/src/**` is
untouched), and is one line at the call site.

## Exact API change in `build/purzig.zig`

```zig
pub const Options = struct {
    name: []const u8,
    main_module: []const u8 = "Main",
    /// NEW. Further modules to expose by name, on top of `main_module`.
    extra_modules: []const []const u8 = &.{},
    project: ?std.Build.LazyPath = null,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    purzig: ?*std.Build.Dependency = null,
};

pub const LibraryArtifacts = struct {
    modules: Modules,                    // built from `extra_modules`
    codegen: *std.Build.Step.Run,
    runtime: *std.Build.Module,
    module_main: *std.Build.Module,      // still `main_module`, unchanged
    pub fn module(self: LibraryArtifacts, name: []const u8) *std.Build.Module;
};
```

- Each name in `extra_modules` becomes a module over
  `b.path("<project>/output-zig/<Name>.zig")` with `addImport("runtime", runtime)`,
  exactly like the existing `module_main`: same `createModule`, same target and
  optimize, same runtime binding.
- The path need not exist at configure time. Creating a module reads nothing;
  Zig resolves the file when the build runs. A listed-but-unemitted name fails as
  a missing root source file at **compile** time, in the caller's import chain.
- `module(name)` returns the module and **panics** if `name` was not listed in
  `extra_modules` — a caller bug, not consumer input.
- `module_main` still points at `main_module`, so `addExecutable`,
  `example/library/libmain.zig` and `test-library` compile unchanged.
- Deleted: `readModuleNames`, the whole `std.json.parseFromSlice` call, and the
  `std.json` dependency it needed (`std` is still used for `std.Build`,
  `std.mem.eql`, `std.builtin`; only the JSON usage went). `grep -n 'manifest'
  build/purzig.zig` now matches only a doc comment saying the backend writes it.

## `runtime/abi.zig`

Already correct on this branch and left semantically identical:
`Status = enum { ok, error }` (no `invalid`), `pub fn call(f, ins, out) Reply`
applying `ins` in order with each element copied into the runtime allocator
first, and `callBytes(f, in)` as a thin wrapper over `call`. Module docs state
that the status reports **transport, never application meaning**.

## How `test-abi-multi` wires the `Api` module (`build.zig`)

- `multi_lib = purzig.addLibrary(b, .{ …, extra_modules = &.{"Api"} })`, ordered
  after `build_compiler` and after `app.codegen` (all library-shaped runs share
  the one `example/` spago project directory).
- `api_module = multi_lib.module("Api")`; `multi_root.addImport("api", api_module)`
  and `addImport("runtime", multi_lib.runtime)`.
- Root `example/abi/abi_multi.zig` does `const f = try api.@"ps.pair"();`
  (`ps.pair` is a thunk and must be called), then
  `rt.abi.call(f, &.{ "ab", "cd" }, &out)` into a caller-owned
  `rt.abi.Reader`, printing `rt.abi.bytes(reply, &out)` plus a newline.
- `check_multi.expectStdOutEqual("abcd\n")`; the step is `test-abi-multi` and is
  added to `test`. `test-abi` is untouched and still asserts `hi!`.

Fixtures: `example/src/Api.purs` (`module Api`, `pair a b = a <> b`) and
`example/abi/abi_multi.zig` are new. `Main.purs` is untouched, so `main`'s
`Hello, Zig` output is unchanged.

## UNVERIFIED

**Nothing below was executed.** No toolchain, no build, no container was run in
this environment; everything here is a read-and-edit change. Every acceptance
criterion is therefore **UNVERIFIED**:

1. `zig build test-abi` → 0, stdout `hi!` — **UNVERIFIED**
2. `zig build test-abi-multi` → 0, stdout `abcd` — **UNVERIFIED** (also
   UNVERIFIED that `spago` now emits `example/output-zig/Api.zig`, i.e. that
   `Api.purs` is picked up by the existing `spago.yaml` sources glob)
3. `zig build test-runtime` → 0 with the abi tests (ok, throw, non-String,
   1/2/0 args, input copying) — **UNVERIFIED**
4. `grep -n 'invalid' runtime/abi.zig docs/codegen.md` empty and
   `grep -n 'Status.error'` present — **CHECKED locally, matches**
5. `zig build test-e2e` → `Hello, Zig`; `test-library`; wasm32-freestanding
   ReleaseSmall installing a `.wasm` starting `00 61 73 6d` — **UNVERIFIED**
6. `grep -in 'freenet|bincode|contract|validate_state' runtime/abi.zig` empty —
   **CHECKED locally, no match**
7. diff limited to `build/purzig.zig`, `runtime/abi.zig`, `build.zig`,
   `example/src/Api.purs`, `example/abi/`, `docs/` — the working tree also
   carries a pre-existing unrelated modification to `tools/mkpackageset.sh`
   that this change did **not** make and does **not** stage.

Also **UNVERIFIED**: that the build script compiles under Zig 0.16 (the error
site is gone — no `std.fs` use remains — but no compiler was run), and that
`Runtime/abi.zig`'s doc claim about `callBytes`'s 64 KiB buffer still holds on a
freestanding target.

### The command that settles it

```
zig build test-runtime && zig build test-abi && zig build test-abi-multi && zig build test-library \
  && zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```
