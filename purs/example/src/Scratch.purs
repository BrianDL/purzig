-- | Scratchpad for exercising codegen paths the fixture `Main.purs` does not
-- | reach. Nothing here is a test in its own right; it earns its keep by being
-- | reachable from `main`, so `zig build run` compiles and executes it.
-- |
-- | Covers: record literal with a runtime field, record update, accessor,
-- | recursive `let` capturing an enclosing local, and every `Case` binder
-- | form except array and numeric literals: constructor, named, string
-- | literal, nested, and guards.
module Scratch (target) where

data Shape
  = Blank
  | Tagged String
  | Pair Shape Shape

target :: String -> String
target n = (base { name = describe (Pair (Tagged n) Blank) }).name
  where
  base = { name: "?", tag: pick false }

  -- Recursive AND closes over `n`, so the group's environment is non-empty.
  pick :: Boolean -> String
  pick b = if b then n else pick true

  -- ConstructorBinder, nested binders, NamedBinder, a string LiteralBinder,
  -- a guard, and a catch-all.
  describe :: Shape -> String
  describe (Pair (Tagged "skip") _) = "skipped"
  describe (Pair whole@(Tagged s) _)
    | isBlank whole = "impossible"
    | true = s
  describe (Tagged s) = s
  describe _ = "blank"

  isBlank :: Shape -> Boolean
  isBlank Blank = true
  isBlank _ = false
