-- | The minimum vocabulary needed to write a program this backend can compile.
-- |
-- | Each `foreign import` here has a matching `pub const @"ps.<name>"` in
-- | ffi/zig-prelude/prim.zig. Nothing checks that correspondence yet; a
-- | mismatch shows up as a Zig compile error naming the missing declaration,
-- | which is at least a decent error message.
module Zig.Prelude
  ( Unit
  , unit
  , Effect
  , concatString
  , log
  , pureUnit
  ) where

-- | `Effect` must be a type constructor of kind `Type -> Type`, and it has no
-- | runtime representation of its own -- an `Effect a` is a thunk. Declaring it
-- | foreign keeps the compiler from expecting a data representation.
foreign import data Effect :: Type -> Type

data Unit = Unit

unit :: Unit
unit = Unit

foreign import concatString :: String -> String -> String

foreign import log :: String -> Effect Unit

foreign import pureUnit :: Effect Unit
