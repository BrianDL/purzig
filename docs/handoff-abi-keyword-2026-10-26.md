# Handoff — ABI status keyword fix and multi-argument probe

Date: 2026-10-26

Scope: the two compile errors only.

- `runtime/abi.zig`
- `example/abi/abi_multi.zig`
- `docs/codegen.md` (the documented API sample and status prose, so it names
  `failed` rather than the non-compiling `error`)
- this handoff

Nothing else was edited. No build, test, install or container was run. Every
claim that would need a compiler or a run is **UNVERIFIED**.

## 1. `Status.error` → `Status.failed`

`error` is a Zig keyword, so this declaration was a syntax error:

```zig
pub const Status = enum { ok, error };
```

It is now:

```zig
pub const Status = enum { ok, failed };
```

Every status use was updated, not just the declaration:

- `Status.error` in tests → `Status.failed`;
- `Reply` construction `.status = .error` → `.status = .failed`;
- switch arms `.error =>` → `.failed =>`;
- comparisons `reply.status == .error` → `reply.status == .failed`;
- the module docs, comments and test names now describe the two transport
  states as `ok` or `failed`.

`error.PsException` and `Error!Value` are Zig error-set names, not `Status`
values, and were left alone.

Checks run (grep only):

```text
$ grep -n 'invalid' runtime/abi.zig
(no output)
$ grep -n 'Status.error' runtime/abi.zig
(no output)
```

## 2. The corrected probe switch arms

The real API in `runtime/abi.zig` is:

```zig
pub const Status = enum { ok, failed };
pub const Reader = struct { buf: []u8, len: usize = 0 };
pub const Reply = struct { status: Status, bytes: []const u8 };

pub fn call(f: Value, ins: []const []const u8, out: *Reader) Reply
pub fn bytes(reply: Reply, out: *const Reader) []const u8
pub fn callBytes(f: Value, in: []const u8) Reply
```

`rt.writeLine` and `rt.writeLineErr` both take one `[]const u8` and append a
newline. `example/abi/abi_multi.zig` now reads the caller-owned `Reader` on
success and `Reply.bytes` on failure:

```zig
const reply = rt.abi.call(f, &.{ "ab", "cd" }, &out);
switch (reply.status) {
    // Transport said the call crossed; the bytes are in our Reader.
    .ok => rt.writeLine(out.buf[0..out.len]),
    // Transport said it did not cross: `reply.bytes` is the reason.
    .failed => rt.writeLineErr(reply.bytes),
}
```

Both arms are `void`, matching `writeLine`/`writeLineErr`. The success arm
prints `out.buf[0..out.len]` plus the newline `writeLine` supplies, so
`test-abi-multi` still expects exactly `abcd\n`. The failure arm prints the
reason to stderr, so a failure cannot corrupt that stdout assertion.

## 3. Status semantics unchanged

`failed` has exactly the same two producers as the old non-`ok` variant:

1. the callee raised (`apply` returned `error.PsException`), with the thrown
   `String` reported verbatim or `"PureScript exception with a non-String value"`;
2. the callee returned a non-`String`, reporting
   `"PureScript function returned a non-String value"`.

The status is transport only. It never says what the bytes mean; application
validity remains the consumer's business.

## 4. Verification

**Nothing was compiled, built, installed, run or tested.** No Zig, purs, spago
or node toolchain was invoked. All of the following are **UNVERIFIED**:

- `zig build test-runtime` exits 0;
- `zig build test-abi` exits 0 and prints exactly `hi!`;
- `zig build test-abi-multi` exits 0 and prints exactly `abcd`;
- `zig build test-library` exits 0;
- `zig build test-e2e` exits 0 with stdout exactly `Hello, Zig`;
- `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` exits 0 and
  installs a `.wasm` starting `00 61 73 6d`.

What was actually checked, statically:

- `grep -n 'invalid' runtime/abi.zig` → no match;
- `grep -n 'Status.error' runtime/abi.zig` → no match;
- `grep -rn 'Status\.error' --include='*.zig' .` → no match;
- `git diff --stat` → `runtime/abi.zig`, `example/abi/abi_multi.zig` and the
  three status lines in `docs/codegen.md` (plus the pre-existing unrelated
  `tools/mkpackageset.sh` mode-only change, which this change did not touch).
  The handoffs are new untracked files.

### The command that settles it

```sh
zig build test-runtime && zig build test-abi && zig build test-abi-multi && zig build test-library \
  && zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```
