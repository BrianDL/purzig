# Conversation Handoff: PureScript → Zig backend, MagicDo + TCO complete

> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.
>
> **This handoff is additive.** It assumes the 2026-08-06 through 08-12 handoffs are already in your context and does not repeat their content. Read those first. Where it says **Supersedes**, the statement here wins.
>
> **`docs/codegen.md` was rewritten this session** and now matches the implementation exactly. It is the primary reference for anything about emission; this file records only what changed and why.

**Date:** 2026-08-14
**Original session purpose:** Finish the optimizer adoption (batch 2), then implement TCO.
**Status:** All green. Every item on the 08-12 "Next actions" list is done except step 3.

---

## Mission

Unchanged. Roadmap status: (1) `Effect` — done 08-09; (2) the optimizer — done 08-12, **finished this session**; (3) `Data.Array`/`Data.String`/`Data.Int` — **next**; (4) extract into an importable lib.

## Next actions

1. **Step 3: `Data.Array`, `Data.String`, `Data.Int`** — the commonly-used subset, vendored with Zig FFI the same way the prelude was. Note the optimizer changes what is needed: operations it turns into a `PrimOp` (`Data.Array.length`, `unsafeIndexImpl`, arithmetic, comparison, `<>`) are emitted and compiled but never called, so writing their FFI carefully is wasted effort.
2. **Step 4: extract into an importable lib**, then a package set, so `dependencies: [prelude]` works without an `extraPackages` block.
3. Optional, in rough value order: memoise top-level nullary functions; integer constructor tags (`CtorMeta` already carries an integer `tag`, so this is nearly free); suppress redundant parentheses on `try`; thread a depth parameter for block indentation.
4. `docs/corefn-schema.md` is now historical — nothing in the backend reads `corefn.json` except the driver, which hands the bytes to `decodeModule`. Keep it, but it is not a current contract.

## Status right now

`zig build test` is green. `Scratch.purs` runs 27 checks; the two new ones (`deepSum`, `deepCount`) recurse a million deep and would blow the stack without TCO. `Main`'s asserted stdout is unchanged.

Deferred cleanups from 08-09 are **done**: `purs/lib/zig-prelude/` deleted, stale `output/` directories cleared.

## What changed

### Batch 2 — the four effect nodes
`EffectBind`, `EffectPure`, `EffectDefer` and `PrimEffect` are implemented, and the twelve `Effect`/`Effect.Ref`/`Control.Monad.ST` entries are out of `unsupported`. **`unsupported` is now five entries, all permanent** — `intDiv`, `ordString` and the three `Data.Int.Bits` shifts, where our semantics deliberately differ from JavaScript's.

### TCO
Landed in three batches, each verified green. `Emit.purs` consumes `TcoExpr` (via `unTcoExpr`) rather than `NeutralExpr`. Top-level and local (`LetRec`) tail-recursive groups, including mutual ones, become real Zig loops. `Data.Void.absurd` picks one up from the prelude unprompted.

### `docs/codegen.md` rewritten
Deleted the `Case`/binder-table, newtype-erasure, `Prim`-filtering and name-suffixing sections — all now the optimizer's job and actively misleading as written. Added `Branch`, `PrimOp`, the effect nodes, `Fail`-as-statement, and a full Tail calls section.

## Decisions (settled — do not relitigate)

- **A chain of `EffectBind`s flattens into ONE Zig block**, not a thunk per bind. `emitPerform` is the other half: every node the optimizer produced structurally is *known* to be an effect, so `EffectPure x` emits as `x` with no closure and no `runEffect`, and a `Ref` read is a pointer dereference. That is the whole MagicDo win.
- **The ES backend's TCO shape does not transfer.** It puts the loop inside the curried arrow chain because a JavaScript closure may reassign a captured `let`; ours cannot, since curried arguments live in a `[]const rt.Value` env. The loop is therefore a **separate uncurried Zig function** with `var` copies of every argument, called by the innermost lambda of an otherwise unchanged curried chain. Every call site, `rt.apply`, partial application and the FFI convention are untouched.
- **Slot mutability cannot be decided before emission.** Zig rejects a `var` that is never mutated, and in a mutual group with mixed arities a high slot may belong to a member nothing jumps to. `St` therefore carries `touched`, recording assigned slot indices, saved and restored around each group so a nested loop does not report its assignments as the enclosing one's.
- **Join points are deliberately not implemented.** The ES backend needs them because a JavaScript call in tail position still grows the stack. In Zig a join is an ordinary call that returns before the next iteration — one transient frame, never accumulating. The residual cost is one `mkClosure` per enclosing evaluation, which inside a loop body is an allocation per iteration; revisit alongside the arena, not before.
- **A synthesised IR node carries `mempty` analysis.** `emitAbsChain` rebuilds the tail of a curried `Abs` as `TcoExpr mempty (Abs rest body)`. Sound because a synthesised node is only walked, never consulted for a TCO decision.
- **Depth is tested behaviourally, not by grepping generated Zig.** `deepSum`/`deepCount` at a million iterations cannot pass without TCO. Asserting on emitted text would be a golden-file test by another name — the same reason those were dropped in 08-06.

## Constraints and facts

- **`BuildOptions` at tag `purs-backend-es-v1.4.2` has exactly five fields** and `onPrepareModule :: BuildEnv -> Module Ann -> m (Module Ann)`. The `analyzeCustom` field and the `Either` return are `main`-branch only. **Supersedes** anything in the 08-12 handoff implying otherwise — that file's description came from `main` and cost three build cycles here.
- **`sortModules` must actually be called.** Importing it and not calling it produces a redundant-import warning and then `Invariant broken: could not determine pattern matched constructor's fields` from `lookupCtorFields`, several modules into the run.
- The no-captures case threads `env` through four independent places — loop signature, wrapper chain, self-reference, `Let`-site binding — and each needed its own discard. Zig's unused-parameter and unused-local rules are separate checks, so they surface one layer at a time.
- `rt.newRef(v)` takes and returns a `Value`; ref read and write are `.asRef().*`.
- Every `Effect` do-block statement whose result is ignored binds `$__unused`; the loop combinators bind a result nobody reads. Both must be discarded rather than bound.

## Open questions

- **`diverges` only tests for a literal `Fail`.** A `Branch` whose arms all diverge is also `noreturn` and would hit the same unreachable-code error one level up. Not reachable today.
- `ordString` could leave `unsupported` if a string comparison were added to the runtime's public surface.
- Memoising top-level nullary functions; integer constructor tags; block indentation; redundant `try` parentheses. All unchanged, all cosmetic or deferred.
- `sourceSpan` still reaches nothing — annotations do not survive into `NeutralExpr`, and `TcoExpr` wraps analysis, not source position.

## Artifacts and references

| Item | Location | Notes |
|---|---|---|
| Codegen spec | `docs/codegen.md` | Rewritten this session; matches the implementation |
| TCO analysis | `Codegen/Tco.purs` at the pinned tag | `analyze`, `tcoRoleIsLoop`, `topLevelTcoEnvGroup`, `localTcoRefBindings` |
| ES loop emission | `backend-es/src/.../EcmaScript/Convert.purs` | `codegenTcoMutualLoopBindings` and friends; read for shape, not to copy |
| Fixture | `purs/example/src/Scratch.purs` | 27 checks; the two depth ones fail by crashing, not by label |

## Dead ends (do not repeat)

- **Describing the optimizer's API from `main` when a tag is pinned.** Three build cycles.
- **Asserting on generated Zig text** to prove an optimisation fired. The user's correction: *"why do we need to look outside our test suite to actually assert something is happening in the code. That's not how it works"* — the fixture is the assertion.
- **Assuming a recursive function's `env` is used.** A tail self-call is a jump, not a closure, so being recursive does not make `env` read. `Data.Void.absurd` catches this — as it did the analogous bug in 08-08.

## User preferences and communication style

Additive to the earlier lists:

- **Tests assert behaviour; nothing outside the test suite is a check.** If an optimisation cannot be observed behaviourally, add a fixture that makes it observable rather than inspecting output.
- **Momentum matters.** Land green, then improve, and prefer doing the throwaway-free version when the intermediate would be discarded entirely.
- When the same error recurs at the same line after a fix was sent, suspect a stale file before re-diagnosing.
