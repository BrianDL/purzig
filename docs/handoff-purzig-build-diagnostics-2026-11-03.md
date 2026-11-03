# Handoff — build: a failing compile prints the compiler's output

Date: 2026-11-03

This file is the issue #31 handoff. The defect: a purzig build that failed to
compile reported

```
run spago failure
error: process exited with error code 1
failed command: cd /tmp/... && PATH=... spago build
```

and purs's own error block — the only thing that says *what* to fix — was gone.
A consumer's first mistyped import cost two repair round trips and a throwaway
harness (`extract repo → zig build once → spago build by hand`).

Now: every external command purzig runs for a build goes through
`build/purzig-run.sh`, which captures the child's stdout **and** stderr (merged,
in the order the child wrote them), prints **all** of it between markers when
the step fails, and names the phase. On success it prints nothing, so a green
build's log is unchanged.

## Verification status — read this before the claims

| Claim | Status |
|---|---|
| The success path still works: `zig build compiler` → `codegen` → `test-e2e` → wasm32 → `zig build test` | **executed on the purzig worker**, all five stages exit 0 (`purzig_tester`, `ok: true`) |
| `zig build test-diagnostics` asserts the FAIL path's text | **executed on the purzig worker**: it is part of `zig build test`, which exits 0 (13.7 s) |
| The gate is LIVE, not vacuous | **executed on the worker**: a negative control (one needle misspelt `type-check failure NEGATIVE-CONTROL`) turned `zig build test` red, `failed_stage: regressions (zig build test)`; then reverted and re-run green. The output quoted below is from that run |
| `zig build test-diagnostics` as its own command line | not run verbatim (the tester's stage list is fixed and does not name it). It is the same step `zig build test` depends on. **UNVERIFIED as a standalone invocation**; a human runs `zig build test-diagnostics` |
| A manual `spago build` and a purzig-driven one agree via `.purzig/spago` | **UNVERIFIED**: the wrapper is written by `purzig.addProjectSetup`, but running it by hand was never executed. Command a human runs: `cd example && .purzig/spago build` (and, to see the "backend unavailable" branch: `cd example && spago build` with no shim on `PATH`) |
| `Backend unavailable` phase | **UNVERIFIED by execution** (it needs a deliberately broken `PATH`); asserted by construction only. See §5 |
| The wasm artifact is `\0asm` | not re-checked here; the `zig -> wasm32` stage exits 0 |

Nothing was downloaded, installed, extracted or vendored; no zig, purs, spago or
node was invoked by hand in this session. The build was run only through the
`purzig_tester` tool.

## 1. What was swallowed, and where

`master`, `build/purzig.zig:266`:

```zig
    // `has_side_effects` because spago writes into its own project tree rather
    // than anywhere Zig models. Spago does its own caching.
    const codegen = b.addSystemCommand(&.{ "spago", "build" });
    codegen.setCwd(project);
    codegen.has_side_effects = true;
    codegen.step.dependOn(&shim.step);
    codegen.step.dependOn(&set.step);

    codegen.addPathDir(bin_dir);
```

That is the whole of the old wiring: the command was handed to Zig's build
runner and nothing captured what it wrote. Whatever the runner did with the
child's streams, the compiler's `[ERROR ...]` block did not reach the log — the
consumer's report shows only the runner's summary, `run spago failure`, and
`failed command:`. The step's *name* also said nothing: `run spago failure`
conflates a type error, a backend error and a missing file.

The same shape was used for the backend bundle itself (`build.zig:48` on
`master`: `b.addSystemCommand(&.{ "spago", "bundle" })`) and for purzig's own
two setup commands (`build/purzig.zig:238-262`: the shim `sh -c` and the
`packages.json` copy), so a failure in any of them printed only `failed
command`.

## 2. The fix

* `build/purzig-run.sh` (new, 269 lines, POSIX `sh`, invoked as `sh <file>`, so
  it needs no executable bit): runs the command with `>log 2>&1`, then
  classifies and prints. Never a `tail` — the whole log, first error and final
  summary both.
* `build/purzig.zig`, new public API:
  * `addReportedCommand(b, ReportedCommand)` — wraps any command (`:443`);
  * `addProjectSetup(b, opts)` — the shim, the package set and the `.purzig/`
    wrapper, as one step (`:334`);
  * `shimDir`, `ReportedCommand` (`:394`).
* Every command purzig runs for a build now goes through the reporter:
  `spago build` (`build/purzig.zig:248`), `spago bundle`
  (`build.zig:52`), the backend shim and the project setup
  (`build/purzig.zig:347`, `:378`).
* Step names: `run.setName("run <label>")` (`build/purzig.zig:463`), so a
  failure summary reads `run spago build`, not `run sh`.

## 3. The exact new failure output

Real output, captured on the purzig worker. Paths are shortened to `…`, and
`…` on its own line marks an elision; everything not elided is exactly what the
log contains.

**Phase 1 — type-check failure** (`example/diagnostics/missing-import`):

```
--- purzig: `spago build` failed (exit 1) — output follows ---
purzig: type-check failure — purs rejected the source, so purzig never ran; purs's own errors are printed below, verbatim.
purzig: everything `spago build` wrote follows, in order and untruncated (also saved in …/missing-import/.purzig/logs/spago-build.log):
--- `spago build` output ---
…
[ERROR 1/1 ModuleNotFound] src/Main.purs:9:1

  9  import Data.Array (cons, uncons)
     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

  Module Data.Array was not found.
  Make sure the source file exists, and that it has been provided as an input to the compiler.

           Src   Lib   All
Warnings     0     0     0
Errors       1     0     1

✘ Failed to build.

--- end of `spago build` output ---
```

**Phase 3 — missing artifact** (`example/diagnostics/missing-artifact`),
complete, including the backend's manifest and its own log lines:

```
--- purzig: `spago build` exited 0, but output-zig/Main.zig is missing — output follows ---
purzig: missing artifact — the backend finished without reporting an error, but the file the build is about to compile is not on disk.
check Options.main_module in build.zig: it names the module that exports `main`, not a source file.
purzig: output-zig/manifest.json, as the backend left it:
{
  "main_module": null,
  "main_export": null,
  "modules": [
    { "name": "Other", "file": "Other.zig", "ffi": null },
    { "name": "Spago.Generated.BuildInfo", "file": "Spago.Generated.BuildInfo.zig", "ffi": null }
  ],
  …
}
purzig: everything `spago build` wrote follows, in order and untruncated (also saved in …/missing-artifact/.purzig/logs/spago-build.log):
--- `spago build` output ---
(node:2194) Warning: The 'NO_COLOR' env is ignored due to the 'FORCE_COLOR' env being set.
(Use `node --trace-warnings ...` to show where the warning was created)
Reading Spago workspace configuration...
…
✓ Build succeeded.

Compiling with backend "purzig"
[purs-backend-zig] 2 of 11 module director(ies) decoded
[purs-backend-zig]   Other -> output-zig/Other.zig
[purs-backend-zig]   Spago.Generated.BuildInfo -> output-zig/Spago.Generated.BuildInfo.zig
[purs-backend-zig]   2 module(s), 4 export shape(s) -> output-zig/manifest.json

✓ Backend build succeeded.

--- end of `spago build` output ---
```

**Phase 2 — backend failure** (`example/diagnostics/backend-ffi`). The marker
line as it appears in the same run:

```
--- purzig: `spago build` exited 0, but the purzig backend rejected a module — output follows ---
purzig: backend failure — purs type-checked the source, but the purzig backend found a foreign import with no Zig FFI beside the .purs file; its own message is below.
…
[purs-backend-zig]   Ffi: MISSING FFI -- 1 foreign import(s) declared but no …/src/Ffi.zig
```

(The marker and the phase sentence are quoted from the run; the
`[purs-backend-zig] Ffi: …` line is the backend's own text, printed by the same
`cat` of the log that printed everything else in the two blocks above. The gate
asserts on that line — `MISSING FFI` and `src/Ffi.zig` — so it cannot be absent.)

**And the failure summary names the phase-bearing step**, instead of `run spago
failure`:

```
test transitive failure
+- test-diagnostics transitive failure
   +- run spago build failure
```

Phases, and where each is decided (`build/purzig-run.sh:153-204`):

| phase | trigger | what it says |
|---|---|---|
| `type-check failure` | non-zero exit and `\[ERROR ` in the log | purs rejected the source; its errors are below |
| `backend failure` | non-zero exit, `Failed to build with backend`, and `[purs-backend-zig]` present — **or** exit 0 with `EMIT FAILED` / `MISSING FFI` in the log | purs type-checked, purzig could not emit Zig |
| `backend unavailable` | non-zero exit, `Failed to build with backend`, **no** backend output | nothing is wrong with the source yet; the shim was not on `PATH` (§5) |
| `missing artifact` | exit 0, no backend complaint, and `output-zig/<main_module>.zig` absent or empty | the backend finished, the file the build compiles is not there |
| `command failure` | anything else non-zero | `spago` itself failed |

## 4. The PATH/shim finding (issue part 3)

The build prepends a generated shim directory to `PATH` for the `spago build`
step **alone** (`addReportedCommand`, `build/purzig.zig:458`:
`run.addPathDir(shimDir(b))`, i.e. `<build root>/.zig-cache/purzig-bin`). The
shim exists because `spago.yaml` says `backend: { cmd: purzig }` and cannot
interpolate a path only the Zig build knows. Consequences, both of which the
issue observed:

* a **hand** `spago build` in the same tree has no `purzig` on `PATH`, so spago
  prints `✘ Failed to build with backend purzig` with no further message, while
  `zig build` on the same tree exits 0. That is the "manual run disagrees"
  symptom, and it is a PATH difference, not a cwd one: a project whose
  `spago.yaml` names `packageSet: path: .purzig/packages.json` (the README's
  consumer shape, and the shape the fixtures use) resolves that path relative
  to the project in both cases, so only `PATH` differs;
* the message blamed nothing, so the missing setup was invisible.

Fix, in `addProjectSetup` (`build/purzig.zig:334`): the setup step now writes
the shim **into the project** as well, and a wrapper beside it —

```
<project>/.purzig/purzig   #!/bin/sh  exec node "<abs>/compiler/dist/bundle.js" "$@"
<project>/.purzig/spago    #!/bin/sh  PATH="<project>/.purzig:$PATH"; export PATH; exec spago "$@"
```

so

```sh
cd example && .purzig/spago build
```

is the manual invocation that behaves exactly like the purzig-driven one (same
shim, same package set, same cwd, same output). And when `spago build` fails
because no backend was reachable at all, the report now names the setup instead
of leaving `✘` unexplained:

```
--- purzig: `spago build` failed (exit 1) — output follows ---
purzig: backend unavailable — `spago build` could not run the purzig backend at all, so nothing is wrong with the source yet.
purzig: the purzig-driven build puts a shim named `purzig` on PATH for this step alone (…/.zig-cache/purzig-bin), and copies the package set to …/.purzig/packages.json.
purzig: a manual run must do the same. There is a wrapper that already does: cd into the project and run '…/.purzig/spago build' -- it puts that shim on PATH and execs the real spago, so a hand run and a purzig-driven run agree on the same tree.
```

(That block is quoted from `build/purzig-run.sh`'s own strings, exercised
locally with a stub command that printed `Failed to build with backend purzig`
and exited 1 — **not** against real spago; the real-spago version of this branch
is **UNVERIFIED**, see the table.)

## 5. What the backend actually rejects (issue part 4)

Finding, and the reason fixture 2 is shaped the way it is: **the purzig backend
never fails its own process for a module it cannot emit.** In
`compiler/src/Main.purs:189-192`:

```haskell
  case emitModule backendMod of
    Left err ->
      log ("[purs-backend-zig]   " <> name <> ": EMIT FAILED -- " <> err)
```

— it logs, skips the module, and continues; `main` (and therefore `spago build`)
still exits 0. The same is true of the foreign-FFI check
(`compiler/src/Main.purs:405`, `MISSING FFI`). So there are two distinct
"backend" failures, and before this change **neither** failed the build at the
point where the cause was known:

1. `spago build` exits non-zero with `✘ Failed to build with backend purzig` —
   the backend *process* died (optimizer crash, node missing, bundle missing).
   Spago prints no reason; a hand run showed exactly that, with no message.
2. `spago build` exits **0** while the backend logged `EMIT FAILED` or
   `MISSING FFI` — the module is simply not there. The failure then surfaced
   much later as a Zig error about a file inside generated code.

The only `Left` sites in the emitter are `Zig/Emit.purs:605`
(`unbound local: …`, an internal invariant) and five `PrimOp` cases at
`:1280`, `:1285`, `:1295-1297` whose comments say "should be filtered" —
`Main.purs:177-190` removes those foreigns from the optimizer's
`foreignSemantics` precisely so they cannot be produced. There is therefore **no
known source construct** that makes `emitModule` return `Left`, which is the
finding the issue asked for ("if no such construct is known, that is itself a
finding").

What *is* reachable from source, and is therefore fixture 2, is a foreign
import with no Zig FFI beside the `.purs` file: `MISSING FFI`, reachable,
backend-authored, and — before this change — a green `spago build`. The gate
asserts the failure text contains `MISSING FFI` and `src/Ffi.zig`, not only
`Failed to build with backend purzig`.

## 6. The fixtures and the gate

Three fixtures under `example/diagnostics/`, one per phase whose message the
issue asks for. Each is a real project (`spago.yaml` + `src/`), built by a real
`spago build` on the worker, offline, in about a second.

| fixture | what it is | asserts the report contains |
|---|---|---|
| `missing-import/` | `src/Main.purs:9` says `import Data.Array (cons, uncons)` and `spago.yaml` does **not** declare `arrays` | the `failed (exit ` marker, the closing `--- end of `spago build` output ---` marker, `type-check failure`, `ModuleNotFound`, `Module Data.Array was not found`, and `/src\/Main\.purs:9:[0-9]+/` (file **and** line:column) |
| `backend-ffi/` | `src/Ffi.purs` declares `foreign import bad :: Int`; no `src/Ffi.zig` exists | the `exited 0, but the purzig backend` marker, `backend failure`, `MISSING FFI`, `src/Ffi.zig` |
| `missing-artifact/` | the only module is `Other`, while the build is told `main_module = "Main"` | the `output-zig/Main.zig is missing` marker, `missing artifact`, `Options.main_module` |

The gate is `build.zig:301`:

```zig
const diag_step = b.step("test-diagnostics", "Assert a failing build prints the compiler's output and names the phase");
```

For each fixture it calls the **same** helper the build uses
(`purzig.addReportedCommand`, `:364`) in its assertion mode
(`.expect_failure = true`, `.require`, `.require_re`), and depends on
`purzig.addProjectSetup` and on `spago bundle`, exactly as `app.codegen` does.
The assertion is on the report text the user reads — same script, same markers,
same phase sentence — so the gate cannot pass while the message regresses. It is
also a dependency of `zig build test`, because a gate nobody runs is the
complaint that produced it.

## 7. Success path: unchanged

The reporter prints nothing when the command succeeds (it only writes
`.purzig/logs/<label>.log`, which is not the build log). `zig build test-e2e`
still asserts exactly `Hello, Zig\n` (`build.zig`, unchanged), and the whole
battery is green on the worker: `compiler`, `codegen`, `test-e2e`, `wasm32`,
`test` (34/34 steps). The three fixture builds add ~1 s each and none of them
can fail a successful path.

## 8. Files touched

* `build/purzig.zig` — reporter wiring (`:224-256`), `addProjectSetup` (`:334`),
  `ReportedCommand` (`:394`), `addReportedCommand` (`:443`), `shimDir`; module
  doc updated.
* `build/purzig-run.sh` — new; the reporter, the phase classifier and the
  assertion mode.
* `build.zig` — `spago bundle` through the reporter (`:52`), the
  `test-diagnostics` step and its three fixtures (`:301-380`), `test` depends on
  it.
* `example/diagnostics/{missing-import,backend-ffi,missing-artifact}/` — the
  fixtures, each with a `spago.yaml` whose comments say which phase it proves;
  `example/diagnostics/.gitignore` ignores the generated `spago.lock`.
* `docs/handoff-purzig-build-diagnostics-2026-11-03.md` — this file.

Not touched: `runtime/`, `compiler/src/**`, `entry/`, `packages.json`,
`spago.yaml`, `build.zig.zon`. No change was needed there; the backend finding
in §5 is recorded rather than "fixed", because making the backend exit non-zero
on `EMIT FAILED` is a change to `compiler/src/Main.purs`, which this branch may
not make.

`build.zig.zon` did not need editing for the new script to ship: its `.paths`
lists the directory `"build"`, so `build/purzig-run.sh` travels in the tag
tarball with `build/purzig.zig` — which it must, because
`addReportedCommand` resolves it against purzig's own tree, exactly as the
bundle is resolved. A `.path` dependency (the in-repo case) would hide a
missing file; only a tarball build would show it, so this is a fact to keep in
mind on the next release, not a claim that a tarball build was run.

## 9. Open questions

* **Should the backend fail instead of logging?** `EMIT FAILED` and
  `MISSING FFI` are logged and skipped by design ("so one unsupported construct
  in a library does not hide progress on everything else",
  `compiler/src/Main.purs:31`). The reporter now turns those lines into a failed
  build, which is the strictest thing the build layer can do without editing the
  backend. If the backend ever exits non-zero for them, the `Exit 0 + marker`
  half of the classifier becomes dead code and should be deleted with it.
* **Colour.** `spago build`'s log is captured to a file, so a colourised error
  block arrives plain (good). The classifier matches `[ERROR `, not a
  line-anchored `^[ERROR `, so an ANSI prefix cannot hide it.
* **`.purzig/logs/` grows.** One file per label (`spago-build.log`,
  `spago-bundle.log`, …), overwritten each run. `zig build clean-purs` does not
  remove it; the root `.gitignore` covers `.purzig/`.
