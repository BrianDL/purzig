# Conversation Handoff: PureScript → Zig backend, Stage 2 complete
 
> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.
>
> **This handoff is additive.** It assumes `handoff-purs-backend-zig-2026-08-06.md` (and the 08-05 file it supersedes) are already in your context and does not repeat their content. Read those first; this file records only what changed on top of them. Where it says **Supersedes**, the statement here wins.
 
**Date:** 2026-08-07
**Original session purpose:** Implement Stage 2 — data types — starting with the smallest, most atomic edits.
**Status:** Stage 2 complete. `zig build test` green. Every CoreFn expression node is implemented.
 
---
 
## Mission
 
Unchanged from the 08-06 handoff. Stage 2 is now **done**: `ObjectUpdate`, recursive `let`, and `Case` in full.
 
## Next actions
 
1. **Grow `zig-prelude` and its FFI as demanded**, then eventually port the real `purescript-prelude`. This is the last item from the 08-06 "Next actions" list still outstanding, and it's now unblocked — records, `Accessor`, and `Case` all exist, which was the ordering problem that made the real prelude undeployable.
2. **Cosmetic: indentation of generated blocks.** Every emitted statement is hardcoded to eight spaces, so nested `Let`/`Case` blocks come out visually wrong. Compiles fine. Fixing it means threading a depth parameter through `emitExpr`.
3. **Untested binder forms.** Array and numeric `LiteralBinder`s are implemented but not covered by any fixture — the example has no `Array` or arithmetic yet, both of which need a real prelude. They come along with item 1.
4. Then the open questions below: memoisation, integer tags, `purescript-backend-optimizer`.
## Status right now
 
`zig build test` is green. A single `zig build run` exercises the whole Stage 2 surface via `purs/example/src/Scratch.purs`: constructors at arity 0/1/2, nested `ConstructorBinder`, `NamedBinder`, string `LiteralBinder`, guards with fallthrough, an irrefutable catch-all, recursive `let` with a captured local, record literal with a runtime field, record update, accessor. Output is still `Hello, Zig`, so `test-e2e`'s assertion is unchanged.
 
`docs/codegen.md` is up to date with all of it.
 
## What changed
 
### Implemented
- **`ObjectUpdate`** → `rt.updateRecord(base, &.{...})`. Copy-on-write, preserves the base's field order, panics if an update key is missing from the base (a miss is a backend bug — record update is type-checked).
- **Recursive `let`** → the group is lifted to `fn @"ps.f.recN.M"(env, arg)` sharing one environment (union of members' free vars, minus the members). Within the group a member is `rt.Value.mkClosure(fn, env)` — a **value, not a call**. A call would re-enter the function while building its own capture list and loop forever.
- **`Case`** in full: all binder forms and guards. Structured after the compiler's own JS backend `bindersToJs`.
### Bugs found and fixed (all latent, none reported by a user)
- **`LitObject` emitted a dangling pointer.** `mkRecord(&.{...})` stores a pointer to a stack temporary when any field value is runtime-computed. `LitArray` already wrapped in `copyValues`; records didn't. Now `rt.Value.mkRecord(rt.copyFields(&.{...}))`.
- **Block labels collided.** A fixed `blk:` broke as soon as one `Let` nested inside another — which `ObjectUpdate` triggers immediately, because record-update desugaring introduces a `Let`. Labels now come from the fresh-name counter: `blk0`, `case3`.
- **`emitAbs` rebuilt captured names instead of reading the scope map.** Would have emitted `@"v.x"` for a shadowed binder actually bound as `@"v.x.3"`. Fixed via a new `scopeText` helper, which is also what makes recursive `let` work (a group member's "name" is a whole `mkClosure` expression).
### Runtime additions
`rt.copyFields`, `rt.updateRecord`, and on `Value`: `asRecord`, `asChar`, `asArray`, `stringEq`. All covered by `zig build test-runtime`.
 
## Decisions (settled — do not relitigate)
 
- **A binder wraps a continuation; it is not a (test, destructure) pair.** Borrowed wholesale from the JS backend. `emitBinder` takes the code to run once the binder matched. Nested binders compose for free — every form differs only in how it addresses its sub-subject (`.arg(i)`, `.asArray()[i]`, `.field("k")`). **Supersedes** the `Case` sketch in the 08-06 `codegen.md`, which described nested `if`s and a test/destructure pair.
- **Reachability is tracked during emission** via a `canFail` flag. The JS backend emits its "Failed pattern match" throw unconditionally because JS tolerates statements after `return`; Zig rejects unreachable code outright. An alternative whose binders emit no test always matches, making later alternatives *and* the trailing `@panic` dead — emission stops there.
- **Guards always report `canFail: true`**, even when the last guard is literally `true`. If every guard fails, PureScript resumes at the next alternative rather than failing the match. Over-reporting costs a dead `@panic`; under-reporting fails the build.
- **Only `Abs` members are supported in a recursive `let`.** PureScript 0.15's laziness transform is a *backend* responsibility — CoreFn hands over the raw `Rec` group, and purerl implements the transform itself. Restricting to function bindings sidesteps it entirely, because a recursive function's self-reference is only forced when called.
- **Generated code references `rt` and nothing else.** Only the entry module imports `std`, so string comparison is `Value.stringEq`, not an inline `std.mem.eql`. Adding `@import("std")` to every generated module was rejected: it widens generated code's dependency surface to the whole standard library.
- **Keep `purs/example/expected/` for now.** A parallel conversation deleted it, correctly reasoning that it becomes a hand-maintained golden file the moment `Main.purs` grows. It only becomes a burden when that happens — deleting it now would mix a `build.zig` edit into unrelated changes. Revisit when the real prelude lands.
## Constraints and facts
 
- `purs/example/src/Scratch.purs` is the scratchpad; `Main.purs` stays a fixture whose stdout is asserted. `Main` imports `Scratch` so the scratch code is actually reachable — without that import the generated `Scratch.zig` is written but never compiled by Zig.
- The example workspace has **no Prelude**. No `otherwise`, no `==`, no arithmetic. Fixtures must use `if`, Boolean literals, and constructors only. `| true =` in place of `| otherwise =`.
- **Recursive `let` was untestable until `Case` existed.** Every base case in PureScript goes through `if` or a pattern match, and both are `Case` in CoreFn.
- Two new skills were written this session and are installed: `purescript-0.15-syntax` and `zig-0.16-syntax`. Consult them before writing either language. The PureScript one exists because of repeated syntax errors, chiefly **record construction uses `:`, record update uses `=`**.
## Open questions
 
Unchanged from 08-06: `purescript-backend-optimizer` adoption, memoising top-level nullary functions, integer constructor tags. All still *blocked on: a real workload existing*, which item 1 in Next actions provides.
 
## Artifacts and references
 
| Item | Location | Notes |
|---|---|---|
| Codegen spec | `docs/codegen.md` | Updated this session; matches the implementation exactly |
| Scratch fixture | `purs/example/src/Scratch.purs` | The only thing exercising Stage 2 |
| JS backend `bindersToJs` | https://hackage.haskell.org/package/purescript-0.5.0/docs/src/Language-PureScript-CodeGen-JS.html | Old version, but the algorithm shape is the one copied |
| purerl release notes | https://github.com/purerl/purerl/releases | Where the laziness-transform finding came from |
 
## Dead ends (do not repeat)
 
- **Inline `std.mem.eql` in generated code** — `std` is only imported by the entry module.
- **A fixture using `otherwise`, `==`, or arithmetic** — not available without a Prelude.
- **Editing a file by targeting the blank line above a declaration.** Done twice this session; both times it joined a signature to its definition and cost a build cycle. Anchor edits on the declaration itself. A useful post-edit check: every top-level signature must be followed by its own definition, and no line should contain `;` followed by more code.
## User preferences and communication style
 
Additive to the 08-06 list:
 
- **Search the docs before hedging.** Verbatim: *"Since you know the version, you can search the docs to verify the syntax."* Stating "I couldn't verify this without the toolchain" when a primary source exists is not acceptable.
- **Look at existing backends' code for patterns** before inventing one. Verbatim: *"when you find these things try to look into the existing backends to copy their patterns."* This paid off twice — the continuation-fold design and the laziness-transform finding both came from doing it.
- Wants to **move fast** once the shape is clear; batch the remaining pieces of a feature rather than one-at-a-time once the risky part is proven.
