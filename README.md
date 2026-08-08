# purzig

A PureScript backend targeting Zig. Zig's build system orchestrates the whole
pipeline; devenv provides the toolchain.

**Status: plumbing only.** The build graph, runtime, FFI convention and Spago
wiring are in place and the pipeline runs end to end, but `Zig/Emit.purs` is a
stub — the backend currently writes a fixed `main.zig` rather than translating
CoreFn. Everything else exists so that writing the emitter is the only remaining
work.

## Layout

```
build.zig               orchestrates everything
docs/                   codegen spec, CoreFn schema, handoff notes
devenv.nix              provisions the toolchain (see below)
package.json            pins spago; devenv installs it locally
purs/
  compiler/             workspace A: the backend, PureScript -> JavaScript
  lib/zig-prelude/      shared package, no workspace of its own
  example/              workspace B: user code, PureScript -> Zig
    expected/           hand-written target: what codegen must produce
runtime/                hand-written Zig: boxed Value, apply, arena
ffi/                    hand-written Zig: implementations of foreign imports
```

Two Spago workspaces, because `workspace.backend` is a per-workspace setting and
the compiler needs the JS backend while the example needs the Zig one. This is
the polyrepo pattern from the Spago docs. `purs/lib/zig-prelude` deliberately has
no `workspace:` key so it can be pulled into either.

## Pipeline

`zig build` runs, in dependency order:

1. `spago build` in `purs/compiler` → `bundle.js` (Node).
2. `spago build` in `purs/example`, whose `spago.yaml` sets
   `workspace.backend.cmd: node` with that bundle as an arg. Spago runs
   `purs compile --codegen corefn`, then execs the backend with cwd
   `purs/example`.
3. The backend reads `output/**/corefn.json`, writes `output-zig/*.zig`.
4. Zig compiles `output-zig/Main.zig` with `runtime` and `ffi` linked in as
   named modules.

The generated root source file does not exist on a clean checkout. The
`exe.step.dependOn(&codegen.step)` line in `build.zig` is what makes that safe —
without it the first build races.

## Commands

| | |
|---|---|
| `zig build run-expected` | build and run the **hand-written target**; no purs/spago/node needed |
| `zig build test-runtime` | test the runtime alone; no purs/spago/node needed |
| `zig build run` | full pipeline, then run the binary |
| `zig build codegen` | stop after generating Zig, for inspection |
| `zig build test-codegen` | diff generated Zig against the target — fails until the emitter exists |
| `zig build clean-purs` | drop PureScript artefacts |

The first two work on a bare checkout with only Zig installed. They are the
fastest way to confirm the runtime is sound.

## Why Node is in the toolchain

Two independent reasons:

1. **Spago.** The current Spago is written in PureScript and distributed on npm,
   so it runs on Node. Not removable while you use it.
2. **The backend compiler.** It is written in PureScript, and PureScript's only
   mature backend is JavaScript — so the backend that generates Zig is itself a
   Node program. This one *is* removable: see below.

Nothing about the compiled output touches Node. Target programs are native
binaries with no runtime dependency beyond libc.

## Design notes

The decisions that shape everything else. The full emission rules are in
[`docs/codegen.md`](docs/codegen.md); rationale, rejected alternatives and open
questions are in the handoff alongside it.

**One boxed `Value` for everything.** CoreFn is untyped, so v0 does no
type-directed code generation. Slow, correct, and unboxing is a later pass.

**One-argument closures.** CoreFn is fully curried — every `Abs` binds one name,
every `App` applies one argument — so `rt.apply` needs no arity analysis. Adding
`purescript-backend-optimizer` later brings uncurrying for free.

**An arena that never frees.** PureScript is garbage-collected and this backend
is not. Zig 0.16's "juicy main" hands `main` an arena described as permanent
storage for the process, cleaned automatically on exit — exactly this strategy,
so the runtime borrows it rather than building its own.

**Flat positional closure environments.** Zig has no closures, so every `Abs`
becomes a top-level function plus a captured `[]const rt.Value`, indexed by
position. A generated struct per lambda would mean naming a type for every
lambda and casting at every call site, to save an indirection the optimizer
would erase anyway.

## Toolchain

`direnv allow` is the whole setup. devenv provides `zig` and `purs` from
nixpkgs, and installs `spago` into `./node_modules` from the root
`package.json` on shell entry — project-local and pinned in the repo, nothing
global. `$DEVENV_ROOT/node_modules/.bin` goes on the front of `PATH`, so
`spago` always means the pinned one even if something else is installed
ambiently.

`check-tools` prints the four versions and runs automatically on entry.

Neither `spago.yaml` pins a package set, so the registry solver resolves
dependency versions from the lists themselves. This means the first build needs
network access and will write a `spago.lock` — commit it.

## Next steps, in order

1. Run `zig build run-expected` and `zig build test-runtime` to confirm the
   runtime compiles on your toolchain. Everything downstream assumes it does.
2. ~~`CoreFn/Decode.purs`~~ — written, against the schema in
   `docs/corefn-schema.md`. `zig build codegen` now logs what it decoded per
   module, so it can be checked against real compiler output before any
   emission exists.
3. `Zig/Emit.purs` — `Lit`, `Var`, `Abs`, `App` and module-level `Bind`, per
   `docs/codegen.md`. Done when `zig build test-codegen` passes.
4. `Case`, records, ADTs. `Case` is most of the remaining work.
5. Grow `zig-prelude` and its FFI only as the programs you compile demand it.
