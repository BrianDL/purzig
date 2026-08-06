-- | PureScript identifier -> legal Zig identifier.
-- |
-- | CoreFn identifiers are arbitrary strings, so everything is wrapped in Zig's
-- | @"..." quoting. The role prefixes ("ps.", "v.", "mod.") contain a dot,
-- | which cannot appear in an unquoted Zig identifier -- so a generated name
-- | can never collide with a Zig keyword, with std, or with `main`.
module Zig.Ident
  ( topLevel
  , lifted
  , local
  , moduleRef
  , moduleFile
  , stringLit
  ) where

import Prelude

import Data.String (replaceAll)
import Data.String.Pattern (Pattern(..), Replacement(..))

-- | A top-level binding: `greet` -> @"ps.greet"
topLevel :: String -> String
topLevel name = quoted ("ps." <> name)

-- | A lifted lambda or constructor step. The suffix already encodes position,
-- | e.g. lifted "greet.lam0" -> @"ps.greet.lam0"
lifted :: String -> String
lifted name = quoted ("ps." <> name)

-- | A local binder: `name` -> @"v.name"
local :: String -> String
local name = quoted ("v." <> name)

-- | An imported module, bound at the top of the file: @"mod.Zig.Prelude"
moduleRef :: String -> String
moduleRef name = quoted ("mod." <> name)

-- | The generated filename for a module. Dots are legal in filenames, which
-- | keeps the mapping trivial and the output directory flat.
moduleFile :: String -> String
moduleFile name = name <> ".zig"

quoted :: String -> String
quoted s = "@\"" <> escape s <> "\""

-- | A Zig string literal, quotes included.
stringLit :: String -> String
stringLit s = "\"" <> escape s <> "\""

-- | Backslash first, or it would double-escape the escapes.
escape :: String -> String
escape =
  replaceAll (Pattern "\\") (Replacement "\\\\")
    >>> replaceAll (Pattern "\"") (Replacement "\\\"")
    >>> replaceAll (Pattern "\n") (Replacement "\\n")
    >>> replaceAll (Pattern "\r") (Replacement "\\r")
    >>> replaceAll (Pattern "\t") (Replacement "\\t")
