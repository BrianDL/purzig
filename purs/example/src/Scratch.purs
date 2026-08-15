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

import Control.Lazy (fix)
import Data.Int as Int
import Data.Int.Bits (complement, shl, shr, zshr, (.&.), (.^.), (.|.))
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String.CodeUnits as SCU
import Data.String.Common as SC
import Data.String.Pattern (Pattern(..), Replacement(..))
import Data.String.Unsafe as SU
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

-- | `Control.Lazy.fix` -- the reason the laziness fallback exists. The `Lazy`
-- | instance for functions is `defer f = \\x -> f unit x`, and `fix f = go
-- | where go = defer \\_ -> f go` is a recursive `let` whose member is NOT a
-- | function, so it goes through `rt.newLazy`/`setLazyInit`/`forceLazy` rather
-- | than the lifted-closure path. Without a reference here, `Control.Lazy.zig`
-- | is emitted but never compiled by Zig.
viaFix :: Int -> Int
viaFix = fix \recur n -> if n == 0 then 0 else recur (n - 1) + 1

-- | DEPTH TEST, top-level. A self tail call at uniform arity, so the analysis
-- | classifies it as a loop and it becomes a Zig `while` rather than a chain of
-- | `rt.apply` frames. Without TCO this overflows the stack long before a
-- | million iterations; with it, it returns.
-- |
-- | This is the only check here that fails by crashing rather than by returning
-- | a wrong label, since a stack overflow is not catchable.
deepSum :: Int -> Int -> Int
deepSum k acc = if k == 0 then acc else deepSum (k - 1) (acc + 1)

-- | DEPTH TEST, `where`-bound. Same shape, but the recursive function is a
-- | `LetRec` member capturing an enclosing variable (`bump`), which is the
-- | idiom most real PureScript recursion uses. Exercises the local-loop path
-- | and its captured `env`.
deepCount :: Int -> Int
deepCount start = go start 0
  where
  bump = 1

  go k acc = if k == 0 then acc else go (k - 1) (acc + bump)

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
        $ check "viaFix" (viaFix 5 == 5)
        $ check "deepSum" (deepSum 1000000 0 == 1000000)
        $ check "deepCount" (deepCount 1000000 == 1000000)
        $ check "sumTo" (s == 10)
        $ check "foreachE" (joined == "abc")
        $ check "whileE" (loops == 3)
        $ check "caught" (recovered == "Error/boom")
        $ check "uncaught" (clean == "clean")
        $ check "notResumed" (witness == 0)

        -- Data.Int. `intRoundNegHalf` is the interesting one: `Math.round`
        -- breaks ties towards positive infinity, so this is -2 and not the -3
        -- that Zig's `@round` would give.
        $ check "intToNumber" (Int.toNumber 3 == 3.0)
        $ check "intFloor" (Int.floor 3.7 == 3)
        $ check "intCeil" (Int.ceil 3.2 == 4)
        $ check "intRoundHalf" (Int.round 2.5 == 3)
        $ check "intRoundNegHalf" (Int.round (-2.5) == (-2))
        $ check "intQuot" (Int.quot 7 2 == 3)
        $ check "intQuotNeg" (Int.quot (-7) 2 == (-3))
        $ check "intQuotZero" (Int.quot 7 0 == 0)
        $ check "intRem" (Int.rem 7 2 == 1)
        $ check "intPow" (Int.pow 2 10 == 1024)
        $ check "intHex" (Int.toStringAs Int.hexadecimal 255 == "ff")
        $ check "intBinary" (Int.toStringAs Int.binary (-5) == "-101")
        $ check "intFromString" (Int.fromString "42" == Just 42)
        $ check "intFromStringSigned" (Int.fromString "-42" == Just (-42))
        $ check "intFromStringBad" (Int.fromString "12x" == Nothing)
        $ check "intFromStringBig" (Int.fromString "99999999999" == Nothing)
        $ check "intFromNumber" (Int.fromNumber 3.0 == Just 3)
        $ check "intFromNumberFrac" (Int.fromNumber 3.5 == Nothing)

        -- Data.Int.Bits. The first four are rewritten into PrimOps and never
        -- reach the FFI; the shifts do reach it, and `bitsShlMask` is the
        -- JavaScript five-bit masking rule that keeps them out of the PrimOp
        -- table.
        $ check "bitsAnd" ((6 .&. 3) == 2)
        $ check "bitsOr" ((6 .|. 3) == 7)
        $ check "bitsXor" ((6 .^. 3) == 5)
        $ check "bitsComplement" (complement 0 == (-1))
        $ check "bitsShl" (shl 1 4 == 16)
        $ check "bitsShlMask" (shl 1 32 == 1)
        $ check "bitsShr" (shr (-16) 2 == (-4))
        $ check "bitsZshr" (zshr (-1) 28 == 15)

        -- Data.Number. `numMaxNaN` and `numSignNegZero` are the two places
        -- Zig's builtin disagrees with `Math`, and `numFromStringPrefix` is
        -- `parseFloat` reading the longest valid prefix.
        $ check "numSqrt" (Number.sqrt 9.0 == 3.0)
        $ check "numRemainder" (Number.remainder 7.0 2.0 == 1.0)
        $ check "numSign" (Number.sign (-3.0) == (-1.0))
        $ check "numSignNegZero" (Number.sign 0.0 == 0.0)
        $ check "numMax" (Number.max 1.0 2.0 == 2.0)
        $ check "numMaxNaN" (Number.isNaN (Number.max Number.nan 1.0))
        $ check "numIsFinite" (not (Number.isFinite Number.infinity))
        $ check "numFromString" (Number.fromString "3.5" == Just 3.5)
        $ check "numFromStringPrefix" (Number.fromString "2.5abc" == Just 2.5)
        $ check "numFromStringInf" (Number.fromString "Infinity" == Nothing)
        $ check "numFromStringBad" (Number.fromString "x" == Nothing)

        -- Data.String.CodeUnits. `cuAstral` pins the one place this backend
        -- disagrees with the JavaScript one: a code point above the BMP counts
        -- as ONE unit here and as a surrogate pair there.
        $ check "cuLength" (SCU.length "abc" == 3)
        $ check "cuTake" (SCU.take 2 "abcd" == "ab")
        $ check "cuTakeOver" (SCU.take 9 "ab" == "ab")
        $ check "cuTakeNeg" (SCU.take (-1) "ab" == "")
        $ check "cuDrop" (SCU.drop 2 "abcd" == "cd")
        $ check "cuSlice" (SCU.slice 1 3 "abcde" == "bc")
        $ check "cuSliceNeg" (SCU.slice 0 (-1) "abcd" == "abc")
        $ check "cuSliceEmpty" (SCU.slice 3 1 "abcd" == "")
        $ check "cuCharAt" (SCU.charAt 1 "abc" == Just 'b')
        $ check "cuCharAtOver" (SCU.charAt 9 "abc" == Nothing)
        $ check "cuToChar" (SCU.toChar "a" == Just 'a')
        $ check "cuToCharLong" (SCU.toChar "ab" == Nothing)
        $ check "cuSingleton" (SCU.singleton 'x' == "x")
        $ check "cuFromCharArray" (SCU.fromCharArray [ 'a', 'b' ] == "ab")
        $ check "cuToCharArray" (SCU.toCharArray "ab" == [ 'a', 'b' ])
        $ check "cuCountPrefix" (SCU.countPrefix (_ == 'a') "aab" == 2)
        $ check "cuIndexOf" (SCU.indexOf (Pattern "b") "abc" == Just 1)
        $ check "cuIndexOfMiss" (SCU.indexOf (Pattern "z") "abc" == Nothing)
        $ check "cuIndexOfFrom" (SCU.indexOf' (Pattern "a") 1 "aba" == Just 2)
        $ check "cuLastIndexOf" (SCU.lastIndexOf (Pattern "a") "aba" == Just 2)
        $ check "cuLastIndexOfFrom" (SCU.lastIndexOf' (Pattern "a") 1 "aba" == Just 0)
        $ check "cuSplitAtBefore" ((SCU.splitAt 2 "abcd").before == "ab")
        $ check "cuSplitAtAfter" ((SCU.splitAt 2 "abcd").after == "cd")
        $ check "cuUnsafeCharAt" (SU.charAt 1 "abc" == 'b')
        $ check "cuAccented" (SCU.length "clé" == 3)
        $ check "cuRoundTrip" (SCU.fromCharArray (SCU.toCharArray "clé") == "clé")

        -- Data.String.Common. The two empty-pattern checks are transcribed
        -- JavaScript behaviour, not an accident.
        $ check "scToUpper" (SC.toUpper "abc" == "ABC")
        $ check "scToLower" (SC.toLower "ABC" == "abc")
        $ check "scTrim" (SC.trim "  ab  " == "ab")
        $ check "scReplace" (SC.replace (Pattern "a") (Replacement "X") "aba" == "Xba")
        $ check "scReplaceMiss" (SC.replace (Pattern "z") (Replacement "X") "aba" == "aba")
        $ check "scReplaceEmpty" (SC.replace (Pattern "") (Replacement "X") "ab" == "Xab")
        $ check "scReplaceAll" (SC.replaceAll (Pattern "a") (Replacement "X") "aba" == "XbX")
        $ check "scReplaceAllEmpty" (SC.replaceAll (Pattern "") (Replacement "X") "ab" == "XaXbX")
        $ check "scSplit" (SC.split (Pattern ",") "a,b" == [ "a", "b" ])
        $ check "scSplitMiss" (SC.split (Pattern ",") "ab" == [ "ab" ])
        $ check "scSplitChars" (SC.split (Pattern "") "ab" == [ "a", "b" ])
        $ check "scJoinWith" (SC.joinWith "-" [ "a", "b" ] == "a-b")
        $ ""
  pure (if failure == "" then n else failure)
