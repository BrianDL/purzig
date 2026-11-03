# Handoff — abi: a byte-exact call path (`callRaw`)

Date: 2026-11-03
Issue: #27, "abi: a byte-exact call path — raw bytes in and out, no UTF-8
assumption"

## What changed

- `runtime/abi.zig` — `callRaw`, documented at the top of the file, plus a
  `Shape = enum { text, raw }` that `call` and `callRaw` are two-line wrappers
  over. `call` and `callBytes` behave exactly as before: `call` is now
  `applyInputs(..., .text, out)` and `callBytes` still calls `call`.
- `runtime/abi.zig` — six tests: a byte round trip, a compiled-style function
  reading element 0 (forwards and empty), `ins.len == 0`, a non-byte-like
  result, a thrown value, and the copy of the caller's input.
- `runtime/root.zig` — doc comment on the `abi` re-export now names `callRaw`.
- `example/src/Bytes.purs`, `example/abi/abi_raw.zig` — the fixture.
- `build.zig` — one new step `test-abi-raw`, added to the `test` step on its own
  line (`all_tests.dependOn(&abi_raw.step);`), not by extending an existing
  `dependOn` chain.
- `docs/codegen.md` — a paragraph in "Byte entry point": `String` for text,
  `callRaw` for bytes, the difference is the UTF-8 step and nothing else.

## The `Value` representation, and why

Bytes are an **`Array Int`, one integer per byte**, built with the constructor
`runtime/value.zig` already has. Nothing in `value.zig` changed; no union arm was
added.

Quoting `runtime/value.zig`:

```zig
pub const Value = union(enum) {
    unit,
    boolean: bool,
    integer: i32,
    ...
    array: []const Value,
    ...
    pub fn mkInt(v: i32) Value {
        return .{ .integer = v };
    }
    ...
    pub fn mkArray(items: []const Value) Value {
        return .{ .array = items };
    }
```

Why this rather than a `bytes: []const u8` arm: a new arm has to appear in every
`switch` over `Value` in the runtime (the accessors, `apply`, the emitters'
translation of `Array`, `curry`, `lazy`, `marray`, ...), and generated code can
never produce it — the backend is untyped but `Array Int` is a type PureScript
already has. With `array` + `mkInt`, a compiled `Array Int -> Int` is callable
with no representation change at all, and the awkwardness of spelling bytes as
integers is confined to `abi.zig`. The one lossy alternative — passing bytes as
a `String` and reinterpreting on the callee's side — is exactly the corruption
this issue exists to remove.

The mapping lives in exactly one place, `rt.abi.byteArray(in: []const u8) Value`,
which `callRaw` uses for every input and which is public so a caller that wants a
result the raw reply refuses (an `Int`, a record) can build the same argument and
apply the function itself. `example/abi/abi_raw.zig` does exactly that for
`firstByte`.

The reply side is symmetric: a `String` (its bytes are bytes) or an `Array Int`
whose elements are all in `0..255`. An `Int`, a record, a closure, an array
holding a non-`Int`, and an out-of-range `Int` are all `Status.failed` with a
reason. Nothing is truncated: data loss reported as success would be worse than
a refusal. `Status` is unchanged, still `ok | failed` and still transport-only.

## How `callRaw` differs from `call`

One step: `call` turns each input slice into a PureScript `String`
(`Value.mkString`) and reads a `String` back, while `callRaw` turns each input
slice into an `Array Int` of its bytes (`byteArray`) and reads a byte-like value
back — no `String` is ever built on the way in, so nothing on the path asks
whether the bytes are text. Arity, left-to-right application, copying each input
into the runtime allocator, the thrown-value handling, the caller-owned
`Reader`, `ins.len == 0`, and the two-variant `Status` are identical.

`runtime/abi.zig` still reaches for no `std.Io`, no `std.debug`, no allocator of
its own, and no platform vocabulary: `grep -in 'freenet\|bincode\|contract'
runtime/abi.zig` finds nothing, and `grep -n 'invalid' runtime/abi.zig` finds
nothing (both run, both exit 1).

## Exact stdout of `test-abi-raw`

`build.zig` asserts

```
ff 00 fe
255
```

i.e. the Zig literal `"ff 00 fe\n255\n"`: the reply bytes from `echoByte` as
lowercase hex with single spaces, then the decimal `Int` that `firstByte` read out
of the same input.

## `Bytes.purs` imports: Prelude and nothing else

Verified by grep — the module's only import line is `import Prelude`.

**One deliberate deviation from the module in the issue**, because the issue's
`case` does not compile. The issue's `firstByte` uses a cons pattern:

```purescript
at0 a i = case a of
  [] -> -1
  b : _ -> if i == 0 then b else at0 a (i - 1)
```

`:` is `List`'s pattern synonym, not an `Array` pattern, and `Data.List` is not
importable here. `spago build` rejects the whole module:

```
[ERROR 1/1 UnknownName] src/Bytes.purs:41:7

  41      b : _ -> if i == 0 then b else at0 a (i - 1)
            ^

  Unknown operator (:)
```

(observed on the purzig worker, first `purzig_tester` run of this branch). The
replacement uses LITERAL array patterns — legal PureScript, Prelude only — so
`firstByte` takes element 0 for the lengths a byte fixture can start with:

```purescript
firstByte :: Array Int -> Int
firstByte a = case a of
  [] -> -1
  [b] -> b
  [b, _] -> b
  [b, _, _] -> b
  _ -> -1
```

`echoByte` is exactly as specified (`echoByte xs = xs`), and `firstByte` still
is what the acceptance criterion needs: a compiled PureScript function that reads
a byte out of the `Array Int` the raw path handed it (`[0xff, 0x00, 0xfe]` →
`255`), with no `Maybe`, no `Data.Array`, and no dependency added to
`example/spago.yaml`.

## What was actually run

Only `purzig_tester` (no arguments), which builds compiler → codegen →
test-e2e → wasm → `zig build test` on the purzig worker against this tree.
Final verdict: **`ok: true`, `errors: []`**, all five stages `exit_code: 0`,
`network_problem: false`.

That is stronger than "I did not break anything", so it is worth being precise
about: the tester's **`zig build test`** stage includes the `test` step, and this
change adds `all_tests.dependOn(&abi_raw.step)`, so `abi-raw-probe` was compiled
and RUN inside that stage, with `expectStdOutEqual("ff 00 fe\n255\n")` as the
assertion — a stdout mismatch fails the step, and the step is not a caching
no-op (the previous run on this branch failed inside it, naming
`run exe abi-raw-probe`). The same stage also runs `test-abi`
(`hi!`), `test-abi-multi` (`abcd`), `test-library`, `test-exports`,
`test-e2e`'s assertion, and `test-runtime`.

Two earlier runs of the same tool on this branch, and what they caught:

1. `Unknown operator (:)` in `Bytes.purs` — the deviation above.
2. `example/abi/abi_raw.zig:100: remainder division with 'i64' and
   'comptime_int': signed integers and floats must use @rem or @mod` — fixed
   with `@rem(x, 10)`.

The runtime test count in the run that failed only at the fixture was
`40/40 tests passed`, which includes the six new `abi` tests; the final run had
no failures at all.

## Acceptance criteria

| # | Criterion | Status |
|---|---|---|
| 1 | `zig build test-abi` exits 0, stdout exactly `hi!` | VERIFIED in aggregate (`zig build test`, exit 0, which depends on `check_abi` with `expectStdOutEqual("hi!\n")`). Not run as a standalone step; human: `zig build test-abi`. |
| 2 | `zig build test-abi-multi` exits 0, prints `abcd` | VERIFIED in aggregate the same way (`check_multi`). Human: `zig build test-abi-multi`. |
| 3 | `zig build test-abi-raw` exits 0, stdout shows `ff`, `00`, `fe`, `255` | VERIFIED in aggregate: the step is in the `test` graph, its exact expected stdout is `ff 00 fe\n255\n`, and `zig build test` exited 0. Human: `zig build test-abi-raw`. |
| 4 | `zig build test-runtime` exits 0, `abi` tests cover round trip, `ins.len == 0`, non-byte-like → `failed` | Tests present (`callRaw round-trips bytes, bytes above 0x7f included`, `callRaw answers ok for ins.len == 0`, `callRaw answers failed for a result that is not byte-like`, plus the element/copy/throw cases). `40/40 tests passed` in the tester's `zig build test`. Human: `zig build test-runtime`. |
| 5 | `zig build test-e2e` exits 0, prints `Hello, Zig` | VERIFIED: it is a named stage of the tester, `exit_code: 0`. Also implies `Bytes.purs` compiles inside the same `example` project. Human: `zig build test-e2e`. |
| 6 | `grep -n 'invalid' runtime/abi.zig` empty; `grep -in 'freenet\|bincode\|contract' runtime/abi.zig` empty | VERIFIED here: both were run on this tree and exited 1 (no match). |
| 7 | `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` exits 0 and the `.wasm` starts `00 61 73 6d` | Exit code VERIFIED (named stage of the tester, `exit_code: 0`). The magic bytes are UNVERIFIED — the tester reports only the exit code and I have no way to read the artifact. Human: `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall && head -c 4 zig-out/bin/example.wasm \| od -An -tx1` (expect `00 61 73 6d`). |
| 8 | `git diff --stat` touches only `runtime/`, `example/src/Bytes.purs`, `example/abi/`, `build.zig`, `docs/` | VERIFIED: modified `build.zig`, `docs/codegen.md`, `runtime/abi.zig`, `runtime/root.zig`; new `example/abi/abi_raw.zig`, `example/src/Bytes.purs`. `compiler/dist/bundle.js` and `tools/mkpackageset.sh` show as modified in `git status` with **mode-only** changes (`100755 => 100644`) that were already there when the workspace was materialised; `git diff --summary` confirms no content change, and neither file was touched here. |

Nothing else was run: no `zig build` by hand, no `purs`, no `spago`, no `node`,
no container, no download or install.

## Review notes

- The fixture root prints through `rt.writeLine` with two hand-rolled
  formatters (`formatHex`, `formatInt`) rather than `std.fmt`, so nothing in the
  native probe depends on a stdlib formatting API that moves between releases.
- `callRaw`'s refusals use fixed literals, like the text path's, so reporting a
  failure cannot itself fail for want of memory.
- `writeSlice` is shared by both paths: a `String` result is bytes on the byte
  path too, which keeps `callRaw` usable for callees that happen to return text.
