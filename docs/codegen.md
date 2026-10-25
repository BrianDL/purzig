# Code generation spec

What `Zig/Emit.purs` must produce.

The best worked example is the generated output itself: run `zig build codegen`
and read `example/output-zig/`. The whole of `purescript-prelude` compiles
through this, so anything described here can be seen in practice there.

## The pipeline

```
purs compile --codegen corefn
    output/<Module>/corefn.json
        -> CoreFn.Json.decodeModule        (the optimizer's decoder)
        -> CoreFn.Sort.sortModules         (dependency order, mandatory)
        -> Builder.buildModules            (optimisation, whole-program)
             -> BackendModule + NeutralExpr
        -> Tco.analyze                     (tail-call decoration)
             -> TcoExpr
        -> Zig.Emit                        (this spec)
    output-zig/<Module>.zig                (modules only)
    output-zig/<Module>.ffi.zig            (only where there are foreign imports)
    output-zig/manifest.json               (what the run wrote)
```

The backend consumes `purescript-backend-optimizer`, not CoreFn directly.
`docs/corefn-schema.md` is retained for historical interest only — nothing here
reads `corefn.json` except the driver, and it hands the bytes straight to
`decodeModule`.

Three consequences of that, each of which used to be the backend's problem and
is now the optimizer's:

- **Pattern matching arrives already compiled.** There are no binders. A `case`
  is a `Branch`: a list of condition/result pairs plus a fallback, with the
  tests expressed as ordinary operations (`OpIsTag`, `OpIntOrd`) and the
  destructuring as `Accessor`s.
- **Newtypes are fully erased**, `Prim` and its submodules are filtered out of
  the import set, and `Prim.undefined` arrives as the `PrimUndefined` node.
- **Dead bindings and unused imports are gone** before emission.

`sortModules` is not cosmetic. `buildModules` threads an `implementations` map
forward so a definition can be inlined into its callers, so a module must be
visited after the modules it depends on. Feeding readdir order crashes the
optimizer inside `lookupCtorFields`.

## Typing

There is one type. Every PureScript value of every type becomes a `rt.Value`, a
tagged union with variants `unit`, `boolean`, `integer`, `number`, `string`,
`char`, `array`, `record`, `data`, `closure`, `ref`, `marray`.

The last two are the only mutable things in the runtime, and both are pointers
for the same reason: a write must be observable through every copy of the
handle, `Value` is passed by value everywhere, and `mkRecord` copies.

`ref` backs `Effect.Ref` and `Control.Monad.ST.Ref`, which are the same cell at
runtime since the region parameter is erased. It also backs the lazy cells
described under `LetRec`.

`marray` is a `*std.ArrayList(Value)` and backs `Data.Array.ST`'s `STArray`. It
cannot reuse `array`, which is a `[]const Value` with no capacity — `push` would
be O(n) per element and `sortBy` O(n²), and `Data.Array`'s `sort`, `nub`,
`group` and `union` all run through `Data.Array.ST`, so that is the common path
rather than an exotic one. The runtime's whole public surface for it is
`rt.newMutArray`; every other operation is an ordinary `std.ArrayList` call that
`Data/Array/ST.zig` makes through `Value.asMutArray()`, which hand-written FFI
is allowed to do. Generated code never touches an `STArray`.

The IR is untyped — the compiler has already type-checked and discarded the
types — so the backend has nothing to be type-directed with. Generated Zig is
monomorphic at the Zig level and dynamically typed at the PureScript level:
Zig's type checker will not catch backend bugs, and a wrong emission shows up as
a runtime panic from `asString`, `asInt`, and friends.

Type classes need no special handling. The compiler desugars them into
dictionary records passed as ordinary arguments; a dictionary is a `record`
Value and method access is an `Accessor`.

## Everything is fallible

`Fn1` — the type every closure body has — returns `rt.Error!rt.Value`, where
`rt.Error` is `error{PsException}`. Zig has no stack unwinding: errors are values
in the return type. Since the backend is untyped, any application might reach
`Effect.Exception.throw`, so every generated function is fallible whether or not
it can actually raise.

- every emitted function returns `rt.Error!rt.Value`;
- every `rt.apply` and every top-level reference is prefixed with `try`;
- **every emitted `try` is parenthesised.** `try` binds looser than postfix field
  access, so `try f().field("k")` parses as `try (f().field("k"))` and fails to
  compile. Output is paren-heavy as a result.

Zig error values carry no payload, so the thrown PureScript `Error` travels in a
side channel: `rt.throwValue` stashes it and returns `error.PsException`,
`rt.takeError` retrieves it in the handler.

`Fn1` is the type generated code is compiled against, so the runtime signature
and the emitter cannot change independently — nothing links in between. They are
necessarily one commit.

## Naming

Zig identifiers must not collide with Zig keywords, with each other, or with
`main`. The rule: **prefix by role, then quote**. A dot cannot appear in an
unquoted Zig identifier, so a prefix containing one can never collide with
anything Zig generates or reserves, and `@"..."` absorbs whatever characters the
IR produces.

| Thing | Zig identifier | Example |
|---|---|---|
| Top-level binding `f` | `@"ps.f"` | `@"ps.greet"` |
| Local binder | `@"v.<name>.<level>"` | `@"v.acc.3"` |
| Anonymous local | `@"v.l.<level>"` | `@"v.l.7"` |
| Lifted lambda | `@"ps.f.lamN"` | `@"ps.greet.lam0"` |
| Imported module `A.B` | `@"mod.A.B"` | `@"mod.Data.Maybe"` |
| Data constructor `C` | `@"ps.C"` | `@"ps.Just"` |
| Recursive-let member | `@"ps.f.recN.M"` | `@"ps.target.rec2.0"` |
| Lazy cell | `@"v.lazy.N.I"` | `@"v.lazy.7.0"` |
| Loop function | `@"ps.f.loopN"` | `@"ps.deepSum.loop3"` |
| Loop wrapper | `@"ps.f.argN.I.J"` | `@"ps.deepSum.arg3.0.1"` |
| Loop slot | `@"v.a.N.J"` | `@"v.a.3.0"` |
| Effect thunk parameter | `@"v.eff.-N"` | `@"v.eff.-4"` |
| Block label | `blkN`, `caseN`, `effN` | `blk0`, `case3` |

**A local is identified by `(Maybe Ident, Level)`, not by name and not by level
alone.** Levels are assigned as the optimizer descends, and a `LetRec` gives
every member of a group the *same* level, distinguishing them by identifier. The
pair is therefore unique by construction, which is why nothing suffixes names on
shadowing — the counter-appending the CoreFn emitter needed is gone.

Anything that needs to *reference* a local must read the scope map rather than
rebuild the name: a recursive-let member is a whole `mkClosure` expression, a
captured variable inside a lifted body is an `env[i]`, and a loop parameter is a
slot variable.

Note `@"main"` and `main` are *the same identifier* in Zig — quoting is not a
namespace. The `ps.` prefix is what keeps PureScript's `main` from colliding
with the Zig entry point.

## Module structure

One PureScript module → one file, named after the module verbatim:
`Data.Maybe` → `Data.Maybe.zig`. Dots in filenames are legal and keep the
mapping trivial. All generated files land in one flat directory, so cross-module
references are plain relative imports needing no build-system registration:

```zig
const @"mod.Data.Maybe" = @import("Data.Maybe.zig");
```

One named import is bound by `build.zig` rather than by path: `@import("runtime")`.
A module's own FFI is a relative import too — see Foreign imports.

The import set arrives already filtered: no `Prim`, no self-import, nothing
unused.

## Top-level bindings are nullary functions

```zig
pub fn @"ps.greet"() rt.Error!rt.Value { ... }
```

Not constants. `rt.apply` allocates, so a `const` would have to be
comptime-known, and a lazily-initialised global would need initialisation
ordering the emitter would have to compute. A nullary function recomputes on
every reference, which is semantically free because PureScript is pure. purerl
uses the same convention.

The cost is real for expensive CAFs and is a known item: memoise with a `?Value`
global once something needs it.

Mutual recursion between nullary functions is fine in Zig, so a recursive
binding group needs no special treatment — unless it qualifies as a loop.

## Emission per IR node

`⟦e⟧` means "the Zig expression for `e`". Every one is a `rt.Value`.

### Literals

```
LitInt n      →  rt.Value.mkInt(n)
LitNumber n   →  rt.Value.mkNumber(n)
LitString s   →  rt.Value.mkString("s")
LitChar c     →  rt.Value.mkChar(<code point>)
LitBoolean b  →  rt.Value.mkBool(b)
LitArray es   →  rt.Value.mkArray(rt.copyValues(&.{ ⟦e₀⟧, ... }))
LitRecord kvs →  rt.Value.mkRecord(rt.copyFields(&.{ .{ .name = "k", .value = ⟦v⟧ }, ... }))
```

`LitChar` emits the numeric code point rather than a Zig character literal: our
`Char` is a `u21`, and the code point needs no escaping analysis.

Arrays and records both copy into the arena, for the same reason: `&.{ ... }` is
a pointer to a temporary in the enclosing frame, and both `mkArray` and
`mkRecord` store that slice inside a `Value` that outlives it.

### Var and Local

Top-level in this module, or in another:

```zig
(try @"ps.greet"())
(try @"mod.Data.Maybe".@"ps.fromMaybe"())
```

There is no asymmetry between foreign and generated bindings at a use site: a
foreign import is re-exported as a nullary function too, precisely so the
emitter never has to consult the module's `foreign` list to write a reference.

A `Local` resolves through the scope map. If the entry is a lazy cell, reading
forces it:

```zig
(try rt.forceLazy(@"v.lazy.7.0"))
```

### Abs and App

`Abs` collects its binders and `App` collects its spine, so both arrive
n-ary. Both are emitted as curried chains of one argument, which is what keeps
the FFI convention intact.

Zig has no closures, so every lambda is lifted:

1. Compute the free variables of the body — the only real algorithm left here.
2. Emit a top-level `fn (env: []const rt.Value, arg: rt.Value)`.
3. Bind each free variable to `env[i]` at a fixed index, in a stable order.
4. At the `Abs` site, emit `rt.Value.mkClosure(body, env)`, with `rt.no_env` if
   nothing was captured.

```zig
fn @"ps.f.lam0"(env: []const rt.Value, @"v.y.2": rt.Value) rt.Error!rt.Value {
    const @"v.x.1" = env[0];
    return ...;
}
rt.Value.mkClosure(@"ps.f.lam0", rt.copyValues(&.{@"v.x.1"}))
```

Environments are flat positional slices, not a generated struct per lambda. A
struct would mean naming and emitting a type for every lambda plus
`@ptrCast`/`@alignCast` at every call, to save one indirection.

Discard unused parameters — Zig errors on them and PureScript produces them
constantly. Both the argument and `env` need this, on separate conditions: the
argument when it is not free in the body, `env` when nothing was captured.

An application is nested applies, which is where the parentheses earn their
keep:

```zig
(try rt.apply((try rt.apply(f, a)), b))
```

**Uncurried nodes collapse to the same shape.** `UncurriedAbs`, `UncurriedApp`
and their effectful counterparts come from `Data.Function.Uncurried` and
`Effect.Uncurried`, i.e. from source that was already uncurried. There is no
n-ary function value in this runtime, so they emit as curried chains; the
nullary forms take an ignored argument, so applying unit runs them. This is why
adopting the optimizer did not disturb the `rt.curry`/`rt.effect` FFI
convention, and why no uncurrying layer like backend-erl's `Calling.purs` is
needed.

### Accessor and Update

```zig
⟦e⟧.field("k")            // GetProp
⟦e⟧.asArray()[i]          // GetIndex
⟦e⟧.arg(i)                // GetCtorField
rt.updateRecord(⟦e⟧, &.{ .{ .name = "k", .value = ⟦v⟧ }, ... })
```

`GetCtorField` always addresses a real constructor — newtype erasure happened
upstream. `updateRecord` copies into the arena as part of its own work, so
unlike `mkRecord` the update slice may stay a stack temporary. It panics if a
key is missing from the base, which is a backend bug rather than bad user code,
since record update is type-checked.

### Constructors

```zig
rt.Value.mkData("Just", rt.copyValues(&.{ ⟦x⟧ }))     // CtorSaturated
```

`CtorDef` — an unsaturated reference — becomes *n* nested closures ending in the
same `mkData`. Arity 0 is just `mkData("Unit", &.{})`.

The tag is the constructor name as a string. `CtorMeta` carries an integer tag,
so switching to integer tags is nearly free whenever wanted.

### Let and LetRec

A `Let` is a labelled block, numbered from the fresh-name counter because a
fixed label collides as soon as one nests inside another:

```zig
blk0: {
    const @"v.x.1" = ⟦e⟧;
    break :blk0 ⟦body⟧;
}
```

A `LetRec` group that is not a loop is handled two ways, depending on whether
the member is a lambda.

**Function members** are lifted to top-level functions sharing one environment —
the union of the members' free variables, minus the members themselves, so every
member has the same env layout. Within the group a member is
`rt.Value.mkClosure(fn, env)`: a **value, not a call**. Emitting a call would
re-enter the function being defined while building its own capture list and loop
forever.

`env` is discarded only when there are no captures **and** no member is mentioned
in the body — a member reference mentions `env` verbatim. `Data.Void.absurd` is
the case that catches this.

**Non-function members get a lazy cell.** PureScript permits a recursive binding
that is not a function, and `Control.Lazy.fix` is one. The compiler offers
`applyLazinessTransform` only to backends embedding it as a Haskell library; a
backend reading `corefn.json` implements the fallback the 0.15.0 release notes
describe.

```zig
const @"v.lazy.5.0" = rt.newLazy("go", "Control.Lazy");
const @"v.env.5" = rt.copyValues(&.{ @"v.f.4", @"v.lazy.5.0" });
rt.setLazyInit(@"v.lazy.5.0", rt.Value.mkClosure(@"ps.fix.rec5.0", @"v.env.5"));
```

The ordering is forced by a mutual dependency: the initialiser closes over an
environment that must contain the cells, so cells first, then the environment,
then the initialisers. Env layout is captures first, then one slot per lazy
member, so every index is a compile-time constant.

**The load-bearing rule: reading a lazy binding forces it; capturing it does
not.** `Local` emits `(try rt.forceLazy(cell))`; `scopeText`, which builds every
capture list, yields the bare cell. Backwards, and `go = defer \_ -> f go` forces
during its own initialisation and hits the cycle panic. `rt.forceLazy` panics
rather than raising a catchable exception, because a cycle is a defect in the
program's definitions rather than a condition to recover from.

### Branch

Pattern matching arrives already compiled, so this is a chain of tests in a
labelled block:

```zig
case3: {
    if (⟦c₀⟧.asBool()) break :case3 ⟦v₀⟧;
    if (⟦c₁⟧.asBool()) break :case3 ⟦v₁⟧;
    break :case3 ⟦fallback⟧;
}
```

No reachability tracking is needed. The optimizer has already pruned
unreachable alternatives, and the fallback is always an expression — often
`Fail` — rather than an optional trailing panic. All the machinery the CoreFn
emitter needed here (the binder continuation fold, the `canFail` flag,
per-alternative bracketing, scrutinee-discard analysis) is gone.

### Fail

`Fail` becomes `@panic("...")`, which is `noreturn`. **It is emitted as a
diverging statement, never as the value of a `break` or `return`** — Zig rejects
the enclosing `break :label @panic(...)` as unreachable code, since control flow
has already diverted. All seven tail positions route through
`returnStmt`/`breakStmt`/`tailText`.

`diverges` currently tests only for a literal `Fail`. A `Branch` whose arms all
diverge is also `noreturn` and would produce the same error one level up; not
reachable today.

### PrimUndefined

`rt.Value.mkUnit()`. The compiler's placeholder for an erased type argument:
passed around, never forced, so any value does.

### PrimOp

The optimizer rewrites the prelude's foreign arithmetic, comparison and append
into primitive operations, so most of what used to be an FFI call arrives here.
Each is a one-liner over the runtime's public surface:

`op1Text` and `op2Text` between them implement eighteen constructors:

| Operator | Zig |
|---|---|
| `OpBooleanNot` | `mkBool(!x.asBool())` |
| `OpIntBitNot` | `mkInt(~x.asInt())` |
| `OpIntNegate` | `mkInt(-%x.asInt())` |
| `OpNumberNegate` | `mkNumber(-x.asNumber())` |
| `OpArrayLength` | `mkInt(@intCast(x.asArray().len))` |
| `OpIsTag C` | `mkBool(x.hasTag("C"))` |
| `OpArrayIndex` | `x.asArray()[@intCast(y.asInt())]` |
| `OpBooleanAnd`/`Or` | `mkBool(x.asBool() and y.asBool())` |
| `OpBooleanOrd` | compares `@intFromBool(x.asBool())` |
| `OpCharOrd` | compares `x.asChar()` |
| `OpIntOrd` | compares `x.asInt()` |
| `OpNumberOrd` | compares `x.asNumber()` |
| `OpStringOrd OpEq` | `mkBool(x.stringEq(y.asString()))` |
| `OpStringOrd OpNotEq` | `mkBool(!x.stringEq(y.asString()))` |
| `OpIntNum` | `+%`, `-%`, `*%` — wrapping, matching JavaScript's `\| 0` |
| `OpNumberNum` | `+`, `-`, `*`, `/` — no wrapping; Number is an f64 |
| `OpIntBitAnd`/`Or`/`Xor` | `&`, `\|`, `^` on `asInt()` |
| `OpStringAppend` | `mkString(rt.concatString(x.asString(), y.asString()))` |

The four ordering operators share one `cmp` helper and differ only in the
accessor they project through, which is why they are one row each rather than a
table of twenty-four comparisons: `OpEq`, `OpNotEq`, `OpLt`, `OpLte`, `OpGt` and
`OpGte` are all handled uniformly.

Zig's `and`/`or` short-circuit and the right operand is part of the right-hand
expression, so laziness in the second argument is preserved.

**Five operators are deliberately not implemented**, because the `PrimOp` the
optimizer produces assumes JavaScript semantics this backend does not share.
`Main.purs` filters the corresponding entries out of `coreForeignSemantics`, so
those calls stay ordinary FFI applications where the semantics already match:

- `Data.EuclideanRing.intDiv` — ours is Euclidean and returns 0 on
  divide-by-zero, transcribed from the original `.js`.
- `Data.Int.Bits.shl`/`shr`/`zshr` — JavaScript masks the shift count to five
  bits, where a shift wider than the type is illegal behaviour in Zig. Note the
  non-shift bitwise operators above ARE implemented: masking is the only part
  of `Data.Int.Bits` whose semantics differ.
- `Data.Ord.ordString` — the runtime has `stringEq` but no comparison.

If one of these ever reaches the emitter, the filter has drifted, and the
emitter returns a `Left` naming it rather than emitting something wrong.

### Effects

`Effect a` is a thunk: a closure ignoring a unit argument, run by
`rt.runEffect`. All four effect nodes produce a lifted closure and differ only in
what its body does.

The thunk's parameter uses a synthetic key with a **negative level** derived from
the fresh counter. Levels are numbered from zero, so a negative one cannot
collide with a real binder, and using the counter keeps nested thunks from
declaring the same parameter name.

**A chain of `EffectBind`s flattens into ONE block of statements.** This is
MagicDo, and it is the whole point of the effect nodes: emitting each bind as
its own thunk would allocate a closure per `>>=`.

```zig
eff7: {
    const @"v.x.3" = ⟦a⟧;
    _ = ⟦b⟧;
    break :eff7 ⟦c⟧;
}
```

A bind whose result the continuation ignores is discarded rather than bound —
Zig rejects an unused local constant, and PureScript produces these constantly,
since every `discard` in a do-block binds `$__unused` and the loop combinators
bind a result nobody reads.

`emitPerform` is what runs one effect, and it is where the saving lands: every
node the optimizer produced structurally is *known* to be an effect, so it needs
no thunk at all.

| Node | Performed as |
|---|---|
| `EffectPure x` | `⟦x⟧` — no closure, no `runEffect` |
| `EffectDefer a` | performs `a` directly |
| `EffectBind` | a nested block |
| `EffectRefNew v` | `rt.newRef(⟦v⟧)` |
| `EffectRefRead r` | `⟦r⟧.asRef().*` |
| `EffectRefWrite r v` | a block: assign, then yield `mkUnit()` |
| anything else | `(try rt.runEffect(⟦e⟧))` |

A ref write is a statement in Zig, not an expression, hence the block — and
`Effect Unit` still has to yield a value.

### Exceptions

`throwException` is `rt.throwValue(e)`; the `try` on every application
propagates it. `catchException` runs the action and, on failure, calls the
handler with `rt.takeError()`. It must be written
`if (rt.runEffect(action)) |v| ... else |_| ...` rather than with `catch`,
because the recovery branch is itself fallible — a handler may throw again — and
`a catch b` requires `b` to be the unwrapped type.

An `Error` is `mkData("Error", &.{ message, name, cause })`, a data constructor
rather than a record: nothing in PureScript projects it structurally, since
`message` and `name` *are* foreign imports.

## Tail calls

`Tco.analyze` decorates the IR with tail-call information relative to an
environment naming a binding group's own members and their arities.
`tcoRoleIsLoop` is true only when **every** self-reference in the group is a
saturated tail call at uniform arity — if the function is ever passed around as
a value, or called with the wrong number of arguments, it is not a loop and the
ordinary curried emission is the only correct one.

The analysis is the toolkit's; the loop emission is the backend's.

**The ES backend's shape does not transfer.** It puts the loop inside the curried
arrow chain, because a JavaScript closure may reassign a captured `let`. Ours
cannot: the arguments of a curried chain live in a `[]const rt.Value` env, so a
jump would have nothing it is allowed to write to.

The loop is therefore a **separate uncurried Zig function** taking every argument
at once, with a mutable copy of each:

```zig
fn @"ps.deepSum.loop3"(env: []const rt.Value, @"v.in.3.0": rt.Value, @"v.in.3.1": rt.Value) rt.Error!rt.Value {
    _ = env;
    var @"v.a.3.0" = @"v.in.3.0";
    var @"v.a.3.1" = @"v.in.3.1";
    while (true) {
        if (...) return @"v.a.3.1";
        const @"v.jump.4.0" = ...;
        const @"v.jump.4.1" = ...;
        @"v.a.3.0" = @"v.jump.4.0";
        @"v.a.3.1" = @"v.jump.4.1";
        continue;
    }
}
```

The curried chain still exists and is unchanged — its innermost lambda just
calls the loop. So every call site, `rt.apply`, partial application, and the
whole FFI convention stay exactly as they were.

Points worth keeping:

- **Assignment is simultaneous.** `go (n - 1) acc` must not see the new `n` while
  evaluating `acc`, so every argument is computed into a temporary first and only
  then written back.
- **No trailing `return`.** Zig knows a `while (true)` with no `break` is
  noreturn, and every tail position emits a `return` or a `continue`.
- **A local loop takes an `env` slice** for captured variables, threaded through
  both the loop function and the wrapper chain. The wrapper's env holds the
  captures followed by the arguments gathered so far, so the final wrapper hands
  the captures back as `env[0..c]` with `c` a compile-time constant.
- **With no captures, nothing mentions `env`**: the loop discards it, a
  self-reference closes over `rt.no_env`, and the `Let` site emits no env
  binding at all. Zig's unused-parameter and unused-local rules are separate, so
  each of these has to be handled independently.
- **A mutual group shares one loop function.** Slots are numbered to the widest
  member's arity, a narrower member leaves the high slots alone and its wrapper
  pads the call with `mkUnit()`, and a `branch` variable selects whose body runs.
  Dispatch is an `if` chain, since every arm is `noreturn`.
- **Slot mutability cannot be decided before emission.** Zig rejects a `var` that
  is never mutated, and with mixed arities a high slot may belong to a member
  nothing ever jumps to. Jumps therefore record which slots they assign, and the
  declaration is `var` or `const` accordingly.

**Join points are deliberately not implemented.** The optimizer's analysis
reports them (`role.joins`), and the ES backend needs them because a JavaScript
call in tail position still grows the stack. In Zig a join is an ordinary call
that returns before the next iteration, so it costs one transient frame and
never accumulates. The remaining cost is one `mkClosure` per enclosing
evaluation, which inside a loop body is an allocation per iteration — worth
revisiting alongside the arena, not before.

## Foreign imports

A module's `foreign` set names the identifiers with no body. Each becomes a
re-export rather than a definition:

```zig
const ffi = @import("Data.Semiring.ffi.zig");
pub fn @"ps.intAdd"() rt.Error!rt.Value {
    return ffi.@"ps.intAdd";
}
```

**The Zig lives beside the `.purs` source**, exactly as `Foo/Bar.js` does for
JavaScript and `Foo/Bar.erl` for purerl: `Data/Semiring.purs` pairs with
`Data/Semiring.zig`. The driver reads `path` from the CoreFn module — which
points at the original source wherever the package was unpacked — and copies the
file into the output directory as `<Module>.ffi.zig`.

A package therefore ships its own FFI and registers nothing anywhere. That is
what makes a third-party package usable: no central directory to edit, no
build-system entry to add. A module declaring foreign imports with no `.zig`
beside it is reported as `MISSING FFI` naming the path expected.

Note that `BackendModule` carries no `path`, so the driver takes it from the
CoreFn module in `onCodegenModule`.

### Writing FFI

Foreign exports are `rt.Value`s, and an *n*-argument PureScript function is *n*
nested one-argument closures. Writing that chain by hand would mean *n*
functions plus hand-managed `env` indices the compiler cannot check, so the
runtime generates it from the function's own signature at comptime:

```zig
fn intAdd(x: Value, y: Value) Value {
    return Value.mkInt(x.asInt() +% y.asInt());
}
pub const @"ps.intAdd" = rt.curry(intAdd);
```

- `rt.curry(f)` — a pure function of one or more arguments.
- `rt.effect(f)` — an `Effect`. Adds the trailing unit thunk, so nothing runs
  until `rt.runEffect` forces it. Works for nullary `f` too.

**Which of the two is decided by what the function DOES, not by its PureScript
type.** Anything that performs an effect takes `rt.effect`, including the
`STFnN`- and `EffectFnN`-typed imports that look like they should run on
saturation. They do not: the emitter lowers an `UncurriedEffectApp` to the
applications followed by `rt.runEffect`, so a saturated `STFn4` still has to
yield a thunk for that `runEffect` to force. Using `rt.curry` there runs the
operation one step early and hands `runEffect` a finished value to apply, which
panics with "applied a non-function" — or, worse, silently does nothing when the
result is discarded.

Two corollaries, both of which were got wrong first:

- A pure function *of* an effectful value is `rt.curry`. `Control.Monad.ST.run`
  is the example: `ST h a -> a` forces immediately and returns the result.
- In the uncurried shim modules the two families are opposites. `runEffectFnN`
  and `runSTFnN` FORWARD a thunk their argument already is, so they are
  `rt.curry`; `mkEffectFnN` and `mkSTFnN` CREATE one, so they are `rt.effect`.
  Getting either backwards adds or removes a thunk level that nothing forces.

When in doubt, read the generated `.zig` for a call site rather than reasoning
from the type.

An FFI function may return either `Value` or `rt.Error!Value` and needs no
annotation either way: Zig coerces `T` to `E!T` on return, so the one `@call`
site inside `curry.zig` accepts both.

purerl solves the same problem by parsing arity out of the Erlang export list;
Zig has comptime reflection, so the backend never learns about arity at all.

Unlike generated code, hand-written FFI may import `std` freely and may allocate
from the arena through `rt.alloc()`.

Some FFI is now dead: an operation the optimizer turns into a `PrimOp` is never
called through its foreign import. `Data.Semiring.intAdd` is emitted and
compiled but unreachable from optimized code.

## Entry point

The emitter produces **modules only**. `output-zig/<Module>.zig` holds the
compiled module and nothing else — no `main`, no `std.process`, no runtime init
— and nothing it writes is a program. A Zig executable needs a root that
declares `main`, and that root is the build helper's business:
`build/purzig.zig` writes it into the build cache, so `output-zig/` never
contains one.

The driver text, reproduced here because a downstream project's `test-e2e`
asserts the program's exact stdout (so this text may not change behaviour):

```zig
const std = @import("std");
const rt = @import("runtime");
const purs_main = @import("purs_main");

fn mainNative(init: rt.ProcessInit) !void {
    rt.init(init.io, init.arena.allocator());
    _ = try rt.runEffect(try purs_main.@"ps.main"());
}

fn mainFreestanding() void {
    @trap();
}

pub const main = if (rt.freestanding) mainFreestanding else mainNative;

pub fn runWithAllocator(allocator: std.mem.Allocator) rt.Error!void {
    rt.initAlloc(allocator);
    _ = try rt.runEffect(try purs_main.@"ps.main"());
}
```

`purs_main` is the module that exports `main` (`Options.main_module`, default
`"Main"`), compiled from `output-zig/<main_module>.zig` and bound under that
fixed name with `addImport`; the program calls `purs_main.@"ps.main"()`.
Everything else — the signature, `rt.init`, both `runEffect` calls, the comptime
branch, the `@trap()` fallback and `runWithAllocator` — is the driver the
emitter used to append to `Main.zig`, moved verbatim. Only the qualification
changed, because `@"ps.main"` was a sibling decl and is now reached through an
import.

The helper roots the executable at the file it wrote with `b.addWriteFiles()`.
It does **not** read the manifest: one constant filename is not worth a JSON
parse in every consumer's build, and the entry now lives in the cache anyway.

`Options.main_module` keeps its default `"Main"` and still means "the module
that exports `main`". It no longer names the root source file.

Two `try`s in `mainNative`, because both steps are fallible: building the
`Effect` value is a call to a generated nullary function, and forcing it runs the
program.

Zig 0.16 routes all I/O through an `Io` instance and provides one, plus a
process-lifetime arena, through `std.process.Init`. The runtime borrows both
rather than constructing its own — which is why `rt.init` takes two arguments and
there is no `rt.deinit`. The driver spells that type `rt.ProcessInit`, so
`std.process` never appears in generated code; the alias is `std.process.Init`
on a native target and `void` on a freestanding one.

### The manifest

`output-zig/manifest.json` is written once, after every module:

```json
{
  "main_module": "Main",
  "main_export": { "name": "main", "zig": "@\"ps.main\"", "kind": "effect-thunk" },
  "modules": [
    { "name": "Main", "file": "Main.zig", "ffi": null },
    { "name": "Greeting", "file": "Greeting.zig", "ffi": "Greeting.ffi.zig" }
  ]
}
```

`modules` has one row per generated `.zig` module in emission (dependency)
order. `ffi` is null unless a `.ffi.zig` was actually written beside it — the
manifest promises files, so it is answered by the filesystem rather than by the
module's foreign set.

`main_export` says what `main` is and how to reach it: a PureScript `Effect`
thunk whose Zig identifier is `@"ps.main"`. With no module exporting `main`,
`main_module` and `main_export` are both null and there is nothing to root an
executable at.

There is no `entry_file`: the program is the build helper's, it lives in the
build cache, and nothing in purzig reads the manifest. It is emitted so that
`addLibrary`, the wasm host ABI and any downstream tool can find the output
without globbing the directory.

### Freestanding targets

`rt.freestanding` is `builtin.target.os.tag == .freestanding`, so
`-Dtarget=wasm32-freestanding` selects `mainFreestanding` and `mainNative` is
never referenced. Zig analyses what is *referenced*, not what runs, so the whole
native half — `rt.init`, `rt.io`, `rt.writeLine`, and the console FFI that calls
it — stays out of the compiled graph. The runtime also turns those names into
`@compileError`s on that target, so an accidental reference fails loudly instead
of trapping at runtime.

`mainFreestanding` traps, because there is no process to hand in an allocator and
therefore nothing to run. `runWithAllocator` is the seam where a host supplies
one: it is emitted on every target, is referenced by nothing, and so is analysed
only when a host links against it. Nothing calls it yet — the host ABI (entry
symbol, state buffer, allocator ownership) is the contract work, and until it
exists a freestanding artifact starts, traps, and is otherwise an empty program.

## Known rough edges

- Generated block indentation is hardcoded to eight spaces, so nested blocks
  read wrong. They compile fine.
- Every `try` is parenthesised, including where it needn't be. Suppressing the
  redundant ones means tracking whether an expression is about to be projected.
- The arena never frees.
- Top-level nullary functions are not memoised.
- Constructor tags are strings, not integers.
