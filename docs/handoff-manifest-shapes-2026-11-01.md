# Handoff — publishing export shapes in the manifest (issue #33)

Date: 2026-11-01. Branch: `agent/01a19634-6194-c133-2628-ba8f8432ef99` (cut from
`master`). Restart of closed issue #19.

**Nothing in this change was compiled or run.** The container this was written
in has no `purs`, `spago`, `node`, `zig`, no container runtime, and no
`example/output*/` directory, and the rules of the job forbade installing any of
them. Every acceptance criterion is therefore **UNVERIFIED**; see the table at
the end. What *was* done instead is stated per claim below: read from this
repository, read from `compiler/dist/bundle.js` (the compiled backend, which is
in the tree), or inferred.

Starting state, verified before any edit:

- `compiler/src/Zig/Abi.purs` — **did not exist**.
- `compiler/src/Main.purs` — wrote `main_module`, `main_export`, `modules` and
  no `exports` array.
- `example/output/`, `example/output-zig/` — **absent**, as the issue warned.
  A filesystem-wide search for `docs.json` and `externs.json` returned nothing,
  so **no real `docs.json` was available to read.**

## 1. The `docs.json` question — what I could and could not establish

This is the part the next agent should re-check first, because everything else
depends on it.

### What I could NOT verify

**I did not read a real `output/<Module>/docs.json`.** There is none on the
machine. So the following are *documented-format assumptions*, not measurements:

1. the file lives at `output/<Module>/docs.json` (the issue states this; a
   filesystem search could not confirm it here);
2. the declarations are a top-level `"declarations"` array, each entry with a
   `"title"` and a declaration kind, and a value's type under `"info"`;
3. **whether it types UNEXPORTED decls.** `purs docs` documents a module's
   public API, so the working assumption is **no** — an unexported top-level
   value is expected to be absent from `declarations`. That answer decides how
   much of a module is typable: with "no", the typed ABI can cover exactly the
   export list, which is what the feature wants, and nothing more. The code does
   not depend on the answer for correctness (see the CoreFn cross-check below),
   but a downstream consumer that wanted shapes for internal functions would
   have to change the mechanism (it would have to read types from somewhere that
   is not docs).

### What I based the decoder on

Two in-tree sources, both readable here:

- **`docs/corefn-schema.md`** records that purs's `CoreFn/ToJSON.hs` is "the only
  real specification of this format", that `Qualified` encodes as
  `{ "moduleName": ["Data","Maybe"], "identifier": "fromMaybe" }`, and that a
  module name is an **array of segments**, not `"Data.Maybe"`. `typeToJSON`
  lives in that same file, so the type AST is the aeson `{"tag": …,
  "contents": …}` encoding with `TypeApp`, `TypeConstructor`, `ForAll`,
  `ConstrainedType`, `RCons`/`REmpty`, `ParensInType` and friends.
- **`compiler/dist/bundle.js`** contains the compiled CoreFn decoder. It proves
  the CoreFn `Module` record's field names — `{name, path, span, imports,
  exports, reExports, decls, foreign, comments}` — which is why `Main.purs` can
  read `m.exports` safely, and it proves `Ident` is a newtype over `String`
  (`decodeIdent = coerce decodeString`), which is why `map unwrap m.exports`
  is the right spelling (`Zig/Emit.purs` already does the same to `m.foreign`).

### Consequence: the decoder accepts BOTH documented encodings

Because the real file could not be read, `Zig/Abi.purs`'s `decodeType` accepts
either shape a `docs.json` has plausibly carried:

1. **a JSON AST** — `{"tag": "TypeApp", "contents": […]}` etc., with
   `TypeConstructor`'s `contents` accepted as a `[moduleName, name]` pair, as a
   single qualified object, or as a one-element array wrapping either;
2. **a rendered PureScript type source string** — `"(Int -> Int) -> Array Int"` —
   parsed by a small recursive-descent parser in the same module.

Accepting both is insurance, not design: whichever the toolchain actually emits,
the manifest gets real shapes, and if it is a third thing the row degrades to
`{"refused": "no type information"}` rather than crashing or guessing. **If a
future agent reads a real `docs.json`, delete the encoding that is not used** —
the type-source parser is ~200 lines that exist only for this uncertainty.

## 2. The shape table as implemented

`compiler/src/Zig/Abi.purs`. `Shape` has exactly the vocabulary in the issue
plus `SRefused`; nothing else was added.

| `Shape` constructor | JSON | When |
|---|---|---|
| `SInt` | `"int"` | type constructor named `Int` |
| `SNumber` | `"number"` | `Number` |
| `SBoolean` | `"boolean"` | `Boolean` |
| `SChar` | `"char"` | `Char` |
| `SString` | `"string"` | `String` |
| `SUnit` | `"unit"` | `Unit`, or **any `Effect` result** |
| `SArray inner` | `{"array": <shape>}` | `Array a`, one argument |
| `SRecord fields` | `{"record": {field: <shape>}}` | closed record; fields in written order |
| `SAdt mod name` | `{"adt": {"module": …, "name": …}}` | a declared `data` type with **no** type arguments |
| `SRefused reason` | `{"refused": "<reason>"}` | everything below |

Details that are decisions, not accidents:

- **Width-agnostic.** The primitive shapes are matched by *name* and emitted as
  `"int"`/`"number"`/…; there is no width anywhere in the vocabulary, in the
  renderer, or in the docs. Changing purzig's `Int` width cannot change the
  manifest.
- **`Int` etc. are matched by name, not by module**, because they arrive as
  `Prim.Int` from the AST and as bare `Int` from source text. A user type that
  shadowed one of those names would be mis-shaped; the compiler reserves them.
- **Argument and result are computed separately** (`Pos = AsArg | AsResult`),
  because `Effect a` is allowed in one position and refused in the other, and so
  is `a -> b`.
- **An ADT with type arguments is refused** (`"parameterised data type"`): the
  vocabulary has no way to say "`Maybe` of what", and publishing `adt Maybe`
  would lose the element type. This is the biggest practical limitation —
  `Maybe`, `Tuple`, `Either` and friends are all refused today — and lifting it
  needs a vocabulary change, which is precisely what the issue forbade.
- **`newtype` is refused, not published as `adt`**, because a newtype is erased at
  runtime and calling it a tagged union would be wrong. `type` synonyms are
  refused (expanding them would need substitution).
- **A type constructor is classified from its own declaration**, not by looking
  at its use site: `Zig.Abi` builds one table from every `docs.json` it loaded
  (all modules, not only the emitted ones), so `adt`/`newtype`/`synonym`/
  `foreign`/`class` is decided from the declaration. An unqualified name in
  source form resolves against the exporting module, and is refused
  (`"unknown type"`) rather than attributed to that module when that module does
  not declare it — an imported type rendered unqualified therefore refuses
  instead of lying about its module.
- **A leading `forall` is peeled and ignored** (every polymorphic function has
  one); a `forall` anywhere else is refused as rank-n.
- **An arrow is a `Function` APPLICATION in the JSON AST.** purs's type has no
  arrow node, so `Int -> Int` arrives as `TypeApp (TypeApp Function Int) Int`
  (and as `TArrow` only from my own source parser). `asArrow` normalises both
  before the signature is split. Without that, every export would be read as
  zero arguments with a *function* result and published as
  `{"refused": "higher-order result"}` — the single most likely silent-wrong
  outcome in this change, and the reason it is called out here.

## 3. How a refusal is produced

Three paths, all of which end in `{"refused": "<reason>"}` and none of which can
fail the emit:

1. **Per position.** A `forall`/constraint/arrow/`Effect`/row/constructor in an
   argument or result position is mapped by `shapeOf` to a refusal with a fixed
   reason string. `Shape` is rendered by `renderShape`, so a refusal is one JSON
   object in one slot of `args` or the `result` — the row itself is still
   emitted, and a consumer sees *which* position it could not encode.
2. **Per constraint.** `signature` records a leading constraint instead of
   dropping it and prepends `{"refused": "type class dictionary"}` to `args`,
   because `Eq a => a -> Int` really does take a dictionary as its first
   argument. The remaining arguments stay typed.
3. **Per export.** If the signature cannot be recovered at all — no `docs.json`,
   unparseable JSON, a declaration with no `type`, or a type encoding the decoder
   does not recognise — `refusedExport` emits the row with
   `{"refused": "no type information"}` in **both** `args` and `result`, so it
   cannot be mistaken for a real signature. `Main.purs` logs the module name
   when this happens.

No export is silently dropped: rows are the docs' **value** declarations that
CoreFn also lists in the module's export list (the authority on *what* is
exported, and the authority on *types* is the docs). Data constructors and
type-class members are not value declarations and are not callable exports, so
they get no row. If a module's docs are missing, undecodable, or yield no value
declarations at all, every name in CoreFn's export list gets a
`{"refused": "no type information"}` row instead — so an empty `exports` array
means "nothing is exported", never "the types could not be read".

## 4. Files changed

- `compiler/src/Zig/Abi.purs` — **new**: docs decoding, both type encodings, the
  shape mapping, the refusal rules, row rendering.
- `compiler/src/Main.purs` — reads `output/<Module>/docs.json` per module, builds
  `Source`s from CoreFn's export list, writes `"exports"` into the manifest.
  `main_module`, `main_export` and `modules` are untouched in shape (the
  `modules` block gains one trailing comma because `exports` follows it).
- `example/src/Shapes.purs` — **new** fixture, `Prelude` only, six functions.
  `example/spago.yaml` was **not** touched; the module imports nothing but
  `Prelude`, so no dependency was added and `Main`'s output is unchanged.
- `example/exports_probe.zig` — **new** Zig probe. It `@embedFile`s
  `output-zig/manifest.json` and asserts the six `Shapes` rows verbatim, that
  there are exactly six of them, and that `main_module`/`modules`/`exports` are
  still present. It lives at `example/` (not `example/abi/`) so that the
  `@embedFile` path is `output-zig/manifest.json` — non-escaping, inside the
  containing directory.
- `build.zig` — the `test-exports` step and its addition to `test`. The step
  reuses the program's one codegen run (`app.codegen`) rather than adding a
  fourth `spago build`: the manifest it asserts is the file that run writes, and
  `spago build` compiles every module in `example/src/`, so `Shapes` is in it.
- `docs/codegen.md` — the "Typed exports" section: vocabulary, refusals, the
  width-agnostic rule, and where the type comes from.

Not touched, as required: `runtime/**`, `build/purzig.zig`, `entry/entry.zig`,
`example/src/Main.purs`, `example/spago.yaml`, `packages.json`.

## 5. Ranking of what is most likely to need fixing

Ordered by (chance of being wrong × cost), for whoever runs this first:

1. **`docs.json` field names.** `declarations` / `title` / `info.type` /
   `declType` are assumptions (§1). A miss here does not crash anything: every
   module's exports come out as `{"refused": "no type information"}` and the log
   says `docs.json has no readable declarations`, while `test-exports` fails.
   That is the designed failure mode, and it names itself.
2. **`@embedFile` of a generated file.** The probe depends on the codegen step,
   so the manifest exists when the probe is compiled — but if a Zig 0.16 root
   module refuses an `@embedFile` path outside the module root, the fix is to
   move the manifest read to runtime (`std.Io.File`/`std.Io.Dir`) or to copy the
   manifest into the probe's directory with a `b.addSystemCommand`. The path
   chosen here does not use `..`, which is why it is the least risky spelling.
3. **`Data.Argonaut.Decode (getField)` + a local `DecodeJson Raw` instance.**
   `getField` is inferred at `DecodeJson Raw` so the module does not depend on a
   `DecodeJson Json` instance existing. If `getField` is not re-exported by the
   `Data.Argonaut.Decode` umbrella at the pinned version, the import path is
   `Data.Argonaut.Decode.Combinators`. This is a compile-only risk and shows up
   as the first `spago bundle` error.
4. **PureScript compile errors in `Abi.purs`** — it is ~600 lines of unverified
   PureScript. It is written in the plainest style available (explicit
   signatures, `Data.Array`/`Data.Maybe`/`Data.String` only, no type classes of
   its own except the one `DecodeJson Raw`), and every parser production
   consumes at least one character so nothing can loop.
5. **Row-count assumption.** The probe asserts exactly six `Shapes` rows. If
   CoreFn's `exports` for `Shapes` also lists the data constructors `Circle` and
   `Square`, that does not change the count — constructors are not docs *value*
   declarations, so they never become rows — but if doc ordering/labels ever
   produced a constructor row the count would catch it, which is the point.

One PureScript detail worth knowing, because it looks like a mistake: the
record field holding a module name is `moduleName`, not `module`. `module` is a
reserved keyword in PureScript and cannot be a record label. The JSON the
manifest emits still says `"module"` — the label is chosen in `renderExport`.

## 6. Acceptance criteria — status

| # | Criterion | Status |
|---|---|---|
| 1 | `zig build test-e2e` exits 0 and prints exactly `Hello, Zig`; `test-library`, `test-abi`, `test-abi-multi` still exit 0 | **UNVERIFIED** — no zig/purs/spago. Nothing in this change touches `Main`'s program, the library path, or the byte ABI, and `example/src/Shapes.purs` is an unimported module, so no behavioural change is expected. |
| 2 | `zig build test-exports` exits 0, asserting all six `Shapes` rows | **UNVERIFIED** — step added (`build.zig`), probe written (`example/exports_probe.zig`), never built. |
| 3 | No export silently dropped; `Shapes` rows == its annotated top-level functions (6) | **UNVERIFIED at runtime.** Enforced by construction in `Abi.exportsFor` (CoreFn `exports` × docs) and asserted by the probe (exact count 6), not executed. |
| 4 | Manifest stays valid JSON; `main_module`, `main_export`, `modules` unchanged in shape | **UNVERIFIED at runtime.** `renderManifest` only adds a fourth key; `renderModules`/`renderRow` are byte-identical to before. JSON validity rests on the same comma discipline the existing arrays use (`commaSeparated`). |
| 5 | Every shape string is width-agnostic (`"int"`, never `"int32"`/`"i32"`) | **VERIFIED by inspection** of the only renderer (`renderShape` in `Abi.purs`); there is no width anywhere in the vocabulary. Not executed. |
| 6 | `git diff --stat` touches only `compiler/src/`, `example/src/Shapes.purs`, `example/` (the probe), `build.zig`, `docs/` | **VERIFIED by inspection** of the working tree. Two files that are NOT part of this change show in `git status`: `compiler/dist/bundle.js` and `tools/mkpackageset.sh`, each a **mode change only** (`100755` → `100644`, 0 content lines) that was already present at checkout. No commit was made, per the job's rules. |

## 7. API claims and their verification status

| Claim | Status |
|---|---|
| `Module Ann`'s record has an `exports :: Array Ident` field | read from `compiler/dist/bundle.js` (the compiled `CoreFn.Json` decoder builds exactly `{name, path, span, imports, exports, reExports, decls, foreign, comments}`) |
| `unwrap :: Ident -> String` | used by `Zig/Emit.purs` on the same type (`Set.toUnfoldable m.foreign :: Array Ident`), so proven in-tree |
| `std.Io.File.stdout()`, `File.writeStreamingAll(io, bytes)` | copy of `runtime/apply.zig`'s `writeLine`, which runs in this repository |
| `std.mem.indexOf`, `std.debug.print`, `@embedFile` relative to the containing file | Zig stdlib/`@embedFile` behaviour as documented; **not compiled here** |
| `Data.Argonaut.Core (caseJson, toArray)`, `Data.Argonaut.Decode (getField)` | `caseJson`/`toArray` are present in `compiler/dist/bundle.js` (used by the CoreFn decoder); `getField` and the `DecodeJson` class are argonaut-codecs' documented surface with a local `DecodeJson Raw` instance so no `DecodeJson Json` instance is needed. `toString`/`toObject` were deliberately NOT used: they are not in the bundle, so `asString` and `field` are spelled through `caseJson` instead |
| `Data.Array (uncons, index, slice, elem, mapMaybe, catMaybes, null)`, `Data.String.CodeUnits (toCharArray, fromCharArray, charAt)`, `Data.String (split, joinWith, Pattern(..))` | signatures read from the vendored packages in `packages/` |

## 8. Repair (same day): `oneArg` was out of scope in `conShape` — `compiler/` did not compile

Measured on the purzig worker, **not by me** (this container has no `purs`,
`spago`, `node` or `zig`, and the job forbids installing them), by running
`spago build` in `compiler/`:

```
[WARNING 1/1 UnusedName] src/Zig/Abi.purs:763:3
  763  oneArg f = case args of
  764    [ inner ] -> f inner
  765    _ -> SRefused "unsupported type"
  Name oneArg was introduced but not used.
  in value declaration conShape

[ERROR 1/1 UnknownName] src/Zig/Abi.purs:757:26
  757  | conName == "Array" = oneArg (\inner -> SArray (shapeOf table modName pos inner))
                              ^^^^^^
  Unknown value oneArg
```

The two diagnostics together say the local was bound where nothing could see it
and used where nothing was bound: `conShape` was a **guarded** declaration, and
a `where` clause hanging off a guarded declaration does not put its bindings in
scope for the guards' right-hand sides. (This is the same failure class the
job warned about: a `where` on a guard/arm is not visible to a sibling guard.)

### Where `oneArg` lives now

`compiler/src/Zig/Abi.purs`, **inside `conShape`'s own `where` clause, at two
spaces — the same binding group as the branches that call it**, defined exactly
once (it was not renamed, duplicated or inlined):

```purescript
conShape :: Array TypeEntry -> String -> Pos -> String -> String -> Array Ty -> Shape
conShape table modName pos conMod conName args = case conName of
  "Int" -> SInt
  ...
  "Array" -> oneArg (\inner -> SArray (shapeOf table modName pos inner))
  "Record" -> oneArg (\inner -> shapeOf table modName pos inner)
  "Function" -> arrowRefusal pos
  "Effect" -> oneArg (\_ -> effectShape pos)
  _ -> adtShape table modName conMod conName args
  where
  -- `Array a` / `Record row` / `Effect a` all take exactly one argument; any
  -- other arity for them is unrepresentable in the vocabulary.
  oneArg f = case args of
    [ inner ] -> f inner
    _ -> SRefused "unsupported type"
```

### Why that scope makes it visible

The `where` is no longer attached to a guard chain; it is attached to the
function's *plain* right-hand side, `case conName of …`. A `where` on a plain
binding scopes over that entire right-hand side — every case arm included — so
each arm that calls `oneArg` is inside the scope that binds it. This is not a
new idiom invented for the repair: the same file already relies on it in
`exportsForOne`, whose `where`-bound `refusedAll` is called from two `case`
arms, and in `signature`/`pRow`/`stripPrefixChars`/`exportsFor`, and the measured
build reported **no** error or warning about any of those.

The dispatch itself is unchanged in meaning: the guard chain was an ordered list
of `conName == "…"` tests ending in `otherwise`; the case is the same ordered
list of string-literal patterns ending in `_`. The vocabulary
(`SInt`/`SNumber`/`SBoolean`/`SChar`/`SString`/`SUnit`/`SArray`/`SRecord`/
`SAdt`/`SRefused`), every refusal reason string, the width-agnostic `"int"`
rendering and the manifest encoding are **byte-identical**. This is a scope fix
only; no shape, no reason string, no encoding changed.

String-literal patterns are proven in this repository, not assumed:
`example/src/Scratch.purs` has `label "circle" = 1` / `label "rect" = 2`, which
the in-tree backend compiles (that fixture is what `test-e2e` runs).

### Other guards audited for the same mistake

Rule applied: a helper referenced from a guard must come from an enclosing
scope, never from a sibling arm's `where`.

- The only guarded declaration in `compiler/src/Zig/Abi.purs` that referenced a
  *local* helper was `conShape` (`oneArg`). After the repair it has no guards.
- `classifyKind` still uses guards (`Just s | s == "value" -> KValue`), but it
  references only its own binder `s` and top-level constructors — there is no
  `where` involved, so there is nothing to be out of scope.
- Every remaining `where` in the file (`pRow`: `go`; `stripPrefixChars`: `go`;
  `exportsFor`: `table`; `exportsForOne`: `refusedAll`; `signature`: `go`;
  `conShape`: `oneArg`) is attached to a plain binding and each local is used
  only inside its owner's right-hand side.
- No name was removed from an import list, so no new `UnusedName` warning was
  introduced by this repair; the `oneArg` warning disappears with the error
  because the binding now has a caller in scope.
- `Zig/Emit.purs`'s guard at :590 was checked and is outside this change: it
  is a guard on a `case` arm with no `where` of its own, and it references only
  `unwrap m`, `ctx` and `st`, all bound in enclosing scopes.

### Files touched by the repair

- `compiler/src/Zig/Abi.purs` — `conShape` only (plus its doc comment).
- `docs/handoff-manifest-shapes-2026-11-01.md` — this section.

Nothing else: `runtime/**`, `example/**`, `build.zig`, `compiler/src/Main.purs`,
`docs/codegen.md` were **not** touched by the repair — no change there was
required by a scope fix inside `conShape`.

### Verification status

**The compiler build is UNVERIFIED locally.** I did not run `spago build`,
`spago bundle`, `zig build`, `purs`, `node` or any container; I claim nothing
that I ran. What was done instead:

| Check | How, without building |
|---|---|
| `oneArg` has exactly one definition and at least one in-scope use | read the edited region; `grep -n oneArg` returns one definition and three call sites, all inside the `case` arms the `where` covers |
| the scope rule relied on is the one purs obeys here | `exportsForOne`/`refusedAll` in the same file is the identical construct and drew no diagnostic from the measured build |
| string-literal patterns are legal PureScript | `example/src/Scratch.purs`'s `label "circle" = 1`, compiled by this repo's own fixture set |
| no vocabulary / refusal string / encoding change | `git diff -- compiler/src/Zig/Abi.purs` touches only the `conShape` block; `renderShape` is untouched |
| indentation matches the file's style (`where` at 2 spaces, locals at 2) | same shape as `signature`/`pRow`/`exportsFor` |

All acceptance criteria in §6 remain **UNVERIFIED** for the same reason: there
is no toolchain in this container. The one thing this repair is *for* — that
`spago build` in `compiler/` gets past `Unknown value oneArg` — must be
re-measured on the purzig worker.

## 9. Repair (same day): a local `data` type resolved to `{"refused": "unknown type"}`

Measured on the purzig worker, **not by me** (no `purs`, `spago`, `node` or
`zig` was available to this container and the job forbids running them), by
running `zig build test-exports` and dumping the generated manifest. Five of the
six `Shapes` rows were exactly right:

```json
{ "module": "Shapes", "name": "fInt", "args": ["int"], "result": "int" }
{ "module": "Shapes", "name": "fStr", "args": ["string"], "result": "string" }
{ "module": "Shapes", "name": "fArr", "args": [{"array": "int"}], "result": {"array": "int"} }
{ "module": "Shapes", "name": "fRec", "args": [{"record": {"a": "int", "b": "string"}}], "result": "int" }
{ "module": "Shapes", "name": "fAdt", "args": [{"refused": "unknown type"}], "result": "int" }   <- wrong
{ "module": "Shapes", "name": "fHo",  "args": [{"refused": "higher-order argument"}], "result": "int" }
```

`fAdt :: Shape -> Int` had to be
`{ "module": "Shapes", "name": "fAdt", "args": [{"adt": {"module": "Shapes", "name": "Shape"}}], "result": "int" }`.

### What that measurement proves, and it is the useful part

`"unknown type"` is produced in exactly one place: `adtShape`, when the type
table has no entry for the constructor under the module being decoded. The five
correct rows are decisive about where the fault is **not**:

- `fInt`/`fStr`/`fArr`/`fRec`/`fHo` all went through `decodeType` and the shape
  mapping with the right answer, so the **type AST decoding is correct**: the
  `TypeApp`/`TypeConstructor` pipeline, `Prim.Int`/`Prim.String` by name, the
  `Record`/`RCons` row, and `Function` as an application (which is what makes
  `(Int -> Int)` an argument and yields `"higher-order argument"`) all work
  against the real file.
- `fAdt`'s **result** is `"int"`, so its signature was decoded too. Only the
  argument failed.
- A local `Shape` arrives with an empty qualifier or `Shapes`, and both resolve
  to `Shapes`: `target = if conMod == "" then modName else conMod`.
- `exportsFor` builds the table from **every** loaded `docs.json`, including the
  module being decoded, and `entryFor` keeps `KData`/`KNewtype`. So if the
  declaration had been classified as a data type, the lookup would have hit.

The only remaining path to `"unknown type"` is therefore the DECLARATION: the
`Shape` entry was in the docs (values from the same module were typed) but did
not reach the table as a data type. Two ways that happens, and both are fixed:

1. **The kind marker was not recognised.** `decodeDecl`'s fallback was
   `KOther -> if isJust tyJson then KValue else KOther`, i.e. "no marker I know,
   but it has a `type`, so it is a value". A data declaration that this decoder
   did not recognise — and that carries a `type`, or that simply got `KOther` —
   was then either dropped from the table (`KValue` is not a table entry) or
   never classified at all.
2. **The table key was not the bare name.** The table is keyed by the docs
   `title`; a title carrying the keyword and type arguments (`data Shape a`)
   never equals the `Shape` a `TypeConstructor` names.

### The fix, in `compiler/src/Zig/Abi.purs`

- `decodeDecl` now decides in this order: a recognised kind marker; then
  **structure** — `dataDeclKind`, which reads `dataDeclType` and a `constructors`
  array, neither of which any other declaration kind in purs's docs model
  carries — and only then "it has a `type`, so it is a value". Structure before
  the `type` test is the whole point: a data declaration classified as a value is
  invisible to the type table, and an invisible declaration is exactly an
  `"unknown type"` at every use site.
- The marker word itself (`classifyKind`) now also accepts `Data`, `adt`,
  `ADT`, `Newtype`, `NEWTYPE`, `newtypeDeclaration`, `NewtypeDeclaration`,
  `externDataDeclaration`, and reads it through `markerWord`, which tolerates a
  tagged wrapper (`{"tag": "data"}` / `{"value": …}`) instead of treating it as
  "no marker".
- `bareDeclName` derives the table key from the `title` for TYPE-level
  declarations only: it strips leading `foreign import data` / `data` /
  `newtype` / `type` / `class` keywords (case-sensitive, requiring a trailing
  space) and then takes the first proper name, so `data Shape a` keys as
  `Shape`. **Value titles are returned untouched**, so no published export
  `name` can change.
- `adtShape` publishes `KNewtype` as `{"adt": …}` as well: the vocabulary's rule
  is "a data type with a known constructor list", which a newtype has. The
  `"newtype"` refusal reason is gone; a newtype WITH type arguments still refuses
  as `"parameterised data type"`, and `foreign data` still refuses as
  `"foreign type"`. Nothing else in the shape vocabulary, and no other refusal
  string, changed.

What is deliberately **not** done: the miss is not turned into a guess. There is
no name-only or fuzzy lookup across modules; if the module the qualifier names
does not declare the name, the answer is still `{"refused": "unknown type"}`.
The repair only makes a declaration that IS present in the docs readable.

### The `docs.json` question, again, and answered plainly

**I did not read a real `docs.json`, in this round or the previous one, and no
copy was obtainable.** Searched in the workspace before editing: no
`example/output/`, no `example/output-zig/`, no `output/` anywhere in
`./workspace/sophos/purzig`, no `docs.json` or `manifest.json` anywhere in the
tree or in this run's storage prefix (`sophos/purzig`), and no purs/purescript
source or binary on the machine to read the format out of. The only filesystem
`docs.json`-adjacent facts available are the measured manifest rows quoted above.
So this section is an **inference from that measurement, not a quotation of the
file**, and the two encodings the decoder accepts are still both unverified
against a real file:

- the declaration entries live in a top-level `"declarations"` array, each with
  a `title` and an `info` object;
- a value's type is a JSON AST under `info.type`, tagged
  `{"tag": "TypeApp"|"TypeConstructor"|"ForAll"|"ConstrainedType"|"Record"|"RCons"|"REmpty", "contents": …}`,
  with a `TypeConstructor`'s `contents` a `[qualifiedModuleName, properName]`
  pair (the module name as an array of segments, e.g. `["Shapes"]`). The five
  correct rows are consistent with this and with nothing else tried so far;
- a data declaration is marked by a `declType`-family word plus `dataDeclType`
  and/or a `constructors` array — **which spelling, exactly, is unmeasured**, and
  because the previous decoder's spelling was demonstrably not the one the real
  file uses, the code now accepts the structural markers as well instead of
  depending on one word.

The **Shape declaration and its use** therefore cannot be quoted. Inferred
encoding, given the above:

```json
// the DECLARATION (inferred, not quoted)
{ "title": "Shape",
  "info": { "declType": "data", "dataDeclType": "data", "typeArguments": [],
            "constructors": [ { "declName": "Circle", "declType": { … } },
                              { "declName": "Square", "declType": { … } } ] } }

// the USE of Shape in fAdt's type (inferred, not quoted)
{ "tag": "TypeConstructor", "contents": [ ["Shapes"], "Shape" ] }
```

`declType`/`dataDeclType` is the field that would mark data vs newtype
(`dataDeclType` carrying `data` / `newtype` / `foreign`); the decoder treats the
constructor list and `dataDeclType` as the authoritative structural markers and
`declType` as the hint, precisely because the hint alone failed on the real file.

**Whether `docs.json` types UNEXPORTED declarations is still unmeasured.** No
real file was read, so the question is open: `exportsFor` cross-checks the docs
against CoreFn's export list, so the published rows are correct either way, but
how much of a module is *typable* at all depends on this and it remains the
first thing a worker run should answer (dump one module's `declarations` titles
and compare with its `.purs`). If the answer is "only exports", the typed ABI can
never cover an internal function and there is nothing to change here; if it is
"everything", a future issue could publish shapes for non-exported decls without
touching this decoder.

### Files changed by this repair

- `compiler/src/Zig/Abi.purs` — `decodeDecl`'s kind decision; `classifyKind`
  split into `markerWord`/`classifyWord`; new `dataDeclKind`, `wordKind`,
  `isDataWord`/`isNewtypeWord`/`isForeignWord`, `bareDeclName`/`firstWord`/
  `dropKeywords`/`dropOneKeyword`/`typeKeywords`; `adtShape`'s newtype case.
- `docs/codegen.md` — the `"newtype"` refusal row is gone; the "Named types"
  subsection now states the `data`/`newtype`/unknown-name rule and that a
  declaration's *structure*, not a single marker spelling, decides.
- `docs/handoff-manifest-shapes-2026-11-01.md` — this section.

Nothing else. `build.zig`, `example/**` and `compiler/src/Main.purs` were not
touched by this repair; the probe and the step added earlier are unchanged.

### Shape table as implemented (unchanged from §2, one row's rule extended)

| PureScript type | Manifest | Rule in `Zig.Abi` |
|---|---|---|
| `Int` | `"int"` | constructor name `Int` (module ignored: `Prim.Int`) |
| `Number` | `"number"` | `Number` |
| `Boolean` | `"boolean"` | `Boolean` |
| `Char` | `"char"` | `Char` |
| `String` | `"string"` | `String` |
| `Unit` | `"unit"` | `Unit` |
| `Effect a` as the **result** | `"unit"` | `effectShape AsResult` |
| `Array a` | `{"array": <shape>}` | `Array` with one argument |
| closed record | `{"record": {field: <shape>}}` | `Record` + `RCons`/`REmpty` row, `closed` only |
| `data` with constructors, arity 0 | `{"adt": {"module": …, "name": …}}` | table entry `KData` |
| `newtype`, arity 0 | `{"adt": {"module": …, "name": …}}` | table entry `KNewtype` |
| anything refused | `{"refused": "<reason>"}` | see the table in `docs/codegen.md` |

Every string is width-agnostic (`"int"`, never `"int32"`/`"i32"`); no width
appears anywhere in `Shape`, `renderShape` or the manifest.

### How a refusal is produced (unchanged)

1. Per position: `shapeOf` maps a forall/constraint/arrow/`Effect`-as-argument/
   open row/synonym/parameterised/unknown constructor to `SRefused reason`, which
   `renderShape` writes as `{"refused": "<reason>"}` in that one slot. The row is
   still emitted; nothing throws.
2. Per constraint: `signature` prepends `{"refused": "type class dictionary"}`
   to `args` rather than dropping the dictionary.
3. Per export: no `docs.json`, undecodable docs, a declaration with no `type`, or
   a signature that cannot be recovered gives
   `{"refused": "no type information"}` in BOTH `args` and `result`, and `Main`
   logs the module.

### Acceptance criteria — status after this repair

| # | Criterion | Status |
|---|---|---|
| 1 | `zig build test-e2e` prints exactly `Hello, Zig`; `test-library`, `test-abi`, `test-abi-multi` exit 0 | **UNVERIFIED** — no toolchain here. Nothing in the repair touches `Main`'s program path, the library path, the byte ABI or `example/src/Shapes.purs`; `Shapes` is imported by nothing. |
| 2 | `zig build test-exports` exits 0 and covers all six `Shapes` rows | **UNVERIFIED** — the step and probe already exist and are unchanged; whether the sixth row now reads `{"adt": {"module": "Shapes", "name": "Shape"}}` is exactly what must be re-measured. |
| 3 | `Shapes` export rows == its annotated top-level functions (6) | **UNVERIFIED at runtime.** By construction: rows are docs value declarations ∩ CoreFn exports; the probe asserts the count is 6. |
| 4 | Manifest stays valid JSON; `main_module`, `main_export`, `modules` unchanged in shape | **UNVERIFIED at runtime.** `renderManifest` is untouched by this repair; it only adds the `exports` key. |
| 5 | Every shape string width-agnostic | **VERIFIED by inspection**: `renderShape` is untouched and emits `"int"`; no width exists in the vocabulary. Not executed. |
| 6 | `git diff --stat` touches only allowed paths | **VERIFIED by inspection**: this repair touches `compiler/src/Zig/Abi.purs`, `docs/codegen.md` and this handoff; `compiler/dist/bundle.js` and `tools/mkpackageset.sh` still show as 0-content-line **mode** changes that were already in the working tree at checkout. |

**Nothing in this section was executed.** No `purs`, `spago`, `zig`, `node`,
container or build was run, and every claim about the real `docs.json` is marked
as inference above. The one measurement this repair is built on is the manifest
dump quoted at the top, which came from the purzig worker.

### If the sixth row still refuses

The fix covers the three ways a present declaration can be missed: an
unrecognised kind word, a structural marker the discriminator hides, and a
decorated `title`. If `zig build test-exports` still reports the `fAdt` row, the
one measurement that settles it is the real file — print the first declaration
entry of `example/output/Shapes/docs.json`:

```
node -e 'const d=require("./example/output/Shapes/docs.json");
         console.log(JSON.stringify(d.declarations.find(x=>x.title.startsWith("Shape")),null,2))'
```

Which fields that entry carries is then a one-line change to `dataDeclKind` (add
the marker) or to `bareDeclName` (add the prefix), and nothing else in the file
needs to move.

### One caveat about the `newtype` rule, recorded rather than hidden

The repair publishes a `newtype` as `{"adt": …}` because the issue asks for it,
and because the vocabulary's own words are "a data type with a known constructor
list". It is worth writing down what that means, since it is the one place where
the vocabulary is about the TYPE rather than the representation: purzig's
generated code **erases** newtypes — `docs/codegen.md` records that "newtype
erasure happened upstream", so `newtype Wrapper = Wrapper Int` arrives at a call
site as the `Int` itself, not as a tagged value. `{"adt": …}` therefore names the
nominal type (module + proper name), and a consumer that needs the payload must
resolve the type's single field. If that ever becomes too loose, the alternative
is to restore the `"newtype"` refusal — a one-line change in `adtShape` — but it
should be a vocabulary decision, not a decoder accident, which is why it is
called out here.
