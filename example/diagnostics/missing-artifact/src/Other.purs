-- Fixture for issue #31, case 3: a missing artifact.
--
-- The module here is `Other`, while `build.zig` asks purzig for `Main`.
-- `spago build` succeeds and the backend writes output-zig/Other.zig, so the
-- only way to notice is to look for the file the build is about to compile.
module Other where

data Other = Other
