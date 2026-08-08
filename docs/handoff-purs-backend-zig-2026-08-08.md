# Conversation Handoff: PureScript → Zig backend, Stage 3 complete

> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.
>
> **This handoff is additive.** It assumes the 2026-08-06 and 2026-08-07 handoffs are already in your context and does not repeat their content. Read those first. Where it says **Supersedes**, the statement here wins.

**Date:** 2026-08-08
**Original session purpose:** Stage 3 — make this usable like any other PureScript backend.
**Status:** Both stated goals met. `zig build test` green with the real `purescript-prelude` compiling and running.

---

## Mission

Two goals, both now met:

1. **Syntax parity** — writing PureScript works. This was already true once every CoreFn node emitted; what was missing was libraries, i.e. the Prelude.
2. **FFI like any other backend** — a package ships its own Zig FFI beside its `.purs`, and needs no central registration.

## What works right now

`purs/example/src/Scratch.purs` contains `if 1 + 1 == 2 then n else show (3 * 4)` and it compiles, links and runs. That exercises the full type-class dictionary path, newtype-erased accessors, and `intAdd`/`intMul`/`eqIntImpl`/`showIntImpl` in Zig. All 50 prelude modules pass through the backend; 17 carry FFI.

## Next actions

1. **Widen `Scratch.purs`.** It was narrowed to a one-liner to debug the Prelude landing, and lost the `Shape` data type that covered constructors, nested binders, `NamedBinder` and guards. Restore that *and* keep the Prelude usage. Array and numeric `LiteralBinder`s are still untested and now finally testable, since `Array` and arithmetic exist.
2. **`Effect` properly.** `Effect.Console`, `Effect.Ref`, `Effect.Exception`, and the `Effect` foreign imports (`pureE`, `bindE`, `untilE`, `whileE`, `forE`, `foreachE`). Same vendoring treatment as the Prelude.
3. **Tail-call optimisation.** The largest correctness risk outstanding — see Known divergences.
4. `Data.Array`, `Data.String`, `Data.Int` — the commonly-used subset only.
5. Extract `purs/lib/purescript-prelude` into its own repo, then a package set, so `dependencies: [prelude]` works without an `extraPackages` block.

## What changed

### FFI moved beside the source (the core of goal 2)
- `Foo/Bar.purs` pairs with `Foo/Bar.zig`, exactly as with `.js` for JavaScript and `.erl` for purerl. The driver reads `modulePath` from corefn.json and copies the file to `output-zig/<Module>.ffi.zig`; the generated module imports it by relative path.
- **Deleted `ffi/` entirely** — the central aggregator and its `build.zig` module binding are gone. Three concepts collapsed into one rule.
- **Deleted `purs/example/expected/`** — it imported the `ffi` module, and had already gone stale when `Main.purs` grew.
- A module with foreign imports and no `.zig` beside it logs `MISSING FFI` naming the expected path, and does not abort the run.

### Comptime currying (`runtime/curry.zig`, new)
- `rt.curry(f)` for pure functions, `rt.effect(f)` for `Effect`s (adds the trailing unit thunk; handles nullary `f`). Both generate the closure chain from the function's signature via `std.meta.ArgsTuple` + `@call`.
- purerl parses arity from the Erlang export list because Erlang offers nothing else; Zig has comptime reflection, so **the backend never learns about arity**. All the work is in the runtime.
- This removed every hand-managed `env[i]` index from FFI — the real win, since those are unchecked positional conventions and there are now 49 functions.

### The Prelude, vendored
- `purs/lib/purescript-prelude/` holds `purescript-prelude` 6.0.2's unmodified `.purs` plus 17 hand-written `.zig` files (49 foreign exports). `spago.yaml` declares `name: prelude`; the example overrides the registry copy via `extraPackages: prelude: path:`.
- Registry packages ship JavaScript and cannot have files added, so a backend needing different FFI must carry its own copy. purerl solves this with a whole forked package set; this is the same idea at one-package scale.
- Sources were read from the actual `v6.0.2` tag and diffed against `master` — byte-identical for all 17.

### Emitter bugs found by the Prelude (none reachable from hand-written fixtures)
- **`Prim.undefined`** in expressions — a placeholder for an erased type argument, passed around but never forced. Emits `rt.Value.mkUnit()`. This alone was most of 282 errors.
- **`Prim.*` submodules** — `Prim.Row`, `Prim.RowList` and friends are equally fictional. The test is the `Prim.` prefix, not equality.
- **Unused lambda parameters** — every `\_ -> ...` and erased dictionary argument. Zig rejects them; discard when the argument is not free in the body.
- **`_ = env;` in recursive-`let`** — `env` appears verbatim in every member reference, so discarding on "no captures" is wrong. `Data.Void.absurd` catches it.
- **Newtype erasure** — see below.

## Decisions (settled — do not relitigate)

- **Newtype erasure is the backend's job, and it is correctness, not optimisation.** CoreFn emits a newtype constructor as the *identity function*, so the wrapper never exists at runtime — but the binder side still arrives as a `ConstructorBinder` carrying `meta: IsNewtype`. Ignoring the meta emits a `hasTag` test against a value that was never tagged. Single-method type classes are newtypes, so `Eq`, `Ord`, `Show`, `Functor` and `Semigroup` all depend on it. **Supersedes** `codegen.md`'s old "Newtypes are erased by the compiler. Nothing to do."
- **`meta` is now decoded, but only `IsNewtype`.** Read through `.:?` at every level so a null or absent field yields `false` rather than failing: a spurious `false` merely leaves a tag test that was already being emitted, whereas a decode error would drop the whole module.
- **FFI may import `std` and use `rt.alloc()`.** The "generated code references `rt` and nothing else" rule applies to *generated* code, not hand-written FFI.
- **Foreign exports are `rt.Value`s**, wrapped with `rt.curry`/`rt.effect`. Not Zig functions the emitter has to know the arity of.
- **Vendoring is the price of shipping FFI for a registry package.** The `LICENSE` is copied and must travel with the sources.

## Known divergences from the JavaScript backend

Written down because they are deliberate, not bugs to fix casually:

- **No tail-call optimisation.** Every call goes through `rt.apply` into a fresh Zig frame. The JS backend rewrites saturated self-recursive functions into loops. Idiomatic PureScript recurses freely, so this is a stack overflow at depth — the largest correctness risk outstanding.
- **Int is 32-bit wrapping**, matching JavaScript's `| 0`. Every Int operation in the FFI uses `+%`, `-%`, `*%`. Zig's `+` panics on overflow in Debug where JS silently wraps.
- **Int division is Euclidean and division by zero returns 0**, not a trap. `@divTrunc`/`@rem` give different answers for negative operands, so the JavaScript definitions were transcribed rather than mapped onto the nearest builtin.
- **String is UTF-8, not UTF-16.** `length`, `charAt`, `splitAt` will disagree on non-ASCII. purerl made the same trade and documents it.
- **`showNumber` uses Zig's `{d}`**, which will not match `Number.prototype.toString` in every case. Integers and simple decimals agree.
- **The arena never frees.** Fine for a compiler or a script, wrong for a long-running process.

## Constraints and facts

- `Data.Bounded.topChar` is `0xFFFF` because PureScript's Char is a UTF-16 code unit. Our Char is a `u21` and could hold more; agreeing with other backends matters more.
- `Record.Unsafe.unsafeSet` **adds** a missing field, unlike `rt.updateRecord`, which panics — record-update syntax is type-checked, `Record.insert` is not.
- `Data/Ord.zig`'s `compareValues` switches on the `Value` union directly rather than through accessors — the one place FFI reads the union rather than its public API.
- `ordArrayImpl` returns `-1` when the LEFT array is longer. Counterintuitive, and it is what the original does.
- The scalar `ord*Impl` functions take `LT`/`EQ`/`GT` as their first three arguments and return one of them — arity five, not `-1/0/1`.
- Uploads land in one flat directory, so files with colliding basenames (`root.zig`, `Main.purs`) must be archived per batch before reading.

## Artifacts and references

| Item | Location | Notes |
|---|---|---|
| Codegen spec | `docs/codegen.md` | Updated this session; FFI section fully rewritten |
| Vendored prelude | `purs/lib/purescript-prelude/` | 6.0.2 sources + 17 `.zig` files |
| Currying | `runtime/curry.zig` | Covered by `zig build test-runtime` |
| purerl FFI convention | https://github.com/purerl/purerl | README, "foreign" section |
| purescript-prelude | https://github.com/purescript/purescript-prelude | Read at tag `v6.0.2` |

## Dead ends (do not repeat)

- **A central `ffi/` directory keyed by module name.** Works for one in-repo package, cannot work for third-party ones. Replaced by beside-the-source files.
- **Parsing arity in the backend** to curry FFI, as purerl does. Unnecessary given comptime reflection.
- **Assuming `master` matches the pinned version.** It did here, but only because it was checked.
- **Working from a hand-built list of FFI modules.** Two were missed (`Data.Reflectable`, `Data.Show.Generic`). Enumerate from the sources: for each `.purs` containing `^foreign import`, assert a sibling `.zig`.

## Build steps

`test-expected` and `run-expected` no longer exist. Current: `run`, `codegen`, `test`, `test-runtime`, `test-e2e`, `clean-purs`.

## User preferences and communication style

Additive to the earlier lists:

- **State the destination path beside every file presented.** Presented artifacts show only a basename, which is ambiguous for `Main.purs`, `root.zig`, `spago.yaml`. For multi-file batches, ship a `.tar.gz` with repo-root-relative paths instead.
- **Verify with the primary source rather than hedging or guessing.** Fetching the actual `.js` from the pinned tag corrected two things that would have been wrong from memory (`ord*Impl` arity, `unsafeSet` adding fields).
- Wants to **move fast** once the shape is clear.
