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
module Main where

import Prelude

import CoreFn.Decode (decodeModule)
import CoreFn.Types (Module)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (filter, length, sort)
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.String as String
import Effect (Effect)
import Effect.Console (log)
import Node.Encoding (Encoding(..))
import Node.FS.Sync (exists, mkdir, readTextFile, readdir, writeTextFile)
import Zig.Emit (emitModule)
import Zig.Ident (moduleFile)

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

parseAndDecode :: String -> Either String Module
parseAndDecode text = do
  json <- jsonParser text
  case decodeModule (json :: Json) of
    Left err -> Left (show err)
    Right m -> Right m
