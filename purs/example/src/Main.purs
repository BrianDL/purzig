-- | The v0 target program.
-- |
-- | Deliberately minimal: one lambda, one saturated application, two foreign
-- | calls, one Effect. It exercises Lit, Var, Abs and App -- and nothing else.
-- | No Case, no records, no ADTs, which are exactly the parts of the code
-- | generator that are not written yet.
module Main where

import Zig.Prelude (Effect, Unit, concatString, log)

greet :: String -> String
greet name = concatString "Hello, " name

main :: Effect Unit
main = log (greet "test")
