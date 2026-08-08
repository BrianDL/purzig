-- FILE: purs/example/src/Scratch.purs
-- | Scratchpad for exercising codegen paths the fixture `Main.purs` does not
-- | reach. Nothing here is a test in its own right; it earns its keep by being
-- | reachable from `main`, so `zig build run` compiles and executes it.
-- |
-- | On the real Prelude, so type-class dictionaries, arithmetic, `show` and
-- | `==` are all in play alongside the hand-rolled data types.
-- |
-- | `target` returns its argument unchanged when every check holds, so
-- | `test-e2e`'s assertion on `Hello, Zig` doubles as the assertion for
-- | everything below. A failure prints `Hello, <label>` naming the first check
-- | that did not hold.
module Scratch (target) where

import Prelude

-- Constructors at arity 0, 1 and 2.
data Shape
  = Blank
  | Circle Int
  | Rect Int Int

-- A wrapper, so a `ConstructorBinder` can nest inside another.
data Box = Box Shape

-- Guards that fall through to the next alternative (the first `Rect` has no
-- `otherwise`), a `NamedBinder`, and an irrefutable catch-all that makes the
-- trailing `@panic` dead.
area :: Shape -> Int
area = case _ of
  Rect w h | w == h -> w * w
  Rect w h -> w * h
  whole@(Circle _) -> radius whole * 3
  _ -> 0

radius :: Shape -> Int
radius (Circle r) = r
radius _ = 0

-- Nested `ConstructorBinder`.
unbox :: Box -> Int
unbox (Box (Rect w h)) = w + h
unbox (Box other) = area other

-- String `LiteralBinder`.
label :: String -> Int
label "circle" = 1
label "rect" = 2
label _ = 0

-- Int `LiteralBinder`.
step :: Int -> Int
step 0 = 10
step 1 = 20
step n = n

-- Array `LiteralBinder` at three lengths, including empty. Array literals are
-- language-level, so this needs no `Data.Array`.
total :: Array Int -> Int
total [] = 0
total [ a ] = a
total [ a, b ] = a + b
total _ = (-1)

-- Record literal with a runtime field, record update, and two accessors.
describe :: Int -> String
describe n = (base { size = n * 2 }).name <> show (base { size = n }).size
  where
  base = { name: "shape", size: n }

-- Recursive `let` whose member captures an enclosing local (`n`). Three
-- increments, then the captured `n`, so the result is `3 + n`.
countDown :: Int -> Int
countDown n =
  let
    go acc k = if k == 0 then acc + n else go (acc + 1) (k - 1)
  in
    go 0 3

-- | `check name ok rest` yields `name` when `ok` is false, otherwise defers to
-- | `rest`. Right-nested, so the first failure wins. Evaluation is strict, so
-- | every check still runs -- a panic instead of a label localises just as
-- | well.
check :: String -> Boolean -> String -> String
check name ok rest = if ok then rest else name

target :: String -> String
target n = if failure == "" then n else failure
  where
  failure :: String
  failure =
    check "areaSquare" (area (Rect 3 3) == 9)
      $ check "areaRect" (area (Rect 2 5) == 10)
      $ check "areaCircle" (area (Circle 4) == 12)
      $ check "areaBlank" (area Blank == 0)
      $ check "unboxRect" (unbox (Box (Rect 1 2)) == 3)
      $ check "unboxBlank" (unbox (Box Blank) == 0)
      $ check "labelCircle" (label "circle" == 1)
      $ check "labelRect" (label "rect" == 2)
      $ check "labelOther" (label "square" == 0)
      $ check "step0" (step 0 == 10)
      $ check "step1" (step 1 == 20)
      $ check "stepN" (step 7 == 7)
      $ check "totalEmpty" (total [] == 0)
      $ check "totalOne" (total [ 5 ] == 5)
      $ check "totalTwo" (total [ 2, 3 ] == 5)
      $ check "totalMany" (total [ 1, 2, 3 ] == (-1))
      $ check "countDown" (countDown 4 == 7)
      $ check "describe" (describe 5 == "shape5")
      $ ""
