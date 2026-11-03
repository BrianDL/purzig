module Main where

-- Fixture for issue #31, case 1: a type-check failure.
--
-- `arrays` is NOT declared in this project's `spago.yaml`, so purs cannot find
-- `Data.Array` and reports ModuleNotFound at the line and column of the import
-- below. `zig build test-diagnostics` asserts the build fails AND that its
-- output contains the module name, this file and that line:column.
import Data.Array (cons, uncons)
