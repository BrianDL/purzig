# Handoff — abi: any named module, k arguments, transport status

Date: 2026-10-26

This file is the issue #21 handoff. The immediate repair recorded in
`docs/handoff-abi-keyword-2026-10-26.md` fixed two compile errors in the work
that was already on this branch:

1. `Status = enum { ok, error }` did not compile because `error` is a Zig
   keyword; the variant is now `failed`.
2. `example/abi/abi_multi.zig` now reads the caller-owned `Reader` on `ok` and
   `Reply.bytes` on `failed`, so both switch arms match the real API.

No toolchain, build, test, container or install was run. Everything requiring
execution is **UNVERIFIED**.

## How module names reach the build helper

Not JSON and not a generated `modules.zig`: the caller lists the extra modules
explicitly in `Options.extra_modules`, and `addLibrary` creates one build module
per listed name.

```zig
const lib = purzig.addLibrary(b, .{
    .name = "example",
    .main_module = "Main",
    .extra_modules = &.{"Api"},
    .project = b.path("example"),
    .target = target,
    .optimize = optimize,
});
const api = lib.module("Api");
```

Why: Zig 0.16 removed `std.fs.cwd()`, so a build script has no supported way to
read `output-zig/manifest.json` at configure time. A generated
`output-zig/modules.zig` would need the same configure-time read before it can
be `@import`ed, so it has the same race and the same missing-file problem on a
clean checkout. A declared name creates a module without reading anything; if
codegen did not emit it, the missing root source is a compile error in the
caller's import chain. `module_main` remains the `main_module` handle, so
existing callers keep compiling.

## The call signature and 0/1/k behaviour

```zig
pub const Status = enum { ok, failed };
pub const Reader = struct { buf: []u8, len: usize = 0 };
pub const Reply = struct { status: Status, bytes: []const u8 };

pub fn call(f: Value, ins: []const []const u8, out: *Reader) Reply
pub fn callBytes(f: Value, in: []const u8) Reply
```

- `ins.len == 0`: nothing is applied; `f` is the result, e.g. a `String`-valued
  constant.
- `ins.len == 1`: `f` is applied once.
- `ins.len == k`: `f` is applied k times, left to right.
- Every input element is copied into the runtime allocator before the callee
  sees it. `out.buf` is caller-owned: written, never freed, never retained.
- `callBytes` is the thin one-slice wrapper over `call`.
- A callee that is not applicable with `ins.len` arguments panics; that is a
  caller bug, not consumer input.

An out-sink was kept rather than returning a runtime-owned slice because a wasm
host owns its linear memory and should not receive memory it cannot free or
size.

## How `Status.failed` is produced

Transport only, never application meaning. Exactly two producers, both leaving
a reason in `Reply.bytes`:

1. the callee raised (`apply` returned `error.PsException`); a thrown `String`
   is reported verbatim, a thrown non-`String` reports
   `"PureScript exception with a non-String value"`;
2. the callee returned a non-`String`, reporting
   `"PureScript function returned a non-String value"`.

`ok` means the call crossed and the result is in `out.buf[0..out.len]`. What
the bytes mean is the consumer's decision; purzig has no validation or domain
step.

## Fixture and gates

- `example/src/Api.purs` is a non-`Main` module exporting
  `pair :: String -> String -> String`.
- `example/abi/abi_multi.zig` obtains `lib.module("Api")`, calls
  `rt.abi.call(f, &.{ "ab", "cd" }, &out)`, and prints the reply plus a newline.
- `zig build test-abi-multi` expects exactly `abcd\n`; `test-abi` is unchanged
  and still expects `hi!`.

## Verification — all runtime criteria UNVERIFIED

Nothing was compiled or run, so these are **UNVERIFIED**:

1. `zig build test-abi` exits 0 and prints exactly `hi!` — **UNVERIFIED**
2. `zig build test-abi-multi` exits 0 and prints exactly `abcd` — **UNVERIFIED**
3. `zig build test-runtime` exits 0 and covers `ok`, throw, non-String return,
   1/2/0 arguments and input copying — **UNVERIFIED**
4. `grep -n 'invalid' runtime/abi.zig docs/codegen.md` is empty — **CHECKED**
   statically, no match. `grep -n 'Status.error' runtime/abi.zig` is empty
   because the variant is named `failed`, not `error` — **CHECKED** statically.
5. `zig build test-e2e`, `test-library` and the wasm32-freestanding
   ReleaseSmall build all succeed — **UNVERIFIED**
6. `grep -in 'freenet|bincode|contract|validate_state' runtime/abi.zig` is
   empty — **CHECKED** statically, no match.
7. The diff is limited to `build/purzig.zig`, `runtime/abi.zig`, `build.zig`,
   `example/src/Api.purs`, `example/abi/` and `docs/` — **CHECKED** with
   `git diff --stat` for tracked edits. The pre-existing unrelated
   `tools/mkpackageset.sh` mode-only change was not touched.

### The command that settles it

```sh
zig build test-runtime && zig build test-abi && zig build test-abi-multi && zig build test-library \
  && zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```
