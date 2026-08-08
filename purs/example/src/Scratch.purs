-- FILE: purs/example/src/Scratch.purs
-- | Scratchpad for exercising codegen paths the fixture `Main.purs` does not
-- | reach. Nothing here is a test in its own right; it earns its keep by being
-- | reachable from `main`, so `zig build run` compiles and executes it.
-- |
-- | Now on the real Prelude, so type-class dictionaries, arithmetic and `show`
-- | are all in play.
module Scratch (target) where

import Prelude

target :: String -> String
target n = if 1 + 1 == 2 then n else show (3 * 4)
