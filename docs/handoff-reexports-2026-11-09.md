# Handoff — why 1229 of 1387 exports say `no type information` (issue #44, analysis half)

Date: 2026-11-09
Issue: #44 — *manifest: 1229 of 1387 exports report "no type information" — explain
the mechanism, and decide the 23 parameterised ones*
Branch: `agent/01a1befb-d666-acb3-b69d-15f9c822d95d` (cut from `master`)

**This change contains no code.** No file under `compiler/src`, no `.zig`, no
`.purs`, no `build.zig`/`build.zig.zon` was touched, and no `zig build
stats-exports` step was added. Everything below is read from the tree, measured
with a throwaway script, or cited from the 2026-11-08 `f/purzig/manifest_stats`
run on `master` (marked **[given]**).

`git status` in the working tree shows this file as the only content change plus
two **mode-only** diffs that were already present at checkout
(`compiler/dist/bundle.js`, `tools/mkpackageset.sh`: `100755 → 100644`, 0 content
lines each).

**[given]** = measured before this task, not re-derived here.
**[measured]** = measured by this task, on a *different* tree than the issue's
(the caveat in §4.1 is the important part).
**[inferred]** = read off the code, not executed.

---

## 1. The code path, quoted

Two files, not three. The manifest builder is `compiler/src/Main.purs` — there is
no `compiler/src/Zig/Main.purs`; the `Zig/` directory holds `Abi.purs`,
`Emit.purs`, `Ident.purs` only.

### 1.1 Where `exports` is filled

`compiler/src/Main.purs:212-222` builds one `Source` per emitted module and hands
them to `Abi.exportsFor`:

```
212:   loaded <- catMaybes <$> traverse loadDocs mods
213:   let
214:     sources = map
215:       ( \row ->
216:           { moduleName: row.name
217:           , exports: row.exports
218:           , docs: find (\docsMod -> docsMod.moduleName == row.name) loaded
219:           }
220:       )
221:       emitted
222:     exportRows = Abi.exportsFor sources
```

`row.exports` is the **CoreFn** export list, verbatim (`compiler/src/Main.purs:288`:
`exports: map unwrap m.exports`). `row.docs` is that same module's `docs.json`
(`compiler/src/Main.purs:237-262`, path built at `:240` as
`output/<Module>/docs.json`).

### 1.2 What `docs.json` is decoded into

`compiler/src/Zig/Abi.purs:104-113` — the two record types that decide everything:

```
104: -- | CoreFn records, and its docs when they could be read and decoded.
...
108:   , docs :: Maybe DocsModule
...
111: -- | A decoded `docs.json`: the declarations it types, in file order.
112: type DocsModule = { moduleName :: String, decls :: Array Decl }
```

There is **no `reExports` field** in `DocsModule`, and
`compiler/src/Zig/Abi.purs:156-159` reads exactly one top-level key:

```
156: decodeDocsModule :: String -> Json -> Maybe DocsModule
157: decodeDocsModule name json = do
158:   declsJson <- field "declarations" json >>= toArray
159:   decls <- traverse decodeDecl declsJson
```

(Note `traverse` over `Maybe`: **one** undecodable declaration makes the whole
module's docs `Nothing`. See §4.4.)

### 1.3 Where a row is produced — and where it is not

`compiler/src/Zig/Abi.purs:753-763`, `exportsForOne`:

```
753: exportsForOne table src = case src.docs of
754:     Nothing -> refusedAll
755:     Just docs -> case mapMaybe (rowFor table src) (filter isValueDecl docs.decls) of
756:       -- The docs decoded but typed nothing: fall back to a refusal per CoreFn
...
760:       [] -> refusedAll
761:       rows -> rows
762:   where
763:   refusedAll = map (refusedExport src.moduleName) src.exports
```

`compiler/src/Zig/Abi.purs:765-767` — only `KValue` declarations are rows:

```
765: isValueDecl :: Decl -> Boolean
766: isValueDecl decl = case decl.kind of
767:   KValue -> true
```

`compiler/src/Zig/Abi.purs:779-793` — the per-name path:

```
779: rowFor table src decl =
780:   if not (exported src decl.name) then Nothing
781:   else case decl.ty of
782:     Nothing -> Just (refusedExport src.moduleName decl.name)
783:     Just ty ->
...
792:           , result: shapeOf table src.moduleName AsResult sig.result
```

### 1.4 The two cases in the issue

**`Data.Boolean.otherwise` → concrete.** **[given]** its docs entry is
`kind = value`, `info = { declType, type }`, and
`info.type = {"annotation":[],"contents":[["Prim"],"Boolean"],"tag":"TypeConstructor"}`.
Path: `docs.decls` contains it → `isValueDecl` true (`Abi.purs:766`) →
`exported` true (`Abi.purs:800`) → `decl.ty = Just` (`:781`) → `signature` finds no
arrow (`Abi.purs:842`) → `shapeOf` (`:852`) → `conShape` matches `"Boolean"`
(`Abi.purs:901: "Boolean" -> SBoolean`). Row published. Nothing about this name
is special: it is *declared in the module whose docs.json is being read*.

**`Type.Proxy.Proxy` → `no type information`.** `packages/purescript-prelude/src/Type/Proxy.purs:49`
is `module Type.Proxy where` and `:53` is `data Proxy a = Proxy`, so the only
value-level ident that module can export is the **constructor** `Proxy`; and
**[given]** docs' only `Proxy` entry is the *type*
(`kind = data`, `info` keys `dataDeclType, declType, roles, typeArguments`, **no
`type` field**). Path: `isValueDecl` false → no row → module has (at most) one
other value (`proxy`), so either `[] -> refusedAll` (`:760`) or `Proxy` is dropped
by `mapMaybe` (`:755`). Either way the answer is `no type information`, and the
refusal is **correct**: a nullary constructor of a parameterised type has no
representable shape in the closed vocabulary.

**The difference is not "class method vs function" and not dictionary passing. It
is: is the name a `KValue` declaration *in this module's own `declarations`
array*.**

---

## 2. The mechanism

Three statements, each with the line that decides it:

1. **The lookup table is `(this module, name)` and nothing else.** `Abi.purs:755`
   maps `rowFor table src` over `filter isValueDecl docs.decls` — i.e. over the
   declarations *of the module being published*. There is no second key, no
   origin module, no fallback. `compiler/src/Main.purs:218` supplies only that
   module's docs (`find (\docsMod -> docsMod.moduleName == row.name)`).
2. **`docs.json`'s `reExports` is never read.** `DocsModule` (`Abi.purs:112`) has
   two fields, `moduleName` and `decls`; `decodeDocsModule` (`Abi.purs:158`) reads
   only `"declarations"`. **[given]** `Prelude`'s docs.json is 471 bytes with
   **0 declarations**, so `filter isValueDecl docs.decls` is `[]` and every one
   of Prelude's exports takes `Abi.purs:760` → `refusedAll` (`:763`). Prelude's
   types exist — in `Data.Boolean`'s, `Data.Eq`'s, `Data.Show`'s docs.json, not
   in Prelude's.
3. **The verdict is per MODULE, not per name.** `:760` is an all-or-nothing
   switch: a module with at least one exported value declaration publishes rows
   and every other export of that module is silently **dropped** by
   `mapMaybe` (`:755`); a module with none refuses **all** its exports with
   `no type information` regardless of whether every type was sitting in the
   file. `refusedExport` (`Abi.purs:770-776`) puts the same string in `args` and
   `result`, so a refused row carries no reason beyond "nothing was read".

Corollary worth fixing separately: `Abi.purs:26-29` promises "Nothing is silently
dropped". `:755` + `:761` break that promise for every export of a row-producing
module that is not a local value declaration (constructors, class members,
re-exports).

---

## 3. Verdict: **(b)**, confirmed — with a correction about *which* key is missing

**It is (b): the lookup is keyed to the local module's declarations and never
follows a re-export.** The deciding lines are `compiler/src/Zig/Abi.purs:755`
(the map runs over *this* module's `decls` only) and `compiler/src/Zig/Abi.purs:760`
(no row for this module ⇒ every export refused). `Data.Boolean.otherwise` is
declared where it is published; a name reached through `Prelude` is declared
nowhere that is ever consulted.

**(a) is refuted**: the type information is present and reachable — 158 rows
(124 concrete + 34 reasoned) prove `docs.json` decodes and types arrive; and
`Data.Boolean`'s docs.json types `otherwise` with the same encoding the other
170 modules use.

**(c) is refuted as the cause of *this* string**: `shapeOf` never returns
`no type information`. Every shape-level failure carries its own reason
(`Abi.purs:852-895`: `type variable`, `higher-order argument`, `parameterised
data type`, `unsupported type`, …), and the measured histogram counts those
separately (23 + 8 + 1 + 1 + 1). A `no type information` row can only come from
`:763` (no row was produced) or `:782` (`decl.ty` is `Nothing`).

**The correction.** The issue's phrasing — "never follows `reExports`" — suggests
reading `docs.json`'s `reExports`. On this toolchain there is nothing there to
follow. **[given]** Prelude's docs.json is 471 bytes; the skeleton

```
{"comments":[],"declarations":[],"name":"Prelude","reExports":{}}   = 65 bytes
```

leaves at most **406 bytes** for `reExports` content, while Prelude's source
re-exports **27 modules** whose bare keys alone (`"Data.NaturalTransformation":[],`)
cost ≈ 783 bytes before a single identifier is listed. **[inferred]** So
`docs.json` carries no per-name re-export index for Prelude at all; the
`reexport_not_followed` bucket, *as defined by "the name appears in that module's
`reExports`"*, is therefore near-empty on this toolchain and those names land in
`no_declaration` from the decoder's point of view.

The per-name origin index that *does* exist is **CoreFn's** `reExports`
(`Map ModuleName [Ident]`), and it is dropped in exactly one place:
`compiler/src/Main.purs:217` copies `exports` but not `reExports`, and
`Abi.Source` (`Abi.purs:104-108`) has no field for it. Proof that the field is
decoded and available:
`compiler/dist/bundle.js:19747-19750` (`decodeReExports` = object → array of
`(key, [Ident])` pairs) and `:19328` (`reExports: fromFoldable52(v.reExports)`),
plus `docs/corefn-schema.md:16`. **So the repair site is `Main.purs:216-220` +
`Abi.Source`, not `decodeDocsModule`.**

---

## 4. The four buckets

### 4.1 What could and could not be measured — read this before quoting a number

The issue's numbers come from a **179-module output tree belonging to
`u/admin/sustainable_forgejo`**, reachable only through `f/purzig/docs_probe`.
**That tool failed on every invocation in this run** (exact text in §6.1), so the
1229 could not be walked. What I measured instead is a real PureScript tree that
*is* in this repository — `packages/**/*.purs` + `example/src/*.purs`, **114
modules, 1500 exported idents** — through a source-side model of
`Abi.exportsForOne` (§6.3). The model reproduces the three facts the issue states
(§6.2: `otherwise` → concrete, `Type.Proxy` → exactly one ident `Proxy`, a
constructor sharing its type's name → `not_a_value`, `Prelude` → 136 idents, 0
rows → `refusedAll`).

**These are the sample's numbers, not the 1229's.** They are the right order of
magnitude (1500 vs 1387 exported idents) and the wrong tree.

### 4.2 Numbers **[measured]**

| Bucket | Count (sample) | Share | Note |
|---|---|---|---|
| `reexport_not_followed` | **667** | 44.5% | not declared in this module; declared in another |
| `no_declaration` | **94** | 6.3% | declared here, but not as a *top-level value* (class members, distinct-named constructors, operators) |
| `not_a_value` | **20** | 1.3% | the name matches a `data`/`newtype`/`type`/`class`/`foreign data` declaration — correct refusal (`Proxy`) |
| `unsupported_shape` | **0** | 0% | a declaration exists but its `type` fails to decode |
| *(remainder: local value rows the code does publish)* | 719 | 47.9% | of which 112 fully concrete under a coarse shape model |

`667 + 94 + 20 + 719 = 1500`. The buckets are disjoint by construction
(`reexport` first, then `not_a_value`, then `no_declaration`).

**Why `unsupported_shape` is 0, by code and not by luck** **[inferred]**: the
only path from "a declaration exists" to `no type information` is `Abi.purs:782`,
i.e. `decodeType` returned `Nothing`. `decodeType` (`Abi.purs:395-403`) returns
`Nothing` only for malformed `contents`; an unknown **tag** is not a failure —
`decodeTagged`'s final `else` returns `Just TOther` (`Abi.purs:435-438`), which
`shapeOf` (`:859`) refuses as **`unsupported type`**, not as `no type
information`. And **[given]** the measured file proves the encoding in use is
CoreFn's `ToJSON` (`"annotation":[]` beside `"tag"`), whose `contents` are the
positional arrays the decoder reads. That is also why the measured histogram has
exactly **1** `unsupported type`: that is the `TOther` path, and it fired once.

### 4.3 The structural decomposition of the 1229 **[inferred]**

Because `:782` is effectively unreachable (§4.2), **each of the 1229 is an export
of a module that published no rows at all** — `Abi.purs:760` — up to at most a
handful of per-name `decodeType` failures that only the tree can rule out (§4.2
shows they have no mass path). That is a module-level fact, and it has exactly
three causes:

| Cause | Where the type actually is | Sample size |
|---|---|---|
| (i) docs declares none of the exported names — a re-export shim (`Prelude`: 0 declarations) | the declaring modules' docs.json | **24 of 114 modules** publish zero rows; they carry **383 idents (25.5%)**, of which **405/419 occurrences (96.7%) are re-exports** |
| (ii) docs declares the names, but nested inside a `class` (`info.members`) or a `data` (`info.constructors`) | the *same* docs.json, one level down | 4 local class members + 4 same-named constructors + 6 operators in the sample |
| (iii) `decodeDocsModule` returned `Nothing` because one declaration failed `traverse` (`Abi.purs:159`) | the file, unread | not measurable here; the build log names it (`Main.purs:260`) |

Sample zero-row modules, biggest first: `Prelude` 136, `Control.MonadPlus` 45,
`Data.String` 28, `Data.Bounded` 28, `Data.Field` 23, `Control.Comonad` 22.
That list is what the 1229 looks like: re-export shims and class-only modules.

**What the sample cannot settle** is the real tree's ratio of (i):(ii): 88.6% of
1387 needs shims to carry ~89% of the surface, which the sample's 25.5% does not
support. Either that package set is much more shim-heavy than
`purescript-prelude`+friends, or cause (iii) is wiping whole modules, or a
`reExports`-shaped umbrella module dominates. One `docs_probe` run settles it
(§6.4). **Do not quote 667/94/20 as the 1229's split.**

### 4.4 Second defect found while reading (not measured, just proved)

`Abi.purs:159` uses `traverse` over `Maybe`, so **one** undecodable declaration
makes the module's entire docs `Nothing`, and `loadDocs` (`Main.purs:258-261`)
then reports `docs.json has no readable declarations` — i.e. a single bad entry
turns a fully typed module into 100% `no type information`. That is cause (iii)
above, and it is a five-line fix (`traverse` over a `Maybe`-preserving decoder, or
skip the bad entry). It is also cheap to rule out: the log line either appears or
it does not.

---

## 5. The 23 `parameterised data type` exports — **decision: widen the vocabulary**

What they are: `adtShape`'s `declared` (`compiler/src/Zig/Abi.purs:946-947`)

```
946:     declared entry =
947:       if null args then SAdt entry.moduleName entry.name
948:       else SRefused "parameterised data type"
```

so the 23 are applied nominal types — `NonEmpty Int`, `Maybe a`, `Either e a`.
The type is known; the vocabulary's `{"adt": {"module","name"}}` has no argument
slot. This is a **vocabulary gap**, not a lookup failure: it is independent of
§2-§3 and would stay refused after any re-export fix.

| Option | Cost (one line) |
|---|---|
| **Widen** — `{"adt": {"module","name","args":[<shape>…]}}`, `args` **omitted when empty**, plus `{"param":"a"}` only when the same variable name occurs in ≥2 slots of one row | ~10 lines in `conShape`/`renderShape` + one row in `docs/codegen.md`'s table + one case in every consumer's shape decoder; the 124 already-concrete rows stay **byte-identical** (omitted when empty), so no existing row changes |
| **Monomorphise at the wrapper site** — #43 picks `a := Int` per wrapper | 0 manifest change, but the 23 stay refused forever, the instantiation lives only in #43 so no other consumer can see it, and it does not help: a wrapper needs the *constructor list* of `NonEmpty`, which the shape does not carry either |
| **Accept** — leave them refused | 0 cost, and the vocabulary stays unable to express the commonest shape in a PureScript API (`Maybe a`), so this decision gets re-opened at the next widening |

**Decision: widen.** Reason: it is the only option that keeps the information in
the manifest, it is additive (empty `args` omitted ⇒ no byte changes for existing
rows), and `{"array": …}`/`{"record": …}` are already compositional — the ADT node
is the single non-compositional case left. Do it **in the same PR as the §3
repair** so the vocabulary changes once, and keep `parameterised data type` as the
refusal for the unbindable case (a type variable in only one slot of a row, e.g.
`pure :: a -> f a`), which is genuinely unusable by a wrapper.

Costs of *not* deciding, for the record: #43's scope stays at 124 rows, and every
future API shape with `Maybe`/`Either` needs the same decision again.

---

## 6. Commands run, and their output

### 6.1 The tree I could not read

```
docs_probe(step="codegen", max_decls=5)
docs_probe(max_decls=3)
docs_probe(step="codegen", modules="Prelude", max_decls=10, ref="master")
docs_probe(step="build", ref="master", modules="Prelude")
docs_probe(ref="u/admin/sustainable_forgejo", step="codegen",
           modules="Prelude,Data.Boolean,Type.Proxy", max_decls=20)
```

All five returned, identically:

```
Error running docs_probe: child job 01a1befe-… (f/purzig/docs_probe) failed: unknown
```

No `docs.json`, `corefn.json` or `manifest.json` exists in this workspace
(`find . -name docs.json` → empty; the storage listing for the run shows no
`output/` tree), `purs`, `spago` and `zig` are all absent, and installing them is
forbidden. So the 179-module tree was unreachable and the 1229 were **not**
walked.

### 6.2 The three-fact check on the model (sample tree)

```
$ bun /tmp/bun/analyze.mjs | tail -2
FACT-CHECK otherwise: localValue ok
FACT-CHECK Type.Proxy idents: [["Proxy","localCtor"]] typeDecl? true
```

### 6.3 The bucket measurement

```
$ cd <repo> && bun /tmp/bun/analyze.mjs
{
  "modules": 114,
  "exportedIdents": 1500,
  "modulesWithRows": 90,
  "modulesWithZeroRows": 24,
  "identsInZeroRowModules": 383,
  "typedLocalValueRows": 719,
  "valueDeclsWithNoSourceSig": 105,
  "buckets": { "reexport_not_followed": 667, "no_declaration": 94,
               "not_a_value": 20, "unsupported_shape": 0 },
  "shapeReasonsOverTypedRows": { "type variable": 56, "type class dictionary": 224,
    "ok": 112, "parameterised data type": 82, "higher-order argument": 88,
    "unsupported type": 40, "unknown type": 7, "effect as argument": 5 },
  "ifReexportsFollowed": { "valueDecl": 262, "noValueDecl": 405, "concrete": 22,
    "reason": { "type class dictionary": 211, "parameterised data type": 6,
                "higher-order argument": 20, "type variable": 3 } },
  "prelude": { "module": "Prelude", "exports": 136, "localRows": 0 }
}
ZERO-ROW MODULES: idents by origin: {"localCtor":4,"reexport":397,
  "localClassMember":4,"reexportClassMember":8,"operator":6}
```

Read the `ifReexportsFollowed` block as the **cost/benefit of the §3 repair**
(**[measured], coarse shape model, sample tree)**: of 667 re-exported names, 262
resolve to a value declaration in their declaring module, but only **22 become
fully concrete**; 211 gain a row whose first argument is `type class dictionary`;
20 are `higher-order argument`; 6 `parameterised data type`; 3 `type variable`;
and **405 have no value declaration anywhere** (constructors and class members —
they need §4.3-(ii), not §3). On this tree the repair therefore converts ~17% of
the surface from `no type information` to *a typed row with at least one reason*,
and ~1.5% to concrete.

### 6.4 What the next agent should run (one command, settles §4.3)

`docs_probe(step="codegen")` on the tree that measured 1387, then per module:
`len(docs.declarations)` filtered to `declType == "value"`, and the build log's
`docs.json has no readable declarations` lines. Three numbers decide everything:
how many modules have 0 value declarations (cause i), how many names are nested
under `class.info.members` / `data.info.constructors` (cause ii), and whether any
module hits cause (iii).

### 6.5 Quoting the source

```
$ awk 'NR==755||NR==760||NR==763 {printf "%d: %s\n", NR, $0}' compiler/src/Zig/Abi.purs
755:     Just docs -> case mapMaybe (rowFor table src) (filter isValueDecl docs.decls) of
760:       [] -> refusedAll
763:   refusedAll = map (refusedExport src.moduleName) src.exports

$ awk 'NR==217||NR==288 {printf "%d: %s\n", NR, $0}' compiler/src/Main.purs
217:           , exports: row.exports
288:       , exports: map unwrap m.exports

$ grep -n "decodeReExports =" -A2 compiler/dist/bundle.js
19747:var decodeReExports = function(json) {
19748-  return bind5(decodeJObject(json))(function(obj) {
19749-    return bind5(traverse8(traverse15(decodeArray2(decodeIdent)))(toArrayWithKey(Tuple.create)(obj)))

$ printf '%s' '{"comments":[],"declarations":[],"name":"Prelude","reExports":{}}' | wc -c
65          # against the measured 471 bytes of Prelude's docs.json
```

---

## 7. What I could NOT determine

1. **The 1229's actual split.** The probe that reads that tree failed five times
   (§6.1). Everything in §4.2 is a *different tree*; §4.3 is inference from the
   code plus the sample. **No number in this file is a count of the 1229.**
2. **Why 88.6% and not ~25%.** The sample's zero-row modules carry a quarter of
   the surface; the issue's tree needs ~89%. Unexplained, and it is the single
   thing that decides whether the §3 repair is a big win or a small one.
3. **Whether `docs.json`'s `reExports` is `{}` or a partial map.** Bounded, not
   read: it cannot hold Prelude's 27 module keys in 406 bytes (§3), but whether it
   holds a handful of explicitly-named re-exports is unknown. It does not change
   the repair (use CoreFn's `reExports`), only the bucket's definition.
4. **Whether any module hits cause (iii)** (whole-file decode failure at
   `Abi.purs:159`). Needs the build log.
5. **Whether `higher-order argument` etc. keep their 8/1/1 counts after the
   repair.** They should (they are shape refusals, orthogonal to lookup), but
   unmeasured.
6. **Whether #43 should be re-scoped.** On the sample: no — the repair yields
   ~1.5% more concrete rows, and the concrete count is gated by the vocabulary
   (constraints, `Array a`, applied ADTs), not by lookup. On the real tree: only
   the §6.4 measurement can say.

## 8. Acceptance criteria — status

| Criterion (issue #44) | Status |
|---|---|
| Mechanism named with code path for `otherwise` and `Proxy` | **DONE** — §1.4, `Abi.purs:766/781/800/901` and `:755/760/763` |
| (a)/(b)/(c) verdict stated explicitly | **DONE** — §3: **(b)**, deciding line `Abi.purs:755`; (a) and (c) refuted with lines |
| If (b)/(c): a fix exists and the newly-concrete count is measured | **PARTLY** — fix located (`Main.purs:217` + `Abi.Source`, §3), count measured on the sample only (22 of 667, §6.3); the 1229's count is §6.4 |
| If (a): reason documented in `docs/codegen.md` | N/A (verdict is (b)) — but `docs/codegen.md` still says nothing about re-exports, and its "Typed exports" section (`:919-980`) should gain one paragraph when the repair lands |
| 23 parameterised exports have a recorded decision | **DONE** — §5: widen, additive `args`, omit when empty |
| Handoff file, repo convention | **DONE** — this file |

## Appendix — the measurement script

`/tmp/bun/analyze.mjs` is a throwaway (not in the repo, per the "docs only" rule).
Its method, in the order it runs:

1. strip `--` / `{- -}` comments and string literals from every `*.purs` under
   `packages/` and `example/src`;
2. parse `module <Name> [( … )] where` and split the export list on depth-0
   commas; entries are `module X`, `class C`, `type T`, `(op)`, `T(..)`,
   `T(C1,C2)`, `T`, or `name`;
3. column-0 scan of the body for `name ::`, `name … =`, `data`/`newtype` (plus
   their `|`-separated constructors), `type`, `class` (plus its indented
   `member ::` lines), `foreign import [data]`;
4. expand the export list to idents, resolving `module X` recursively and
   `T(..)` through a global `type → constructors` table (cycle-guarded);
5. bucket each ident exactly as `exportsForOne` would: local value declaration ⇒
   row; else re-export ⇒ `reexport_not_followed`; else the name matches a
   non-value declaration ⇒ `not_a_value`; else ⇒ `no_declaration`;
6. shape-classify a row's source signature with a coarse model of
   `signature`+`shapeOf` (`forall` peeled, depth-0 `->` split, `=>` ⇒ dictionary,
   `Array`/`Effect`/records/`{}`/nullary-ADT vs applied-ADT vs variable).

Fidelity: steps 1-5 are mechanical and reproduce the three known facts exactly;
step 6 is a heuristic — quote its numbers as ±, and re-derive them from a real
`docs.json` walk when the probe works.
