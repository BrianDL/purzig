# purzig

A PureScript backend that emits Zig, plus the runtime that generated code runs
on. Write PureScript, get a native binary.

```purescript
module Main where

import Prelude
import Effect (Effect)
import Effect.Console (log)

main :: Effect Unit
main = log "hello"
```

```
$ zig build run
hello
```

## Licence — read this first

purzig is **AGPL-3.0**, and the runtime is linked into every binary it
produces. A program compiled with purzig is therefore a combined work with an
AGPL library and must itself be released under AGPL-3.0 — including,
under AGPL §13, offering source to the users of a network service.

There is no linking exception. This is deliberate. If you need to ship software
under other terms, purzig is not a suitable toolchain for it.

The vendored PureScript sources under `packages/*/src/**.purs` are their
upstream authors' work under the licence in each package directory; everything
else in this repository is purzig's and is AGPL. `NOTICE` carries the licences
of everything bundled into `compiler/dist/bundle.js`.

## > [!WARNING]
> while not vibe-coded, this code is produced with heavy assistance from text extrusion machines.

## What you need

| Tool | Why |
|---|---|
| Zig 0.16.0 | Builds your program; orchestrates the whole pipeline |
| PureScript 0.15.x (`purs`) | Compiles your sources to CoreFn |
| Spago 1.x | Resolves packages and drives `purs` |
| Node | Runs the backend, which is PureScript compiled to JavaScript |

purzig ships its backend prebuilt, so you never build it — but you do need
`node` to run it, and **you need your own spago**, since purzig does not provide
one. Spago is not in nixpkgs at a useful version; pin it in a `package.json` and
let your environment install it locally:

```json
{ "devDependencies": { "spago": "^1.0.0" } }
```

There is no npm package for purzig itself. It is a Zig dependency.

## A project

Five files, the same shape any other PureScript backend gives you, plus the two
Zig files that replace what would otherwise be a bundler config:

```
my-app/
├── build.zig
├── build.zig.zon
├── spago.yaml
├── package.json      pins spago
└── src/Main.purs
```

**`build.zig.zon`**

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .fingerprint = 0x0,               // zig prints the value to use
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .purzig = .{
            .url = "https://github.com/BrianDL/purzig/archive/refs/tags/v0.1.1.tar.gz",
            .hash = "...",            // zig fetch prints this
        },
    },
    .paths = .{""},
}
```

**`build.zig`**

```zig
const std = @import("std");
const purzig = @import("purzig");

pub fn build(b: *std.Build) void {
    const exe = purzig.addExecutable(b, .{
        .name = "my-app",
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .purzig = b.dependency("purzig", .{}),
    }).exe;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run it").dependOn(&run.step);
}
```

**`spago.yaml`**

```yaml
package:
  name: my-app
  dependencies:
    - prelude
    - effect
    - console
workspace:
  packageSet:
    path: .purzig/packages.json
  backend:
    cmd: purzig
```

**`.gitignore`** wants `.purzig/`, `.spago/`, `output/`, `output-zig/`,
`.zig-cache/`, `zig-out/`, `node_modules/`.

Then:

```sh
zig fetch https://github.com/BrianDL/purzig/archive/refs/tags/v0.1.1.tar.gz
zig build run
```

### Why `packageSet: path:` and not a URL

purzig needs its own package set: the PureScript registry ships JavaScript FFI,
and a package with foreign imports needs Zig FFI instead. The set lives inside
the purzig tarball, and the build copies it to `.purzig/packages.json` before
running spago — so the set you resolve against always belongs to the exact tag
you pinned in `build.zig.zon`, and the version number appears in your project
exactly once.

Do not edit `.purzig/`; it is regenerated on every build.

## Foreign function interface

A module's Zig FFI lives beside its source, exactly as `.js` does for the
JavaScript backend:

```
src/Data/Thing.purs
src/Data/Thing.zig
```

Nothing is registered anywhere. The build copies the sibling `.zig` into the
output directory next to the generated code.

```purescript
foreign import addOne :: Int -> Int
```

```zig
const rt = @import("runtime");
const Value = rt.Value;

fn addOne(x: Value) Value {
    return Value.mkInt(x.asInt() +% 1);
}
pub const @"ps.addOne" = rt.curry(addOne);
```

`rt.curry` for pure functions, `rt.effect` for anything that performs an effect.
The runtime builds the closure chain from the function's signature at comptime,
so you never manage arity or environment indices. See `docs/codegen.md`,
"Writing FFI", for the details — particularly which of the two to use, which is
decided by what the function *does* rather than by its PureScript type.

## Which packages work

`docs/SUPPORTED.md`. Short version: the seventeen vendored packages work, a
registry package with no `foreign import` works untouched, and a registry
package *with* foreign imports resolves and then fails at `MISSING FFI` naming
the file it wanted.

## Differences from the JavaScript backend

Deliberate, and documented in `docs/SUPPORTED.md`: Int is 32-bit wrapping,
strings are indexed by code point rather than UTF-16 code unit, division by zero
returns 0, and **the arena never frees** — fine for a program that exits, wrong
for a long-running process today.

## Development

```
zig build test           everything
zig build test-runtime   the Zig runtime alone; needs no purs, spago or node
zig build run            build and run example/
zig build codegen        generate Zig, stop before compiling
zig build packageset     regenerate packages.json
```

`docs/codegen.md` is the specification of what the emitter produces and the
best thing to read before touching `compiler/src/Zig/Emit.purs`.
