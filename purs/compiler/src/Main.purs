-- | Entry point for the PureScript -> Zig backend.
-- |
-- | Spago invokes this with the project root as its working directory, after
-- | running `purs compile --codegen corefn`. The contract is entirely
-- | filesystem-based: read ./output/<Module.Name>/corefn.json, write
-- | ./output-zig/<Module.Name>.zig. No arguments, no stdin.
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
import Data.Array (catMaybes, filter, length, sort)
import Data.Either (Either(..))
import Data.List (List)
import Data.List as List
import Data.Map as Map
import Data.Maybe (Maybe(..))
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
    mods <- readModules candidates
    let sorted = sortModules mods
    log
      ( "[purs-backend-zig] " <> show (List.length sorted) <> " of "
          <> show (length candidates)
          <> " module director(ies) decoded"
      )
    build sorted

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
-- | this backend cannot currently express. Removing an entry here does not
-- | break the call -- it just leaves it an ordinary application of the foreign
-- | import, exactly as before the optimizer existed, and the hand-written Zig
-- | FFI already has the right semantics.
-- |
-- | Two reasons appear in this list.
-- |
-- | SEMANTICS. `intDiv` becomes `OpIntNum OpDivide`, which assumes
-- | JavaScript's truncating division; ours is Euclidean and returns 0 rather
-- | than trapping on divide-by-zero, transcribed from the original `.js`. The
-- | `Data.Int.Bits` shifts assume JavaScript masks the shift count to five
-- | bits. `ordString` becomes `OpStringOrd`, and the runtime has `stringEq`
-- | but no comparison.
-- |
-- | NOT YET IMPLEMENTED. `Effect.bindE`/`pureE`, the `Effect.Ref` primitives
-- | and their `Control.Monad.ST` equivalents rewrite into `EffectBind`,
-- | `EffectPure`, `EffectDefer` and `PrimEffect` -- four IR nodes the emitter
-- | does not handle yet. Dropping these from the list is the whole of batch 2,
-- | and is where MagicDo starts paying off.
unsupported :: Set (Qualified Ident)
unsupported = Set.fromFoldable
  [ qualified "Data.EuclideanRing" "intDiv"
  , qualified "Data.Ord" "ordString"
  , qualified "Data.Int.Bits" "shl"
  , qualified "Data.Int.Bits" "shr"
  , qualified "Data.Int.Bits" "zshr"
  , qualified "Effect" "bindE"
  , qualified "Effect" "pureE"
  , qualified "Effect.Ref" "_new"
  , qualified "Effect.Ref" "read"
  , qualified "Effect.Ref" "write"
  , qualified "Effect.Ref" "modify"
  , qualified "Effect.Unsafe" "unsafePerformEffect"
  , qualified "Control.Monad.ST.Internal" "new"
  , qualified "Control.Monad.ST.Internal" "read"
  , qualified "Control.Monad.ST.Internal" "write"
  , qualified "Control.Monad.ST.Internal" "modify"
  , qualified "Control.Monad.ST.Internal" "run"
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
