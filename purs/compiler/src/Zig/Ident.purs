-- | PureScript identifier -> legal Zig identifier.
-- |
-- | Needed because CoreFn identifiers are arbitrary strings. Zig's escape hatch
-- | for awkward names is the @"..." syntax, which handles most cases without
-- | any mangling scheme at all -- likely the simplest correct answer for v0.
-- |
-- | STATUS: stub.
module Zig.Ident where

import Prelude

-- | Wrap an arbitrary string so it is a legal Zig identifier.
escape :: String -> String
escape s = "@\"" <> s <> "\""
