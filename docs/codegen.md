# Code generation spec

What `Zig/Emit.purs` must produce.

The best worked example is now the generated output itself: run `zig build
codegen` and read `purs/example/output-zig/`. The whole of `purescript-prelude`
compiles through this, so anything the spec describes can be seen in practice
there. (`purs/example/expected/`, a hand-written reference, was deleted once
the emitter outgrew it.)

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
- Newtypes are erased by the compiler only **halfway**, and finishing the job
  is the backend's responsibility. CoreFn emits a newtype constructor as the
  identity function, so the wrapper never exists at runtime — but the *binder*
  side still arrives as a `ConstructorBinder`, carrying `meta: IsNewtype`. A
  backend that ignores the meta emits a `hasTag` test against a value that was
  never tagged, and it can only fail. Single-method type classes are newtypes,
  so `Eq`, `Ord`, `Show`, `Functor` and `Semigroup` all depend on this.

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
| Recursive-let member | `@"ps.f.recN.M"` | `@"ps.target.rec2.0"` |
| Case scrutinee temporary | `@"v.c.N.I"` | `@"v.c.3.0"` |
| Block label | `blkN`, `caseN` | `blk0`, `case3` |

Note `@"main"` and `main` are *the same identifier* in Zig — quoting is not a
namespace. The `ps.` prefix is what keeps PureScript's `main` from colliding
with the Zig entry point.

Zig forbids shadowing, so the emitter carries a scope map from PureScript
binder to Zig identifier and appends a counter when a name is already live.
Anything that needs to *reference* a local must read that map rather than
rebuild the name from the PureScript identifier — a shadowed binder carries a
suffix, and a recursive-let member is a whole `mkClosure` expression rather
than an identifier at all.

Block labels are the exception to the quote-and-prefix rule: they are plain
identifiers like `blk0`, because a label is not an identifier namespace Zig
declarations live in. They still get a counter, since labels within one
function must be distinct.

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

**Filter out `Prim` and everything under it.** Every CoreFn module carries at
least one, and row-polymorphic code pulls in `Prim.Row`, `Prim.RowList`,
`Prim.Symbol`, `Prim.Ordering`, `Prim.Coerce` and `Prim.TypeError` besides.
None corresponds to a real module, so the test is the `Prim.` prefix, not
equality with `Prim`.

`Prim` also appears in *expressions*: the compiler emits `Prim.undefined` as a
placeholder for an erased type argument, passed around and never forced. The
JavaScript backend emits a literal `undefined`; any value does, so this emits
`rt.Value.mkUnit()`.

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
LitObject kvs →  rt.Value.mkRecord(rt.copyFields(&.{ .{ .name = "k", .value = ⟦v⟧ }, ... }))
```

Both arrays and records go through a copy into the arena, for the same reason:
`&.{ ... }` is a pointer to a temporary in the *enclosing function's* frame, and
both `mkArray` and `mkRecord` store that slice inside a `Value` that outlives the
frame. Field *names* are comptime-known, which is why the slice can be written as
a struct literal at all — but the values are not, so the literal cannot be
promoted to static storage and must be copied.

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

Discard unused parameters — Zig errors on unused function parameters, and
PureScript produces them constantly: every `\_ -> ...` and every erased
dictionary argument is one. Both the argument and `env` need this, on separate
conditions:

- the argument is discarded when it is not free in the body;
- `env` is discarded when nothing was captured.

For a recursive-`let` member the second condition is not enough. `env` also
appears verbatim in every reference to a group member, including the
self-reference, so it is discarded only when there are no captures **and** no
member is mentioned in the body. `Data.Void.absurd` is exactly the case that
catches this: recursive, capturing nothing.

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

```zig
rt.updateRecord(⟦e⟧, &.{ .{ .name = "k", .value = ⟦v⟧ }, ... })
```

Copy-on-write: `updateRecord` allocates a fresh field slice, copies the base
record's fields in their original order, and substitutes any whose name appears
in the updates. The base is untouched, which is what makes this safe under an
arena that never frees — nothing else can be holding a stale view of a record
that just changed.

No `copyFields` here. Unlike `mkRecord`, `updateRecord` copies into the arena as
part of its own work, so the update slice may stay a stack temporary.

PureScript's record update syntax is type-checked, so every update key must
already exist in the base record. A key that misses is therefore a *backend*
bug, never bad user code, and `updateRecord` panics rather than silently adding
or dropping a field.

### Let

Zig has statement-level `const`, so a `Let` becomes a labelled block:

```zig
blk0: {
    const @"v.x" = ⟦e₁⟧;
    break :blk0 ⟦body⟧;
}
```

Block labels share one namespace within a function, so the label is numbered
from the same fresh-name counter the lifted lambdas use. A fixed `blk` collides
as soon as one `Let` nests inside another — and record update desugaring
introduces a `Let`, so this happens without the source containing nested
`where` blocks at all.

`Rec` groups inside a `Let` are the awkward case: local mutual recursion cannot
be expressed with `const`. The group is lifted to top-level functions sharing
one environment — the union of the members' free variables, minus the members
themselves, so every member has the same env layout:

```zig
fn @"ps.target.rec2.0"(env: []const rt.Value, @"v.b": rt.Value) rt.Value {
    const @"v.n" = env[0];
    return ...;                       // `pick` here is mkClosure(rec2.0, env)
}
// at the Let site:
const @"v.env.2" = rt.copyValues(&.{ @"v.n" });
const @"v.pick" = rt.Value.mkClosure(@"ps.target.rec2.0", @"v.env.2");
```

Within the group, a member — including itself — is
`rt.Value.mkClosure(fn, env)`: a **value**, not a call. Emitting a call would
re-enter the function being defined while building its own capture list and
loop forever. This is what removes the need to tie a knot.

Only `Abs` members are supported. A non-function recursive binding diverges
under strict evaluation anyway; PureScript 0.15 added a laziness transform that
turns that divergence into a runtime error, but CoreFn hands over the raw `Rec`
group and the transform is each backend's own job (purerl implements it). Since
a recursive *function* binding never needs laziness — the self-reference is
only forced when called — restricting to `Abs` sidesteps the whole problem.

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

Structured after the compiler's own JS backend (`bindersToJs`), adapted to
Zig's constraints.

Scrutinees are bound to temporaries first, since binders may test them
repeatedly. Each alternative is a chain of tests falling through to the next
alternative, and the whole thing is a labelled block where `break :caseN` plays
the part of the JS backend's `return`:

```zig
case3: {
    const @"c.3.0" = ⟦scrutinee⟧;
    if (@"c.3.0".asBool() == true) {
        break :case3 ⟦result⟧;
    }
    break :case3 ⟦other result⟧;
}
```

**A binder wraps a continuation; it is not a (test, destructure) pair.** This is
the one idea worth borrowing wholesale. `emitBinder` takes the code to run once
the binder has matched and wraps it in whatever test and bindings it needs, so
nested binders compose without special handling — a sub-binder is emitted
inside the bindings its parent introduced, which is exactly where it needs to
be for `Just (Just x)` to work.

**Reachability has to be tracked during emission.** The JS backend emits its
"Failed pattern match" throw unconditionally, because JavaScript tolerates
statements after a `return`. Zig rejects unreachable code outright, so the fold
carries a `canFail` flag: an alternative whose binders emit no test always
matches, which makes both the following alternatives and the trailing `@panic`
dead. Emission stops at the first irrefutable alternative and the panic is
omitted.

Every binder form is implemented. Each addresses its sub-subject differently
and is otherwise the same fold, which is what makes nesting free:

| Binder | Test | Sub-subject |
|---|---|---|
| `NullBinder` | none | — |
| `VarBinder` | none | binds the subject |
| `NamedBinder` | inner binder's | binds *and* keeps matching the same subject |
| `ConstructorBinder` | `.hasTag("Just")` | `.arg(i)` |
| `ConstructorBinder`, `IsNewtype` | none | the subject itself |
| `LiteralBinder` scalar | `.asInt() == 3`, `.stringEq("x")`, … | — |
| `LiteralBinder` array | `.asArray().len == n` | `.asArray()[i]` |
| `LiteralBinder` record | none | `.field("k")` |

String comparison is `Value.stringEq`, not an inline `std.mem.eql`: only the
entry module imports `std`, and generated code is meant to reference nothing
but `rt`. A record binder needs no test because the type checker has already
guaranteed the fields exist; an array binder does, because length is a runtime
property.

Guards are conditions *on* an alternative, not alternatives themselves — if
every guard fails, matching resumes at the next alternative rather than
failing. So a guarded alternative always reports `canFail`, even when its last
guard is literally `true`. That can leave a redundant `@panic`, which is the
safe direction: Zig rejects unreachable code, so over-reporting reachability
costs a dead branch while under-reporting fails the build.

The tag is the constructor name as a string. Integer tags are faster and are a
later optimisation.

## Foreign imports

A module's `foreign` list names the identifiers with no CoreFn body. For each,
emit a re-export rather than a definition:

```zig
const ffi = @import("Data.Semiring.ffi.zig");
pub fn @"ps.intAdd"() rt.Value {
    return ffi.@"ps.intAdd";
}
```

**The Zig lives beside the `.purs` source**, exactly as `Foo/Bar.js` does for
the JavaScript backend and `Foo/Bar.erl` for purerl: `Data/Semiring.purs` pairs
with `Data/Semiring.zig`. The driver reads `modulePath` from corefn.json —
which points at the original source wherever the package was unpacked — and
copies the file into the output directory as `<Module>.ffi.zig`.

A package therefore ships its own FFI and registers nothing anywhere. That is
what makes a third-party package usable: there is no central directory to edit,
and no build-system entry to add.

A module declaring foreign imports with no `.zig` beside it is reported as
`MISSING FFI` naming the path that was expected. The generated module will fail
to compile in Zig regardless; the report just makes the cause legible.

### Writing FFI

Foreign exports are `rt.Value`s, and an *n*-argument PureScript function is *n*
nested one-argument closures. Writing that chain by hand means *n* functions
plus hand-managed `env` indices the compiler cannot check, so the runtime
generates it from the function's own signature at comptime:

```zig
fn intAdd(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() +% y.asInt());
}
pub const @"ps.intAdd" = rt.curry(intAdd);
```

- `rt.curry(f)` — a pure function of one or more arguments.
- `rt.effect(f)` — an `Effect`. Adds the trailing unit thunk, so nothing runs
  until `rt.runEffect` forces it. Works for nullary `f` too.

purerl solves the same problem by parsing arity out of the Erlang export list;
Zig has comptime reflection, so the backend never learns about arity at all.

Unlike generated code, hand-written FFI may import `std` freely, and may
allocate from the arena through `rt.alloc()`.

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
