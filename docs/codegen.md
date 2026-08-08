# Code generation spec

What `Zig/Emit.purs` must produce. The worked example is
`purs/example/expected/`, which compiles and runs today via
`zig build run-expected` — read it alongside this.

## Typing

There is one type. Every PureScript value of every type becomes a `rt.Value`,
a tagged union with variants `unit`, `boolean`, `integer`, `number`, `string`,
`char`, `array`, `record`, `data`, `closure`.

CoreFn is untyped — the compiler has already type-checked, and discards the
types on the way out — so the backend has nothing to be type-directed *with*.
Attempting to recover types would mean reading `externs.json` alongside
`corefn.json`, which purerl does and which is a v2 concern at best.

Consequences worth internalising:

- Generated Zig is monomorphic at the Zig level and dynamically typed at the
  PureScript level. Zig's type checker will not catch backend bugs; a wrong
  emission shows up as a runtime panic from `asString`, `asInt`, etc.
- Type classes need no special handling. The compiler has already desugared
  them into dictionary records passed as ordinary arguments. Dictionaries are
  `record` Values; method access is `Accessor`.
- Newtypes are erased by the compiler. Nothing to do.

The JSON shapes are recorded in [`corefn-schema.md`](corefn-schema.md),
transcribed from the compiler's `ToJSON.hs`. `CoreFn/Decode.purs` implements it.

## Naming

Zig identifiers must not collide with Zig keywords, with each other, or with
`main`. PureScript identifiers are worse than they look: CoreFn identifiers are
*arbitrary strings*, because type class desugaring concatenates printed types
into names.

The rule: **prefix by role, then quote**. A dot cannot appear in an unquoted
Zig identifier, so a prefix containing one can never collide with anything Zig
generates or reserves, and `@"..."` absorbs whatever characters CoreFn produces.

| Thing | Zig identifier | Example |
|---|---|---|
| Top-level binding `f` | `@"ps.f"` | `@"ps.greet"` |
| Local binder `x` | `@"v.x"`, suffixed on collision | `@"v.name"`, `@"v.name.1"` |
| Lambda body for binding `f` | `@"ps.f.lamN"` | `@"ps.greet.lam0"` |
| Imported module `A.B` | `@"mod.A.B"` | `@"mod.Zig.Prelude"` |
| Data constructor `C` | `@"ps.C"` | `@"ps.Just"` |

Note `@"main"` and `main` are *the same identifier* in Zig — quoting is not a
namespace. The `ps.` prefix is what keeps PureScript's `main` from colliding
with the Zig entry point.

Zig forbids shadowing, so the emitter carries a scope map from PureScript
binder to Zig identifier and appends a counter when a name is already live.

## Module structure

One PureScript module → one file, named after the module verbatim:
`Zig.Prelude` → `Zig.Prelude.zig`. Dots in filenames are legal and keep the
mapping trivial.

All generated files land in one flat directory, so cross-module references are
plain relative imports needing no build-system registration:

```zig
const @"mod.Zig.Prelude" = @import("Zig.Prelude.zig");
```

Two named imports are bound by `build.zig`, not by path: `@import("runtime")`
and `@import("ffi")`.

**Filter out the `Prim` import.** Every CoreFn module carries one; it does not
correspond to a real module and emitting an import for it produces a broken
reference.

## Top-level bindings are nullary functions

```zig
pub fn @"ps.greet"() rt.Value { ... }
```

Not constants. `rt.apply` allocates, so a `const` would have to be
comptime-known, and a lazily-initialised global would need initialisation
ordering the emitter would have to compute. A nullary function recomputes on
every reference, which is semantically free because PureScript is pure. purerl
uses the same convention.

The cost is real for expensive CAFs and is a known v2 item: memoise with a
`?Value` global once something needs it.

`Rec` binding groups need no special treatment — mutual recursion between
nullary functions is fine in Zig.

## Emission per CoreFn node

`⟦e⟧` means "the Zig expression for `e`". Every one is a `rt.Value`.

### Literals

```
LitInt n      →  rt.Value.mkInt(n)
LitNumber n   →  rt.Value.mkNumber(n)
LitString s   →  rt.Value.mkString("s")          -- escape for Zig
LitChar c     →  rt.Value.mkChar('c')
LitBoolean b  →  rt.Value.mkBool(b)
LitArray es   →  rt.Value.mkArray(rt.copyValues(&.{ ⟦e₀⟧, ⟦e₁⟧, ... }))
LitObject kvs →  rt.Value.mkRecord(&.{ .{ .name = "k", .value = ⟦v⟧ }, ... })
```

Arrays go through `copyValues` because their elements are runtime-computed;
record field *names* are comptime-known so the field slice can be a literal.

### Var

Local (in scope) → the scope map's Zig identifier, used directly:

```zig
@"v.name"
```

Top-level in this module → a call:

```zig
@"ps.greet"()
```

Top-level in another module → qualified call:

```zig
@"mod.Zig.Prelude".@"ps.log"
```

Note the asymmetry: `log` is a foreign import, re-exported as a `const`, so no
parentheses. A generated binding in another module *would* take them. The
emitter knows which from the module's `foreign` list.

### Abs

The one genuinely non-trivial case, because Zig has no closures.

1. Compute the free variables of the body — the only real algorithm in the
   backend.
2. Emit a top-level function taking `(env: []const rt.Value, arg: rt.Value)`.
3. Bind each free variable to `env[i]` at a fixed index, in a stable order.
4. At the `Abs` site, emit `rt.Value.mkClosure(body, env)` where `env` is
   `rt.no_env` if empty, else `rt.copyValues(&.{ ... })`.

```zig
fn @"ps.f.lam0"(env: []const rt.Value, @"v.y": rt.Value) rt.Value {
    const @"v.x" = env[0];
    return ...;
}
// at the Abs site:
rt.Value.mkClosure(@"ps.f.lam0", rt.copyValues(&.{@"v.x"}))
```

Environments are flat positional slices, not per-lambda structs. A struct per
`Abs` would mean naming and emitting a type for every lambda plus
`@ptrCast`/`@alignCast` at every call — all to save one indirection that
`purescript-backend-optimizer` would erase anyway.

Discard unused parameters (`_ = env;`) — Zig errors on unused function
parameters.

### App

```zig
rt.apply(⟦f⟧, ⟦a⟧)
```

Nested for multiple arguments. `rt.apply2` / `apply3` exist as sugar; the
emitter may ignore them.

### Accessor

```zig
⟦e⟧.field("k")
```

### ObjectUpdate

Build a fresh record: copy the fields of `⟦e⟧`, overriding the named ones.
Needs a runtime helper that does not exist yet — add `rt.updateRecord` when
first required.

### Let

Zig has statement-level `const`, so a `Let` becomes a block:

```zig
blk: {
    const @"v.x" = ⟦e₁⟧;
    break :blk ⟦body⟧;
}
```

`Rec` groups inside a `Let` are the awkward case: local mutual recursion cannot
be expressed with `const`. Lift them to top-level nullary functions, capturing
enclosing locals through the environment mechanism.

### Constructor

```zig
pub fn @"ps.Just"() rt.Value { ... }   // curried over its field count
```

A constructor of arity *n* is *n* nested closures ending in
`rt.Value.mkData("Just", rt.copyValues(&.{...}))`. Arity 0 is just the `mkData`
call, as `@"ps.Unit"` in the worked example shows.

The tag is the constructor name as a string. Integer tags are faster and are a
later optimisation.

### Case

Not yet designed in detail; the largest remaining piece. The shape:

- Scrutinees bound to temporaries first, since binders may test them repeatedly.
- Each alternative becomes a nested `if`, falling through to the next.
- `ConstructorBinder` tests with `.hasTag("Just")` and destructures with
  `.arg(0)`; both exist in `runtime/value.zig` already.
- `LiteralBinder` compares with `std.mem.eql` for strings, `==` otherwise.
- `NamedBinder` binds *and* continues matching.
- Guards add a condition to the alternative rather than a new alternative.
- Falling off the end is a pattern match failure: `@panic`.

## Foreign imports

A module's `foreign` list names the identifiers with no CoreFn body. For each,
emit a re-export rather than a definition:

```zig
const ffi = @import("ffi");
pub const @"ps.log" = ffi.zig_prelude.prim.@"ps.log";
```

The path is `ffi.<package with dashes as underscores>.<final module segment,
lowercased>`. Generated code therefore never mentions `ffi` at a use site, and
a package can rearrange its Zig implementation freely.

On the Zig side each foreign value is a `Value`, never a Zig function, so
generated code applies it through `rt.apply` like anything else. An
*n*-argument PureScript function is *n* nested one-argument closures.

## Effects

`Effect a` is a thunk: a closure ignoring a unit argument. Nothing runs until
`rt.runEffect` applies unit. This falls out of the one-argument-closure rule
and needs no special emission — an `Effect` is just a `Value` that happens to
be a closure.

## Entry point

Emitted only into the module the build is rooted at:

```zig
pub fn main(init: std.process.Init) !void {
    rt.init(init.io, init.arena.allocator());
    _ = rt.runEffect(@"ps.main"());
}
```

Zig 0.16 routes all I/O through an `Io` instance and provides one, plus a
process-lifetime arena, through `std.process.Init`. The runtime borrows both
rather than constructing its own — which is why `rt.init` takes two arguments
and there is no `rt.deinit`.
