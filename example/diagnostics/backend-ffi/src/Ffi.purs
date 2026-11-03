-- Fixture for issue #31, case 2: a backend failure.
--
-- A foreign import with no Zig FFI beside it: `src/Ffi.zig` is deliberately
-- absent. The purzig backend names the problem (`MISSING FFI`) and exits 0, so
-- before this fixture existed the build carried on and Zig later failed on an
-- import inside generated code. `zig build test-diagnostics` asserts the
-- failure text contains the backend's own message.
module Ffi where

foreign import bad :: Int
