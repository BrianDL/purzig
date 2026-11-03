# Handoff — applyN: the tests that make it a claim instead of a green tick

Date: 2026-11-03
Issue: #32 (`runtime: applyN — apply to k arguments`), branch cut from
`agent/01a19634-58af-3e25-91f3-276ab5116cfc`, PR #34.

## The state this branch started in

`runtime/apply.zig` already carried `applyN`, and `runtime/root.zig:46`
already exported it (`pub const applyN = apply_mod.applyN;`). What was missing
was every test. `zig build test` and `zig build test-runtime` exited 0
**because nothing called `applyN`** — a green build over untested new code, the
exact trap this issue exists to close.

The fix is therefore tests only. `applyN`'s body, signature, doc comment and
export line are **unchanged**; the new diff is additions to the test section of
`runtime/apply.zig` (`111` inserted lines, `0` removed).

```zig
/// Apply `f` to `args` left to right. `args.len == 0` returns `f` unchanged.
/// Same error semantics as `apply`: applying a non-callable is an error.
pub fn applyN(f: Value, args: []const Value) Error!Value {
    var out = f;
    for (args) |argument| {
        out = try apply(out, argument);
    }
    return out;
}
```

Still a fold over `apply` — there is no second copy of the application logic,
so arity is only a loop bound. No allocation of its own.

## The tests

Added in `runtime/apply.zig`, in the existing test section and in the same
style as `apply2`/`apply3` ("currying through a captured environment"): an
`ArenaAllocator` + `init(std.testing.io, ...)`, values built with
`Value.mkClosure` / `Value.mkInt` / `value.no_env` / `copyValues`, assertions
via `std.testing.expectEqual`.

1. `applyN with one argument agrees with plain application`
   — `apply(inc, 5)` and `applyN(inc, &.{5})` are compared, then the result is
   pinned to the literal `6`; one argument also saturates a curried function of
   arity one.
2. `applyN with two arguments agrees with apply2`
   — compared with `apply2` on the same value and the same arguments, and
   pinned to the literal `12`.
3. `applyN with three arguments agrees with apply3`
   — compared with `apply3` on the same value and the same arguments, and
   pinned to the literal `123`.
4. `applyN with no arguments returns the function itself`
   — identity, not "did not crash": same closure body, same captured
   environment length and pointer, and the returned value is still the
   two-argument adder it was (`apply2` on it still yields `5`).
5. (extra, covering the arity the issue also asks for)
   `applyN with four arguments reaches a curried function of arity four`
   — one argument past the highest fixed arity, pinned to `1234` and compared
   with the same fold the fixed arities can spell, `apply(apply3(f, 1, 2, 3), 4)`.

### Why the curried value is a digit accumulator

The curried functions are built with the runtime's own constructors — a
closure whose body returns another `Value.mkClosure` over the running total via
`copyValues` — exactly the shape of the existing `addTakeFirst`/`addFirst`
pair, generalised to any arity by carrying `{ arguments remaining, total }`:

```zig
fn digitsCurried(env: []const Value, argument: Value) Error!Value {
    const remaining = env[0].asInt();
    const total = Value.mkInt(env[1].asInt() * 10 + argument.asInt());
    if (remaining == 1) return total;
    return Value.mkClosure(digitsCurried, copyValues(&.{ Value.mkInt(remaining - 1), total }));
}
```

Each argument is accumulated as a decimal digit, so the **result encodes the
order**: `1, 2, 3` gives `123` and the reverse order gives `321`. Order is the
one thing a fold can get wrong that an addition hides — `add(1, 2)` and
`add(2, 1)` are both `3`, so a sum-based test would pass a reversed fold.

## How test 3 proves `applyN` agrees with `apply3`

`applyN == apply3` on three arguments is now **ASSERTED**, not assumed:

```zig
const three = curriedDigits(3);
const args = [_]Value{ Value.mkInt(1), Value.mkInt(2), Value.mkInt(3) };

try std.testing.expectEqual(@as(i32, 123), (try applyN(three, &args)).asInt());
try std.testing.expectEqual(
    (try apply3(three, args[0], args[1], args[2])).asInt(),
    (try applyN(three, &args)).asInt(),
);
```

Both halves matter. The literal `123` anchors `applyN` to a known result, so
the two implementations cannot be wrong together and still pass; the
`apply3` comparison then makes the fixed arity the reference, so the variadic
one cannot drift away from it. The `apply3` call receives the three arguments
individually from the same array that `applyN` receives as a slice, so the only
difference between the two sides is variadic-vs-fixed, never the input.

## Proof that the tests bite (measured, not assumed)

Checking that a green suite means something is the point of this issue, so the
fold was deliberately broken and the suite re-run:

- Mutation: `applyN` folded **right to left** (`while (i > 0)` over
  `args[i - 1]`) — same arity, same values, only the order reversed.
- `zig build test` then reported `31 pass, 3 fail (34 total)`. The visible
  failure was `expected 12, found 21` in test 2, and tests 3 and 5 failed on
  the same order reversal (the tool's `errors[0]` showed test 2 in full and the
  start of tests 3 and 5; the reversed digits make those `321` and `4321`).
  Tests 1 and 4 are order-insensitive by construction (one argument, no
  argument) and correctly stayed green.
- The mutation was then reverted; `runtime/apply.zig` was restored
  byte-identically to the correct fold, and the suite re-ran green.

So the new tests fail when `applyN` is wrong, not merely when it crashes.

## Final tester verdict

Run with the workspace's `purzig_tester` tool against this tree (including
this document), three times in total: a first green run, a deliberately
mutated run that failed as intended, and a final confirm run after the restore.
Final verdict: `ok: true`, `failed_stage: null`, `network_problem: false`.
Final `stages` (verbatim values from the tool's response):

| name | cmd | exit_code | ms |
| --- | --- | --- | --- |
| compiler (purs -> bundle) | `zig build compiler` | 0 | 57067 |
| purs -> corefn -> zig (codegen) | `zig build codegen` | 0 | 12344 |
| zig -> binary (test-e2e) | `zig build test-e2e` | 0 | 7277 |
| zig -> wasm32 | `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` | 0 | 14896 |
| regressions (zig build test) | `zig build test` | 0 | 26005 |

`zig build test` depends on the runtime test runner
(`build/purzig.zig:362 addRuntimeTests`, root source `runtime/root.zig`), so it
is the same set `zig build test-runtime` runs. The suite went from 29 tests to
34: the five new tests are among the tests actually executed, and the earlier
mutation run proves they are live rather than skipped.

## Criteria

1. `zig build test` exits 0 with the new tests among the 34 — **VERIFIED** by
   the tester's final stage above (and the pre-fix run showed the same suite
   failing when a test was wrong).
2. The runtime tests are also addressable directly as
   `zig build test-runtime` — **VERIFIED indirectly**: it depends on the same
   `addRuntimeTests` artifact that the green `zig build test` stage ran. Not run
   as a separate command by the tester.
3. `zig build test-e2e` still exits 0 (and still prints `Hello, Zig`) —
   exit 0 **VERIFIED**; the exact printed line was not inspected by this run.
4. `zig build test-abi`, `test-abi-multi`, `test-library` — **UNVERIFIED**: the
   tester does not run those three steps. Human command:
   `zig build test-abi && zig build test-abi-multi && zig build test-library`.
5. Platform-neutrality: `grep -in 'freenet\|bincode' runtime/apply.zig
   runtime/root.zig` finds nothing — **CHECKED**, no match. The broader
   `grep -n 'freenet\|bincode\|contract'` still matches two *pre-existing*
   comments (`runtime/apply.zig:457`, `runtime/root.zig:66`) that use the
   English word "contract"; neither is about Freenet, and neither line was
   touched by this branch.
6. Diff scope — **CHECKED** with `git diff --stat`: `runtime/apply.zig` (+111,
   -0) and this document. `runtime/root.zig` needed no change: the export line
   was already there. The pre-existing mode-only entries
   `compiler/dist/bundle.js` and `tools/mkpackageset.sh` (0 insertions, 0
   deletions) were dirty before this task and were left alone.

### Commands a human runs to settle 2–4

```sh
zig build test-runtime && zig build test-abi && zig build test-abi-multi \
  && zig build test-library && zig build test-e2e
```
