# Handoff: `ps.<name>` is a thunk (fix for `zig build test-abi`)

Date: 2026-02-14
Scope: `example/abi/abi_probe.zig`, `docs/codegen.md`, this file.

## The decl signature found

`example/output-zig/Main.zig` is not present on a clean checkout, so the shape
comes from the emitter that writes it, `compiler/src/Zig/Emit.purs`
(`emitTopValue`, ~line 233), whose own comment states it: *"Top-level bindings
become NULLARY FUNCTIONS, not constants"*. Emitted form:

```zig
pub fn @"ps.<name>"() rt.Error!rt.Value { ... }
```

i.e. `fn () error{PsException}!value.Value` — a thunk, as the build showed.
Corroborated by the existing consumer `example/library/libmain.zig:23`:
`_ = try rt.runEffect(try purs_main.@"ps.main"());` — it calls the decl.

Consequence: `rt.abi.callBytes(f: Value, ...)` needs the *value*, so a caller
must call the decl first. `ps.echo` is `echo :: String -> String`,
`echo s = s <> "!"` in `example/src/Main.purs:30`, so `try purs_main.@"ps.echo"()`
yields the one-argument closure `Value`; `callBytes` applies `"hi"` to it.

## The change

Before (did not compile — passed a function where a `Value` was expected):

```zig
const reply = rt.abi.callBytes(purs_main.@"ps.echo", "hi");
```

After:

```zig
const f = try purs_main.@"ps.echo"();
const reply = rt.abi.callBytes(f, "hi");
rt.writeLine(reply.bytes);
```

`main` already returns `!void`, so the `try` is at the top level of `main`; no
`error{PsException}` handling is added or suppressed. The assertion is untouched:
`build.zig:172` still reads `check_abi.expectStdOutEqual("hi!\n")`.

`docs/codegen.md`, byte-entry-point section: two sentences added recording the
convention (every `@"ps.<name>"` is a thunk `fn () rt.Error!rt.Value` that must
be called; applying arguments is the runtime's job), plus the example sentence
updated to show the two-line form.

## UNVERIFIED

No zig/purs/spago/node, no builds, no containers were run. Therefore:

- **UNVERIFIED**: `zig build test-abi` exits 0 and prints exactly `hi!`.
- **UNVERIFIED**: `zig build test-e2e` exits 0 with stdout `Hello, Zig`.
- **UNVERIFIED**: `zig build test-library` exits 0.
- **UNVERIFIED**: the probe compiles against the real generated `Main.zig`
  (the decl signature above is read from the emitter, not from generated output).
- **UNVERIFIED**: `zig build test` includes `test-abi`.

Checked statically, without executing anything:

- `rt.writeLine` exists (`runtime/root.zig:53` re-exports it from
  `runtime/apply.zig:73`) and writes the bytes **then** `"\n"`, so the probe
  prints `<bytes>` + newline — consistent with `expectStdOutEqual("hi!\n")`.
- `rt.abi.callBytes(f: Value, in: []const u8) Reply` matches the contract.
- `build.zig:172` still asserts `"hi!\n"`; `echo` exists in `Main.purs:30`.

## Command to run

```
zig build test-abi && zig build test-e2e && zig build test-library
```
