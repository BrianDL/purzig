-- | Entry point for the PureScript -> Zig backend.
-- |
-- | Spago invokes this with the project root as its working directory, after
-- | running `purs compile --codegen corefn`. The contract is entirely
-- | filesystem-based: read ./output/<Module.Name>/corefn.json, write
-- | ./output-zig/<Module.Name>.zig. No arguments, no stdin.
-- |
-- | A module that fails to emit is reported and skipped rather than aborting
-- | the run, so one unsupported construct in a library does not hide progress
-- | on everything else.
-- |
-- | Foreign imports follow the convention every other backend uses: the Zig
-- | lives beside the `.purs` source (`Foo/Bar.purs` pairs with `Foo/Bar.zig`,
-- | as it pairs with `Foo/Bar.js` for JavaScript and `Foo/Bar.erl` for purerl)
-- | and is copied into the output directory. `modulePath` in corefn.json is
-- | what makes that possible -- it points at the original source, wherever the
-- | package was unpacked. A package therefore ships its own FFI and needs no
-- | central registration.
module Main where

import Prelude

import CoreFn.Decode (decodeModule)
import CoreFn.Types (Module)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (filter, length, null, sort)
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.String as String
import Effect (Effect)
import Effect.Console (log)
import Node.Encoding (Encoding(..))
import Node.FS.Sync (exists, mkdir, readTextFile, readdir, writeTextFile)
import Zig.Emit (emitModule)
import Zig.Ident (ffiFile, moduleFile)

corefnDir :: String
corefnDir = "output"

-- | Deliberately NOT `output/`: keeping generated Zig separate means the
-- | JavaScript backend and this one can coexist. purerl uses the same
-- | convention.
zigDir :: String
zigDir = "output-zig"

main :: Effect Unit
main = do
  hasCorefn <- exists corefnDir
  if not hasCorefn then
    log "[purs-backend-zig] no ./output directory -- did purs run with --codegen corefn?"
  else do
    entries <- readdir corefnDir
    let candidates = sort (filter isModuleDir entries)
    ensureDir zigDir
    log ("[purs-backend-zig] " <> show (length candidates) <> " module director(ies)")
    for_ candidates processModule

isModuleDir :: String -> Boolean
isModuleDir name = not (String.contains (String.Pattern ".json") name)

ensureDir :: String -> Effect Unit
ensureDir dir = do
  present <- exists dir
  when (not present) (mkdir dir)

processModule :: String -> Effect Unit
processModule dir = do
  let path = corefnDir <> "/" <> dir <> "/corefn.json"
  present <- exists path
  if not present then
    pure unit -- Prim.* and friends have no corefn.json
  else do
    text <- readTextFile UTF8 path
    case parseAndDecode text of
      Left err ->
        log ("[purs-backend-zig]   " <> dir <> ": DECODE FAILED -- " <> err)
      Right m ->
        case emitModule m of
          Left err ->
            log ("[purs-backend-zig]   " <> m.name <> ": EMIT FAILED -- " <> err)
          Right code -> do
            let out = zigDir <> "/" <> moduleFile m.name
            writeTextFile UTF8 out code
            log ("[purs-backend-zig]   " <> m.name <> " -> " <> out)
            copyForeign m

-- | Copy a module's hand-written Zig beside the code that imports it.
-- |
-- | A missing file is a hard error, not a skip: the module declared foreign
-- | imports, so the generated Zig references them and will not compile. Failing
-- | here names the path the author was expected to create, whereas letting it
-- | through produces a "file not found" from Zig pointing at generated code
-- | instead of at the package that forgot to ship its FFI.
copyForeign :: Module -> Effect Unit
copyForeign m =
  when (not (null m.foreigns)) do
    let
      src = replaceExtension m.path
      dest = zigDir <> "/" <> ffiFile m.name
    present <- exists src
    if not present then
      log
        ( "[purs-backend-zig]   " <> m.name <> ": MISSING FFI -- "
            <> show (length m.foreigns)
            <> " foreign import(s) declared but no "
            <> src
        )
    else do
      text <- readTextFile UTF8 src
      writeTextFile UTF8 dest text
      log ("[purs-backend-zig]   " <> m.name <> " (ffi) -> " <> dest)

-- | `src/Data/Semiring.purs` -> `src/Data/Semiring.zig`. Anything not ending
-- | in `.purs` is left alone, which cannot happen in practice but keeps this
-- | total.
replaceExtension :: String -> String
replaceExtension path =
  case String.stripSuffix (String.Pattern ".purs") path of
    Just base -> base <> ".zig"
    Nothing -> path <> ".zig"

parseAndDecode :: String -> Either String Module
parseAndDecode text = do
  json <- jsonParser text
  case decodeModule (json :: Json) of
    Left err -> Left (show err)
    Right m -> Right m
