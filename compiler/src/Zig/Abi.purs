-- | The typed ABI: one closed SHAPE per compiled export (issue #33).
-- |
-- | CoreFn is type-erased -- a decl's `annotation` is `{meta, sourceSpan}` and
-- | nothing else -- so the only place a signature survives is the `docs.json`
-- | purs writes beside `corefn.json` in `output/<Module>/`. This module reads
-- | that file, decodes a type, and maps it onto ONE shape from a fixed
-- | vocabulary:
-- |
-- |     "int" / "number" / "boolean" / "char" / "string" / "unit"
-- |     {"array": <shape>}
-- |     {"record": {field: <shape>}}
-- |     {"adt": {"module": .., "name": ..}}
-- |     {"refused": "<reason>"}
-- |
-- | The vocabulary is deliberately WIDTH-AGNOSTIC: the shape is `"int"`, never
-- | `"int32"` or `"i32"`. How wide an `Int` is is an open question in purzig,
-- | and a later decision must be able to change it without changing the
-- | manifest.
-- |
-- | Two rules decide everything else:
-- |
-- |   * **Nothing is guessed.** A type the vocabulary cannot express becomes
-- |     `{"refused": "<reason>"}`, carrying the reason so tooling can report
-- |     it. A refusal is a first-class answer, not a failure: `renderExport`
-- |     always produces a row.
-- |   * **Nothing is silently dropped.** `exportsFor` produces a row for every
-- |     exported value the docs list, and -- when the docs are missing or a
-- |     signature cannot be recovered -- a row of `{"refused": "no type
-- |     information"}` for every name CoreFn calls an export.
-- |
-- | ## What docs.json is taken to look like
-- |
-- | The declarations live in a top-level `declarations` array. Each entry has a
-- | `title`, a declaration kind (`declType`, in the entry or in its `info`
-- | object) and, for a value, a type in `info.type`. The type is accepted in
-- | BOTH encodings purs has used:
-- |
-- |   1. a **JSON AST**: `{"tag": "TypeApp", "contents": [..]}`,
-- |      `{"tag": "TypeConstructor", "contents": [qual, name]}`, `ForAll`,
-- |      `ConstrainedType`, `Record`, `RCons`, `REmpty`, `ParensInType`, ...;
-- |   2. a **rendered PureScript type source string**, e.g.
-- |      `"(Int -> Int) -> Array Int"`, which is parsed here.
-- |
-- | Accepting both is not redundancy for its own sake: this file's author could
-- | not read a real `output/<Module>/docs.json` (there is no purs on the
-- | machine that wrote it), so the decoder is written against both documented
-- | encodings and degrades to `no type information` rather than guessing. See
-- | `docs/handoff-manifest-shapes-2026-11-01.md`.
module Zig.Abi
  ( DocsModule
  , Export
  , Shape(..)
  , Source
  , decodeDocsModule
  , exportsFor
  , renderExport
  ) where

import Prelude

import Data.Argonaut.Core (Json, caseJson, toArray)
import Data.Argonaut.Decode (class DecodeJson, getField')
import Data.Array (catMaybes, concatMap, elem, filter, find, index, length, mapMaybe, null, slice, uncons)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.String (Pattern(..), joinWith, split)
import Data.String.CodeUnits as CU
import Data.Traversable (traverse)
import Zig.Ident (stringLit)

--------------------------------------------------------------------------------
-- The shape vocabulary (fixed -- do not add to it)
--------------------------------------------------------------------------------

data Shape
  = SInt
  | SNumber
  | SBoolean
  | SChar
  | SString
  | SUnit
  | SArray Shape
  | SRecord (Array ShapeField)
  | SAdt String String
  | SRefused String

type ShapeField = { label :: String, shape :: Shape }

-- | One published export: what it is called, the shape of each argument, and
-- | the shape of the result.
type Export =
  { moduleName :: String
  , name :: String
  , args :: Array Shape
  , result :: Shape
  }

-- | One module's contribution: the name CoreFn knows it by, the export list
-- | CoreFn records, and its docs when they could be read and decoded.
type Source =
  { moduleName :: String
  , exports :: Array String
  , docs :: Maybe DocsModule
  }

-- | A decoded `docs.json`: the declarations it types, in file order.
type DocsModule = { moduleName :: String, decls :: Array Decl }

type Decl = { name :: String, kind :: Kind, ty :: Maybe Ty }

-- | What a docs declaration IS. Only a `KValue` becomes an export row; the rest
-- | exist so a type constructor can be classified at its use site (an ADT, an
-- | erased newtype, a synonym, a foreign type, a class).
data Kind = KValue | KData | KNewtype | KSynonym | KForeign | KClass | KOther

--------------------------------------------------------------------------------
-- Types, as this module models them
--------------------------------------------------------------------------------

-- | A type, reduced to what the vocabulary can ask of it. `TOther` is the
-- | catch-all for a shape of type this module does not model (type operators,
-- | type-level literals, wildcards): it refuses, and never guesses.
data Ty
  = TCon String String
  | TVar String
  | TDict
  | TApp Ty Ty
  | TArrow Ty Ty
  | TRecord (Array TyField) Boolean
  | TForall Ty
  | TConstrained Ty
  | TOther

type TyField = { label :: String, ty :: Ty }

-- | Which end of the signature a shape is being computed for. The same type can
-- | be acceptable in one position and refused in the other: `Effect a` is
-- | `"unit"` as a result, and refused as an argument.
data Pos = AsArg | AsResult

--------------------------------------------------------------------------------
-- Decoding docs.json
--------------------------------------------------------------------------------

-- | `decodeDocsModule moduleName json`.
-- |
-- | Returns `Nothing` only when the file is not shaped like a docs module at
-- | all (no readable `declarations` array). An individual declaration that
-- | cannot be read is kept with no type rather than dropped, so the export
-- | still gets a row.
decodeDocsModule :: String -> Json -> Maybe DocsModule
decodeDocsModule name json = do
  declsJson <- field "declarations" json >>= toArray
  decls <- traverse decodeDecl declsJson
  pure { moduleName: name, decls: decls }

decodeDecl :: Json -> Maybe Decl
decodeDecl json = do
  title <- field "title" json >>= asString
  let info = fromMaybe json (field "info" json)
  -- The type is usually under `info`, and occasionally beside `title`.
  let tyJson = case field "type" info of
        Just t -> Just t
        Nothing -> field "type" json
  let kindJson = case field "declType" json of
        Just k -> Just k
        Nothing -> case field "kind" json of
          Just k -> Just k
          Nothing -> case field "declType" info of
            Just k -> Just k
            Nothing -> field "kind" info
  let kindData = case field "dataDeclType" info of
        Just k -> Just k
        Nothing -> field "dataDeclType" json
  let kind0 = refineKind (classifyKind kindJson) kindData
  -- No recognised kind marker, but a type: every encoding of a value
  -- declaration carries one, so treat it as a value rather than dropping the
  -- export. A data declaration carries `constructors` instead, never `type`.
  let kind = case kind0 of
        KOther -> if isJust tyJson then KValue else KOther
        other -> other
  pure { name: title, kind: kind, ty: tyJson >>= decodeType }

classifyKind :: Maybe Json -> Kind
classifyKind Nothing = KOther
classifyKind (Just json) = case asString json of
  Nothing -> KOther
  Just s
    | s == "value" -> KValue
    | s == "data" -> KData
    | s == "newtype" -> KNewtype
    | s == "typeSynonym" -> KSynonym
    | s == "synonym" -> KSynonym
    | s == "type" -> KSynonym
    | s == "externData" -> KForeign
    | s == "foreignData" -> KForeign
    | s == "typeClass" -> KClass
    | s == "class" -> KClass
    | otherwise -> KOther

-- | A `data` declaration carries its newtype-ness in a second field when the
-- | docs format keeps them together, which is the difference between "a tagged
-- | union" and "the field itself, erased" -- too big a difference to guess.
refineKind :: Kind -> Maybe Json -> Kind
refineKind kind dataKind = case dataKind >>= asString of
  Just "newtype" -> KNewtype
  Just "foreign" -> KForeign
  Just "foreignData" -> KForeign
  _ -> kind

-- | One JSON object field, or `Nothing`. A `DecodeJson Raw` instance is
-- | declared here rather than relying on one for `Json` itself: `getField` is
-- | total over its decoder, and `Raw` is how this module says "hand it back
-- | unchanged".
newtype Raw = Raw Json

instance decodeRawJson :: DecodeJson Raw where
  decodeJson json = Right (Raw json)

-- | A JSON string, or `Nothing`.
-- |
-- | `caseJson` rather than `toString`: it is the one member of argonaut's
-- | accessor family whose presence in this dependency set is proven by the
-- | compiled backend in `compiler/dist/bundle.js`, and the family differs only
-- | in which argument it projects.
asString :: Json -> Maybe String
asString = caseJson Nothing (const Nothing) (const Nothing) Just (const Nothing) (const Nothing)

field :: String -> Json -> Maybe Json
field key json =
  caseJson
    Nothing
    (const Nothing)
    (const Nothing)
    (const Nothing)
    (const Nothing)
    (\obj -> hushRaw (getField key obj))
    json

hushRaw :: forall e. Either e Raw -> Maybe Json
hushRaw result = case result of
  Left _ -> Nothing
  Right (Raw value) -> Just value

at :: Array Json -> Int -> Maybe Json
at xs i = index xs i

--------------------------------------------------------------------------------
-- Decoding a type
--------------------------------------------------------------------------------

-- | Either encoding, decided by what the value is: a string is rendered
-- | PureScript type source, an object is the tagged type AST.
decodeType :: Json -> Maybe Ty
decodeType json = case asString json of
  Just src -> parseTypeSource src
  Nothing -> case field "tag" json >>= asString of
    Just tag -> decodeTagged tag json
    Nothing -> case field "type" json of
      -- Some shapes nest the real node one level deeper; follow it once.
      Just inner -> decodeType inner
      Nothing -> Nothing

decodeTagged :: String -> Json -> Maybe Ty
decodeTagged tag json =
  let
    contents = field "contents" json
  in
    if tag == "TypeApp" || tag == "TypeAppJson" then do
      cs <- contents >>= toArray
      ty1 <- at cs 0 >>= decodeType
      ty2 <- at cs 1 >>= decodeType
      pure (TApp ty1 ty2)
    else if tag == "TypeConstructor" then decodeConstructor contents
    else if tag == "TypeVar" || tag == "TypeVariable" || tag == "Skolem" then do
      name <- contents >>= asString
      pure (TVar name)
    else if tag == "ForAll" || tag == "Forall" then do
      cs <- contents >>= toArray
      body <- at cs (length cs - 1) >>= decodeType
      pure (TForall body)
    else if tag == "ConstrainedType" || tag == "Constraint" then do
      cs <- contents >>= toArray
      body <- at cs (length cs - 1) >>= decodeType
      pure (TConstrained body)
    else if tag == "ParensInType" || tag == "Parens" || tag == "KindApp" || tag == "KindApplication" || tag == "KindSignature" || tag == "SkolemEscape" then
      contents >>= decodeType
    else if tag == "Record" then
      case contents of
        Just row -> Just (tRecordOf row)
        Nothing -> Just TOther
    else if tag == "RCons" || tag == "REmpty" then
      Just (tRecordOf json)
    else
      -- Type operators, type-level literals, wildcards, unknowns: modelled as
      -- untypable, which refuses with a reason instead of inventing a shape.
      Just TOther

-- | The row of a record type, as a `TRecord`. A row tail that is not `REmpty`
-- | is a row VARIABLE, so the record is open and cannot be published.
tRecordOf :: Json -> Ty
tRecordOf row =
  let r = rowOf row
  in TRecord r.fields r.closed

rowOf :: Json -> { fields :: Array TyField, closed :: Boolean }
rowOf json = case field "tag" json >>= asString of
  Just "RCons" -> case field "contents" json >>= toArray of
    Nothing -> { fields: [], closed: false }
    Just cs -> case at cs 0 >>= asString of
      Nothing -> { fields: [], closed: false }
      Just label -> case at cs 1 >>= decodeType of
        Nothing -> { fields: [], closed: false }
        Just ty ->
          let
            rest = case at cs 2 of
              Just tail_ -> rowOf tail_
              Nothing -> { fields: [], closed: false }
          in
            { fields: [ { label: label, ty: ty } ] <> rest.fields, closed: rest.closed }
  Just "REmpty" -> { fields: [], closed: true }
  _ -> { fields: [], closed: false }

-- | A type constructor's name and module.
-- |
-- | Three encodings are accepted, because all three are plausible in a
-- | `docs.json`: `contents` as a `[moduleName, name]` pair, `contents` as a
-- | single qualified object `{"moduleName": [..], "identifier": ..}`, and
-- | `contents` as a one-element array wrapping either of those. A module name
-- | is an array of segments (`["Data","Maybe"]`) everywhere else in purs's
-- | JSON, and a plain string in a rendered type.
decodeConstructor :: Maybe Json -> Maybe Ty
decodeConstructor contents = do
  json <- contents
  case toArray json of
    Just arr -> case length arr of
      2 ->
        Just
          ( TCon
              (fromMaybe "" (moduleOf (fromMaybe json (at arr 0))))
              (fromMaybe "" (nameOf (fromMaybe json (at arr 1))))
          )
      1 ->
        let one = fromMaybe json (at arr 0)
        in Just (TCon (fromMaybe "" (moduleOf one)) (fromMaybe "" (nameOf one)))
      _ -> Just (TCon (fromMaybe "" (moduleOf json)) (fromMaybe "" (nameOf json)))
    Nothing -> Just (TCon (fromMaybe "" (moduleOf json)) (fromMaybe "" (nameOf json)))

moduleOf :: Json -> Maybe String
moduleOf json = case asString json of
  Just s -> Just s
  Nothing -> case toArray json of
    Just segs -> Just (joinWith "." (mapMaybe asString segs))
    Nothing -> case field "moduleName" json of
      Just inner -> moduleOf inner
      Nothing -> Just ""

nameOf :: Json -> Maybe String
nameOf json = case asString json of
  Just s -> Just s
  Nothing -> case field "identifier" json of
    Just inner -> asString inner
    Nothing -> case field "properName" json of
      Just inner -> asString inner
      Nothing -> field "name" json >>= asString

--------------------------------------------------------------------------------
-- Parsing a rendered type (`"Int -> Array Int"`)
--------------------------------------------------------------------------------
--
-- Used when `docs.json` carries the type as source text instead of a JSON AST.
-- A small recursive-descent parser, with one rule that matters for
-- termination: every parser consumes at least one character or fails, so no
-- production can loop without making progress.

type Parsed a = { value :: a, rest :: Array Char }

parseTypeSource :: String -> Maybe Ty
parseTypeSource src = do
  r <- pType (CU.toCharArray src)
  pure r.value

pType :: Array Char -> Maybe (Parsed Ty)
pType cs0 =
  let cs = skipWs cs0 in
  case forallPrefix cs of
    Just after -> pForall after
    Nothing -> pConstrained cs

-- | `forall a b. ty` / `forall (a :: Type). ty`. A leading `forall` is every
-- | polymorphic function's prefix and says nothing about representation; one
-- | that survives into an argument is rank-n and is refused there.
pForall :: Array Char -> Maybe (Parsed Ty)
pForall cs0 = do
  afterVars <- skipForallVars (skipWs cs0)
  body <- pType afterVars
  pure { value: TForall body.value, rest: body.rest }

skipForallVars :: Array Char -> Maybe (Array Char)
skipForallVars cs = case uncons cs of
  Nothing -> Nothing
  Just r ->
    if r.head == '.' then Just r.tail
    else if r.head == '(' then do
      rest <- skipParens r.tail
      skipForallVars (skipWs rest)
    else if isNameStart r.head then do
      name <- takeName cs
      skipForallVars (skipWs name.rest)
    else Nothing

skipParens :: Array Char -> Maybe (Array Char)
skipParens cs = case uncons cs of
  Nothing -> Nothing
  Just r -> if r.head == ')' then Just r.tail else skipParens r.tail

pConstrained :: Array Char -> Maybe (Parsed Ty)
pConstrained cs = do
  r <- pArrow cs
  case stripPrefixChars "=>" (skipWs r.rest) of
    Just after -> do
      inner <- pType after
      pure { value: TConstrained inner.value, rest: inner.rest }
    Nothing -> pure r

pArrow :: Array Char -> Maybe (Parsed Ty)
pArrow cs = do
  r <- pApp cs
  case stripPrefixChars "->" (skipWs r.rest) of
    Just after -> do
      deeper <- pArrow after
      pure { value: TArrow r.value deeper.value, rest: deeper.rest }
    Nothing -> pure r

pApp :: Array Char -> Maybe (Parsed Ty)
pApp cs = case pAtom cs of
  Nothing -> Nothing
  Just first -> Just (pAppMore first.value first.rest)

-- | The rest of an application spine: `Array Int` is two atoms, so the head is
-- | applied to each following atom until one cannot start.
pAppMore :: Ty -> Array Char -> Parsed Ty
pAppMore acc rest = case pAtom rest of
  Nothing -> { value: acc, rest: rest }
  Just next -> pAppMore (TApp acc next.value) next.rest

pAtom :: Array Char -> Maybe (Parsed Ty)
pAtom cs0 =
  let cs = skipWs cs0 in
  case uncons cs of
    Nothing -> Nothing
    Just r ->
      if r.head == '(' then pParen r.tail
      else if r.head == '{' then pRecord r.tail
      else pNameAtom cs

-- | An atom that is a name: `forall` (rank-n, refused where it lands unless the
-- | signature's own prefix) or a type constructor / type variable.
pNameAtom :: Array Char -> Maybe (Parsed Ty)
pNameAtom cs = case forallPrefix cs of
  Just after -> pForall after
  Nothing -> case takeName cs of
    Just name -> Just { value: conOf name.value, rest: name.rest }
    Nothing -> Nothing

pParen :: Array Char -> Maybe (Parsed Ty)
pParen cs0 = do
  inner <- pType cs0
  rest <- expectChar ')' (skipWs inner.rest)
  pure { value: inner.value, rest: rest }

pRecord :: Array Char -> Maybe (Parsed Ty)
pRecord cs0 = do
  row <- pRow cs0
  pure { value: TRecord row.fields row.closed, rest: row.rest }

pRow :: Array Char -> Maybe { fields :: Array TyField, closed :: Boolean, rest :: Array Char }
pRow cs0 = go [] cs0
  where
  go acc cs =
    let s = skipWs cs in
    case uncons s of
      Nothing -> Nothing
      Just r ->
        if r.head == '}' then Just { fields: acc, closed: true, rest: r.tail }
        else if r.head == '|' then do
          rest <- skipToBrace 0 r.tail
          pure { fields: acc, closed: false, rest: rest }
        else do
          label <- takeLabel s
          after <- expectColon label.rest
          field_ <- pType after
          go (acc <> [ { label: label.value, ty: field_.value } ]) field_.rest

-- | Consume the rest of an open row (`| r`), tracking nested braces so a record
-- | field inside one does not end it early.
skipToBrace :: Int -> Array Char -> Maybe (Array Char)
skipToBrace depth cs = case uncons cs of
  Nothing -> Nothing
  Just r ->
    if r.head == '{' then skipToBrace (depth + 1) r.tail
    else if r.head == '}' then
      if depth == 0 then Just r.tail else skipToBrace (depth - 1) r.tail
    else skipToBrace depth r.tail

expectChar :: Char -> Array Char -> Maybe (Array Char)
expectChar c cs = case uncons (skipWs cs) of
  Just r | r.head == c -> Just r.tail
  _ -> Nothing

expectColon :: Array Char -> Maybe (Array Char)
expectColon cs = case stripPrefixChars "::" (skipWs cs) of
  Just rest -> Just (skipWs rest)
  Nothing -> case stripPrefixChars ":" (skipWs cs) of
    Just rest -> Just (skipWs rest)
    Nothing -> Nothing

forallPrefix :: Array Char -> Maybe (Array Char)
forallPrefix cs = case stripPrefixChars "forall" cs of
  Just rest -> case uncons rest of
    Just r | isNameChar r.head -> Nothing
    _ -> Just rest
  Nothing -> stripPrefixChars "∀" cs -- the other spelling of `forall`

skipWs :: Array Char -> Array Char
skipWs cs = case uncons cs of
  Just r | isSpaceChar r.head -> skipWs r.tail
  _ -> cs

isSpaceChar :: Char -> Boolean
isSpaceChar c = c == ' ' || c == '\n' || c == '\r' || c == '\t'

isNameStart :: Char -> Boolean
isNameStart c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'

isNameChar :: Char -> Boolean
isNameChar c = isNameStart c || (c >= '0' && c <= '9') || c == '\'' || c == '.'

isLabelChar :: Char -> Boolean
isLabelChar c = isNameStart c || (c >= '0' && c <= '9') || c == '\'' || c == '-'

takeName :: Array Char -> Maybe { value :: String, rest :: Array Char }
takeName cs = case uncons cs of
  Just r | isNameStart r.head -> Just (spanChars isNameChar cs)
  _ -> Nothing

takeLabel :: Array Char -> Maybe { value :: String, rest :: Array Char }
takeLabel cs = case uncons cs of
  Just r | isLabelChar r.head -> Just (spanChars isLabelChar cs)
  _ -> Nothing

-- | Consume the longest run of `ok` characters from the FRONT of `cs`.
spanChars :: (Char -> Boolean) -> Array Char -> { value :: String, rest :: Array Char }
spanChars ok cs = case uncons cs of
  Just r | ok r.head -> gather ok [ r.head ] r.tail
  _ -> { value: "", rest: cs }

gather :: (Char -> Boolean) -> Array Char -> Array Char -> { value :: String, rest :: Array Char }
gather ok acc rest = case uncons rest of
  Just r | ok r.head -> gather ok (acc <> [ r.head ]) r.tail
  _ -> { value: CU.fromCharArray acc, rest: rest }

stripPrefixChars :: String -> Array Char -> Maybe (Array Char)
stripPrefixChars prefix cs = go (CU.toCharArray prefix) cs
  where
  go pat rest = case uncons pat of
    Nothing -> Just rest
    Just p -> case uncons rest of
      Just r | r.head == p.head -> go p.tail r.tail
      _ -> Nothing

-- | A name in source form is qualified or not, and UPPER-case means a type
-- | constructor while lower-case means a type variable. An unqualified
-- | constructor has no module, which is resolved against the exporting module
-- | at the use site -- and refused when that module does not declare it.
conOf :: String -> Ty
conOf full =
  let
    parts = split (Pattern ".") full
    lastPart = fromMaybe full (index parts (length parts - 1))
  in
    if startsUpper lastPart then TCon (modulePrefix parts) lastPart else TVar lastPart

modulePrefix :: Array String -> String
modulePrefix parts =
  if length parts <= 1 then "" else joinWith "." (slice 0 (length parts - 1) parts)

startsUpper :: String -> Boolean
startsUpper s = case CU.charAt 0 s of
  Just c -> c >= 'A' && c <= 'Z'
  Nothing -> false

--------------------------------------------------------------------------------
-- Types -> shapes
--------------------------------------------------------------------------------

-- | Every export row for every source, in order. The type table is built from
-- | all the docs that were loaded, so a type declared in another module is
-- | classified from ITS declaration rather than from a guess.
-- |
-- | A row is a docs VALUE declaration that CoreFn also lists as an export --
-- | data constructors and type-class members are not value declarations and are
-- | not callable exports, so they get no row. When the docs are missing, or type
-- | nothing at all, every CoreFn export gets a `no type information` row
-- | instead, so a broken docs file never silently empties a module's exports.
exportsFor :: Array Source -> Array Export
exportsFor sources = concatMap (exportsForOne table) sources
  where
  table = typeTable sources

exportsForOne :: Array TypeEntry -> Source -> Array Export
exportsForOne table src = case src.docs of
    Nothing -> refusedAll
    Just docs -> case mapMaybe (rowFor table src) (filter isValueDecl docs.decls) of
      -- The docs decoded but typed nothing: fall back to a refusal per CoreFn
      -- export rather than publishing an empty list, which would drop every
      -- export the module has. A module with no exported values at all also
      -- lands here, and a refused row is the honest answer for it.
      [] -> refusedAll
      rows -> rows
  where
  refusedAll = map (refusedExport src.moduleName) src.exports

isValueDecl :: Decl -> Boolean
isValueDecl decl = case decl.kind of
  KValue -> true
  _ -> false

refusedExport :: String -> String -> Export
refusedExport modName name =
  { moduleName: modName
  , name: name
  , args: [ SRefused "no type information" ]
  , result: SRefused "no type information"
  }

rowFor :: Array TypeEntry -> Source -> Decl -> Maybe Export
rowFor table src decl =
  if not (exported src decl.name) then Nothing
  else case decl.ty of
    Nothing -> Just (refusedExport src.moduleName decl.name)
    Just ty ->
      let
        sig = signature ty
      in
        Just
          { moduleName: src.moduleName
          , name: decl.name
          , args: (if sig.constrained then [ SRefused "type class dictionary" ] else [])
              <> map (shapeOf table src.moduleName AsArg) sig.args
          , result: shapeOf table src.moduleName AsResult sig.result
          }

-- | A name the module does not export is not an export. An empty export list is
-- | treated as "unknown" rather than "nothing": docs already lists only the
-- | public API, and dropping every row on a CoreFn list this program could not
-- | read would be the silent drop the issue forbids.
exported :: Source -> String -> Boolean
exported src name = null src.exports || elem name src.exports

type TypeEntry = { moduleName :: String, name :: String, kind :: Kind }

typeTable :: Array Source -> Array TypeEntry
typeTable sources = concatMap entries (catMaybes (map (\src -> src.docs) sources))

entries :: DocsModule -> Array TypeEntry
entries docs = mapMaybe (entryFor docs.moduleName) docs.decls

entryFor :: String -> Decl -> Maybe TypeEntry
entryFor modName decl = case decl.kind of
  KValue -> Nothing
  KOther -> Nothing
  kind -> Just { moduleName: modName, name: decl.name, kind: kind }

findType :: Array TypeEntry -> String -> String -> Maybe TypeEntry
findType table modName conName = find (\entry -> entry.name == conName && entry.moduleName == modName) table

-- | A signature's arguments and result, with a leading `forall` peeled and a
-- | constraint recorded rather than dropped: `Eq a => a -> Int` takes a
-- | dictionary as its first argument, so the argument list starts with one.
type Signature = { constrained :: Boolean, args :: Array Ty, result :: Ty }

-- | An arrow, in either encoding: `TArrow` from a rendered type source, or
-- | `Function a b` -- an ordinary type application of `Prim.Function` -- from
-- | the JSON AST. Normalising here is what keeps `Int -> Int` from being read as
-- | a RESULT that is a function, which would publish every export as
-- | `{"refused": "higher-order result"}`.
asArrow :: Ty -> Maybe { arg :: Ty, result :: Ty }
asArrow ty = case ty of
  TArrow a b -> Just { arg: a, result: b }
  _ ->
    let
      parts = unapply ty
    in
      case parts.head of
        TCon _ "Function" -> case parts.args of
          [ a, b ] -> Just { arg: a, result: b }
          _ -> Nothing
        _ -> Nothing

signature :: Ty -> Signature
signature ty = go ty [] false
  where
  go t acc constrained = case t of
    TForall inner -> go inner acc constrained
    TConstrained inner -> go inner acc true
    _ -> case asArrow t of
      Nothing -> { constrained: constrained, args: acc, result: t }
      Just arrow -> go arrow.result (acc <> [ arrow.arg ]) constrained

shapeOf :: Array TypeEntry -> String -> Pos -> Ty -> Shape
shapeOf table modName pos ty = case ty of
  TArrow _ _ -> arrowRefusal pos
  TForall _ -> SRefused "existential or rank-n type"
  TConstrained _ -> SRefused "type class dictionary"
  TDict -> SRefused "type class dictionary"
  TVar _ -> SRefused "type variable"
  TOther -> SRefused "unsupported type"
  TRecord fields closed -> recordShape table modName pos fields closed
  TCon conMod conName -> conShape table modName pos conMod conName []
  TApp _ _ ->
    let
      parts = unapply ty
    in
      case parts.head of
        TCon conMod conName -> conShape table modName pos conMod conName parts.args
        TVar _ -> SRefused "type variable"
        _ -> SRefused "unsupported type"

-- | Flatten an application spine: `Array (Array Int)` -> head `Array`, two
-- | arguments.
unapply :: Ty -> { head :: Ty, args :: Array Ty }
unapply ty = case ty of
  TApp f x ->
    let rec = unapply f
    in { head: rec.head, args: rec.args <> [ x ] }
  other -> { head: other, args: [] }

recordShape :: Array TypeEntry -> String -> Pos -> Array TyField -> Boolean -> Shape
recordShape table modName pos fields closed =
  if closed then
    SRecord (map (\f -> { label: f.label, shape: shapeOf table modName pos f.ty }) fields)
  else SRefused "open record"

-- | A named type. The primitives are matched by NAME, because they arrive as
-- | `Prim.Int` from the AST and as bare `Int` from source text; everything else
-- | is a nominal type, classified from its own declaration.
-- |
-- | The dispatch is a `case` on the constructor name rather than a guard chain
-- | on purpose: a `where` clause attached to a GUARDED declaration does not put
-- | its bindings in scope for the guards' right-hand sides (the compiler reports
-- | the local as "introduced but not used" where it is defined and "unknown
-- | value" where it is called). With a plain right-hand side the `where` covers
-- | the whole body, case arms included, so `oneArg` below is visible to every
-- | branch that calls it.
conShape :: Array TypeEntry -> String -> Pos -> String -> String -> Array Ty -> Shape
conShape table modName pos conMod conName args = case conName of
  "Int" -> SInt
  "Number" -> SNumber
  "Boolean" -> SBoolean
  "Char" -> SChar
  "String" -> SString
  "Unit" -> SUnit
  "Foreign" -> SRefused "foreign type"
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

effectShape :: Pos -> Shape
effectShape pos = case pos of
  -- `Effect a` as a RESULT is a thunk the host runs; what it produces is the
  -- unit value the run returns.
  AsResult -> SUnit
  AsArg -> SRefused "effect as argument"

arrowRefusal :: Pos -> Shape
arrowRefusal pos = case pos of
  AsArg -> SRefused "higher-order argument"
  AsResult -> SRefused "higher-order result"

-- | A nominal type is publishable only when it is a data type with no type
-- | arguments: the vocabulary has no way to say "`Maybe` of what", and an
-- | erased newtype is not a tagged value at all.
adtShape :: Array TypeEntry -> String -> String -> String -> Array Ty -> Shape
adtShape table modName conMod conName args =
  let target = if conMod == "" then modName else conMod
  in
    case findType table target conName of
      Nothing -> SRefused "unknown type"
      Just entry -> case entry.kind of
        KData ->
          if null args then SAdt entry.moduleName entry.name
          else SRefused "parameterised data type"
        KNewtype -> SRefused "newtype"
        KSynonym -> SRefused "type synonym"
        KForeign -> SRefused "foreign type"
        KClass -> SRefused "type class dictionary"
        _ -> SRefused "unknown type"

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

-- | One manifest row, with no trailing comma and no indentation -- the caller
-- | joins and indents, exactly as it does for `modules`.
renderExport :: Export -> String
renderExport row =
  "{ \"module\": " <> stringLit row.moduleName
    <> ", \"name\": " <> stringLit row.name
    <> ", \"args\": " <> renderShapes row.args
    <> ", \"result\": " <> renderShape row.result
    <> " }"

renderShapes :: Array Shape -> String
renderShapes shapes = "[" <> joinWith ", " (map renderShape shapes) <> "]"

renderShape :: Shape -> String
renderShape shape = case shape of
  SInt -> stringLit "int"
  SNumber -> stringLit "number"
  SBoolean -> stringLit "boolean"
  SChar -> stringLit "char"
  SString -> stringLit "string"
  SUnit -> stringLit "unit"
  SArray inner -> "{\"array\": " <> renderShape inner <> "}"
  SRecord fields ->
    "{\"record\": {" <> joinWith ", " (map renderField fields) <> "}}"
  SAdt adtMod adtName ->
    "{\"adt\": {\"module\": " <> stringLit adtMod <> ", \"name\": " <> stringLit adtName <> "}}"
  SRefused reason -> "{\"refused\": " <> stringLit reason <> "}"

renderField :: ShapeField -> String
renderField f = stringLit f.label <> ": " <> renderShape f.shape
