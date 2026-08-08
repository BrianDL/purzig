-- | The CoreFn AST, mirroring the compiler's `Language.PureScript.CoreFn.ToJSON`.
-- |
-- | See docs/corefn-schema.md for the JSON shapes these correspond to. The
-- | field names here deliberately match the JSON keys, so the decoder reads as
-- | a transcription rather than a translation.
-- |
-- | Annotations are dropped, and metadata all but one flag: `IsNewtype` on a
-- | ConstructorBinder is required for correctness, not optimisation, because
-- | the compiler erases newtype wrappers on the construction side.
-- | `IsConstructor`/`ProductType` remain unused and become interesting only
-- | once `Case` is optimised.
module CoreFn.Types where

-- import Prelude

import Data.Maybe (Maybe, isNothing)

-- | Dotted, e.g. "Data.Maybe". The JSON carries an array of segments; the
-- | decoder joins them.
type ModuleName = String

-- | CoreFn identifiers are ARBITRARY STRINGS, not PureScript identifiers --
-- | type class desugaring concatenates printed types into names. Anything
-- | emitting these into Zig must escape them. See Zig.Ident.
type Ident = String

-- | A name that may or may not be module-qualified. `moduleName` is absent in
-- | the JSON for locals, and its presence is the only local/global test.
type Qualified =
  { moduleName :: Maybe ModuleName
  , identifier :: String
  }

type Module =
  { name :: ModuleName
  , path :: String
  , imports :: Array ModuleName
  , exports :: Array Ident
  , foreigns :: Array Ident
  , decls :: Array Bind
  , builtWith :: String
  }

data Bind
  = NonRec Ident Expr
  | Rec (Array { identifier :: Ident, expression :: Expr })

-- | Parameterised because the compiler reuses one encoder for literals in
-- | expressions (payload `Expr`) and in binders (payload `Binder`).
data Literal a
  = LitInt Int
  | LitNumber Number
  | LitString String
  | LitChar String
  | LitBoolean Boolean
  | LitArray (Array a)
  | LitObject (Array { key :: String, value :: a })

data Expr
  = Var Qualified
  | Lit (Literal Expr)
  | Constructor
      { typeName :: String
      , constructorName :: String
      , fieldNames :: Array Ident
      }
  | Accessor { fieldName :: String, expression :: Expr }
  | ObjectUpdate
      { expression :: Expr
      , updates :: Array { key :: String, value :: Expr }
      }
  | Abs { argument :: Ident, body :: Expr }
  | App { abstraction :: Expr, argument :: Expr }
  | Case
      { caseExpressions :: Array Expr
      , caseAlternatives :: Array CaseAlternative
      }
  | Let { binds :: Array Bind, expression :: Expr }

type CaseAlternative =
  { binders :: Array Binder
  , result :: Result
  }

data Result
  = Unconditional Expr
  | Guarded (Array { guard :: Expr, expression :: Expr })

data Binder
  = NullBinder
  | VarBinder Ident
  | LiteralBinder (Literal Binder)
  | NamedBinder Ident Binder
  | ConstructorBinder
      { typeName :: Qualified
      , constructorName :: Qualified
      , binders :: Array Binder
      -- | True when the annotation carries `meta: IsNewtype`.
      -- |
      -- | This is NOT an optimisation hint. The compiler emits a newtype
      -- | constructor as the identity function, so the value reaching this
      -- | binder was never wrapped and testing its tag can only fail. Single-
      -- | method type classes are newtypes, which makes `Eq`, `Ord`, `Show`
      -- | and most of the Prelude depend on getting this right.
      , isNewtype :: Boolean
      }

-- | Convenience for the emitter: a `Var` with no module qualifier is a
-- | reference to a local binder, and compiles to a plain Zig identifier rather
-- | than a call.
isLocal :: Qualified -> Boolean
isLocal q = isNothing q.moduleName
