# CoreFn JSON schema

Transcribed from the compiler's `src/Language/PureScript/CoreFn/ToJSON.hs`,
which is the only real specification of this format. There is no published
schema document; the encoder *is* the contract.

## Module

```jsonc
{
  "sourceSpan":  { "start": [line, col], "end": [line, col] },
  "moduleName":  ["Data", "Maybe"],        // ARRAY of segments, not "Data.Maybe"
  "modulePath":  "src/Data/Maybe.purs",
  "imports":     [ { "annotation": ..., "moduleName": ["Prim"] } ],
  "exports":     ["fromMaybe", "maybe"],   // plain identifier strings
  "reExports":   { "Data.Maybe": ["..."] },// map moduleName -> identifiers
  "foreign":     ["someForeignFn"],        // identifiers with no CoreFn body
  "decls":       [ Bind, ... ],
  "builtWith":   "0.15.16",
  "comments":    [ ... ]
}
```

Every module's `imports` contains **`Prim`**, which is not a real module and
must be filtered out. Modules also import themselves.

## Bind

```jsonc
{ "bindType": "NonRec", "annotation": ..., "identifier": "f", "expression": Expr }

{ "bindType": "Rec",
  "binds": [ { "identifier": "f", "annotation": ..., "expression": Expr } ] }
```

Note `Rec` has **no** top-level `annotation`.

## Expr — tagged by `"type"`

| tag | fields |
|---|---|
| `Var` | `value`: Qualified |
| `Literal` | `value`: Literal |
| `Constructor` | `typeName`, `constructorName` (**plain strings**), `fieldNames`: array |
| `Accessor` | `fieldName`, `expression` |
| `ObjectUpdate` | `expression`, `copy` (bool), `updates`: Record |
| `Abs` | `argument` (one identifier), `body` |
| `App` | `abstraction`, `argument` |
| `Case` | `caseExpressions`: array, `caseAlternatives`: array |
| `Let` | `binds`: array of Bind, `expression` |

All also carry `annotation`.

**Asymmetry worth knowing:** in `Expr`, `Constructor`'s `typeName` and
`constructorName` are bare `ProperName` strings. In `Binder`,
`ConstructorBinder`'s equivalents are **Qualified objects**. Same concept,
different encoding, because `exprToJSON` uses `properNameToJSON` while
`binderToJSON` uses `qualifiedToJSON`.

## Qualified

```jsonc
{ "moduleName": ["Data", "Maybe"], "identifier": "fromMaybe" }   // global
{ "sourcePos": [line, col],        "identifier": "x" }           // local
```

`moduleName` is **absent** for locals. Its presence is the local/global test —
there is no explicit tag.

## Literal — tagged by `"literalType"`

`IntLiteral`, `NumberLiteral`, `StringLiteral`, `CharLiteral`,
`BooleanLiteral` all carry a scalar `value`. `ArrayLiteral`'s `value` is an
array of the inner type.

**`ObjectLiteral`'s `value` is an array of two-element arrays**, not an object:

```jsonc
{ "literalType": "ObjectLiteral", "value": [ ["x", Expr], ["y", Expr] ] }
```

That falls out of `recordToJSON` encoding a `[(PSString, a)]` as a list of
tuples, and it is the single easiest thing to get wrong. `ObjectUpdate`'s
`updates` uses the same encoding.

Literals are parameterised: inside an `Expr` the payload is `Expr`, inside a
`LiteralBinder` it is `Binder`. One decoder, taking the inner decoder as an
argument.

## CaseAlternative

```jsonc
{ "binders": [Binder],
  "isGuarded": false,
  "expression": Expr }

{ "binders": [Binder],
  "isGuarded": true,
  "expressions": [ { "guard": Expr, "expression": Expr } ] }
```

The key name itself changes with `isGuarded` — singular `expression` when
unguarded, plural `expressions` when guarded. Read `isGuarded` first.

## Binder — tagged by `"binderType"`

| tag | fields |
|---|---|
| `NullBinder` | — |
| `VarBinder` | `identifier` |
| `LiteralBinder` | `literal` |
| `NamedBinder` | `identifier`, `binder` |
| `ConstructorBinder` | `typeName`, `constructorName` (**Qualified**), `binders` |

## Annotation and meta

```jsonc
{ "sourceSpan": ..., "meta": null }
{ "sourceSpan": ..., "meta": { "metaType": "IsForeign" } }
```

`metaType` is one of `IsConstructor` (also carries `constructorType`, either
`ProductType` or `SumType`, plus `identifiers`), `IsNewtype`,
`IsTypeClassConstructor`, `IsForeign`, `IsWhere`, `IsSyntheticApp`.

v0 ignores all of it. Later it is worth having: `IsNewtype` allows erasing
constructor wrappers, and `IsConstructor` with `ProductType` means a single-
constructor type whose `Case` needs no tag test at all.
