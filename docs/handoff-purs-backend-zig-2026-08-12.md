# Conversation Handoff: PureScript → Zig backend, purescript-backend-optimizer integrated

> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.
>
> **This handoff is additive.** It assumes the 2026-08-06, 08-07, 08-08 and 08-09 handoffs plus `docs/codegen.md` are already in your context and does not repeat their content. Read those first. Where it says **Supersedes**, the statement here wins.

**Date:** 2026-08-12
**Original session purpose:** Step 2 of the four-step roadmap — adopt `purescript-backend-optimizer`.
**Status:** Done and green. `zig build test` passes with all 89 modules going through the optimizer. Batch 2 (effect nodes) is the immediate next task.

---

## Mission

Unchanged. The roadmap set in 08-09 was: (1) `Effect` — done then; (2) the optimizer — **done this session**; (3) `Data.Array`/`Data.String`/`Data.Int`; (4) extract into an importable lib.

Step 2 shipped as "batch 1": everything except four IR nodes. Batch 2 finishes it.

## Next actions

1. **Batch 2 — the four effect nodes.** Implement `EffectBind`, `EffectPure`, `EffectDefer` and `PrimEffect` in `Zig/Emit.purs` (each currently returns `Left` naming itself), and delete the twelve `Effect`/`Effect.Ref`/`Control.Monad.ST` entries from `unsupported` in `Main.purs`. This is MagicDo: an `Effect` do-block currently allocates a closure per `>>=` and becomes a straight-line block instead. Expected to need no new runtime — `mkClosure` gives the thunk shape, `rt.newRef` exists, and ref read/write are `.asRef().*`.
2. **TCO.** Now the largest correctness risk. `PureScript.Backend.Optimizer.Codegen.Tco` ships the *analysis* (`analyze`, `topLevelTcoEnvGroup`, `topLevelTcoRefBindings`, `popTcoScope`, `unwindTcoScope`); the loop emission is the backend's job — see `backend-es/src/.../EcmaScript/Convert.purs` lines ~200–230 and ~400–440 for the shape. **Supersedes** the 08-09 implication that the optimizer subsumes TCO: it does the hard detection, not the codegen.
3. **Deferred cleanups**, both still outstanding from 08-09: delete `purs/lib/zig-prelude/` and its `build.zig` wiring, and run `zig build clean-purs` for stale `output/` module dirs.
4. Step 3: `Data.Array`, `Data.String`, `Data.Int` — commonly-used subset. Note the optimizer changes what's needed: `Data.Array.length` and `unsafeIndexImpl` are already `PrimOp`s and their FFI is never called.

## Status right now

`zig build test` is green. `Scratch.purs`'s 25 checks and `Main`'s asserted stdout both pass through the optimized IR. No `EMIT FAILED` on any of the 89 modules.

`docs/codegen.md` is **stale** and was not updated this session. Its `Case`, binder-table, newtype-erasure and `Prim` sections now describe a pipeline that no longer exists.

## What changed

### Integration shape
- `purs/compiler/spago.yaml` gains `backend-optimizer` as a `git`/`ref` `extra_packages` entry (it is not a registry package). Its dependency list is transcribed from its own `spago.yaml`. **The registry solver resolved the whole closure with no package set pinned** — backend-erl pins set 43.0.0 and uses a fork, and neither turned out to be necessary.
- `Main.purs` is now: read every `corefn.json` → `sortModules` → `buildModules`. `CoreFn/Types.purs` and `CoreFn/Decode.purs` are deleted; the optimizer's `CoreFn/Json.purs` replaces them, so every gotcha in `docs/corefn-schema.md` is now someone else's problem.
- `buildModules` is `forall m. Monad m`, so the driver stays on synchronous node-fs. No `aff`, no globbing.

### Emitter rewrite
`Zig/Emit.purs` went 924 → ~640 lines and consumes `NeutralExpr`. Deleted: the whole binder machinery (`emitBinder`, the continuation fold, `canFail` reachability, per-alternative bracketing, scrutinee-discard analysis) and name-suffixing on shadowing. Added: `emitPrimOp`, a lookup table.

## Decisions (settled — do not relitigate)

- **A local is keyed by `(Maybe Ident, Level)`, not by `Level`.** A `LetRec` gives every member of the group the *same* level and distinguishes them by identifier. `@"v.<name>.<level>"` is therefore collision-free by construction, which is why nothing suffixes names any more. **Supersedes** `codegen.md`'s "appends a counter when a name is already live".
- **Uncurried nodes collapse to curried chains.** `UncurriedAbs`/`UncurriedApp`/`UncurriedEffectAbs`/`UncurriedEffectApp` emit as nested one-argument closures; the nullary forms take an ignored argument so applying unit runs them. This is what keeps the `rt.curry`/`rt.effect` FFI convention intact across all 55 foreign exports — **the risk flagged as the main danger of step 2 did not materialise.** backend-erl needs 953 lines of `Calling.purs` for this only because Erlang has no curried functions and it cannot reach externs; their README states FFI functions stay curried there too.
- **`Fail` is emitted as a diverging statement, never as the value of a `break` or `return`.** `@panic` is `noreturn`, so Zig rejects the enclosing `break :label @panic(...)` as unreachable code. All seven tail positions route through `returnStmt`/`breakStmt`/`tailText`. The CoreFn emitter never hit this because it tracked reachability itself and omitted the panic; the optimizer hands `Fail` over as an ordinary expression in tail position.
- **Five entries in `unsupported` are permanent, not temporary.** `Data.EuclideanRing.intDiv`, `Data.Ord.ordString`, and the three `Data.Int.Bits` shifts are filtered out of `coreForeignSemantics` because the resulting `PrimOp`s assume JavaScript semantics this backend deliberately does not share (Euclidean division returning 0 on divide-by-zero; JS masking shift counts to five bits; no string comparison in the runtime). They stay FFI calls, where the semantics already match. The other twelve entries are batch-2 temporaries.
- **Newtype erasure, `Prim` filtering and `Prim.undefined` are no longer the backend's problem.** The optimizer resolves all three. `GetCtorField` always addresses a real constructor; `imports` arrives with `Prim` and the module's own name already removed, and dead imports dropped.
- **No `analyzeCustom`, and `onPrepareModule` returns `m (Module Ann)`.** See Constraints — this is a property of the pinned tag.

## Constraints and facts

- **Pinned to tag `purs-backend-es-v1.4.2`.** There is no library-versioned tag; the tags are named for the ES CLI release. `BuildOptions` there has exactly five fields: `directives`, `foreignSemantics`, `onPrepareModule`, `onCodegenModule`, `traceIdents`. **The optimizer's `main` branch has diverged** — it adds `analyzeCustom` and makes `onPrepareModule` return `m (Either BackendModule (Module Ann))` for incremental builds. Moving the pin forward requires adding `analyzeCustom: \_ _ -> Nothing` and wrapping the `onPrepareModule` result in `Right`. Read the *tag*, never `main`.
- **`sortModules` is mandatory, not cosmetic.** Feeding modules in readdir order crashes the optimizer with `Invariant broken: could not determine pattern matched constructor's fields during conversion` — `lookupCtorFields` in `Convert.purs` needs the defining module already in the `implementations` map.
- `BackendModule` has **no `path`, no `builtWith`, no `sourceSpan`**. The driver takes `path` from the CoreFn `Module` in `onCodegenModule` for the FFI-sibling copy. This makes the 08-09 `sourceSpan` open question harder, not easier: annotations do not survive into `NeutralExpr` at all.
- `80 of 89 module director(ies) decoded` is correct and expected — the nine are `Prim` and friends, which have no `corefn.json`.
- Per-module `@inline` directives need no wiring; `toBackendModule` reads them off the module's comments itself. Only a directives *file* would need plumbing.
- `rt.concatString` takes and returns `[]const u8` — `OpStringAppend` emits `rt.Value.mkString(rt.concatString(x.asString(), y.asString()))`. Verified by it compiling.
- Spago rewrites `spago.yaml` (adding dependency ranges) and `spago.lock` on every build; expect diffs you didn't type. It also warns the config format is outdated and suggests `--migrate`, not yet done.

## Open questions

- **`diverges` only tests for a literal `Fail`.** A `Branch` whose arms *all* diverge is also `noreturn` and would produce the same unreachable-code error one level up. Not reachable today.
- **`ordString` could come off `unsupported`** if a string comparison were added to the runtime's public surface.
- Generated-block indentation is still hardcoded to eight spaces; `try` is still parenthesised everywhere. Both cosmetic, both now cheaper to fix than before.
- Memoising top-level nullary functions. Integer constructor tags — note `CtorMeta` now carries an integer `tag`, so this is nearly free whenever wanted.
- `docs/codegen.md` needs a rewrite against the new pipeline.

## Artifacts and references

| Item | Location | Notes |
|---|---|---|
| Optimizer, pinned | tag `purs-backend-es-v1.4.2` | Read this tree, not `main` |
| IR definition | `src/PureScript/Backend/Optimizer/Syntax.purs` | 24 constructors; the whole contract |
| Builder entry point | `src/PureScript/Backend/Optimizer/Builder.purs` | 77 lines |
| TCO analysis | `src/PureScript/Backend/Optimizer/Codegen/Tco.purs` | For next action 2 |
| ES backend codegen | `backend-es/src/.../EcmaScript/Convert.purs` | Reference for TCO loop emission |
| backend-erl uncurrying | `src/PureScript/Backend/Erl/Calling.purs` | Read only if uncurrying is ever wanted |

## Dead ends (do not repeat)

- **Reading the optimizer's `main` branch.** Cost three build cycles this session (`analyzeCustom`, then `onPrepareModule`'s `Either`, then a stale copy of both). The tag is the contract.
- **Building an uncurrying layer like backend-erl's.** Unnecessary: Zig has closures-as-values and the FFI is already curried.
- **Passing modules to `buildModules` in any order but `sortModules`'s.**
- **`break :label @panic(...)` / `return @panic(...)`.** Unreachable code in Zig.

## User preferences and communication style

Additive to the earlier lists:

- **Verify against the actual pinned source, don't infer from a nearby version.** Verbatim: *"stop guessing"*. When a version is pinned, read that tree.
- When a fix has been sent and the same error recurs at the same line, suspect a stale file before re-diagnosing.
