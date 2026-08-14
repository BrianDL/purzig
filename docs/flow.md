# How Zig is generated from PureScript

This is the end-to-end walkthrough: what happens between a `.purs` file and the
`.zig` file that Zig compiles. It is the *pipeline*; for the exact emission
rules of every IR node see [`docs/codegen.md`](codegen.md).

The short version: **PureScript is not compiled to Zig directly.** It is first
compiled to CoreFn, then run through `purescript-backend-optimizer` (a
whole-program optimisation pass), and only then is the optimised IR emitted as
Zig text by a PureScript program running on Node. Three different languages are
in play, and the pipeline is orchestrated by Zig's own build system.

```
.purs source
   │  purs compile --codegen corefn
   ▼
output/<Module>/corefn.json          (JSON, one file per module)
   │  backend driver (Node + PureScript)
   ▼
purescript-backend-optimizer         (sort, build, TCO-analyse)
   │
   ▼
Zig.Emit                             (emits Zig source text)
   │
   ▼
output-zig/<Module>.zig              (generated Zig, one file per module)
   │  zig build
   ▼
native binary
```

## The three stages

### 1. `purs compile --codegen corefn`

The PureScript compiler (`purs`) type-checks and desugars the source and emits
one `corefn.json` per module into `output/<Module.Name>/`. CoreFn is the
compiler's untyped intermediate representation — types have been checked and
discarded by this point, which is why the backend can never be type-directed.

This stage is Spago's job, not the backend's. The example workspace's
`spago.yaml` sets `workspace.backend.cmd` to `node ../compiler/bundle.js`, so
Spago runs `purs compile --codegen corefn` and then execs the backend with the
project root as its working directory.

### 2. The backend driver (`purs/compiler/src/Main.purs`)

The backend is itself a PureScript program compiled to JavaScript and bundled
to a single Node file (`bundle.js`). Its contract is entirely filesystem-based:
read `output/**/corefn.json`, write `output-zig/**/*.zig`. No arguments, no
stdin.

The driver does not read CoreFn itself. It hands the raw bytes of each
`corefn.json` to the optimizer's `decodeModule`, then:

1. **Sorts the modules** with `sortModules`. This is mandatory, not cosmetic:
   `buildModules` threads an `implementations` map forward so a definition can
   be inlined into its downstream callers, so a module must be visited after the
   modules it depends on. Feeding readdir order crashes the optimizer.
2. **Builds the whole program** with `buildModules`. This is the optimisation
   pass: dead bindings and unused imports are removed, pattern matching is
   compiled into `Branch`/`Accessor`/`OpIsTag`, newtypes are erased, `Prim` is
   filtered out, and the prelude's foreign arithmetic/comparison/append are
   rewritten into `PrimOp` nodes.
3. **Runs `Tco.analyze`**, which decorates the IR with tail-call information —
   whether a recursive binding group is a genuine loop.
4. **Calls `Zig.Emit.emitModule`** per module, which produces the Zig source
   text, and writes it to `output-zig/<Module>.zig`.

The driver also copies each module's hand-written FFI: a `Data/Semiring.purs`
pairs with a `Data/Semiring.zig` sitting beside it in the package, which is
copied to `output-zig/Data.Semiring.ffi.zig`.

A module that fails to emit is reported and skipped rather than aborting the
run, so one unsupported construct in a library does not hide progress on
everything else.

### 3. `Zig.Emit` (`purs/compiler/src/Zig/Emit.purs`)

This is the actual code generator. It consumes the optimizer's `BackendModule`
(never CoreFn) and returns Zig source text. The full rules are in
`docs/codegen.md`; the shape is:

- **One PureScript module → one `.zig` file**, named after the module verbatim
  (`Data.Maybe` → `Data.Maybe.zig`). All files land in one flat directory, so
  cross-module references are plain relative imports.
- **One boxed `Value` for everything.** Every PureScript value of every type
  becomes a `rt.Value`, a tagged union. Generated Zig is monomorphic at the Zig
  level and dynamically typed at the PureScript level.
- **Top-level bindings become nullary functions**, not constants.
- **Every lambda is lifted** to a top-level Zig function plus a captured
  `[]const rt.Value` environment, because Zig has no closures. `freeKeys` — the
  free-variable computation — is the only real algorithm left in the emitter.
- **Tail-recursive groups become real Zig loops** (a separate uncurried
  function with mutable argument copies), while the ordinary curried chain is
  kept for every non-loop use.
- **Names are prefixed by role and quoted** (`@"ps.greet"`, `@"v.x.1"`,
  `@"mod.Data.Maybe"`) so they can never collide with Zig keywords or `main`.

## Where the pieces live

| Piece | Location | Role |
|---|---|---|
| Build orchestration | `build.zig` | Runs the whole pipeline in dependency order |
| Backend driver | `purs/compiler/src/Main.purs` | Reads CoreFn, drives the optimizer, writes files |
| Code generator | `purs/compiler/src/Zig/Emit.purs` | `BackendModule` → Zig source text |
| Identifier mangling | `purs/compiler/src/Zig/Ident.purs` | PureScript name → legal Zig identifier |
| CoreFn decoding | `purs/compiler/src/CoreFn/Decode.purs` | (historical — see below) |
| Optimizer | `purescript-backend-optimizer` (git dep) | Whole-program optimisation + TCO analysis |
| Runtime | `runtime/*.zig` | Hand-written Zig: `Value`, `apply`, arena, lazy cells |
| FFI | `purs/lib/*/src/**/*.zig` | Hand-written Zig beside each `.purs` |
| Example | `purs/example/src/Main.purs` | User code compiled through the backend |

## Who runs what

`zig build` is the entry point, and its dependency graph is the pipeline:

1. `spago bundle` in `purs/compiler` → `bundle.js` (the backend, as a Node
   program).
2. `spago build` in `purs/example` → runs `purs compile --codegen corefn`, then
   execs the backend, which writes `output-zig/*.zig`.
3. Zig compiles `output-zig/Main.zig` with `runtime` and the FFI linked in as
   named modules.

The generated root source file does not exist on a clean checkout; the explicit
`exe.step.dependOn(&codegen.step)` in `build.zig` is what makes the first build
safe instead of racing.

## Two workspaces, and why

`workspace.backend` is a per-workspace Spago setting, and the two sides need
different backends:

- **`purs/compiler`** (workspace A) is the backend itself, so it uses the
  *default JavaScript* backend — it is a Node program.
- **`purs/example`** (workspace B) is user code, so it uses the *Zig* backend.

This is the polyrepo pattern from the Spago docs.

## Why Node is in the toolchain

Two independent reasons:

1. **Spago** is written in PureScript and distributed on npm, so it runs on
   Node.
2. **The backend compiler** is written in PureScript, and PureScript's only
   mature backend is JavaScript — so the backend that generates Zig is itself a
   Node program.

Nothing about the *compiled output* touches Node. Target programs are native
binaries with no runtime dependency beyond libc.

## A note on `docs/corefn-schema.md`

`corefn-schema.md` documents the `corefn.json` format and is retained for
historical interest only. Nothing in the backend reads that format directly
anymore — the driver hands the raw bytes straight to the optimizer's
`decodeModule`. The current contract is the optimizer's IR, described in
`docs/codegen.md`.

## Reading order

- `docs/flow.md` (this file) — the pipeline, end to end.
- `docs/codegen.md` — the emission rules for every IR node.
- `README.md` — layout, commands, design rationale.
- `docs/handoff-*.md` — dated session logs; the newest one is the current state.
