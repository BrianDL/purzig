# Handoff: `wasm32-freestanding` reachability gate (issue #3)

**Date:** 2026-10-24
**Scope:** `sophos/purzig` issue #3 — make generated output build for
`wasm32-freestanding` by removing `std.Io` / `std.Io.Threaded` /
`std.process.Init` **reachability**, gated at comptime on
`builtin.target.os.tag == .freestanding`.
**Status:** change written, **not executed**. No zig, purs, spago or node was
available (and none was installed), so nothing below is a measured result.
Criteria 1–4 are **UNVERIFIED**.

---

## The one command

Run in the repository root (the example fixture builds through the public
helper, so this is the whole check):

```
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall && head -c 4 zig-out/bin/example | od -An -c
```

Expected last line, and the only thing that matters:

```
   \0   a   s   m
```

Notes for whoever runs it:

- `zig build` depends on `zig build compiler` (`spago bundle`), so the prebuilt
  `compiler/dist/bundle.js` is regenerated first. If you invoke the compile step
  some other way, regenerate the bundle first or you will be measuring the old
  template.
- Zig names installed wasm artifacts `example.wasm` in some versions. If
  `zig-out/bin/example` does not exist, `ls zig-out/bin/` and `head -c 4` the
  file that is there. Criterion 1 is about the four bytes, not the filename.
- Do **not** run criterion 3 with `-Dtarget=wasm32-freestanding`: `test-runtime`
  links `std.testing`, which needs an OS. The criteria are native for 2 and 3,
  freestanding only for 1 and 4.

---

## What changed

| file | change |
|---|---|
| `runtime/apply.zig` | the gate: `freestanding`, `unavailable()`, `ProcessInit`, native-only `host` namespace holding `io_inst`/`init`/`io`/`writeLine`/`writeLineErr`, plus `initAlloc`; one new test |
| `runtime/root.zig` | re-exports `freestanding`, `ProcessInit`, `initAlloc`; `init`/`io`/`writeLine`/`writeLineErr` stay declared for native |
| `compiler/src/Zig/Emit.purs` | the driver: `mainNative(init: rt.ProcessInit)`, `mainFreestanding`, `pub const main = …`, `runWithAllocator` |
| `docs/codegen.md` | "Entry point" section now documents what is emitted, plus the freestanding gate |
| `docs/handoff-freestanding-2026-10-24.md` | this file |
| `build/purzig.zig` | **unchanged**, deliberately — see "Deviations" |

`git diff --stat` shows `compiler/dist/bundle.js` and `tools/mkpackageset.sh`
with 0 insertions: those are mode-only changes (755→644) that predate this work.

---

## The comptime condition

One occurrence, in `runtime/apply.zig:33`:

```zig
pub const freestanding = builtin.target.os.tag == .freestanding;
```

Everything else references it — `rt.freestanding` in the driver, `freestanding`
in the four runtime aliases. It is `builtin.target`, i.e. the *resolved* target,
so `-Dtarget=wasm32-freestanding` reaches the runtime through
`build/purzig.zig`'s existing `createModule(.{ .target = opts.target })` with no
new build option (the issue forbids one). `os.tag == .freestanding` also covers
`arm-freestanding` and friends. `wasm32-wasi` and `wasm32-emscripten` are
*not* `.freestanding`, so they keep today's driver: they have a process-ish host,
and they are untested here — out of scope, not deliberately blessed.

### Native vs freestanding, symbol by symbol

| symbol | native | freestanding |
|---|---|---|
| `rt.freestanding` | `false` | `true` |
| `rt.ProcessInit` | `std.process.Init` | `void` |
| `rt.init` | `host.init(io, allocator)`: stores the `Io`, calls `initAlloc` | `unavailable("rt.init")` → `@compileError` |
| `rt.initAlloc` | sets `alloc_inst` | sets `alloc_inst` (the whole entry) |
| `rt.alloc` | reads `alloc_inst` | identical |
| `rt.io` | `host.io()` | `unavailable("rt.io")` → `@compileError` |
| `rt.writeLine` / `writeLineErr` | `host.writeLine` → `std.Io.File.stdout/stderr` | `unavailable("rt.writeLine…")` → `@compileError` |
| `host` (private) | struct with `io_inst: ?std.Io`, `init`, `io`, `writeLine`, `writeLineErr` | `struct {}` — the declarations do not exist |
| emitted `main` | `mainNative` (unchanged body) | `mainFreestanding`: `@trap()` |
| emitted `runWithAllocator` | emitted, referenced by nothing | emitted, referenced by nothing |

`unavailable` (`runtime/apply.zig:40`) returns `noreturn` and is a
`@compileError`, so a stray freestanding reference fails with
`runtime: rt.writeLine does not exist on a freestanding target: there is no
process, no std.Io and no console; use initAlloc` instead of trapping at runtime.
Native behaviour is bit-for-bit the old one: `host.init` stores the same `Io` and
forwards the same arena allocator; `host.writeLine` is the old function body.

---

## Reachability sites

Sites that made `std.Io`/`std.process` reachable, and where each lives now. Line
numbers are this tree (old number in parentheses).

| site now | was | what |
|---|---|---|
| `runtime/apply.zig:57` | `apply.zig:17` | `var io_inst: ?std.Io = null` — now inside `host`, which is `struct {}` on freestanding |
| `runtime/apply.zig:59-62` | `apply.zig:25` | `host.init(io_value: std.Io, allocator)` — the only writer of `io_inst` |
| `runtime/apply.zig:64-66` | `apply.zig:36` | `host.io() std.Io` |
| `runtime/apply.zig:69` | `apply.zig:166` | `std.Io.File.stdout()` |
| `runtime/apply.zig:75` | `apply.zig:174` | `std.Io.File.stderr()` |
| `runtime/apply.zig:50` | — (new) | `std.process.Init`, the only `std.process` in the runtime, behind `if (freestanding)` |
| `runtime/apply.zig:96` | `apply.zig:25` | `pub const init = if (freestanding) unavailable(…) else host.init` |
| `runtime/apply.zig:106` | `apply.zig:36` | `pub const io = …` |
| `runtime/apply.zig:234,238` | `apply.zig:165,173` | `pub const writeLine` / `writeLineErr` |
| `runtime/root.zig:27,32,36,40,42,53,54` | `root.zig:24,26,37,38` (plus the new lines) | the re-exports: `freestanding`, `ProcessInit`, `init`, `initAlloc`, `io`, `writeLine`, `writeLineErr` |
| `compiler/src/Zig/Emit.purs:159` | `Emit.purs:149` | the driver's `main` parameter, now `rt.ProcessInit` |
| `compiler/src/Zig/Emit.purs:167,171` | — (new) | `mainFreestanding`, and the `pub const main` choice |

Reference chains, old and new.

**Old, the failure.** Two chains, both live on every target:

```
start (_start) → callMain → std.process.Init
                            └── std.Io.Threaded            lib/std/Io/Threaded.zig:81
                                 └── RandomFile            lib/std/Io/Threaded.zig:373
                                      ├── posix.system.getrandom  Threaded.zig:2064  ← error 1
                                      └── std.posix.IOV_MAX       posix.zig:90       ← error 2
```
```
Main.main → rt.runEffect → @"ps.main" → Effect.Console.log
                                        └── packages/purescript-console/src/Effect/Console.zig:31
                                             └── rt.writeLine → io() → std.Io.File.stdout()
                                                                  → std.Io → Io.Threaded
Main.main → rt.init → io_inst: ?std.Io
```

**New, freestanding.** `main` resolves to `mainFreestanding`, which references
only `@trap()`. `mainNative` is in the untaken branch of a comptime `if`, so it
is never referenced; `@"ps.main"`, `rt.init`, `rt.writeLine` and the console FFI
behind them are therefore never analysed, and `rt.freestanding` is `true`, so
`std.process.Init` is never resolved. Compiled graph: the driver's trap and
whatever the freestanding start code needs. Nothing else.

**New, native.** Unchanged: `main` → `mainNative` → `rt.init(init.io,
init.arena.allocator())` → `rt.runEffect(try @"ps.main"())`.

---

## Deliberately left reachable

1. **25 `@panic` sites outside `host`.** `apply.zig:102,116,157,170,179,190,206,
   219,226`; `value.zig:158,165,172,179,186,193,207,216,231,240,250`;
   `lazy.zig:52,77,99`; `marray.zig:32,34`. They are unreachable on freestanding
   for the only reason that matters here — the graph is empty — not because they
   were converted. This is the next blocker, and it is worth knowing before the
   host ABI work: Zig's default `panic` (the `Panic` default in
   `lib/std/builtin.zig`, ~lines 1203-1230 on master) is
   `std.debug.FullPanic(std.debug.defaultPanic)`, so *one* reachable `@panic` in
   a freestanding build drags `std.debug` in. Converting them to `@trap()` under
   the same `freestanding` flag is mechanical and is the first thing to do when
   `runWithAllocator` (or any host entry) becomes referenced.
2. **`runWithAllocator`** (`Emit.purs:176`). Emitted on every target, referenced
   by nothing, therefore never analysed. It is the seam a host will call, and
   the reason `initAlloc` exists. It is not `export`ed and there is no start
   symbol.
3. **`std.math.inf`, `std.mem.order`, `std.fmt.allocPrint`** in generated
   modules (the 53-module survey in the issue). Freestanding-safe and, like
   everything else below `ps.main`, unreferenced in a freestanding build.
4. **`build/purzig.zig:157`** `std.process.currentPathAlloc` — build-helper code
   running on the host at configure time. It never reaches `output-zig/` or the
   artifact.
5. **`compiler/dist/bundle.js`** still contains the old template text until
   `zig build compiler` runs. Not hand-edited, per the rules.

---

## Deviations and residual risks

**Deviation: the freestanding driver still declares `main`.** The issue asks for
"a driver without `std.process.Init` (and without an entry point)". The first
half is done. The second cannot be done in one target-agnostic file: Zig's start
code finds the entry through `@hasDecl(root, "main")` — a *name* check, on
master's `lib/std/start.zig` — and the single emitted `Main.zig` must declare that
name for native builds. So the file declares
`pub const main = if (rt.freestanding) mainFreestanding else mainNative;`, and on
freestanding that is a nullary `void` function whose body is `@trap()` — a start
symbol that exists and traps immediately, not a usable entry point. The real fix
is the target-derived switch in `build/purzig.zig` (`-fno-entry`, or a second
root file chosen per target), which the issue explicitly defers; `build/purzig.zig`
is therefore untouched.

**Risk 1 (highest): Zig 0.16.0's `callMain` and a nullary `void` `main`.** The
argument above assumes 0.16 accepts a 0-argument `main` without instantiating the
juicy `std.process.Init` path. That was verified only against master's
`lib/std/start.zig`, which no longer contains `std.process.Init`, so 0.16's exact
shape could not be read in this sandbox. If 0.16 builds `Init` unconditionally
before dispatching on the signature, the two std errors come back unchanged and
the mitigation is the deferred per-target entry.

**Risk 2: `main` as a `const` alias.** `pub const main = …` relies on Zig
resolving an entry point through a comptime-known function value. The same
mechanism carries the *native* entry, so if 0.16 rejects it, criterion 2
(`zig build run` → `Hello, Zig`) fails immediately and loudly — it cannot fail
silently and only on wasm.

**Risk 3: `@compileError` firing on native.** `unavailable` is never called when
`freestanding` is false, but if the native build reports
`runtime: rt.… does not exist on a freestanding target`, the `if` was not
comptime-pruned — read that as "the gate is wrong", not "the message is wrong".

**Not done, on purpose:** `@panic` → `@trap` conversion, any allocator policy for
a host-owned buffer, `-Dshape=contract`, any Freenet export set, `-fno-entry` as
a user option, and any README API change (none was needed: the README never
listed `rt.init`).

---

## Acceptance criteria

| # | criterion | status |
|---|---|---|
| 1 | `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` exits 0; `head -c 4 zig-out/bin/example \| od -An -c` shows `\0 a s m` | **UNVERIFIED** |
| 2 | `zig build && zig build run` still prints exactly `Hello, Zig` | **UNVERIFIED** |
| 3 | `zig build test-e2e` and `zig build test-runtime` pass, unmodified | **UNVERIFIED** (one test *added*: "initAlloc alone is enough to allocate", which exercises the freestanding contract natively; `expected_output` untouched) |
| 4 | no `Io.Threaded`, `getrandom` or `IOV_MAX` in the freestanding output; `grep -rn 'std\.process' output-zig/` finds nothing | **UNVERIFIED** — checked statically only: the emitter emits `rt.ProcessInit`, and no generated comment spells `std.process` (an earlier draft did; it would have failed this grep) |
| 5 | `git diff --stat` touches only `runtime/`, the codegen template, `build/purzig.zig` | holds for code; `docs/codegen.md` and this handoff are the only extra paths, both required |
| 6 | no new dependency in `build.zig.zon`, `package.json`, `spago.yaml` | holds — no dependency file touched |

## If it fails

1. Error names `std/Io/Threaded.zig` → Risk 1: something still reaches the juicy
   `Init`. Check whether the driver that ran was the new one
   (`grep -n 'mainFreestanding' example/output-zig/Main.zig`); if it was, the
   0.16 `callMain` shape is the cause and the fix is the per-target entry.
2. Error names `rt.writeLine` or `rt.io` with the `@compileError` text → a
   freestanding-reachable path still calls a console primitive. The message names
   the symbol; the fix is either a comptime guard at the call site or the
   `@trap` conversion of the panics above.
3. `error: no entry point found` → the wasm linker is requiring an entry that
   `pub const main` no longer provides. Same fix as 1.
4. Native fails while wasm passes → Risk 2 or 3; the alias or the `if` is the
   only thing that changed on the native path. If the alias itself is rejected,
   the fix is the deferred one: `build/purzig.zig` roots the freestanding
   artifact at a generated entry file that declares no `main`, and the fixture
   keeps rooting at `Main.zig`.
