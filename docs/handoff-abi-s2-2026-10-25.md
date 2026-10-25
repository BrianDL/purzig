# Handoff — abi probe fixture, `test-abi`, docs (S2 of #13)

Issue: [#15](https://forge.tensorial.space/sophos/purzig/issues/15)
Date: 2026-10-25
Branch: `agent/01a1752f-4b20-7888-7e50-c7083f28d605` (cut from `master`)

Scope: S2 only — the fixture, the build step and the docs. `runtime/abi.zig`
itself is S1 (#14), written in parallel; nothing here implements it.

## What changed

| File | Change |
|---|---|
| `example/src/Main.purs` | appended `echo :: String -> String ; echo s = s <> "!"` (exported; `Main` is the module `addLibrary` exposes). `main` untouched. No `spago.yaml` change. |
| `example/abi/abi_probe.zig` | new root: binds `runtime` and `purs_main`, calls `rt.abi.callBytes(purs_main.@"ps.echo", "hi")`, prints the returned bytes. |
| `build.zig` | new `test-abi` step; wired into `test`. |
| `docs/codegen.md` | new "Byte entry point" section (bytes entry point, internal-to-platform-packages status, allocator lifetime). |

Nothing under `runtime/**`, `compiler/src/**`, `build/purzig.zig`,
`entry/entry.zig`, `packages.json` or any `spago.yaml` was touched.

## The probe's exact wiring

```zig
const abi_lib = purzig.addLibrary(b, opts);          // opts: example, main_module = "Main"
abi_lib.codegen.step.dependOn(&build_compiler.step); // bundle built from source
abi_lib.codegen.step.dependOn(&app.codegen.step);    // both run `spago build` in example/

const abi_root = b.createModule(.{
    .root_source_file = b.path("example/abi/abi_probe.zig"),
    .target = target,
    .optimize = optimize,
});
abi_root.addImport("purs_main", abi_lib.module);
abi_root.addImport("runtime", abi_lib.runtime);

const abi_probe = b.addExecutable(.{ .name = "abi-probe", .root_module = abi_root });
abi_probe.step.dependOn(&abi_lib.codegen.step);      // generated modules do not exist otherwise

const check_abi = b.addRunArtifact(abi_probe);
check_abi.expectStdOutEqual("hi!\n");

b.step("test-abi", "...").dependOn(&check_abi.step);
// and: all_tests.dependOn(&check_abi.step);
```

Import names: `purs_main` ← `LibraryArtifacts.module`, `runtime` ←
`LibraryArtifacts.runtime`. Dependency edge: the executable's step depends on
`abi_lib.codegen.step` (required — `addLibrary` never sees the artifact), and the
codegen step itself is ordered after the backend bundle and after the program's
codegen because both run `spago build` in the same project directory.

Not installed: the probe is a check, not an artifact, exactly as
`example/library/libmain.zig` is.

## What it prints, and why that proves the call path

`echo "hi"` is `"hi" <> "!"` = `"hi!"`; the probe writes those bytes plus a
newline, so stdout is exactly `hi!\n`. That proves the call path because the
fixture never builds a `rt.Value` or applies a closure itself — the only route
from the string `"hi"` to the bytes `hi!` is through
`rt.abi.callBytes(purs_main.@"ps.echo", …)`: it must find the compiled closure,
decode the input slice, apply the function, encode the result, and hand back a
`Reply` whose `bytes` are exactly what `echo` returned. A stub that returned its
input unchanged would print `hi\n` and fail the assertion; a wrong encoding would
print bytes or panic.

## Criteria

All **UNVERIFIED** — no toolchain, no builds, no containers were run, so nothing
below was executed. Not one of these was claimed as passing.

1. `zig build test-abi` exits 0 and prints exactly `hi!` — **UNVERIFIED**
2. `zig build test-e2e` exits 0, stdout exactly `Hello, Zig` — **UNVERIFIED**
   (reasoning only: `echo` is a new exported binding and `main` is textually
   unchanged, so `Main`'s behaviour should be identical)
3. `zig build test-library` still exits 0 — **UNVERIFIED**
4. `zig build test` includes `test-abi` — **UNVERIFIED** at runtime; the edge
   `all_tests.dependOn(&check_abi.step)` is present in `build.zig`
5. `grep -n 'hi!' build.zig` finds the assertion — **VERIFIED** (static):
   `build.zig:172:    check_abi.expectStdOutEqual("hi!\n");`
6. `git diff --stat` touches only `example/`, `build.zig`, `docs/` —
   **VERIFIED** (static) for this change: `build.zig`, `docs/codegen.md`,
   `example/src/Main.purs`, plus new `example/abi/abi_probe.zig`. Note: the
   working tree additionally shows a pre-existing mode-only change on
   `tools/mkpackageset.sh` (100755 → 100644) that this change neither made nor
   touched; it is outside the owned paths and was left alone.

Assumption to check on the first real run: `rt.abi` must be reachable as a
decl of the `runtime` module (`runtime/root.zig` re-exports it), and
`Reply.bytes` must be a `[]const u8` so `rt.writeLine(reply.bytes)` type-checks.
Both are S1's; if S1 exposes `abi` only under a different name, this probe needs
that one line changed.

## Verification command

```
zig build test-abi && zig build test-e2e && zig build test-library
```
