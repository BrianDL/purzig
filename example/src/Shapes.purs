-- | The typed-ABI fixture (issue #33).
-- |
-- | Six functions, one per shape the manifest can publish, plus the four
-- | columns of the shape vocabulary they exercise:
-- |
-- |     fInt :: Int -> Int                                    "int"
-- |     fStr :: String -> String                              "string"
-- |     fArr :: Array Int -> Array Int                        {"array": "int"}
-- |     fRec :: { a :: Int, b :: String } -> Int              {"record": {...}}
-- |     fAdt :: Shape -> Int                                  {"adt": {...}}
-- |     fHo  :: (Int -> Int) -> Int                           refused, higher-order
-- |
-- | `zig build test-exports` asserts all six rows in
-- | `example/output-zig/manifest.json`, so this file is the input to that gate.
-- |
-- | **Prelude only, and a local ADT.** This workspace's `spago.yaml` is not
-- | touched by this fixture: importing `arrays`, `maybe` or
-- | `foldable-traversable` here would either need a dependency it does not
-- | declare or make the whole spago step fail, which would take every other
-- | gate down with it. `Array` comes from `Prim`, and `Shape` is declared here
-- | so the `adt` shape has a constructor list to point at.
-- |
-- | Nothing in `Main` imports this module. `spago build` compiles every module
-- | in `src/`, so the manifest gets its rows without `main`'s output changing:
-- | `test-e2e` still sees exactly `Hello, Zig`.
module Shapes where

import Prelude

-- | Two constructors, one type argument to `Circle`/`Square`: the ADT shape is
-- | `{"adt": {"module": "Shapes", "name": "Shape"}}` because the type itself
-- | takes no parameters.
data Shape
  = Circle Number
  | Square Number

fInt :: Int -> Int
fInt x = x

fStr :: String -> String
fStr s = s

fArr :: Array Int -> Array Int
fArr xs = xs

fRec :: { a :: Int, b :: String } -> Int
fRec r = r.a

fAdt :: Shape -> Int
fAdt _ = 0

-- | A function as an ARGUMENT. The vocabulary has no shape for a closure, so
-- | the row must refuse this position by name rather than pretend a `Value`
-- | of unknown shape is encodable.
fHo :: (Int -> Int) -> Int
fHo _ = 0
