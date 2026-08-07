-- | Scratchpad for exercising codegen paths the fixture `Main.purs` does not
-- | reach. Nothing here is a test in its own right; it earns its keep by being
-- | reachable from `main`, so `zig build run` compiles and executes it.
-- |
-- | Covers: a record literal holding a runtime-computed field, a record update
-- | over it, an accessor, a recursive `let` capturing an enclosing local, and
-- | the `Case` that `if` desugars to.
module Scratch (target) where

target :: String -> String
target n = (base { name = pick false }).name
  where
  base = { name: "?", tag: n }

  -- Recursive AND closes over `n`, so the group's environment is non-empty.
  -- Terminates on the second call. `if` is the only conditional available
  -- without a Prelude: no Eq, no arithmetic.
  pick :: Boolean -> String
  pick b = if b then n else pick true
