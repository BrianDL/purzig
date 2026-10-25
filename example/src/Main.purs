-- FILE: purs/example/src/Main.purs
-- | The fixture whose stdout `zig build test-e2e` asserts. Keep it printing
-- | exactly `Hello, Zig`; put new codegen exercises in `Scratch.purs`, which
-- | this module imports so they are actually reachable.
-- |
-- | On the real `Effect` and `Effect.Console`. The `do` block desugars to
-- | `bind`/`discard` through the `Monad Effect` instance, whose `bindE` is a
-- | foreign import, so control flow here runs through the Effect FFI.
module Main where

import Prelude

import Effect (Effect)
import Effect.Console (log)
import Scratch (target)

greet :: String -> String
greet name = "Hello, " <> name

main :: Effect Unit
main = do
  result <- target "Zig"
  log (greet result)

-- | Reached from Zig rather than from `main`: `example/abi/abi_probe.zig` calls
-- | it through `rt.abi.callBytes` and `zig build test-abi` asserts the result.
-- | It lives in `Main` on purpose -- `addLibrary` exposes only the module named
-- | by `main_module`, so a separate module would need a second module handle.
-- | `main`'s output is unaffected.
echo :: String -> String
echo s = s <> "!"
