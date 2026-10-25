-- | The `test-abi-multi` fixture's module (issue #21). Deliberately NOT `Main`:
-- | a real consumer's exports are spread over several modules, so the proof
-- | that `addLibrary.module("Api")` reaches one by name has to use a module
-- | that is not the entry.
-- |
-- | `pair` is `String -> String -> String`, i.e. a TWO-argument function, which
-- | `callBytes` could not invoke at all: `example/abi/abi_multi.zig` calls it
-- | through `rt.abi.call` with two buffers, in order, and
-- | `zig build test-abi-multi` asserts the reply is exactly `abcd`.
-- |
-- | Nothing here touches `Main`, so `main`'s `Hello, Zig` output is unaffected.
module Api where

import Prelude

pair :: String -> String -> String
pair a b = a <> b
