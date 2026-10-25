# Handoff: `runtime/abi.zig`, the bytes call path (issue #14, S1 of #13)

**Date:** 2026-10-25
**Branch:** `agent/01a1752e-96d5-a095-3053-39e9c1deda5d`, cut from `master`.
**Status:** change written, **not executed**. There is no `zig`, `purs`, `spago`
or `node` toolchain in this environment; nothing was installed and no build,
test or container was run. Everything that needs a compiler is marked
**UNVERIFIED** below; only the `grep` and `git status` criteria were actually
executed, and they are marked as such.

---

## (i) What landed

| file | change |
|---|---|
| `runtime/abi.zig` | **new**, 199 lines: `Status`, `Reply`, `callBytes`, two private helpers, four `test` blocks |
| `runtime/root.zig` | **one added line** at file scope — `pub const abi = @import("abi.zig");` (line 67), plus `_ = abi;` inside the existing `test { … }` block so its tests are collected |
| `docs/handoff-abi-s1-2026-10-25.md` | this file |
| `runtime/apply.zig`, `runtime/value.zig`, `compiler/src/**`, `build/purzig.zig`, `example/**`, `build.zig`, `docs/codegen.md` | **untouched** |

`example/`, `build.zig` and `docs/codegen.md` belong to issue #15 and were not
opened for writing.

---

## (ii) The allocator and value surface I found, and where

Read out of `runtime/apply.zig` (line numbers are this branch's `master` base):

| declaration | line | why `callBytes` needs it |
|---|---|---|
| `pub const freestanding` | 33 | the target gate; `abi.zig` references nothing behind it, so no action needed |
| `var alloc_inst: ?std.mem.Allocator = null;` | 86 | the one stored allocator — `abi.zig` declares **no** allocator of its own |
| `pub fn initAlloc(allocator: std.mem.Allocator) void` | 91 | the seam a host uses on `wasm32-freestanding` |
| `pub fn alloc() std.mem.Allocator` | 106 | the whole allocation surface `abi.zig` uses; panics only if called before `initAlloc` |
| `pub fn apply(f: Value, argument: Value) Error!Value` | 121 | the call itself; panics on a non-closure (`"applied a non-function"`) |
| `pub fn throwValue(err: Value) Error` | 156 | sets the side channel and returns `error.PsException` — the source of `invalid` |
| `pub fn takeError() Value` | 163 | consumes the in-flight thrown value; exactly once per caught error |
| `pub const io` / `pub const init` | 101, 114 | **not referenced** — `abi.zig` has no `std.Io` and no process |

From `runtime/value.zig`:

| declaration | line | use |
|---|---|---|
| `pub const Fn1` | 37 | the shape of a test closure body: `fn ([]const Value, Value) Error!Value` |
| `pub const no_env` | 56 | empty captured environment for the test closures |
| `pub const Value = union(enum)` | 58 | `apply`/`mkString`/switch target |
| `string: []const u8` | 63 | the only variant an `ok` reply accepts |
| `pub fn mkString` / `mkClosure` / `mkInt` | 116 / 136 / 108 | constructors used by `callBytes` and the tests |

So the file's entire dependency footprint is `apply_mod.alloc`, `apply_mod.apply`,
`apply_mod.takeError`, `apply_mod.throwValue` (tests only) and
`value.Value` / `value.Error` / `value.no_env`. No allocator, no `Io`, no
`std.debug`, no arena, no `DebugAllocator`, no `page_allocator`.

---

## (iii) The exact `callBytes` body, as delivered

```zig
pub fn callBytes(f: Value, in: []const u8) Reply {
    // Copy first: the callee may keep the argument, and `in` is the caller's.
    const argument = copyOf(in);

    const result = apply_mod.apply(f, Value.mkString(argument)) catch {
        // `apply` fails only with `error.PsException`, which always carries the
        // thrown value in the runtime's side channel. Consuming it here is what
        // keeps a later catch from seeing a stale one.
        return .{ .status = .invalid, .bytes = exceptionBytes(apply_mod.takeError()) };
    };

    return switch (result) {
        .string => |s| .{ .status = .ok, .bytes = s },
        else => .{ .status = .invalid, .bytes = returned_non_string },
    };
}

fn exceptionBytes(err: Value) []const u8 {
    return switch (err) {
        .string => |s| copyOf(s),
        else => threw_non_string,
    };
}

/// Copy bytes into the runtime's allocator. The only allocation this file
/// makes, and the reason a reply outlives the call: everything returned points
/// at memory the runtime owns.
fn copyOf(bytes: []const u8) []const u8 {
    const out = apply_mod.alloc().dupe(u8, bytes) catch
        @panic("runtime: out of memory");
    return out;
}
```

with

```zig
pub const Status = enum { ok, invalid };
pub const Reply = struct { status: Status, bytes: []const u8 };

const threw_non_string = "PureScript exception with a non-String value";
const returned_non_string = "PureScript function returned a non-String value";
```

Three decisions worth recording:

1. **The input is copied, once, before the callee sees it.** A PureScript
   `String -> String` is untyped at this boundary and may store the string in a
   ref, a record or a captured environment; `in` may be a temporary in the
   caller's frame. After the copy the caller may drop its buffer immediately.
   This is also the only reason the file touches an allocator at all, which is
   what the parent issue asks for ("use the allocator `initAlloc` already
   stores").
2. **The ok path does not copy the result.** The callee's string is already
   runtime-allocated or a comptime literal, and the reply's rule is "never
   freed by us, valid for the life of the runtime" — copying would only buy a
   second allocation.
3. **No `ArrayList`, no writer, no formatting.** `allocator.dupe(u8, …)` per the
   0.16 notes in the issue; the two fixed reasons are literals so that
   *reporting* a failure can never itself fail for want of memory.

---

## (iv) How `invalid` is produced, and what does panic

`invalid` is a result, never a trap. Exactly two producers:

| producer | `Reply.bytes` |
|---|---|
| the callee raised a PureScript exception (`apply` returned `error.PsException`) | the thrown `String`, copied verbatim into the runtime allocator; any other thrown `Value` gets the literal `threw_non_string` |
| the callee returned a `Value` that is not `.string` | the literal `returned_non_string` |

The `catch` arm calls `takeError()` because that is the runtime's documented
"call exactly once per caught error" — it also clears the side channel so a
later `catchException` cannot observe a stale value.

The only panic is in `rt.apply` itself, when `f` is not a closure at all: there
is no bytes-shaped answer for "you handed me an `Int` instead of a function",
and the issue allows exactly that case to panic. `callBytes` adds no panic of
its own apart from out-of-memory in `copyOf`.

`exceptionBytes`'s use of `takeError()` assumes what every path in this runtime
guarantees: `error.PsException` is only ever produced by `rt.throwValue`, which
stashes the value first. If a future callee returns `error.PsException` without
stashing, `takeError` panics — it cannot be guarded from here, because
`pending_error` is private to `apply.zig` and S1 may not change that file.

---

## (v) Tests (in `runtime/abi.zig`, no PureScript)

Four `test` blocks, all driving real closures built from the runtime's own
constructors, so `zig build test-runtime` exercises both statuses without a
PureScript toolchain:

| test | status exercised | what it pins down |
|---|---|---|
| `callBytes answers ok with the bytes the callee returned` | `ok` ×2 | an echoing closure returns `in` unchanged; a closure that ignores its argument still returns its own `"hi!"` |
| `callBytes answers invalid when the callee throws` | `invalid` ×2 | a thrown `String` is reported verbatim (`"rejected"`); a thrown `Int` falls back to the fixed reason |
| `callBytes answers invalid when the callee returns a non-String` | `invalid` | an `Int` result is `invalid`, not a panic |
| `callBytes copies its input, so the caller may drop it` | `ok` | the input buffer is scribbled over after the call and the echoed reply is unchanged — the copy, not an alias |

Test-only allocator: `std.heap.FixedBufferAllocator` over a stack array, reset
per test by construction. Deliberately **not** an arena and **not**
`std.testing.allocator`: the runtime never frees, so a leak-tracking allocator
would fail these tests by design, and the arena type is a name criterion 2
forbids in this file. A fixed buffer is also the honest model of the freestanding
contract — memory handed in from outside, nothing freed.

---

## (vi) Acceptance criteria — what is verified and what is not

| # | criterion | state |
|---|---|---|
| 1 | `zig build test-runtime` exits 0 and runs an `abi` test exercising both statuses | **UNVERIFIED** — no `zig`. Both statuses are asserted in-file (section v) |
| 2 | `grep -n 'ArenaAllocator\|DebugAllocator\|GeneralPurposeAllocator\|page_allocator\|std\.Io\|std\.debug' runtime/abi.zig` finds nothing | **VERIFIED (grep only)**: 0 matching lines, exit 1 |
| 3 | `grep -in 'freenet\|bincode\|contract' runtime/abi.zig` finds nothing | **VERIFIED (grep only)**: 0 matching lines, exit 1 |
| 4 | `grep -rn 'callBytes' runtime/` shows the definition plus the `root.zig` export only | **VERIFIED (grep only)** with a caveat: outside `abi.zig` there is **no** hit at all, and `root.zig:67` carries the export `pub const abi = @import("abi.zig");`. Inside `abi.zig` the hits are the doc sentence, the definition (line 73) and the four in-file tests' call sites — unavoidable, since the tests must call it |
| 5 | `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` exits 0, `.wasm` starts `00 61 73 6d` | **UNVERIFIED** — no `zig`. Nothing in `abi.zig` references `std.Io`, `std.debug`, a process or a console, which is the part this issue controls; S2 wires the artifact |
| 6 | `git diff --stat` touches only `runtime/` | **VERIFIED (git status only)**: `M runtime/root.zig`, `?? runtime/abi.zig` (plus this handoff file, which the criteria line in #14 does not list but the deliverable requires). `tools/mkpackageset.sh` shows a **pre-existing** mode-only modification (`100755` → `100644`, 0 insertions) that was already in the worktree before this branch and that I did not touch — the same one recorded in `handoff-entry-deletion-2026-10-25.md`. `compiler/dist/bundle.js` was neither rebuilt nor hand-edited |

Additional **UNVERIFIED** items, because they need a Zig 0.16 compile and there
is no toolchain here:

- `std.mem.Allocator.dupe(u8, slice)` keeping its `(comptime T, slice)` shape in
  0.16 (the issue names it as the recommended call, so the risk is low).
- `std.heap.FixedBufferAllocator`, its `init(buffer: []u8)` and
  `allocator() *Self` signatures at 0.16.0 (the pinned `minimum_zig_version`).
  If that API moved, the fix is local to the two-line preamble of each test.
- That `const result = x() catch { return …; };` still coerces a diverging
  `catch` block to the payload type (standard Zig, unchecked here).
- That the file-scope `pub const abi = @import("abi.zig");` plus `_ = abi;` in
  `root.zig`'s existing `test { … }` block is enough for `addRuntimeTests`
  (`build/purzig.zig:262`, root file `runtime/root.zig`) to collect the four
  tests. `_ = abi;` is there precisely because collection follows analysis.
- That the two `@panic` calls in `copyOf` stay out of the freestanding graph's
  way — they are plain panic strings, the same shape `apply.zig` uses
  throughout, and no `std.debug` name is spelled.

---

## (vii) The one command

From the repository root — settles criteria 1, 5 and the grep pair:

```
grep -n 'ArenaAllocator\|DebugAllocator\|GeneralPurposeAllocator\|page_allocator\|std\.Io\|std\.debug' runtime/abi.zig; \
grep -in 'freenet\|bincode\|contract' runtime/abi.zig; \
zig build test-runtime \
  && zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall \
  && head -c 4 zig-out/bin/example.wasm | od -An -c
```

Expected: both `grep`s silent (exit 1), `test-runtime` exits 0 with four `abi`
tests passing, the freestanding build exits 0, and the last line is the wasm
magic `\0 a s m`. Do **not** pass `-Dtarget=wasm32-freestanding` to
`test-runtime`: it links `std.testing`, which needs an OS.

If `test-runtime` fails on the `FixedBufferAllocator` lines only, check the 0.16
signature first (section vi); the assertions and the runtime code above are
independent of it.
