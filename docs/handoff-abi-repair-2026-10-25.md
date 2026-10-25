# Handoff — ABI repair: any module, k arguments, `Status.error`

Date: 2026-10-25 (branch `agent/01a17574-7845-e72a-d86f-f2e888d5b2e2`, repairing
the commit that completed #21)

The previous attempt left three things undone: `build/purzig.zig` did not
compile, the fixture did not exist, and the `abi` unit tests had been deleted.
This repair works from the **actual compiler error**, not from a re-read of the
issue.

## 1. The Zig ordering rule (the actual error)

```
build/purzig.zig:109:9: error: declarations are not allowed between container fields
build/purzig.zig:96:5: note: field before declarations here:  modules: Modules,
build/purzig.zig:117:5: note: field after declarations here:  codegen: *std.Build.Step.Run,
```

A Zig `struct`/`union`/`enum` container takes **all fields first, then all
declarations**. `LibraryArtifacts` had `pub fn module(...)` sitting between the
`modules` and `codegen` fields, which is not a style problem — it is a hard
parse/analyse error.

The whole struct was reordered rather than the one line moved:

`modules` → `codegen` → `runtime` → `module_main` → `pub fn module`.

Two follow-on fixes were required by that reorder, and neither was cosmetic:

- `module` was a **field** before and is a **declaration** now, so both callers
  in `build.zig` (`lib.module`, `abi_lib.module`) had to become
  `lib.module_main` / `abi_lib.module_main`. Left as-is they would pass a
  `fn` value to `addImport`.
- `module_main` was `?*std.Build.Module`; it is now `*std.Build.Module`, matching
  the issue's signature and the fact that `addCodegen` always creates it
  (`addExecutable` needs it on a clean checkout, before any manifest exists).

`Modules` (the name→module list, with its `get` decl) already had its field
first; it was checked and left alone. No other container in the file carries a
declaration between fields.

## 2. How module names reach the build helper: `std.json`, at configure time

Chosen: **`std.json` in the build script**, parsing
`<project>/output-zig/manifest.json`'s `modules[]` (`readModuleNames`), and
creating one `*std.Build.Module` per name with `runtime` bound.

Why not the generated `output-zig/modules.zig` alternative: it would need the
same configure-time file read to `@import` it, plus an emission change in
`compiler/src/**`, which this issue forbids. One parser call is less surface and
less to keep in sync with the backend.

Consequences, stated plainly:

- The read happens when the build **script configures**. A manifest written by a
  later `spago build` is not seen until the next configure. This is inherent to
  configure-time reads, not a bug in the lookup.
- On the very first configure of a clean checkout the list is therefore empty
  and `module(name)` answers `null`. `build.zig`'s `test-abi-multi` step
  tolerates that by falling back to the one path the convention guarantees,
  `output-zig/<Name>.zig` with the runtime bound, so a clean `zig build
  test-abi-multi` still works; on any later configure the manifest branch is the
  one taken, which is the lookup this issue asks to prove.

## 3. `call`, and its 0/1/k behaviour

```zig
pub const Status = enum { ok, error };
pub const Reader = struct { buf: []u8, len: usize = 0 };
pub const Reply  = struct { status: Status, bytes: []const u8 };

pub fn call(f: Value, ins: []const []const u8, out: *Reader) Reply
pub fn bytes(reply: Reply, out: *const Reader) []const u8
pub fn callBytes(f: Value, in: []const u8) Reply   // thin wrapper over call
```

- `ins.len == 0`: nothing is applied; `f` **is** the result (a `String`-valued
  constant). Legal, tested.
- `ins.len == 1`: applied once.
- `ins.len == k`: applied k times **in order** through `rt.apply`, which is the
  nested-`apply` chain the generated code writes for an application node.
- Every element is **copied** into the runtime allocator before the callee sees
  it; the caller may drop all of them immediately after `call` returns.
- `out.buf` is the caller's: written, never freed, never retained; `out.len` is
  the length written. An out-sink was kept (not dropped) because a wasm host
  owns its linear memory and should not receive memory it can neither free nor
  size.
- Not applicable with `ins.len` arguments (an `Int`, or a 2-arg function applied
  once) → panic inside `rt.apply`: a caller bug, not consumer input. `out.buf`
  too small → panic; the reply is never silently truncated.
- `callBytes` allocates one 64 KiB buffer, calls `call` with `&.{in}`, and
  re-points `Reply.bytes` at a runtime-owned copy on `ok`, so its old
  `ok ⇒ bytes` contract is unchanged for existing callers.

## 4. How `Status.error` is produced

Exactly two transport conditions, both leaving a reason in `Reply.bytes`:

1. the callee raised — `apply` returns `error.PsException`, the reason is taken
   with `takeError()`; a thrown `String` is reported verbatim (copied into the
   runtime allocator), a thrown non-`String` reports
   `"PureScript exception with a non-String value"`;
2. the callee returned a non-`String` — reason
   `"PureScript function returned a non-String value"`.

The docs now say explicitly that the status reports **transport, never
application meaning**: `"no"` is `ok`, and a reason is a message, not an error
code. What the bytes mean is the consumer's business. `grep -n invalid
runtime/abi.zig docs/codegen.md` is empty (`invalidates` in the old codegen
prose was reworded too); `grep -n 'Status.error' runtime/abi.zig` hits the docs,
`call`'s doc line and the tests.

## 5. The two-buffer wiring in `build.zig`

New step `test-abi-multi`, added to `test`, with `test-abi` untouched:

```zig
const multi_lib = purzig.addLibrary(b, opts);
multi_lib.codegen.step.dependOn(&build_compiler.step);
multi_lib.codegen.step.dependOn(&app.codegen.step);   // same `example/` spago build

const api_module = multi_lib.module("Api") orelse blk: { /* output-zig/Api.zig fallback */ };

const multi_root = b.createModule(.{ .root_source_file = b.path("example/abi/abi_multi.zig"), ... });
multi_root.addImport("api", api_module);          // the module handle, by name
multi_root.addImport("runtime", multi_lib.runtime);

const check_multi = b.addRunArtifact(multi_probe);
check_multi.expectStdOutEqual("abcd\n");
```

The root, `example/abi/abi_multi.zig`, does the consumer's side:

```zig
const f = try api.@"ps.pair"();                    // decls are thunks
var buf: [64]u8 = undefined;
var out: rt.abi.Reader = .{ .buf = &buf };
const reply = rt.abi.call(f, &.{ "ab", "cd" }, &out);
switch (reply.status) { .ok => rt.writeLine(rt.abi.bytes(reply, &out)), .error => rt.writeLineErr(reply.bytes) };
```

`Api` is a **new, non-`Main`** module (`example/src/Api.purs`,
`pair a b = a <> b`), so the step proves three things at once: a module reached
by name, a two-argument function, two independent buffers.

## 6. Tests in `runtime/abi.zig` (restored)

The previous commit deleted all of them. Restored, covering the listed matrix:
`ok` with 1 arg / 2 args / 0 args, error-from-throw (String and non-String),
error-from-non-String return, `call` copying **every** input (two temps
scribbled after the call), the callee seeing a copy rather than the caller's
buffer, and `callBytes` as `call` with one buffer (including error pass-through).

## 7. Verification

**No toolchain in this environment.** No `zig`, no `purs`, no `spago`, no
`node`, nothing installed, no build and no test executed. Claiming a green
build here would be a lie.

What I *did* run, and what it showed:

- `git status --short` / `git diff --stat`: changes are confined to
  `build.zig`, `build/purzig.zig`, `runtime/abi.zig`, `docs/codegen.md`,
  `example/src/Api.purs`, `example/abi/abi_multi.zig`. `tools/mkpackageset.sh`
  shows a **pre-existing mode-only change** that was in the worktree before this
  branch; I did not touch it. `compiler/dist/bundle.js` was not regenerated or
  hand-edited.
- `grep -n 'invalid' runtime/abi.zig docs/codegen.md` → no hits (criterion 4,
  first half). `grep -n 'Status.error' runtime/abi.zig` → hits (second half).
- `grep -in 'freenet\|bincode\|contract\|validate_state' runtime/abi.zig` → no
  hits (criterion 6).
- Read the full `LibraryArtifacts`/`Modules` structs and confirmed no remaining
  declaration-between-fields (criterion: the actual compile error).

**UNVERIFIED — everything that needs a compile or a run:**

1. `zig build test-abi` exits 0 and prints exactly `hi!`.
2. `zig build test-abi-multi` exits 0 and prints exactly `abcd`.
3. `zig build test-runtime` exits 0 and the seven `abi` tests pass.
4. `zig build test-e2e` exits 0 with stdout exactly `Hello, Zig`;
   `zig build test-library` exits 0.
5. `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` exits 0 and
   the installed `.wasm` starts `00 61 73 6d`. Nothing added here touches
   `std.Io`, a process or a console: `abi.zig` allocates only through
   `apply_mod.alloc()` and the fixture is native-only, so the freestanding graph
   is unchanged — but that is reasoning, not a run.
6. **New `LazyPath.getPath(b)` call** in `readModuleNames` (Zig 0.16 is the
   pinned minimum). `project.path(b, ...)` is pre-existing and was already
   compiling; `getPath` is newly introduced here and is the single most likely
   build-script breakage if the 0.16 `std.Build` API differs. If it fails, the
   fix is local to that one line.
7. `std.json.parseFromSlice` with the local `Manifest` struct and
   `.ignore_unknown_fields = true` at 0.16 (the arena from `Parsed` is
   deliberately not deinited; the copied names are what the caller keeps).
8. That `spago build` emits `Api.zig` for a module nothing imports — it compiles
   every module under `src/`, and `Api` has no foreign imports, so this is
   expected but not observed.

## 8. The one command (needs a toolchain)

```
zig build test-runtime && zig build test-abi && zig build test-abi-multi && zig build test-library \
  && zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

plus `zig build test-e2e` for criterion 5's stdout check.
