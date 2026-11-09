# Handoff — the tool CLI and `addTool` (part 2 of two)

Date: 2026-11-08
Issue: #45, "purzig: move the value codec into runtime/, and add addTool
(native tool binary)"

**This PR is PART 2: the tool itself.** Part 1 (the codec move to
`runtime/valuecodec.zig`, `5912cff`) is already on the branch and is unchanged
here. This part adds the shipped CLI, the build-graph shape that compiles it,
and the gate that runs it.

## What changed

- `entry/tool.zig` — **new**, and shipped, not generated. `<tool> run <export>
  [<infile>]`, `<tool> list`, `<tool> --version`. Bytes in, bytes out.
- `build/purzig.zig` — `ToolOptions`, `ToolArtifacts`, `addTool`, `version`, and
  the registry source that `addTool` writes into the cache. `addLibrary` and the
  other two shapes are untouched.
- `build.zig` — re-exports `addTool`/`ToolOptions`/`ToolArtifacts`/`version`
  beside `addExecutable`/`addLibrary`/`addRuntimeTests`, and adds the
  `test-tool` gate (also part of `test`).
- `example/src/Main.purs` — one added binding, `seed :: Unit; seed = unit`: the
  zero-argument export the gate needs, and the smallest possible one.

## `addTool`

```zig
pub const ToolArtifacts = struct {
    exe: *std.Build.Step.Compile,   // already installed
    codegen: *std.Build.Step.Run,   // the spago build
    runtime: *std.Build.Module,     // the Zig runtime module
};

pub const ToolOptions = struct {
    name: []const u8,                       // binary name, and the word --version prints
    project: ?std.Build.LazyPath = null,    // dir holding spago.yaml; default build root
    main_module: []const u8 = "Main",
    extra_modules: []const []const u8 = &.{},
    exports: []const []const u8,            // the names `list` prints, in order
    optimize: std.builtin.OptimizeMode,
    purzig: ?*std.Build.Dependency = null,
};

pub fn addTool(b: *std.Build, opts: ToolOptions) ToolArtifacts;
```

Consumer side, from a project whose `build.zig.zon` has a `.path` dependency
named `purzig` (`@import("purzig")` in `build.zig` is the dependency's
`build.zig`, which is where the re-export happens):

```zig
const purzig = @import("purzig");

const tool = purzig.addTool(b, .{
    .name = "my-tool",
    .project = b.path("."),
    .main_module = "Main",
    .exports = &.{ "encode", "decode", "empty" },
    .optimize = optimize,
    .purzig = b.dependency("purzig", .{}),
});
// -> { exe, codegen, runtime }; the exe is INSTALLED.
// `b.getInstallStep().dependOn(&tool.exe.step)` is unnecessary, and naming
// `tool.exe` in `addRunArtifact` is how a gate of your own runs it.
```

Four decisions worth knowing:

- **HOST, always.** `ToolOptions` has no `target` field on purpose. A tool is the
  shape you reach for when the *build* needs to call PureScript, so the binary
  must run where the build runs; building it for `opts.target` would produce a
  cross-compiled CLI the step wanting it cannot execute.
- **`exports` is written down, not read.** `output-zig/manifest.json` knows the
  shapes, but it is produced by codegen and a build script cannot read a file at
  configure time. So the caller states the names, and `addTool` treats that list
  as the whole contract: a name not in it is refused.
- **Nothing lands in the consumer's tree except the installed binary.** The
  registry is a `b.addWriteFiles()` source in the cache, and `entry/tool.zig` is
  rooted at its real path in the dependency rather than embedded and copied.
  Codegen still writes `output-zig/` and `.purzig/` beside `spago.yaml`, exactly
  as `addLibrary` does — that is codegen's litter, not the tool's.
- **A listed name that no module emits is a runtime diagnostic, not a build
  failure.** Resolution is `@hasDecl` over the generated modules at comptime, so
  a typo in `exports` costs an exit-2 message that names the export, not a Zig
  compile error about a decl nobody can see.

## The CLI contract

```text
<tool> run <export> [<infile>]   input bytes from <infile>, or stdin; result on stdout
<tool> list                      the .exports names, one per line
<tool> --version                 "<name> <version>\n"
```

The v1 arity rule, which is the one thing here that is deliberately unfinished:
**no input bytes at all → call the export with zero arguments** (its value is the
result); **any bytes at all → codec-decode exactly one `rt.Value` and apply the
export to it once**. There is no syntax for k arguments. The output is always
codec-encoded, so a tool composes with itself: the stdout of one `run` is a valid
`infile` for the next.

Exit codes: `0` success; `1` the call raised or the codec refused; `2` the
command line was wrong or named an export `.exports` does not contain. Every
diagnostic goes to stderr as `<tool>: ...`, and nothing but the encoded value
ever reaches stdout, so `tool run f > out.bin` is always safe.

Invocations against `example/` (`.exports = &.{ "seed", "greet" }`), with the
bytes they produce:

| invocation | stdin / infile | stdout | exit |
| --- | --- | --- | --- |
| `example-tool list` | — | `seed\ngreet\n` | 0 |
| `example-tool --version` | — | `example-tool 0.3.0\n` | 0 |
| `example-tool run seed` | empty | `01 00` (unit) | 0 |
| `example-tool run greet arg.bin` | `01 04 02 00 00 00 68 69` (`"hi"`) | `01 04 09 00 00 00 48 65 6c 6c 6f 2c 20 68 69` (`"Hello, hi"`) | 0 |
| `example-tool run nonexistent` | — | — | 2, stderr `unknown export "nonexistent"; allowed: seed, greet` |
| `example-tool run greet stale.bin` | `02 00` | — | 1, stderr `run greet: input: UnsupportedVersion` |
| `example-tool` (no command) | — | — | 2, usage on stderr |

## What `zig build test-tool` asserts

Six run steps, all from the build graph, all with hard-coded vectors
(`step.expectStdOutEqual` / `expectExitCode`) — no golden files, no diffs:

1. `list` → exactly `seed\ngreet\n`, in the order `exports` gave them.
2. `--version` → `b.fmt("example-tool {s}\n", .{purzig.version})`.
3. `run seed`, no input → exactly `01 00`. This is the zero-argument path: a
   nullary PureScript binding producing a seed file.
4. `run greet <infile>` → exactly the codec bytes for `"Hello, hi"`, where the
   infile is written by `addWriteFiles` so no binary fixture is checked in.
5. `run nonexistent` → exit 2.
6. `run greet <stale-version infile>` → exit 1, where the fixture starts `02`
   instead of the codec's `01`.

`test-tool` is also a dependency of `test`, so the aggregate gate covers it.

## Measured facts this part depends on

- `File.readStreaming(io, &.{&buffer})` reports the end of the stream as
  `error.EndOfStream`, **not** as a zero return. Treating only `n == 0` as the
  end makes every ordinary file a refusal — a 2-byte infile comes back as
  `EndOfStream` on stderr. `readToEnd` in `entry/tool.zig` catches that error as
  its loop exit.
- `std.Io.File.stdout()/stdin()/stderr()` take no arguments; every method takes
  `io`. `writeStreamingAll` is unbuffered, so a tool that exits immediately after
  writing still delivers its bytes and needs no flush.
- `std.process.Init` supplies `io`, `arena` and `minimal.args`; `Args.iterate()`
  with `it.next()` is the argv form, and `argv[0]` is the tool's own path.
- `std.process.exit(status: u8)` exists and is `noreturn`, which is why `main`
  only exits explicitly on a non-zero code.
- `rt.apply` panics when the callee is not a `.closure`, so `run` checks the tag
  before applying and reports the mismatch instead.

## Verification

`u/admin/purzig_tool_tester` on this tree, stage by stage:

| stage | result |
| --- | --- |
| `zig build compiler` | pass, 36.7 s |
| `zig build test-valuecodec` | pass, 0.6 s |
| `zig build test-runtime` | pass, 0.6 s |
| **`zig build test-tool`** | **pass, 8.8 s** — all six run steps, bytes and exit codes |
| `zig build test` | pass, 15.7 s — `test-tool` included |
| `zig build probe` (tester's consumer fixture) | **fails compiling the tester's own `src/main.zig`** — see below |

All 18 structural assertions are green as well: `runtime/valuecodec.zig` exists,
`root.zig` exposes it, the codec carries no `@import("runtime")`, `version` is
`0x01`, all nine tag numbers are what the format says, `entry/tool.zig` exists,
`build/purzig.zig` declares `addTool`, `build.zig` re-exports it, and
`build.zig.zon`'s `.paths` keep `runtime` and `entry`.

**The one red stage is not this tree.** The fixture stage now gets past configure
(the absolute `.path` bug recorded in part 1 is fixed) and dies compiling the
fixture's own probe program, before it reaches any purzig code:

```
src/main.zig:7:52: error: root source file struct 'fmt' has no member named 'fmtSliceHexLower'
    return std.fmt.allocPrint(gpa, "{x}", .{std.fmt.fmtSliceHexLower(bytes)});
```

`std.fmt.fmtSliceHexLower` was removed in Zig 0.16 — `{x}` on the slice is the
replacement, i.e. `std.fmt.allocPrint(gpa, "{x}", .{bytes})`. That line is the
harness's, not the repo's, so it fails identically on any tree. The bytes that
stage would have checked are asserted in-repo instead: criterion 4 by
`test-valuecodec`, and criterion 5 (a tool built by `addTool`, `list` / `run` /
`run nonexistent`) by `test-tool`.

## Open items

- **k arguments.** `.exports` names an export, not a shape, and the manifest that
  knows the shapes lives in the cache where a configure-time build script cannot
  read it. So v1 has the 0-or-1 rule above and no query syntax. The shapes are
  already emitted by codegen (`Zig.Abi`), so a later version can either take the
  arity from a generated table that `addTool` writes alongside the registry, or
  let the caller pass `{ name, arity }` pairs in `exports`.
- **JSON input.** Every byte is codec bytes today. A `--json` mode would need a
  second reader in the tool and a decision about numbers and records that the
  codec already made differently.
- **stdout flushing.** Nothing to flush now (`writeStreamingAll` is unbuffered).
  If the tool ever buffers stdout to make many small writes cheap, the buffer has
  to be flushed before `std.process.exit`, which is the one path that skips the
  rest of `main`.
- **Zero-argument non-`Unit` exports** are not exercised: `seed :: Unit` is the
  only one in `example/`. The path is shape-agnostic (whatever the thunk returns
  is encoded), but a second vector would be cheap.
