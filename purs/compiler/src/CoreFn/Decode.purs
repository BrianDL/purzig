-- | corefn.json -> CoreFn.Types
-- |
-- | Transcribed from the compiler's `Language.PureScript.CoreFn.ToJSON`, which
-- | is the only specification of this format that exists. docs/corefn-schema.md
-- | records the shapes; the traps worth restating here:
-- |
-- |  * `moduleName` is an ARRAY of segments everywhere it appears, never a
-- |    dotted string. Joined on decode.
-- |  * `Prim` appears in every module's imports and is not a real module.
-- |    Filtered here so nothing downstream has to remember.
-- |  * `ObjectLiteral`'s value is an array of two-element `[key, value]`
-- |    arrays, not a JSON object. Same for `ObjectUpdate`'s `updates`.
-- |  * A `Qualified` has no tag: `moduleName` present means global, absent
-- |    means local.
-- |  * `CaseAlternative` changes its key name with `isGuarded` -- singular
-- |    `expression` when false, plural `expressions` when true.
-- |  * `Constructor` in an expression carries bare `ProperName` strings, but
-- |    `ConstructorBinder` carries `Qualified` objects. Same concept, two
-- |    encodings.
module CoreFn.Decode
  ( decodeModule
  , decodeExpr
  , decodeBind
  , decodeBinder
  ) where

import Prelude

import CoreFn.Types (Bind(..), Binder(..), CaseAlternative, Expr(..), Literal(..), Module, Qualified, Result(..))
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (JsonDecodeError(..), decodeJson, (.:), (.:?))
import Data.Array (filter)
import Data.Either (Either(..))
import Data.Maybe (Maybe)
import Data.String (joinWith)
import Data.Traversable (traverse)

type Decoded a = Either JsonDecodeError a

-- | Top level. The caller supplies parsed JSON from `output/<M>/corefn.json`.
decodeModule :: Json -> Decoded Module
decodeModule json = do
  o <- decodeJson json
  nameSegments <- o .: "moduleName"
  path <- o .: "modulePath"
  importsJson <- o .: "imports"
  imports <- traverse decodeImport importsJson
  exports <- o .: "exports"
  foreigns <- o .: "foreign"
  declsJson <- o .: "decls"
  decls <- traverse decodeBind declsJson
  builtWith <- o .: "builtWith"
  let name = joinSegments nameSegments
  pure
    { name
    , path
    , imports: filter (\m -> m /= "Prim" && m /= name) imports
    , exports
    , foreigns
    , decls
    , builtWith
    }

decodeImport :: Json -> Decoded String
decodeImport json = do
  o <- decodeJson json
  segments <- o .: "moduleName"
  pure (joinSegments segments)

joinSegments :: Array String -> String
joinSegments = joinWith "."

decodeQualified :: Json -> Decoded Qualified
decodeQualified json = do
  o <- decodeJson json
  identifier <- o .: "identifier"
  segments <- o .:? "moduleName"
  pure { moduleName: map joinSegments (segments :: Maybe (Array String)), identifier }

decodeBind :: Json -> Decoded Bind
decodeBind json = do
  o <- decodeJson json
  bindType <- o .: "bindType"
  case bindType of
    "NonRec" -> do
      identifier <- o .: "identifier"
      exprJson <- o .: "expression"
      expression <- decodeExpr exprJson
      pure (NonRec identifier expression)
    "Rec" -> do
      bindsJson <- o .: "binds"
      binds <- traverse decodeRecBind bindsJson
      pure (Rec binds)
    other ->
      Left (TypeMismatch ("unknown bindType: " <> other))

decodeRecBind :: Json -> Decoded { identifier :: String, expression :: Expr }
decodeRecBind json = do
  o <- decodeJson json
  identifier <- o .: "identifier"
  exprJson <- o .: "expression"
  expression <- decodeExpr exprJson
  pure { identifier, expression }

decodeExpr :: Json -> Decoded Expr
decodeExpr json = do
  o <- decodeJson json
  tag <- o .: "type"
  case tag of
    "Var" -> do
      valueJson <- o .: "value"
      Var <$> decodeQualified valueJson

    "Literal" -> do
      valueJson <- o .: "value"
      Lit <$> decodeLiteral decodeExpr valueJson

    "Constructor" -> do
      typeName <- o .: "typeName"
      constructorName <- o .: "constructorName"
      fieldNames <- o .: "fieldNames"
      pure (Constructor { typeName, constructorName, fieldNames })

    "Accessor" -> do
      fieldName <- o .: "fieldName"
      exprJson <- o .: "expression"
      expression <- decodeExpr exprJson
      pure (Accessor { fieldName, expression })

    "ObjectUpdate" -> do
      exprJson <- o .: "expression"
      expression <- decodeExpr exprJson
      updatesJson <- o .: "updates"
      updates <- traverse (decodePair decodeExpr) updatesJson
      pure (ObjectUpdate { expression, updates })

    "Abs" -> do
      argument <- o .: "argument"
      bodyJson <- o .: "body"
      body <- decodeExpr bodyJson
      pure (Abs { argument, body })

    "App" -> do
      absJson <- o .: "abstraction"
      abstraction <- decodeExpr absJson
      argJson <- o .: "argument"
      argument <- decodeExpr argJson
      pure (App { abstraction, argument })

    "Case" -> do
      scrutineesJson <- o .: "caseExpressions"
      caseExpressions <- traverse decodeExpr scrutineesJson
      altsJson <- o .: "caseAlternatives"
      caseAlternatives <- traverse decodeCaseAlternative altsJson
      pure (Case { caseExpressions, caseAlternatives })

    "Let" -> do
      bindsJson <- o .: "binds"
      binds <- traverse decodeBind bindsJson
      exprJson <- o .: "expression"
      expression <- decodeExpr exprJson
      pure (Let { binds, expression })

    other ->
      Left (TypeMismatch ("unknown expression type: " <> other))

-- | One decoder for both positions the compiler uses literals in: the inner
-- | decoder is `decodeExpr` inside an expression and `decodeBinder` inside a
-- | `LiteralBinder`.
decodeLiteral :: forall a. (Json -> Decoded a) -> Json -> Decoded (Literal a)
decodeLiteral inner json = do
  o <- decodeJson json
  literalType <- o .: "literalType"
  case literalType of
    "IntLiteral" -> LitInt <$> o .: "value"
    "NumberLiteral" -> LitNumber <$> o .: "value"
    "StringLiteral" -> LitString <$> o .: "value"
    "BooleanLiteral" -> LitBoolean <$> o .: "value"

    -- Aeson encodes Char as a one-character JSON string. Kept as String
    -- because PureScript's Char is a UTF-16 code unit while the Zig side wants
    -- a codepoint; converting is the emitter's problem, not the decoder's.
    "CharLiteral" -> LitChar <$> o .: "value"

    "ArrayLiteral" -> do
      itemsJson <- o .: "value"
      LitArray <$> traverse inner itemsJson

    -- NOT a JSON object: an array of [key, value] pairs.
    "ObjectLiteral" -> do
      pairsJson <- o .: "value"
      LitObject <$> traverse (decodePair inner) pairsJson

    other ->
      Left (TypeMismatch ("unknown literalType: " <> other))

-- | `[key, value]` -- a two-element heterogeneous JSON array, produced by
-- | Aeson encoding a Haskell tuple.
decodePair :: forall a. (Json -> Decoded a) -> Json -> Decoded { key :: String, value :: a }
decodePair inner json = do
  elements <- decodeJson json
  case elements of
    [ keyJson, valueJson ] -> do
      key <- decodeJson keyJson
      value <- inner valueJson
      pure { key, value }
    _ ->
      Left (TypeMismatch "expected a two-element [key, value] array")

decodeCaseAlternative :: Json -> Decoded CaseAlternative
decodeCaseAlternative json = do
  o <- decodeJson json
  bindersJson <- o .: "binders"
  binders <- traverse decodeBinder bindersJson
  isGuarded <- o .: "isGuarded"
  result <-
    if isGuarded then do
      guardsJson <- o .: "expressions"
      Guarded <$> traverse decodeGuard guardsJson
    else do
      exprJson <- o .: "expression"
      Unconditional <$> decodeExpr exprJson
  pure { binders, result }

decodeGuard :: Json -> Decoded { guard :: Expr, expression :: Expr }
decodeGuard json = do
  o <- decodeJson json
  guardJson <- o .: "guard"
  guardExpr <- decodeExpr guardJson
  exprJson <- o .: "expression"
  expression <- decodeExpr exprJson
  pure { guard: guardExpr, expression }

decodeBinder :: Json -> Decoded Binder
decodeBinder json = do
  o <- decodeJson json
  binderType <- o .: "binderType"
  case binderType of
    "NullBinder" ->
      pure NullBinder

    "VarBinder" ->
      VarBinder <$> o .: "identifier"

    "LiteralBinder" -> do
      literalJson <- o .: "literal"
      LiteralBinder <$> decodeLiteral decodeBinder literalJson

    "NamedBinder" -> do
      identifier <- o .: "identifier"
      binderJson <- o .: "binder"
      inner <- decodeBinder binderJson
      pure (NamedBinder identifier inner)

    -- Qualified here, unlike the bare strings in a Constructor expression.
    "ConstructorBinder" -> do
      typeNameJson <- o .: "typeName"
      typeName <- decodeQualified typeNameJson
      constructorNameJson <- o .: "constructorName"
      constructorName <- decodeQualified constructorNameJson
      bindersJson <- o .: "binders"
      binders <- traverse decodeBinder bindersJson
      pure (ConstructorBinder { typeName, constructorName, binders })

    other ->
      Left (TypeMismatch ("unknown binderType: " <> other))
