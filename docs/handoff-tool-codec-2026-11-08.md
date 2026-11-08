# Handoff — the value codec in `runtime/`, and `addTool` (part 1 of two)

Date: 2026-11-08
Issue: #45, "purzig: move the value codec into runtime/, and add addTool
(native tool binary)"

**This PR is PART 1: the codec move only.** `addTool`, `entry/tool.zig`, the
`test-tool` gate and the `addTool` acceptance checks are PART 2 and are
deliberately absent here — see "What remains" at the bottom. Nothing in this
part touches I/O, `std.process` or `std.Io`.

## What changed

- `runtime/valuecodec.zig` — **new**, and it is a MOVE, not a rewrite: the
  canonical codec that used to live in `sophos/purzig-freenet` at
  `zig/valuecodec.zig`. Only the imports were adapted (see below). The module
  docs still carry the tag table, the versioning rule ("a bump is required for…",
  "a bump is not required for…"), the "equal values encode equally, and what
  that does not cover" section, `MAX_DEPTH`, and the `Error` set — those are the
  format's specification, not commentary, and they travelled with the code.
- `runtime/root.zig` — one line of exposure, plus `_ = valuecodec;` in the test
  block so the runtime test step compiles the codec's tests:

  ```zig
  pub const valuecodec = @import("valuecodec.zig");
  ```

  A consumer reaches it as `rt.valuecodec`, exactly like `rt.abi`.
- `build.zig` — one new step, `test-valuecodec`, over
  `b.path("runtime/valuecodec.zig")` as its own test root. Pure Zig: no purs, no
  spago, no node, no wasm runtime, no `Io`. It is the cheap gate to run while
  editing the codec.
- `docs/handoff-tool-codec-2026-11-08.md` — this file.

`zig build test-runtime` runs the codec's tests as well, because `root.zig`'s
`test` block imports the module: a regression in the codec cannot leave the
aggregate `zig build test` green. `test-valuecodec` adds the narrow entry point,
not a second copy of the coverage.

## The import adaptation, and why it is only that

The sibling file did `const rt = @import("runtime");`. Inside the runtime that
specifier names nothing — `root.zig` is the file that *publishes* the name — so
it would have been a self-import through a name that does not resolve. The moved
file now imports its **sibling** module and binds the four declarations it uses:

```zig
const value_module = @import("value.zig");

const Value = value_module.Value;   // was rt.Value
const Field = value_module.Field;   // was rt.Field
const no_env = value_module.no_env; // was rt.no_env
const RtError = value_module.Error; // was rt.Error, the Fn1 error set
```

`RtError` is aliased rather than named `Error` because this file already defines
its own `Error` — the set the *codec* refuses with. Nothing else in the file
changed, and the file contains **no** self-import of the runtime module by name
(the one mention is prose explaining why there is none).

The doc header was genericised in the three places that named one consumer
("a Freenet host", "contract") to "a host", "program"; the tag table, the
versioning rule and the equality section are verbatim. The codec still takes a
`std.mem.Allocator` and never reaches for the runtime's global allocator — the
tests pass `std.testing.allocator`/an arena over it, which is what keeps them
runnable with no runtime initialised.

## The wire format is byte-identical, and how I know

The body of the file was copied, not retyped, and the only edits were the
import block, the doc nouns and one test comment. So the format is unchanged by
construction:

- `version: u8 = 0x01` is byte 0 of every buffer; `decode` answers
  `error.UnsupportedVersion` for any other byte-0 value before it reads a tag.
- Every `tag` number keeps its value: unit `0x00`, boolean `0x01`, integer
  `0x02`, number `0x03`, string `0x04`, char `0x05`, array `0x06`, record `0x07`,
  data `0x08`, and the reserved closure `0x09` / ref `0x0a` / marray `0x0b`.
- `MAX_DEPTH = 64`; the `Error` set is unchanged (`UnsupportedVersion`,
  `Unencodable`, `Truncated`, `OversizedLength`, `UnknownTag`, `InvalidBoolean`,
  `InvalidChar`, `DepthExceeded`, `TrailingBytes`, `OutOfMemory`).
- Records stay canonical: fields are written in ascending byte order of their
  names, and an empty buffer is still `error.Truncated`.

The tests assert the exact bytes rather than only round trips, so a silent change
of the format fails:

| value | bytes |
|---|---|
| `unit` | `01 00` |
| `integer 42` | `01 02 2a 00 00 00` |
| `string "hi"` | `01 04 02 00 00 00 68 69` |
| `integer -2` | `01 02 fe ff ff ff` |
| `data "Just" [3]` | `01 08 04 00 00 00 4a 75 73 74 01 00 00 00 02 03 00 00 00` |

A record inserted as `{ b, a }` encodes to the same bytes as `{ a, b }`, and the
decoded record comes back in that name order — asserted by name, not merely by
re-encoding.

## What `zig build test-valuecodec` asserts

15 tests, all host-only, straight from the format's own docs:

1. round trip of every shape (unit, boolean, integer including `i32` bounds,
   number, char, string, array, record, data) with `decode(encode v) == v` **and**
   `encode(decode(encode v)) == encode v`;
2. one case per tag in tag order, asserting byte 0 is `version` for each;
3. the version prefix on its own — `unit` is exactly `{0x01, 0x00}`, and nothing
   but the prefix moved;
4. an unknown version is `error.UnsupportedVersion`, not `UnknownTag`,
   `Truncated` or `OversizedLength`, and the version is decided *before* the
   value (a `0x02` buffer with a hostile body is still a version error);
5. record field ordering: two insertion orders produce identical bytes;
6. `data` writes its tag STRING, not an index (exact bytes);
7. `closure`/`ref`/`marray` are `Unencodable` both ways, and a refusal leaves the
   writer empty — including a refusal half-way through a container;
8. truncation at every length-prefixed point;
9. a length or count larger than the remaining bytes is `OversizedLength` (never
   an allocation of a hostile count);
10. unknown tags; the three reserved tags; trailing bytes; an out-of-range char;
    a non-boolean boolean byte;
11. `MAX_DEPTH`: exactly 64 nested arrays encode and decode, 65 is
    `DepthExceeded`, on both the write and the read side;
12. two writers over one allocator produce identical bytes.

`zig build test-runtime` runs these too, and `zig build test` depends on it, so
all three agree by construction.

## How this part was verified

`u/admin/purzig_tool_tester` on this tree, five stages, stage by stage:

| stage | result |
|---|---|
| `zig build compiler` | pass — the bundle still builds |
| `zig build test-valuecodec` | pass — exit 0, no purs/spago/node involved (it ran before codegen and standalone) |
| `zig build test-runtime` | pass — the same tests through `root.zig`'s test block |
| `zig build test-tool` | **absent by design** — part 2 |
| consumer fixture (`codec parity`, `addTool`) | **fails, part 2 / harness** — see below |

Its structural assertions are all green: `runtime/valuecodec.zig` exists,
`root.zig` carries the exact exposure line, the moved file contains no
self-import of the runtime module by name, `version` is `0x01`, and every tag
number is what the format says, and `build.zig.zon`'s `.paths` still list
`runtime` and `entry`.

**The gate is not decoration — it was mutation-tested.** Commenting out the one
`sortFieldsByName(sorted)` call in `encodeFields` (canonical ordering removed)
turned `zig build test-valuecodec` RED at the first round-trip test — `expected
x / found y`, i.e. the record came back in insertion order — and the pipeline
stopped there. Restored, and the file is byte-identical to the version above that
passed.

Two failures in the last two stages are NOT this part's:

- `test-tool`, `entry/tool.zig`, `build/purzig.zig:addTool`, the `addTool`
  re-export and the fixture's `addTool`/tool-binary assertions are exactly the
  part-2 checklist. They cannot pass before `addTool` exists, and adding it here
  would be the other PR.
- The consumer-fixture stage currently dies before compiling my code, on its own
  generated manifest: `/tmp/ptt-*/fx/build.zig.zon:7:30: error: expected path
  relative to build root; found absolute path` for
  `.purzig = .{ .path = "/tmp/ptt-*/ws/sophos/purzig" }`. Zig requires a `.path`
  dependency to be relative to the fixture's build root (it would be
  `../ws/sophos/purzig`), so that stage fails identically on ANY tree, including
  one that already has `addTool`. This is a harness fix, not a repo change — it
  is why the byte vectors in the table above are also asserted inside the repo by
  `test-valuecodec`, which does not depend on that fixture.

## What remains (part 2, separate PR)

- `entry/tool.zig` and `build/purzig.zig`'s `addTool` (a sibling of
  `addExecutable`/`addLibrary`, `addLibrary`-based, always host target, entry
  from the shipped file, the binary INSTALLED, returning
  `{ exe, codegen, runtime }`), re-exported from `build.zig`.
- The CLI contract: `run <export> [<infile>]`, `list`, `--version`; zero
  arguments when no input bytes; codec-decode in, codec-encode out; exit 2 for
  an export not in `.exports` with the allowed names on stderr; a codec refusal
  reported as a non-zero exit naming the `Error`; arity from the manifest.
- The `test-tool` gate: build a tool over `example/`, run it from the build
  graph, assert stdout bytes against hard-coded vectors.

Still open after part 2: k-argument exports (v1 takes arity from the manifest and
has no query syntax), JSON input, and stdout flushing behaviour for large
outputs.

No file outside `runtime/`, `build.zig` and `docs/` is touched by this part.
`compiler/src/**` is untouched: this is a runtime-surface move, not an emitter
change.
