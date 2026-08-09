-- FILE: purs/example/src/Scratch.purs
-- | Scratchpad for exercising codegen paths the fixture `Main.purs` does not
-- | reach. Nothing here is a test in its own right; it earns its keep by being
-- | reachable from `main`, so `zig build run` compiles and executes it.
-- |
-- | `target` returns its argument unchanged when every check holds, so
-- | `test-e2e`'s assertion on `Hello, Zig` doubles as the assertion for
-- | everything below. A failure prints `Hello, <label>` naming the first check
-- | that did not hold.
-- |
-- | `target` is now an `Effect`, because `Ref` and `catchException` are both
-- | effectful and there is no way to observe them from pure code without
-- | `unsafePerformEffect`.
module Scratch (target) where

import Prelude

import Effect (Effect, forE, foreachE, whileE)
import Effect.Exception (catchException, error, message, name, throwException)
import Effect.Ref as Ref

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

-- Array `LiteralBinder` at three lengths, including empty.
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

-- Recursive `let` whose member captures an enclosing local. Three increments,
-- then the captured `n`, so the result is `3 + n`.
countDown :: Int -> Int
countDown n =
  let
    go acc k = if k == 0 then acc + n else go (acc + 1) (k - 1)
  in
    go 0 3

-- | `Ref` plus `forE`: sum 1..4 by mutation. Exercises `_new`, `read`,
-- | `modify_` (which goes through `modifyImpl` and its `{ state, value }`
-- | record) and the loop combinator.
sumTo :: Int -> Effect Int
sumTo n = do
  acc <- Ref.new 0
  forE 0 n \i -> Ref.modify_ (\running -> running + i + 1) acc
  Ref.read acc

-- | `foreachE` over an array literal, accumulating through a `Ref.write`.
concatAll :: Array String -> Effect String
concatAll xs = do
  acc <- Ref.new ""
  foreachE xs \x -> do
    current <- Ref.read acc
    Ref.write (current <> x) acc
  Ref.read acc

-- | `whileE`: decrement until zero, counting iterations.
countWhile :: Int -> Effect Int
countWhile start = do
  remaining <- Ref.new start
  iterations <- Ref.new 0
  whileE (map (_ > 0) (Ref.read remaining)) do
    Ref.modify_ (_ - 1) remaining
    Ref.modify_ (_ + 1) iterations
  Ref.read iterations

-- | A thrown exception unwinds through an intervening `Ref` write and is
-- | recovered by the handler, which reads the message back off the `Error`.
caught :: Effect String
caught = catchException (\e -> pure (name e <> "/" <> message e)) do
  _ <- throwException (error "boom")
  pure "not reached"

-- | The handler is not entered when nothing throws.
uncaught :: Effect String
uncaught = catchException (\_ -> pure "handler") (pure "clean")

-- | An effect written after a throw must not run. Uses a `Ref` as the witness.
notResumed :: Effect Int
notResumed = do
  witness <- Ref.new 0
  _ <- catchException (\_ -> pure unit) do
    _ <- throwException (error "stop")
    Ref.write 1 witness
  Ref.read witness

-- | `check name ok rest` yields `name` when `ok` is false, otherwise defers to
-- | `rest`. Right-nested, so the first failure wins.
check :: String -> Boolean -> String -> String
check lbl ok rest = if ok then rest else lbl

target :: String -> Effect String
target n = do
  s <- sumTo 4
  joined <- concatAll [ "a", "b", "c" ]
  loops <- countWhile 3
  recovered <- caught
  clean <- uncaught
  witness <- notResumed
  let
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
        $ check "sumTo" (s == 10)
        $ check "foreachE" (joined == "abc")
        $ check "whileE" (loops == 3)
        $ check "caught" (recovered == "Error/boom")
        $ check "uncaught" (clean == "clean")
        $ check "notResumed" (witness == 0)
        $ ""
  pure (if failure == "" then n else failure)
