# Conversation Handoff: bootstrap a PureScript → Zig backend

> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.

**Date:** 2026-08-05
**Original session purpose:** Research the PureScript and Zig ecosystems, then scaffold the simplest possible PureScript backend targeting Zig.
**Status:** Scaffold complete and packaged. Code generation not yet implemented.

---

## Mission

Ship a working PureScript backend that emits Zig, as fast as possible, starting with a handful of types. "Done" for v0 is `zig build run` printing output from `purs/example/src/Main.purs` — a native binary produced from PureScript source via CoreFn. The whole repository is orchestrated by `build.zig`; the toolchain comes from devenv.

## Next actions

1. Write `purs/compiler/src/CoreFn/Decode.purs` — decode `output/<Module>/corefn.json` into the AST already sketched in `CoreFn/Types.purs`.
2. Hand-write the Zig you *want* emitted for `purs/example/src/Main.purs`. That artifact becomes the target the emitter aims at, and it validates the runtime API before any codegen exists.
3. Write `purs/compiler/src/Zig/Emit.purs` covering `Lit`, `Var`, `Abs`, `App` only — enough for the example, which needs no `Case`, records, or ADTs.
4. Replace the `stubMain` constant in `purs/compiler/src/Main.purs` with a real traversal. That constant is the only thing standing between the current scaffold and a genuine backend.
5. Then `Case`, records, ADTs. `Case` is most of the remaining work.

## Status right now

Every piece of plumbing exists and the pipeline runs end to end, but the backend writes a **fixed** `main.zig` rather than translating CoreFn. Working: `build.zig` (full step graph), the Zig runtime with passing tests, the FFI convention, both Spago workspaces, devenv. Stubbed: `CoreFn/Decode.purs`, `Zig/Emit.purs`, `Zig/Ident.purs`.

`zig build test-runtime` passes standalone with no PureScript toolchain present — this was deliberate and should stay true.

## Decisions (settled — do not relitigate)

- **One boxed `Value` for everything.** CoreFn is untyped, so v0 does no type-directed code generation at all. Every PureScript expression becomes a `Value` tagged union. Slow and correct; unboxing is a later pass.
- **One-argument closures.** CoreFn is fully curried — every `Abs` binds exactly one name, every `App` applies exactly one argument. So `rt.apply` needs no arity analysis and codegen is a mechanical tree walk. This is the single biggest simplification in the design.
- **An arena that never frees.** PureScript is garbage-collected, Zig is not. Every allocation goes through `rt.alloc()`, which is what will make a real memory strategy tractable later. Deliberately a v2 problem.
- **Backend written in PureScript, not Zig.** Considered and rejected — see Dead ends.
- **Two Spago workspaces.** `workspace.backend` is per-workspace, and the compiler needs the JS backend while the example needs the Zig one. `purs/lib/zig-prelude` has no `workspace:` key so it can be pulled into either via `extraPackages: path:`. This is the polyrepo pattern from the Spago docs.
- **`backend.cmd: node` + bundle path**, rather than a `purs-backend-zig` executable on `PATH`. Avoids a shim script and `npm link` entirely.
- **Generated code goes to `output-zig/`, not `output/`.** Keeps the JS and Zig backends from fighting over one directory. Same convention purerl uses.
- **Registry solver, no pinned package set.** First build needs network and writes `spago.lock`, which should be committed.
- **No `build.zig.zon`.** Nothing fetches an external Zig package, so the manifest is unnecessary. Add it only when something calls `b.dependency(...)`.
- **devenv provisions everything; nothing global.** `spago` is pinned in the root `package.json` and installed to `./node_modules` on shell entry, with `$DEVENV_ROOT/node_modules/.bin` prepended to `PATH`.

## Constraints and facts

- PureScript **0.15.16** (released 15 March 2026). Zig **0.16.0** (released 14 April 2026) — pinned deliberately; do not chase master (`0.17.0-dev`).
- Zig 0.16 **deprecated `@cImport`**; C translation now goes through the build system via `addTranslateC`. Not currently needed — the boxed-`Value` design touches no C.
- `exe.step.dependOn(&codegen.step)` in `build.zig` is load-bearing. The generated root source file doesn't exist on a clean checkout; without that edge the first build races.
- Both `spago build` steps are `has_side_effects = true` — Spago writes into its own project tree, so Zig can't cache them. Spago does its own caching. Tightening this later means copying `output-zig` into the Zig cache with a `WriteFiles` step.
- **Two known CoreFn gotchas** that will bite `Decode.purs`: CoreFn identifiers are arbitrary strings (type class desugaring concatenates printed types), and modules carry a bogus `Prim` import that must be filtered out.
- Generated code may use only what `runtime/root.zig` re-exports. Keeping that surface small is what lets the runtime be rewritten without touching the emitter.
- No PureScript → Zig backend existed before this. Closest prior art: `purescript-native` (C++/Go, stuck at PS 0.14.x, useful as reference only), `purerl`, `purenix`, `purescript-lua`.

## Open questions

- `"spago": "^1.0.0"` in the root `package.json` is unverified — both 0.93.x and 1.0.3 were visible on npm. Confirm with `npm view spago version`. *Blocked on: running the environment.*
- `languages.javascript.npm.install.enable` is the devenv option name I'm fairly confident of, but devenv option names move. Fallback if rejected: drop the block, put `npm install --silent` at the top of `enterShell`. *Blocked on: running the environment.*
- Whether to adopt `purescript-backend-optimizer` later. It brings inlining, TCO and uncurrying for free, and `purescript-backend-erl` is proof the approach works. Not needed for v0. *Blocked on: v0 landing first.*

## Artifacts and references

| Item | Location | Notes |
|---|---|---|
| Repo scaffold | `/mnt/user-data/outputs/purs-backend-zig.tar.gz` | 24 files |
| Alternate backends list | https://github.com/purescript/documentation/blob/master/ecosystem/Alternate-backends.md | Official registry of backends |
| purescript-backend-optimizer | https://github.com/aristanetworks/purescript-backend-optimizer | The v2 path |
| purescript-backend-erl | https://github.com/id3as/purescript-backend-erl | Template for building on the optimizer |
| CoreFn gotchas | https://github.com/purescript/purescript/issues/4381 | Read before writing `Decode.purs` |
| Spago backend config | https://github.com/purescript/spago | `workspace.backend` section of the README |

## Dead ends (do not repeat)

- **Routing PureScript → C++/Go → Zig** via `purescript-native`: rejected. Zig can't import C++ headers (name mangling, templates) or Go directly — each hop needs a hand-written `extern "C"` shim, and you inherit two runtimes. Go CoreFn → Zig directly.
- **Writing the backend compiler in Zig** (`std.json` instead of PureScript): genuinely simpler build — deletes one workspace, one language, the bundle-and-exec dance — but permanently forgoes `purescript-backend-optimizer`, which is a PureScript library. User's call, explicitly: *"it really sounds like it's actually needed. Let's keep it then."*
- **Global npm installs.** User: *"no globals. Also, installing the development tool IS the job of devenv."*
- **Pinned package set** (`packageSet.registry: 61.0.0`): replaced with the registry solver at user request.

## User preferences and communication style

- **Handoff files are for the project, by default.** Always surface them as a
  presented artifact so they can be added to project knowledge. Only also write
  them into `docs/` when explicitly asked.
- Strongly biased toward **the simplest thing that works** — pushed back on `build.zig.zon` with *"we are doing the simplest thing, remember?"* Justify anything that adds a file, a dependency, or a concept.
- Wants **Zig as the orchestrator** for everything, and devenv doing the full provisioning job. Reach for the tooling rather than instructing the user to run commands manually.
- Reviews via inline comments on specific lines. Expects the edit made, plus a brief note on consequences — not a restatement of what was changed.
- Values **honesty about uncertainty**: flag what couldn't be verified rather than presenting guesses as fact.

## Glossary

- **Backend:** the target language PureScript compiles to. Mechanically, an external executable that reads `corefn.json` and emits source. It never touches the compiler.
- **CoreFn:** the compiler's untyped, fully-curried intermediate representation, emitted by `purs compile --codegen corefn`.
