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
