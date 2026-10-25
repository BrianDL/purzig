-- | Entry point for the PureScript -> Zig backend.
-- |
-- | Spago invokes this with the project root as its working directory, after
-- | running `purs compile --codegen corefn`. The contract is entirely
-- | filesystem-based: read ./output/<Module.Name>/corefn.json, write
-- | ./output-zig/<Module.Name>.zig, and -- once, after the modules -- a
-- | description of the run (`output-zig/manifest.json`). No arguments, no
-- | stdin.
-- |
-- | The emitter writes modules only (issue #7). No program is written here at
-- | all: `build/purzig.zig` generates the entry point into the build cache,
-- | roots the executable at it, and never reads the manifest. What this program
-- | records is which module exports `main`, so tooling does not have to guess.
-- |
-- | Unlike the CoreFn-direct version this replaces, the whole program is read
-- | before anything is emitted. `purescript-backend-optimizer` is a
-- | whole-program pipeline: it carries an `implementations` map forward from
-- | module to module so a definition can be inlined into its downstream
-- | callers, which means modules must be visited in dependency order
-- | (`sortModules`) and in one process. Decoding, sorting and the optimisation
-- | passes are all the toolkit's; `Zig.Emit` sees `BackendModule` and never
-- | touches corefn.json.
-- |
-- | `buildModules` is `forall m. Monad m`, not `Aff`, so this stays on
-- | synchronous node-fs exactly as before. The ES backend runs in `Aff` because
-- | it globs and parallelises; neither is worth a dependency here.
-- |
-- | A module that fails to emit is reported and skipped rather than aborting
-- | the run, so one unsupported construct in a library does not hide progress
-- | on everything else.
-- |
-- | Foreign imports follow the convention every other backend uses: the Zig
-- | lives beside the `.purs` source (`Foo/Bar.purs` pairs with `Foo/Bar.zig`,
-- | as it pairs with `Foo/Bar.js` for JavaScript and `Foo/Bar.erl` for purerl)
-- | and is copied into the output directory. `path` on the CoreFn module is
-- | what makes that possible -- it points at the original source, wherever the
-- | package was unpacked. A package therefore ships its own FFI and needs no
-- | central registration.
module Main where

import Prelude

import Data.Argonaut.Decode.Error (printJsonDecodeError)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (catMaybes, filter, find, fromFoldable, length, mapWithIndex, sort)
import Data.Either (Either(..))
import Data.List (List)
import Data.List as List
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (unwrap)
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)
import Node.Encoding (Encoding(..))
import Node.FS.Sync (exists, mkdir, readTextFile, readdir, writeTextFile)
import PureScript.Backend.Optimizer.Builder (buildModules)
import PureScript.Backend.Optimizer.Convert (BackendModule)
import PureScript.Backend.Optimizer.CoreFn (Ann, Ident, Module(..), Qualified)
import PureScript.Backend.Optimizer.CoreFn.Json (decodeModule)
import PureScript.Backend.Optimizer.CoreFn.Sort (sortModules)
import PureScript.Backend.Optimizer.Directives (parseDirectiveFile)
import PureScript.Backend.Optimizer.Directives.Defaults (defaultDirectives)
import PureScript.Backend.Optimizer.Semantics.Foreign (coreForeignSemantics, qualified)
import Zig.Emit (emitModule)
import Zig.Ident (ffiFile, moduleFile, stringLit, topLevel)

corefnDir :: String
corefnDir = "output"

-- | Deliberately NOT `output/`: keeping generated Zig separate means the
-- | JavaScript backend and this one can coexist. purerl uses the same
-- | convention.
zigDir :: String
zigDir = "output-zig"

-- | The description of a run, written beside the modules.
manifestFile :: String
manifestFile = "manifest.json"

-- | The module that exports `main`. It is compiled exactly like every other
-- | module; nothing in `output-zig/` is a program.
-- |
-- | `build/purzig.zig`'s `Options.main_module` defaults to this name and means
-- | the same thing: the module that exports `main`, not a root source file.
mainModule :: String
mainModule = "Main"

-- | The export the program calls. A PureScript `main` is an `Effect` thunk, so
-- | the Zig name is `@"ps.main"` and running the program is calling it.
mainExport :: String
mainExport = "main"

main :: Effect Unit
main = do
  hasCorefn <- exists corefnDir
  if not hasCorefn then
    log "[purs-backend-zig] no ./output directory -- did purs run with --codegen corefn?"
  else do
    entries <- readdir corefnDir
    let candidates = sort (filter isModuleDir entries)
    ensureDir zigDir
    mods <- readModules candidates
    let sorted = sortModules mods
    log
      ( "[purs-backend-zig] " <> show (List.length sorted) <> " of "
          <> show (length candidates)
          <> " module director(ies) decoded"
      )
    build sorted
    finish (fromFoldable sorted)

-- | The only `BuildOptions` fields carrying any weight are `foreignSemantics`
-- | and `onCodegenModule`. The rest are at their trivial value deliberately:
-- |
-- |   * `onPrepareModule` is a per-module hook run before conversion. On the
-- |     optimizer's `main` branch it can also return `Left` to skip a module
-- |     whose output is still current; at the pinned tag there is no such
-- |     escape hatch, so it just hands the module straight back.
-- |   * `traceIdents` drives `--trace-rewrites`. No CLI, no tracing.
-- |
-- | `BuildOptions` on the optimizer's `main` branch carries an extra
-- | `analyzeCustom` field -- where a backend teaches the optimizer the cost of
-- | its own primitives -- but it does not exist at the pinned tag. If the pin
-- | ever moves forward, that field has to be added back with a
-- | `\_ _ -> Nothing`.
-- |
-- | `foreignSemantics` evaluates known foreign functions during optimisation --
-- | which is why `Data/Semiring.zig`'s `intAdd` largely stops being called, and
-- | its work arrives as a `PrimOp` instead. We add none of our own, and remove
-- | the handful listed under `unsupported`.
-- |
-- | `directives` gets the toolkit's defaults. Per-module `@inline` comments
-- | need no wiring at all -- `toBackendModule` reads them off the module's
-- | comments itself.
build :: List (Module Ann) -> Effect Unit
build mods =
  buildModules
    { directives: (parseDirectiveFile defaultDirectives).directives
    , foreignSemantics: Map.filterKeys (\k -> not (Set.member k unsupported)) coreForeignSemantics
    , onPrepareModule: \_ m -> pure m
    , onCodegenModule: \_ coreFnMod backendMod _ -> codegen coreFnMod backendMod
    , traceIdents: Set.empty
    }
    mods

-- | Foreign functions the optimizer knows how to evaluate, but whose result
-- | this backend cannot express. Removing an entry here does not break the
-- | call -- it just leaves it an ordinary application of the foreign import,
-- | exactly as before the optimizer existed, and the hand-written Zig FFI
-- | already has the right semantics.
-- |
-- | All five are here for the same reason: the `PrimOp` the optimizer produces
-- | assumes JavaScript semantics this backend deliberately does not share.
-- | `intDiv` becomes `OpIntNum OpDivide`, which assumes truncating division;
-- | ours is Euclidean and returns 0 rather than trapping on divide-by-zero,
-- | transcribed from the original `.js`. The `Data.Int.Bits` shifts assume
-- | JavaScript masks the shift count to five bits. `ordString` becomes
-- | `OpStringOrd`, and the runtime has `stringEq` but no comparison.
-- |
-- | These are permanent, not a to-do list. `ordString` is the only one worth
-- | revisiting, and only if a string comparison is added to the runtime's
-- | public surface.
unsupported :: Set (Qualified Ident)
unsupported = Set.fromFoldable
  [ qualified "Data.EuclideanRing" "intDiv"
  , qualified "Data.Ord" "ordString"
  , qualified "Data.Int.Bits" "shl"
  , qualified "Data.Int.Bits" "shr"
  , qualified "Data.Int.Bits" "zshr"
  ]

codegen :: Module Ann -> BackendModule -> Effect Unit
codegen (Module coreFnMod) backendMod = do
  let name = unwrap backendMod.name
  case emitModule backendMod of
    Left err ->
      log ("[purs-backend-zig]   " <> name <> ": EMIT FAILED -- " <> err)
    Right code -> do
      let out = zigDir <> "/" <> moduleFile name
      writeTextFile UTF8 out code
      log ("[purs-backend-zig]   " <> name <> " -> " <> out)
      copyForeign name coreFnMod.path (Set.size backendMod.foreign)

-- | The manifest, once, after every module.
-- |
-- | There is no entry file to point at: the program belongs to the build
-- | helper, which writes it into the build cache rather than into `output-zig/`.
-- | What is recorded here is the MODULES on disk, plus which of them exports
-- | `main` and how that export is spelled -- so `addLibrary`, a wasm host ABI
-- | or any other tool can find the output without globbing the directory.
-- |
-- | The manifest describes what is on disk, not what was attempted: a module
-- | that failed to emit is absent from `modules`, so nothing reading the file
-- | can mistake it for one that exists.
finish :: Array (Module Ann) -> Effect Unit
finish mods = do
  emitted <- catMaybes <$> traverse describe mods
  let manifestPath = zigDir <> "/" <> manifestFile
  writeTextFile UTF8 manifestPath (renderManifest emitted)
  log
    ( "[purs-backend-zig]   " <> show (length emitted) <> " module(s) -> "
        <> manifestPath
    )

-- | One row of the manifest.
type Emitted =
  { name :: String
  , file :: String
  , ffi :: Maybe String
  }

-- | A row per generated `.zig` module, in emission order.
-- |
-- | `ffi` is answered by the filesystem rather than by the module's foreign
-- | set, because the manifest promises FILES: a module whose declared foreign
-- | imports had no `.zig` beside them gets no `.ffi.zig` in the output and must
-- | not claim one.
describe :: Module Ann -> Effect (Maybe Emitted)
describe (Module m) = do
  let name = unwrap m.name
  generated <- exists (zigDir <> "/" <> moduleFile name)
  hasFfi <- exists (zigDir <> "/" <> ffiFile name)
  let
    row =
      { name: name
      , file: moduleFile name
      , ffi: if hasFfi then Just (ffiFile name) else Nothing
      }
  pure (if generated then Just row else Nothing)

-- | The manifest: valid JSON, and enough to find every file this run wrote.
-- |
-- | `main_module` and `main_export` are null together when no module exported
-- | `main`, in which case there is nothing to root an executable at. No entry
-- | file is named: the build helper does not read this file, and the filename
-- | is the helper's business.
renderManifest :: Array Emitted -> String
renderManifest rows =
  let
    entry = find (\e -> e.name == mainModule) rows
  in
    String.joinWith "\n"
      ( [ "{"
        , "  \"main_module\": " <> maybe "null" (\e -> stringLit e.name) entry <> ","
        , "  \"main_export\": " <> maybe "null" (const renderMainExport) entry <> ","
        , "  \"modules\": " <> renderModules rows
        , "}"
        ]
      )
      <> "\n"

-- | What `main` is, so a consumer needs to know nothing about the backend's
-- | naming: a PureScript `Effect` thunk, called in Zig as `@"ps.main"()`.
-- | `kind` says what it is; `zig` is the identifier to call.
renderMainExport :: String
renderMainExport =
  "{ \"name\": " <> stringLit mainExport
    <> ", \"zig\": " <> stringLit (topLevel mainExport)
    <> ", \"kind\": \"effect-thunk\" }"

renderModules :: Array Emitted -> String
renderModules rows =
  String.joinWith "\n"
    ([ "[" ] <> commaSeparated (map renderRow rows) <> [ "  ]" ])

renderRow :: Emitted -> String
renderRow row =
  "{ \"name\": " <> stringLit row.name
    <> ", \"file\": " <> stringLit row.file
    <> ", \"ffi\": " <> maybe "null" stringLit row.ffi
    <> " }"

-- | One line per row, indented, with a comma on all but the last -- so the
-- | array stays valid JSON whether or not it is empty.
commaSeparated :: Array String -> Array String
commaSeparated rows =
  mapWithIndex
    (\i line -> "    " <> line <> (if i == length rows - 1 then "" else ","))
    rows

-- | Dependency order is not optional. `buildModules` threads an
-- | `implementations` map forward, and a module's constructors and inlinable
-- | definitions are only in it once that module has been built. Feeding
-- | modules in readdir order makes the optimizer crash with "could not
-- | determine pattern matched constructor's fields" the first time a `case`
-- | scrutinises a type from a module that has not been seen yet.
readModules :: Array String -> Effect (Array (Module Ann))
readModules dirs = catMaybes <$> traverse readModule dirs

readModule :: String -> Effect (Maybe (Module Ann))
readModule dir = do
  let path = corefnDir <> "/" <> dir <> "/corefn.json"
  present <- exists path
  if not present then
    pure Nothing -- Prim.* and friends have no corefn.json
  else do
    text <- readTextFile UTF8 path
    case decode text of
      Left err -> do
        log ("[purs-backend-zig]   " <> dir <> ": DECODE FAILED -- " <> err)
        pure Nothing
      Right m ->
        pure (Just m)

decode :: String -> Either String (Module Ann)
decode text = do
  json <- jsonParser text
  case decodeModule json of
    Left err -> Left (printJsonDecodeError err)
    Right m -> Right m

-- | Copy a module's hand-written Zig beside the code that imports it.
-- |
-- | A missing file is reported loudly rather than skipped silently: the module
-- | declared foreign imports, so the generated Zig references them and will not
-- | compile. Naming the expected path here points at the package that forgot to
-- | ship its FFI, instead of leaving Zig to report a missing file from inside
-- | generated code.
copyForeign :: String -> String -> Int -> Effect Unit
copyForeign name modulePath foreignCount =
  when (foreignCount > 0) do
    let
      src = replaceExtension modulePath
      dest = zigDir <> "/" <> ffiFile name
    present <- exists src
    if not present then
      log
        ( "[purs-backend-zig]   " <> name <> ": MISSING FFI -- "
            <> show foreignCount
            <> " foreign import(s) declared but no "
            <> src
        )
    else do
      text <- readTextFile UTF8 src
      writeTextFile UTF8 dest text
      log ("[purs-backend-zig]   " <> name <> " (ffi) -> " <> dest)

isModuleDir :: String -> Boolean
isModuleDir name = not (String.contains (String.Pattern ".json") name)

ensureDir :: String -> Effect Unit
ensureDir dir = do
  present <- exists dir
  when (not present) (mkdir dir)

-- | `src/Data/Semiring.purs` -> `src/Data/Semiring.zig`. Anything not ending
-- | in `.purs` is left alone, which cannot happen in practice but keeps this
-- | total.
replaceExtension :: String -> String
replaceExtension path =
  case String.stripSuffix (String.Pattern ".purs") path of
    Just base -> base <> ".zig"
    Nothing -> path <> ".zig"
