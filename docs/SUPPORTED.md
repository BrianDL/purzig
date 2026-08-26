# Supported packages and known divergences

## The rule

A PureScript package works with purzig if it needs no foreign function
interface, or if purzig ships a vendored copy carrying Zig FFI.

That is the whole test, and you can apply it yourself:

```sh
grep -rl '^foreign import' .spago/p/<package>/src
```

No matches means the registry copy compiles through the backend untouched — the
`.js` files beside its sources are never read, because nothing references them.
Matches mean it needs a vendored copy, and without one the build stops with
`MISSING FFI` naming the exact path it wanted.

## Vendored, with Zig FFI (seventeen packages)

| Package | Version |
|---|---|
| `prelude` | 6.0.2 |
| `effect` | 4.0.0 |
| `console` | 6.1.0 |
| `refs` | 6.0.0 |
| `exceptions` | 6.1.0 |
| `control` | 6.0.0 |
| `unsafe-coerce` | 6.0.0 |
| `partial` | 4.0.0 |
| `functions` | 6.0.0 |
| `integers` | 6.0.0 |
| `numbers` | 9.0.1 |
| `strings` | 6.0.1 |
| `arrays` | 7.3.0 |
| `st` | 6.2.0 |
| `foldable-traversable` | 6.0.0 |
| `unfoldable` | 6.0.0 |
| `enums` | 6.0.1 |

Every `.purs` file is byte-identical to its upstream tag. Only Zig FFI was
added. 178 foreign exports; 171 are covered by the test fixture, and the seven
that are not are unreachable rather than untested — see below.

### Modules deliberately omitted

Four modules are missing from otherwise-complete packages. Omitting a module
from a vendored package costs nothing at build time, since `purs` compiles only
what is in `src/`.

| Module | Why |
|---|---|
| `Data.Number.Format` | Three ECMA-262 number formatters with no equivalent |
| `Data.String.Regex` and its two satellites | Needs a regex engine |
| `Data.String.NonEmpty.*`, `.CaseInsensitive`, `.Gen` | No FFI of their own; drag in `gen` |
| `Data.Enum.Gen` | Same |

If you need one of these, the work is real but bounded, and it happens in this
repository rather than in yours.

## Registry packages with no FFI — work as-is

`either`, `maybe`, `tuples`, `newtype`, `safe-coerce`, `invariant`,
`bifunctors`, `contravariant`, `profunctor`, `distributive`, `const`,
`identity`, `nonempty`, `type-equality`, `exists`, and many others. Nothing to
do; depend on them normally.

## Registry packages with FFI — will fail

Anything doing real I/O or interop needs Zig FFI that does not exist yet:
`aff`, `node-fs`, `node-buffer`, `node-process`, `node-path`, `foreign`,
`foreign-object`, `js-date`, `now`, `random`, `argonaut-core`, and others.

They resolve through the package set — the set is a complete registry set with
purzig's overrides merged in — and then stop at `MISSING FFI`. That is
deliberate: leaving them resolvable means the error names the file to write,
rather than failing at resolution with nothing actionable.

Adding one means vendoring the package here with `.zig` files beside its
sources. `packages/purescript-refs/` is the smallest worked example.

## Divergences from the JavaScript backend

All deliberate. Written down because they are design decisions, not bugs.

**Int is 32-bit wrapping.** Every Int operation uses Zig's `+%`, `-%`, `*%`,
matching JavaScript's `| 0`. Zig's plain `+` would panic on overflow in Debug
where JavaScript silently wraps.

**Int division is Euclidean, and division by zero returns 0.** Transcribed from
the original JavaScript rather than mapped onto `@divTrunc`/`@rem`, which give
different answers for negative operands.

**Strings are UTF-8, indexed by code point.** PureScript's `Data.String.CodeUnits`
is defined over UTF-16 code units. Here a "code unit" is one Unicode code point,
which agrees with the JavaScript backend across the whole Basic Multilingual
Plane and differs only on astral-plane characters — `length` of a single emoji
is 1 here and 2 there. Indexing is O(n) as a result.

**`toLower`/`toUpper` are ASCII-only**, `trim` handles ASCII whitespace plus
NBSP, and `localeCompare` compares by code point.

**`showNumber` uses Zig's `{d}`**, which does not match
`Number.prototype.toString` in every case. Integers and simple decimals agree.

**Violated preconditions panic rather than throw.** `Partial._crashWith`,
`Data.String.Unsafe.charAt`, and a cyclic lazy binding abort the process instead
of raising a catchable PureScript exception. A broken precondition is a defect,
not a recoverable condition, and the compiler's own release notes tell backends
to make these errors appropriate for the target.

**The arena never frees.** Every allocation comes from a process-lifetime arena.
For a program that runs and exits — a CLI, a build tool, a script — this is
fine and fast. For a long-running process it is a leak proportional to work
done: `forE`, `whileE`, `foreachE` and a `Ref` written in a loop all allocate
per iteration. This is the largest outstanding design item.

## Test coverage

The fixture in `example/src/Scratch.purs` runs 231 checks covering every binder
form, all three loop combinators, throw/catch, laziness, mutable arrays, string
operations, and two recursions a million deep that would overflow the stack
without tail-call optimisation. Coverage of the FFI surface is verified
mechanically rather than by eye.

Seven of 178 foreign exports are uncovered, all for structural reasons:
`Partial._crashWith` panics, so any check for it aborts the run; and
`Data.Array.length`, `Data.Array.unsafeIndexImpl` and the four `Data.Int.Bits`
operators are unconditionally rewritten into primitive operations by the
optimizer, so no PureScript call site can reach the Zig at all. The primitives
themselves are checked.
