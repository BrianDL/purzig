-- | CoreFn.Types -> Zig source text.
-- |
-- | STATUS: not implemented; Main.purs emits a fixed stub instead.
-- |
-- | The emission contract, which the runtime is built to satisfy:
-- |
-- |   Abs x e      ->  a closure with an env struct capturing the free vars
-- |   App f a      ->  rt.apply(<f>, <a>)
-- |   Lit          ->  rt.Value.mkInt / mkString / ...
-- |   Accessor k e ->  <e>.field("k")
-- |   Constructor  ->  rt.Value.mkData("Tag", &.{ ... })
-- |   Case         ->  a switch over the .data tag plus nested ifs
module Zig.Emit where

-- import Prelude
