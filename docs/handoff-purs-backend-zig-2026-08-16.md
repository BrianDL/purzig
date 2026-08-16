# Conversation Handoff: PureScript → Zig backend, step 3 complete

> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.
>
> **This handoff is additive.** It assumes the 2026-08-06 through 08-14 handoffs plus `docs/codegen.md` are already in your context and does not repeat their content. Read those first. Where it says **Supersedes**, the statement here wins.

**Date:** 2026-08-16
**Original session purpose:** Step 3 of the four-step roadmap — vendor `Data.Array`, `Data.String`, `Data.Int` and whatever their closure demands.
**Status:** Step 3 done. `zig build test` green, 231 fixture checks, 171 of 178 foreign exports covered.

---

## Mission

Unchanged. Roadmap: (1) `Effect` — done 08-09; (2) the optimizer — done 08-14; (3) commonly-used libraries — **done this session**; (4) extract into an importable lib.

## Next actions

1. **Step 4: extract the vendored packages into their own repositories, then define a package set** so a downstream user writes `dependencies: [prelude, arrays]` with no `extraPackages` block. There are now **twelve** `extraPackages` entries in `purs/example/spago.yaml`; that list is the thing step 4 deletes. purerl's forked package set is the model.
2. **Update `docs/codegen.md`'s PrimOp table.** It lists ten operators; `emitPrimOp` implements eighteen. `OpIntBitAnd`, `OpIntBitOr`, `OpIntBitXor` and `OpIntBitNot` exist at `Emit.purs:1263` and `:1299–1301` and are missing from the table. Nothing else in that document went stale this session.
3. **Add a `marray` row to `codegen.md`'s type list** — it documents ten `Value` variants and there are now eleven.
4. Optional, unchanged from 08-14: memoise top-level nullary functions; integer constructor tags; suppress redundant `try` parentheses; thread a depth parameter for block indentation.

## Status right now

Twelve packages vendored under `purs/lib/`, 178 foreign exports, one new runtime variant. Shipped in five verified-green batches: A (`integers`, `numbers`), B (`functions`, `strings` partial), C1 (`partial`, `unfoldable`, `foldable-traversable`, `st`), C2 (runtime `marray` + `arrays`), C3 (`enums`, `strings` completed).

## What changed

### The runtime grew a mutable array
`Value` gains `marray: *std.ArrayList(Value)`, with `mkMutArray`/`asMutArray` and a new `runtime/marray.zig` exporting one function, `rt.newMutArray`. A pointer for the reason `ref` is: a write must be observable through every copy of the handle. It cannot reuse `array`, which is a `[]const Value` with no capacity — `push` would be O(n) and `sortBy` O(n²), and `sort`/`nub`/`group`/`union` all run through `Data.Array.ST`.

The surface is one function because everything else is an ordinary `std.ArrayList` operation that `Data/Array/ST.zig` performs through `asMutArray()`. Generated code never touches an `STArray`.

### Twelve vendored packages
`integers` 6.0.0, `numbers` 9.0.1, `functions` 6.0.0, `strings` 6.0.1, `partial` 4.0.0, `unfoldable` 6.0.0, `foldable-traversable` 6.0.0, `st` 6.2.0, `arrays` 7.3.0, `enums` 6.0.1 — all `.purs` byte-identical to their tags, verified by diff before packing.

**Four modules are deliberately omitted** from otherwise-complete packages, each documented in its `spago.yaml`: `Data.Number.Format` (three ECMA-262 formatters, unreferenced), `Data.String.Regex` and its two satellites (needs a regex engine, unreferenced), `Data.String.NonEmpty.*`/`CaseInsensitive`/`Gen` (no FFI, drags in `gen`), `Data.Enum.Gen` (same). Omitting a module from a vendored package costs nothing at build time — purs compiles only what is in `src/`.

## Decisions (settled — do not relitigate)

- **A "code unit" in `Data.String.CodeUnits` is one Unicode code point, not one byte.** Refines the 08-08 note that anticipated byte semantics. Byte indexing breaks `fromCharArray <<< toCharArray` (é decomposes into two `Char`s that re-encode as four bytes), makes `charAt` return half a character, and disagrees with UTF-16 on everything above ASCII where code points agree across the whole BMP. Residual divergence is astral-plane only: `length "<emoji>"` is 1 here, 2 in the JS backend. Cost is O(n) indexing. Pinned by `cuAccented` and `cuRoundTrip`.
- **`Data.String.CodePoints`' FFI is forwarders to the PureScript fallbacks.** Each foreign import takes a `fallback` used in JS only on engines lacking `Symbol.iterator`. The fallbacks are written on `CodeUnits`, which is already code-point indexed, so their surrogate arithmetic is inert and they degenerate to exactly the right operation. The native path the original prefers is the one that would be *wrong* here.
- **A foreign import that PERFORMS an effect defers with `rt.effect`, whatever its type says.** `STFnN` reads like "performs on saturation, so `rt.curry`" — wrong. The emitter lowers `UncurriedEffectApp` to applications followed by `rt.runEffect`, so a saturated `STFnN` must yield a thunk. All 18 `Data.Array.ST` exports are `rt.effect`; only `ST.run`, a pure function *of* an ST value, is `rt.curry`.
- **`runEffectFnN`/`runSTFnN` are `rt.curry`; `mkEffectFnN`/`mkSTFnN` are `rt.effect`.** The run family FORWARDS an existing thunk, the mk family CREATES one. Both were backwards in `Effect/Uncurried.zig` (pre-existing) and in the `ST/Uncurried.zig` written this session. **Supersedes** the 08-09 note that "`mkEffectFnN` forces, `runEffectFnN` defers" — the bodies are right, the wrappers were swapped.
- **Both `sortByImpl`s are transcribed, not handed to `std.sort`.** Two reasons: the sort must be stable, which `std.sort.pdq` is not and which `sortWith` documents; and the comparator is PureScript code that can throw, which `std.sort`'s comparator signature cannot express.
- **`unsafeThaw` copies; `unsafeFreeze` shares.** Sharing on thaw would mean `@constCast`ing a slice that may point at static memory, and a later `poke` would write to a read-only page. The contract says the original is not reused, so copying is invisible to correct programs. `unsafeFreeze` stays O(1) because `Data.Array` ends nearly every ST block with it.
- **`Partial._crashWith`, `Data.String.Unsafe.charAt`/`char` panic rather than throwing.** Follows `rt.forceLazy`: the release notes tell backends to make the error appropriate for the target, and a violated precondition is a defect, not a recoverable condition. They are therefore not catchable by `catchException`, where in JavaScript they would be.
- **`Data.Array.NonEmpty.Internal.traverse1Impl` drops the original's `Cont` trampoline.** It encodes a right fold as thunks purely to spare JavaScript's stack; a backwards `while` is the same computation with the same association order. The applicative structure `apply(map(consList)(f(x)))(acc)` is preserved, which is the observable part. Note it cannot use `traverseArrayImpl`'s balanced-tree split — `Apply` has no `pure`, so there is no empty case to bottom out at.
- **`Data.Traversable.traverseArrayImpl` keeps its balanced tree**, for the opposite reason: the log-depth nesting is a real asymptotic property for an `Applicative` whose `apply` is not cheap, and a loop would silently remove it.
- **FFI files are self-contained; helpers are duplicated, never imported across modules.** The ~90-line UTF-8 block appears verbatim in three string FFI files and the merge sort in two array ones. The driver copies `<Module>.zig` only for modules it compiles, so a shared non-module file never reaches `output-zig`, and importing another module's `.ffi.zig` breaks as soon as that module is not in a build.

## Testing — and why coverage is 171/178, not 178/178

`purs/example/src/Scratch.purs` runs **231 checks**. Coverage was verified mechanically, not by eye: a script maps every `pub const @"ps.…"` export to the PureScript identifiers that reach it and greps the fixture for each. Rerun it when adding FFI.

The seven uncovered exports are uncovered for reasons, not by omission:

- **`Partial._crashWith`** — panics, so any check for it aborts the run.
- **`Data.Array.length`, `Data.Array.unsafeIndexImpl`, `Data.Int.Bits.and`/`or`/`xor`/`complement`** — unconditionally rewritten into PrimOps by the optimizer, so no PureScript call site can reach the Zig. The *PrimOps* are checked (`arrLength`, `arrUnsafeIndex`, `bitsAnd` and friends), so the semantics are covered; only these unreachable bodies are not.

Two testing lessons worth keeping:

- **Interception depends on call shape, not just on the identifier.** A saturated `runSTFn2` is rewritten and never reaches the FFI; a partial application like `Data.Array.ST`'s `splice = runSTFn4 spliceImpl` does reach it. That is how the swapped uncurried wrappers survived. `stUncurried` and `fnUncurried` use a `let`-bound partial application deliberately, to force the FFI path for all 40 shims.
- **A check can pass because the effect never ran.** Before the wrapper fix, `stShift` passed for two builds while `shift` was silently not executing; it started failing once the effect actually happened. Assert each operation separately from a fresh state — a skipped step hides easily inside a chained expectation.

## Constraints and facts

- `Data.Array.ST` exports are `rt.effect`; `Data.Array` (immutable) exports are `rt.curry`.
- `nub` keeps the FIRST occurrence in the ORIGINAL order — it sorts internally to find duplicates, then sorts back by index. The docstring's `nub [1,2,1,3,3] = [1,2,3]` only looks sorted because its input was.
- `Data.Number.round` is `floor(x + 0.5)`, not `@round`: ties go towards positive infinity, so `round (-2.5)` is `-2`. Above 2^52 it returns its argument unchanged.
- `Data.Number.max`/`min` propagate NaN; Zig's `@max`/`@min` return the non-NaN operand.
- `toLower`/`toUpper` are ASCII-only, `trim` handles ASCII whitespace plus NBSP, `localeCompare` compares by code point. `S.toUpper "clé"` is `"CLé"`, asserted.
- `Data.Enum.fromCharCode` masks to 16 bits, consistent with `topChar` being `0xFFFF` from 08-08.
- Empty-pattern behaviour in `Data.String.Common` is transcribed, not approximated: `replaceAll (Pattern "") (Replacement "X") "ab"` is `"XaXbX"`.
- `numbers` depends on `functions` for `Fn4`, which is why `functions` is vendored despite all 20 of its exports being dead.
- PureScript's `<*>` is `infixl 4` and `==` is `infix 4` — mixing them without parentheses is `MixedAssociativityError`.
- An anonymous argument must be a **direct** argument of the enclosing expression: `(_ + 1)` is fine, `(_ + a + b)` is not. (Recorded in 08-09; walked into again.)
- Spago regenerates `spago.lock` whenever `extraPackages` changes, which re-clones the optimizer on the next build. Harmless, slow once.

## Open questions

- **`Effect/Uncurried.zig`'s `mkEffectFnN` family is fixed but only indirectly tested.** `mkSTFn2` is exercised by `stUncurried`; the `Effect` equivalents are not, because nothing in the vendored closure uses them. Worth a fixture if `Effect.Uncurried` ever gets a real consumer.
- Unchanged from 08-14: `diverges` tests only for a literal `Fail`; `ordString` could leave `unsupported` if the runtime gained string comparison; `sourceSpan` reaches nothing; memoisation, integer tags, indentation, redundant `try` parens.

## Artifacts and references

| Item | Location | Notes |
|---|---|---|
| Vendored packages | `purs/lib/purescript-{integers,numbers,functions,strings,partial,unfoldable,foldable-traversable,st,arrays,enums}/` | Plus the six from 08-09 |
| Mutable arrays | `runtime/marray.zig` | Three tests in `test-runtime` |
| Fixture | `purs/example/src/Scratch.purs` | 231 checks |
| Workspace config | `purs/example/spago.yaml` | Twelve `extraPackages` entries — step 4 deletes these |
| Optimizer foreign semantics | `src/PureScript/Backend/Optimizer/Semantics/Foreign.purs` at the pinned tag | The authority on what is intercepted |

## Dead ends (do not repeat)

- **Reasoning about `rt.curry` vs `rt.effect` from the PureScript type.** `STFnN` looks like it performs on saturation; what decides is how the emitter lowers the call. Read the generated Zig.
- **Assuming an optimizer-intercepted import is unreachable.** Interception fires only on saturated call sites.
- **Hand-tracing an expected value for a multi-step mutable fixture.** Produced three wrong answers in a row this session (`nub`, `stShift`, the `splice` round-trip). Split the fixture and let it name the failing step.
- **`STA.run` for a block whose value is not an `STArray`.** It requires one, and thawing a result just to satisfy the type tests nothing. `ST.run` returns the value directly.
- **Sharing storage in `unsafeThaw`.** `@constCast` on a possibly-static slice, then a write.

## User preferences and communication style

Additive to the earlier lists:

- **One file means one file, not a tarball.** Present it directly and state its destination path. Reserve `.tar.gz` for multi-file batches or when two files share a basename.
- **"Stop guessing."** When two hypotheses fit the evidence, ask for the artifact that discriminates them — the generated `.zig`, the actual source at the tag — rather than shipping a plausible fix. Said twice this session, both times deservedly.
- Verifies by running `zig build test` and pasting the output, including the full backend module list. Expect one fix per cycle.
