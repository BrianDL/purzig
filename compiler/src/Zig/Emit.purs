-- FILE: purs/compiler/src/Zig/Emit.purs
-- | `BackendModule` -> Zig source text. See docs/codegen.md for the rules.
-- |
-- | This consumes `purescript-backend-optimizer`'s IR, not CoreFn. Three
-- | structural facts drive the design:
-- |
-- |  * A local is identified by `(Maybe Ident, Level)`, not by name. Levels are
-- |    assigned by the optimizer as it descends, and a `LetRec` gives every
-- |    member of a group the SAME level, distinguished by identifier -- so the
-- |    pair is the key, and `@"v.<name>.<level>"` is collision-free by
-- |    construction. That is why nothing here suffixes names on shadowing.
-- |  * Pattern matching has already been compiled away. There are no binders:
-- |    a `case` arrives as `Branch` (a list of condition/result pairs) plus
-- |    `Accessor` and `OpIsTag`. The continuation-passing binder fold, the
-- |    `canFail` reachability tracking and the per-alternative bracketing that
-- |    the CoreFn emitter needed are all gone.
-- |  * Zig still has no closures, so every `Abs` is LIFTED to a top-level
-- |    function plus a captured `[]const rt.Value`. `freeKeys` is the only real
-- |    algorithm left here.
-- |
-- | The tree walked here is `TcoExpr`, not `NeutralExpr`: `Tco.analyze`
-- | decorates each node with tail-call information, which the loop emission
-- | reads. Matching therefore goes through `unTcoExpr`. A node this module
-- | synthesises (the tail of a curried `Abs` chain) carries `mempty` analysis,
-- | which is sound because a synthesised node is only ever walked, never
-- | consulted for a TCO decision.
-- |
-- | Every IR node is implemented, including the four effect nodes. A chain of
-- | `EffectBind`s flattens into a single Zig block of statements rather than a
-- | closure per bind -- that is what MagicDo buys.
-- |
-- | This module emits MODULES and nothing else. The program -- the `main` a Zig
-- | executable needs -- is `emitEntry`: a separate file, importing exactly the
-- | module that exports `main`, which `build/purzig.zig` roots the executable
-- | at. No generated `<Module>.zig` knows which module that is, and none of
-- | them mentions `main`, `std.process` or the runtime init.
-- |
-- | NAMING HAZARD: nothing in this module may be called `bind` or `discard`.
-- | Do-notation desugars to functions of exactly those names, so a parameter
-- | shadowing one breaks every `do` block in scope -- and the error points at
-- | the do block, not at the shadowing name.
module Zig.Emit (emitEntry, emitModule, entryFile, mainModule) where

import Prelude

import Data.Array (concat, cons, elem, filter, findIndex, findMap, foldl, length, mapWithIndex, nub, null, snoc, sortWith, uncons)
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Enum (fromEnum)
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Newtype (unwrap)
import Data.Set as Set
import Data.String (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), snd)
import PureScript.Backend.Optimizer.Convert (BackendModule)
import PureScript.Backend.Optimizer.CoreFn (Ident(..), Literal(..), ModuleName, Prop, Qualified(..), propKey, propValue)
import PureScript.Backend.Optimizer.Codegen.Tco (TcoExpr(..), analyze, localTcoRefBindings, tcoRoleIsLoop, topLevelTcoEnvGroup, topLevelTcoRefBindings, unTcoExpr)
import PureScript.Backend.Optimizer.Semantics (NeutralExpr)
import PureScript.Backend.Optimizer.Syntax (BackendAccessor(..), BackendEffect(..), BackendOperator(..), BackendOperator1(..), BackendOperator2(..), BackendOperatorNum(..), BackendOperatorOrd(..), BackendSyntax(..), Level(..), Pair(..))
import Zig.Ident as Ident

-- | Emitter state threaded left-to-right: a counter for fresh names, and the
-- | lifted top-level functions accumulated so far.
type St =
  { counter :: Int
  , lifted :: Array String
  -- | Slot indices a jump has assigned during the loop currently being
  -- | emitted. Zig rejects a `var` that is never mutated, and with members of
  -- | differing arity a high slot may belong to a member nothing ever jumps to,
  -- | so mutability cannot be decided until the bodies are emitted.
  , touched :: Array Int
  }

type Out =
  { text :: String
  , st :: St
  }

type Defs =
  { defs :: Array String
  , st :: St
  }

-- | A local's identity. `name` is "" for an anonymous binder (the optimizer
-- | introduces plenty while inlining). The pair is unique: two distinct
-- | binders never share both, and a `LetRec` group shares only the level.
type Key = { name :: String, level :: Int }

-- | How a local is written in Zig, and whether reading it goes through a lazy
-- | cell. `lazy` lives on the scope ENTRY rather than in a set on `Ctx`, so a
-- | new binder simply conses a fresh entry and lookup resolves shadowing.
type Scoped = { key :: Key, zig :: String, lazy :: Boolean }

type Ctx =
  { moduleName :: String
  , prefix :: String
  , scope :: Array Scoped
  , loop :: Maybe Loop
  }

-- | The tail-recursive binding currently being emitted as a loop, if any.
-- | `params` are the mutable copies a jump assigns, in order.
type Loop =
  { members :: Array { target :: LoopTarget, arity :: Int }
  , slots :: Array String
  , branch :: Maybe String
  }

-- | A loop is reached either as a top-level binding (`Var`) or as a `LetRec`
-- | member (`Local`). The two are otherwise identical.
data LoopTarget
  = LoopTop String
  | LoopLocal Key

-- | One member of a tail-recursive group. `key` is what a non-tail reference
-- | to the member resolves to in scope; for a top-level member it is a
-- | synthetic key that no real binder can produce.
type LoopMember =
  { target :: LoopTarget
  , key :: Key
  , ident :: String
  , arity :: Int
  , params :: Array Key
  , body :: TcoExpr
  }

emitModule :: BackendModule -> Either String String
emitModule m = do
  let
    name = unwrap m.name
    ctx0 = { moduleName: name, prefix: "", scope: [], loop: Nothing }
    foreigns = map unwrap (Set.toUnfoldable m.foreign :: Array Ident)
    imports = map unwrap (Set.toUnfoldable m.imports :: Array ModuleName)

  result <- emitGroups ctx0 m.name { counter: 0, lifted: [], touched: [] } m.bindings

  let
    header =
      [ "// GENERATED by purs-backend-zig from " <> name <> ". Do not edit."
      , ""
      , "const rt = @import(\"runtime\");"
      ]
        <> (if null foreigns then [] else [ "const ffi = @import(\"" <> Ident.ffiFile name <> "\");" ])
        <> [ "" ]
        <> map importLine imports
        <> [ "" ]

  pure
    ( joinWith "\n"
        ( header
            <> map foreignLine foreigns
            <> result.st.lifted
            <> result.defs
        )
        <> "\n"
    )

-- | The module that exports `main`. It is compiled exactly like every other
-- | module; the program that calls it is `entryFile`.
-- |
-- | `build/purzig.zig`'s `Options.main_module` defaults to this name and means
-- | the same thing. Neither the emitter nor the build helper treats it as a
-- | root source file any more.
mainModule :: String
mainModule = "Main"

-- | The generated program, written beside the modules and importing exactly one
-- | of them. Written only when `mainModule` was emitted; there is no entry for a
-- | project with no `main`.
-- |
-- | The filename is fixed by contract, not by the manifest: `build/purzig.zig`
-- | roots the executable here by name and never reads `output-zig/manifest.json`.
entryFile :: String
entryFile = "purzig_entry.zig"

-- | The program, as its own file.
-- |
-- | This text used to sit at the foot of the module that exports `main`,
-- | because a Zig executable's root has to declare `main` and the module was the
-- | root. It is moved here VERBATIM -- same signature, same `rt.init` call, same
-- | `runEffect`s, same comptime freestanding branch with its `@trap()` fallback
-- | -- with exactly one adjustment: `@"ps.main"` was a sibling decl in the same
-- | file and is now reached through the import, because the decl lives in
-- | another file. Nothing observable changes: same stdout, same exit status.
-- |
-- | `moduleName` is the module that exports `main`.
emitEntry :: String -> String
emitEntry moduleName =
  joinWith "\n"
    ( [ "// GENERATED by purs-backend-zig. Do not edit."
      , "//"
      , "// The program. This file is the executable's root, not a module:"
      , "// every output-zig/<Module>.zig is a module, and none of them knows"
      , "// which one exports `main`."
      , ""
      , "const std = @import(\"std\");"
      , "const rt = @import(\"runtime\");"
      , importLine moduleName
      ]
        <> entryBody moduleName
    )
    <> "\n"

-- | The driver, verbatim from where it used to sit at the foot of `mainModule`.
entryBody :: String -> Array String
entryBody moduleName =
  [ ""
  , "// The entry point is chosen at comptime, so this file is identical for"
  , "// every target. Zig analyses what is REFERENCED, not what runs, so the"
  , "// native half below must not be reachable from a freestanding build:"
  , "// that target has no process, no `Io`, no console and no panic printer."
  , "//"
  , "// Native: zig 0.16 hands `main` an `Io` and a process-lifetime arena,"
  , "// both wrapped in the type its start code passes in. That type is spelled"
  , "// `rt.ProcessInit` so it does not appear in generated sources, and so a"
  , "// freestanding target -- where it does not exist -- has one place to say"
  , "// so."
  , "fn mainNative(init: rt.ProcessInit) !void {"
  , "    rt.init(init.io, init.arena.allocator());"
  , "    _ = try rt.runEffect(try " <> entryMain moduleName <> "());"
  , "}"
  , ""
  , "// Freestanding: no process, so no `Io`, no arena and no console. Nothing"
  , "// can run until a host binds memory through `rt.initAlloc`, so the start"
  , "// function traps instead of pretending the program ran."
  , "fn mainFreestanding() void {"
  , "    @trap();"
  , "}"
  , ""
  , "pub const main = if (rt.freestanding) mainFreestanding else mainNative;"
  , ""
  , "// The freestanding seam: a host calls this once it owns the memory."
  , "// Deliberately unreferenced -- zig analyses only what is referenced, and"
  , "// every console primitive this program uses is native-only."
  , "pub fn runWithAllocator(allocator: std.mem.Allocator) rt.Error!void {"
  , "    rt.initAlloc(allocator);"
  , "    _ = try rt.runEffect(try " <> entryMain moduleName <> "());"
  , "}"
  ]

-- | `@"ps.main"` on its own was a sibling decl; from another file it is
-- | qualified by the module import `importLine` writes. This is the only
-- | difference between the driver here and the one that used to be emitted into
-- | the module.
entryMain :: String -> String
entryMain moduleName = Ident.moduleRef moduleName <> "." <> Ident.topLevel "main"

-- | The optimizer has already filtered `Prim` and the module's own name out of
-- | the import set, and dropped every import that survived dead-code
-- | elimination unused. Nothing to do here but write the lines.
importLine :: String -> String
importLine name =
  "const " <> Ident.moduleRef name <> " = @import(\"" <> Ident.moduleFile name <> "\");"

-- | A foreign import has no body, so it becomes a re-export from the module's
-- | own FFI file -- as a nullary function, so that it is referenced exactly
-- | like a generated binding.
foreignLine :: String -> String
foreignLine name =
  joinWith "\n"
    [ "pub fn " <> Ident.topLevel name <> "() rt.Error!rt.Value {"
    , "    return ffi." <> Ident.topLevel name <> ";"
    , "}"
    , ""
    ]

-- | Binding groups. `recursive` needs no handling at all: mutual recursion
-- | between nullary Zig functions is fine, and the optimizer has already
-- | ordered the groups.
emitGroups
  :: Ctx
  -> ModuleName
  -> St
  -> Array { recursive :: Boolean, bindings :: Array (Tuple Ident NeutralExpr) }
  -> Either String Defs
emitGroups ctx mod st groups = case uncons groups of
  Nothing -> Right { defs: [], st }
  Just { head, tail } -> do
    one <- emitGroup ctx mod st head.bindings
    rest <- emitGroups ctx mod one.st tail
    pure { defs: one.defs <> rest.defs, st: rest.st }

-- | `analyze` decorates every node with tail-call information, relative to an
-- | environment naming the group's own bindings and their arities. That is what
-- | lets it see a self-call in tail position as a jump rather than a call.
-- |
-- | `tcoRoleIsLoop` is true when EVERY self-reference in the group is a
-- | saturated tail call at a uniform arity -- if the function is ever passed
-- | around as a value, or called with the wrong number of arguments, it is not
-- | a loop and the ordinary curried emission is the only correct one.
-- |
-- | Only single-binding groups take the loop path for now. A mutual group needs
-- | a branch variable dispatching between members, which is a later batch.
emitGroup :: Ctx -> ModuleName -> St -> Array (Tuple Ident NeutralExpr) -> Either String Defs
emitGroup ctx mod st binds = case NEA.fromArray binds of
  Nothing -> Right { defs: [], st }
  Just nea -> do
    let
      env = topLevelTcoEnvGroup mod nea
      analyzed = map (map (analyze env)) nea
      isLoop = maybe false tcoRoleIsLoop (topLevelTcoRefBindings mod analyzed)
    case topLoopMembers (NEA.toArray analyzed) of
      Just members | isLoop -> emitLoopBinding ctx st members
      _ -> emitBindings ctx st (NEA.toArray analyzed)

emitBindings :: Ctx -> St -> Array (Tuple Ident TcoExpr) -> Either String Defs
emitBindings ctx st binds = case uncons binds of
  Nothing -> Right { defs: [], st }
  Just { head: Tuple ident expr, tail } -> do
    one <- emitTopValue ctx st (unwrap ident) expr
    rest <- emitBindings ctx one.st tail
    pure { defs: one.defs <> rest.defs, st: rest.st }

-- | Top-level bindings become NULLARY FUNCTIONS, not constants: rt.apply
-- | allocates, so a const would have to be comptime-known, and a lazy global
-- | would need initialisation ordering. Recomputing is semantically free
-- | because PureScript is pure. purerl uses the same convention.
emitTopValue :: Ctx -> St -> String -> TcoExpr -> Either String Defs
emitTopValue ctx st ident expr = do
  o <- emitExpr (ctx { prefix = ident }) st expr
  pure
    { defs:
        [ "pub fn " <> Ident.topLevel ident <> "() rt.Error!rt.Value {"
        , returnStmt (diverges expr) o.text
        , "}"
        , ""
        ]
    , st: o.st
    }

-- | A tail-recursive binding group, emitted as a real Zig loop.
-- |
-- | The ES backend can put the loop inside the curried arrow chain, because a
-- | JavaScript closure may reassign a captured `let`. Ours cannot: arguments of
-- | a curried chain live in a `[]const rt.Value` env, so a jump has nothing it
-- | is allowed to write to. The loop therefore becomes a separate UNCURRIED Zig
-- | function taking every argument at once, with a mutable copy of each:
-- |
-- | ```zig
-- | fn @"ps.f.loop0"(env: []const rt.Value, @"v.in.0.0": rt.Value) rt.Error!rt.Value {
-- |     _ = env;
-- |     var @"v.a.0.0" = @"v.in.0.0";
-- |     while (true) { ... }
-- | }
-- | ```
-- |
-- | The curried chain still exists and is unchanged -- its innermost lambda
-- | just calls the loop. Every call site, `rt.apply`, and the whole FFI
-- | convention stay exactly as they were, and partial application still works.
-- |
-- | A group of several mutually tail-recursive members shares ONE loop
-- | function. Slots are numbered up to the widest member's arity, a member of
-- | lesser arity leaves the high slots alone, and a `branch` variable says
-- | which member's body to run. That is the ES backend's design; only the
-- | dispatch differs, being an `if` chain rather than a switch.
-- |
-- | No trailing `return`: Zig knows a `while (true)` with no `break` is
-- | noreturn, and every tail position emits either a `return` or a `continue`.
emitLoopGroup
  :: Ctx
  -> St
  -> String
  -> Array Key
  -> Array LoopMember
  -> Either String { lifted :: Array String, entry :: Array String, st :: St }
emitLoopGroup ctx st base captured members = do
  let
    n = st.counter
    loopName = Ident.lifted (base <> ".loop" <> show n)
    argName i j = Ident.lifted (base <> ".arg" <> show n <> "." <> show i <> "." <> show j)
    slotName j = Ident.local ("a." <> show n <> "." <> show j)
    inName j = Ident.local ("in." <> show n <> "." <> show j)
    branchName = Ident.local ("br." <> show n)
    branchIn = Ident.local ("brin." <> show n)

    capCount = length captured
    multi = length members > 1
    maxArity = foldl max 0 (map _.arity members)
    slots = map slotName (range' 0 maxArity)
    envRef = if capCount == 0 then "rt.no_env" else "env"

    loopInfo =
      { members: map (\m -> { target: m.target, arity: m.arity }) members
      , slots
      , branch: if multi then Just branchName else Nothing
      }

    -- A member referenced anywhere but a tail call is still an ordinary value:
    -- the closure chain, closed over the same env.
    selfEntries env = mapWithIndex
      (\i m -> { key: m.key, zig: "rt.Value.mkClosure(" <> argName i 0 <> ", " <> env <> ")", lazy: false })
      members
    capEntries = map (\k -> { key: k, zig: zigOf k, lazy: false }) captured

    memberCtx m =
      ctx
        { scope =
            mapWithIndex (\j k -> { key: k, zig: slotName j, lazy: false }) m.params
              <> capEntries
              <> selfEntries envRef
        , loop = Just loopInfo
        }

  bodies <- emitLoopBodies memberCtx (st { counter = st.counter + 1, touched = [] }) members

  let
    touched = bodies.st.touched
    -- Restore the enclosing loop's slot record: a nested loop must not report
    -- its own assignments as the outer one's.
    st' = bodies.st { touched = st.touched }

    envBindings = mapWithIndex
      (\i k -> "    const " <> zigOf k <> " = env[" <> show i <> "];")
      captured
    envDiscard = if capCount == 0 then [ "    _ = env;" ] else []

    branchDecl = if multi then [ "    var " <> branchName <> " = " <> branchIn <> ";" ] else []

    copies = map
      ( \j ->
          (if elem j touched then "    var " else "    const ")
            <> fromMaybe "" (indexAt slots j)
            <> " = "
            <> inName j
            <> ";"
      )
      (range' 0 maxArity)

    dispatch =
      if not multi then bodies.lines
      else
        concat
          ( mapWithIndex
              ( \i ls ->
                  [ "        if (" <> branchName <> " == " <> show i <> ") {" ]
                    <> map (\l -> "    " <> l) ls
                    <> [ "        }" ]
              )
              bodies.perMember
          )
          <> [ "        unreachable;" ]

    signature =
      "fn " <> loopName <> "(env: []const rt.Value"
        <> (if multi then ", " <> branchIn <> ": u32" else "")
        <> joinWith "" (map (\j -> ", " <> inName j <> ": rt.Value") (range' 0 maxArity))
        <> ") rt.Error!rt.Value {"

    loopDef =
      joinWith "\n"
        ( [ signature ]
            <> envDiscard
            <> envBindings
            <> branchDecl
            <> copies
            <> [ "    while (true) {" ]
            <> dispatch
            <> [ "    }", "}", "" ]
        )

    -- One curried wrapper chain per member. Its env holds the captures followed
    -- by the arguments gathered so far, so every index is a compile-time
    -- constant and the final wrapper hands the captures back as `env[0..c]`.
    wrapper i m =
      map
        ( \j ->
            let
              argZig = Ident.local ("p." <> show n <> "." <> show j)
              held = map (\k -> "env[" <> show k <> "]") (range' 0 (capCount + j))
              usesEnv = capCount + j > 0
              gathered =
                map (\k -> "env[" <> show k <> "]") (range' capCount (capCount + j))
                  <> [ argZig ]
              padding = map (\_ -> "rt.Value.mkUnit()") (range' m.arity maxArity)
              result =
                if j == m.arity - 1 then
                  "try " <> loopName <> "("
                    <> (if capCount == 0 then "rt.no_env" else "env[0.." <> show capCount <> "]")
                    <> (if multi then ", " <> show i else "")
                    <> joinWith "" (map (\g -> ", " <> g) (gathered <> padding))
                    <> ")"
                else
                  "rt.Value.mkClosure(" <> argName i (j + 1) <> ", rt.copyValues(&.{ "
                    <> joinWith ", " (snoc held argZig)
                    <> " }))"
            in
              joinWith "\n"
                ( [ "fn " <> argName i j <> "(env: []const rt.Value, " <> argZig <> ": rt.Value) rt.Error!rt.Value {" ]
                    <> (if usesEnv then [] else [ "    _ = env;" ])
                    <> [ "    return " <> result <> ";", "}", "" ]
                )
        )
        (range' 0 m.arity)

  pure
    { lifted: concat (mapWithIndex wrapper members) <> [ loopDef ]
    , entry: mapWithIndex (\i _ -> argName i 0) members
    , st: st'
    }

-- | Emit each member's body in tail position, threading state and keeping the
-- | per-member line blocks separate so the dispatch can bracket them.
emitLoopBodies
  :: (LoopMember -> Ctx)
  -> St
  -> Array LoopMember
  -> Either String { lines :: Array String, perMember :: Array (Array String), st :: St }
emitLoopBodies mkCtx st members = case uncons members of
  Nothing -> Right { lines: [], perMember: [], st }
  Just { head, tail } -> do
    one <- emitTail (mkCtx head) st head.body
    rest <- emitLoopBodies mkCtx one.st tail
    pure
      { lines: one.lines <> rest.lines
      , perMember: cons one.lines rest.perMember
      , st: rest.st
      }

-- | Top-level group: no captures, and each member keeps its `pub fn` entry
-- | point returning the head of its wrapper chain.
emitLoopBinding :: Ctx -> St -> Array LoopMember -> Either String Defs
emitLoopBinding ctx st members = do
  r <- emitLoopGroup (ctx { prefix = memberBase members }) st (memberBase members) [] members
  pure
    { defs: concat
        ( mapWithIndex
            ( \i m ->
                [ "pub fn " <> Ident.topLevel m.ident <> "() rt.Error!rt.Value {"
                , "    return rt.Value.mkClosure(" <> fromMaybe "" (indexAt r.entry i) <> ", rt.no_env);"
                , "}"
                , ""
                ]
            )
            members
        )
    , st: r.st { lifted = r.st.lifted <> r.lifted }
    }

-- | Every member of a loop group must be a lambda. `tcoRoleIsLoop` already
-- | implies it, but the emitter needs the arguments and body, so it destructures
-- | rather than trusting.
topLoopMembers :: Array (Tuple Ident TcoExpr) -> Maybe (Array LoopMember)
topLoopMembers = traverse \(Tuple ident texpr) -> case unTcoExpr texpr of
  Abs args body ->
    Just
      { target: LoopTop (unwrap ident)
      , key: { name: unwrap ident, level: topLevelPseudoLevel }
      , ident: unwrap ident
      , arity: NEA.length args
      , params: map (\(Tuple mIdent lvl) -> keyOf mIdent lvl) (NEA.toArray args)
      , body
      }
  _ -> Nothing

-- | Levels are assigned from zero upwards, so nothing a binder produces can
-- | collide with this.
topLevelPseudoLevel :: Int
topLevelPseudoLevel = -1000000

memberBase :: Array LoopMember -> String
memberBase members = case uncons members of
  Just { head } -> head.ident
  Nothing -> "loop"

-- | Emit an expression in TAIL position as statements rather than as a value.
-- |
-- | This is the second emission mode, and the reason TCO needs one: a jump is a
-- | `continue`, which is a statement and cannot be the value of an expression.
-- | Only constructs that can *hold* a tail position recurse here -- `Branch`
-- | arms, `Let` bodies -- and everything else bottoms out in `return`.
-- |
-- | Nothing recurses into an `Abs`: a lambda body is a different Zig function,
-- | so a tail call there is not a tail call of this loop.
emitTail :: Ctx -> St -> TcoExpr -> Either String { lines :: Array String, st :: St }
emitTail ctx st expr = case unTcoExpr expr of
  -- Each arm's statements always end in `return` or `continue`, so the arms
  -- need no `else` and the fallback can simply follow them.
  Branch pairs fallback -> do
    arms <- emitTailArms ctx st (NEA.toArray pairs)
    fb <- emitTail ctx arms.st fallback
    pure { lines: arms.lines <> fb.lines, st: fb.st }

  Let mIdent lvl e body -> do
    let
      key = keyOf mIdent lvl
      zig = zigOf key
    o <- emitExpr ctx st e
    let ctx' = ctx { scope = cons { key, zig, lazy: false } ctx.scope }
    rest <- emitTail ctx' o.st body
    pure
      { lines: cons ("        const " <> zig <> " = " <> o.text <> ";") rest.lines
      , st: rest.st
      }

  -- A saturated call to any member of the loop group: assign that member's
  -- slots, select its branch, and go round again.
  App f as
    | Just loop <- ctx.loop
    , Just i <- loopMemberIndex ctx loop f (NEA.length as) ->
        emitJump ctx st loop i (NEA.toArray as)

  _ -> do
    o <- emitExpr ctx st expr
    pure
      { lines: [ "        " <> (if diverges expr then o.text else "return " <> o.text) <> ";" ]
      , st: o.st
      }

emitTailArms :: Ctx -> St -> Array (Pair TcoExpr) -> Either String { lines :: Array String, st :: St }
emitTailArms ctx st pairs = case uncons pairs of
  Nothing -> Right { lines: [], st }
  Just { head: Pair cond result, tail } -> do
    c <- emitExpr ctx st cond
    r <- emitTail ctx c.st result
    rest <- emitTailArms ctx r.st tail
    pure
      { lines:
          [ "        if (" <> c.text <> ".asBool()) {" ]
            <> map (\l -> "    " <> l) r.lines
            <> [ "        }" ]
            <> rest.lines
      , st: rest.st
      }

-- | The head of a tail call is the loop's own binding: either unqualified or
-- | qualified with the module being emitted.
loopMemberIndex :: Ctx -> Loop -> TcoExpr -> Int -> Maybe Int
loopMemberIndex ctx loop f arity =
  findIndex (\m -> m.arity == arity && isLoopCall ctx m.target f) loop.members

isLoopCall :: Ctx -> LoopTarget -> TcoExpr -> Boolean
isLoopCall ctx target f = case target, unTcoExpr f of
  LoopTop ident, Var (Qualified mn callee) ->
    unwrap callee == ident
      && case mn of
        Nothing -> true
        Just m -> unwrap m == ctx.moduleName
  LoopLocal key, Local mIdent lvl -> keyOf mIdent lvl == key
  _, _ -> false

-- | Assignment is SIMULTANEOUS: `go (n - 1) acc` must not see the new `n` when
-- | it evaluates `acc`. Every argument is therefore computed into a temporary
-- | first, and only then written back to the loop variables.
emitJump :: Ctx -> St -> Loop -> Int -> Array TcoExpr -> Either String { lines :: Array String, st :: St }
emitJump ctx st loop index args = do
  parts <- emitList ctx st args
  let
    n = parts.st.counter
    tmp i = Ident.local ("jump." <> show n <> "." <> show i)
    temps = mapWithIndex (\i t -> "        const " <> tmp i <> " = " <> t <> ";") parts.texts
    writes = mapWithIndex
      (\i _ -> "        " <> fromMaybe "" (indexAt loop.slots i) <> " = " <> tmp i <> ";")
      parts.texts
    branch = case loop.branch of
      Just b -> [ "        " <> b <> " = " <> show index <> ";" ]
      Nothing -> []
  pure
    { lines: temps <> writes <> branch <> [ "        continue;" ]
    , st: parts.st
        { counter = parts.st.counter + 1
        , touched = parts.st.touched <> range' 0 (length args)
        }
    }

emitExpr :: Ctx -> St -> TcoExpr -> Either String Out
emitExpr ctx st expr = case unTcoExpr expr of
  Lit literal -> emitLit ctx st literal

  -- A `Var` is always a top-level reference; locals are `Local`. `Qualified
  -- Nothing` means the current module.
  Var (Qualified mn ident) ->
    let
      target = unwrap ident
    in
      case mn of
        Nothing -> Right { text: "(try " <> Ident.topLevel target <> "())", st }
        Just m
          | unwrap m == ctx.moduleName ->
              Right { text: "(try " <> Ident.topLevel target <> "())", st }
          | otherwise ->
              Right
                { text: "(try " <> Ident.moduleRef (unwrap m) <> "." <> Ident.topLevel target <> "())"
                , st
                }

  Local mIdent lvl -> case lookupEntry ctx (keyOf mIdent lvl) of
    -- Reading a lazy binding forces it. Capturing it must not: `scopeText`,
    -- which builds every capture list, deliberately yields the bare cell.
    -- Backwards, and a recursive non-function binding forces during its own
    -- initialisation and hits the cycle panic.
    Just e | e.lazy -> Right { text: "(try rt.forceLazy(" <> e.zig <> "))", st }
    Just e -> Right { text: e.zig, st }
    Nothing -> Left ("unbound local: " <> keyText (keyOf mIdent lvl))

  -- Applications arrive as a collected spine. Nesting them back into
  -- one-argument applies is what keeps the FFI convention intact: every
  -- foreign export is still a chain of one-argument closures.
  App f args -> do
    fo <- emitExpr ctx st f
    applyAll ctx fo (NEA.toArray args)

  Abs args body -> emitAbsChain ctx st (NEA.toArray args) body

  -- The uncurried forms come from Data.Function.Uncurried and
  -- Effect.Uncurried. There is no N-ary function value in this runtime, so
  -- they collapse to the curried chain -- the same decision as the EffectFnN
  -- shim. Effectful and pure differ only in when the body runs, and since
  -- Values are strict here, applying the last argument runs it either way.
  UncurriedAbs args body -> emitUncurriedAbs ctx st args body
  UncurriedEffectAbs args body -> emitUncurriedAbs ctx st args body

  UncurriedApp f args -> emitUncurriedApp ctx st f args
  UncurriedEffectApp f args -> emitUncurriedApp ctx st f args

  Accessor e acc -> do
    o <- emitExpr ctx st e
    pure { text: o.text <> accessorText acc, st: o.st }

  -- rt.updateRecord copies into the arena itself, so the update slice may stay
  -- a stack temporary -- unlike a bare record literal, which needs copyFields.
  Update e props -> do
    o <- emitExpr ctx st e
    fs <- emitProps ctx o.st props
    pure { text: "rt.updateRecord(" <> o.text <> ", " <> fs.text <> ")", st: fs.st }

  -- A saturated constructor application needs no closure chain at all: the
  -- optimizer has already collected the arguments.
  CtorSaturated _ _ _ ctor fields -> do
    parts <- emitList ctx st (map snd fields)
    pure
      { text:
          "rt.Value.mkData(" <> Ident.stringLit (unwrap ctor)
            <> ", rt.copyValues(&.{ "
            <> joinWith ", " parts.texts
            <> " }))"
      , st: parts.st
      }

  CtorDef _ _ ctor fields -> emitCtorDef ctx st (unwrap ctor) (length fields)

  Let mIdent lvl e body -> emitLet ctx st mIdent lvl e body

  LetRec lvl bindings body -> emitLetRec ctx st lvl (NEA.toArray bindings) body

  Branch pairs fallback -> emitBranch ctx st (NEA.toArray pairs) fallback

  PrimOp op -> emitPrimOp ctx st op

  -- The compiler's placeholder for an erased type argument: passed around,
  -- never forced. Any value does.
  PrimUndefined -> Right { text: "rt.Value.mkUnit()", st }

  -- `Fail` is how the optimizer represents an incomplete match. @panic is
  -- noreturn, so it coerces to whatever type the surrounding expression needs.
  Fail msg -> Right { text: "@panic(" <> Ident.stringLit msg <> ")", st }

  -- An `Effect a` is a thunk: a closure ignoring a unit argument, run by
  -- `rt.runEffect`. All four nodes below produce a lifted closure, and differ
  -- only in what its body does. `emitPerform` is what runs one.
  EffectPure a ->
    emitThunk ctx st (freeKeys a) \c s -> emitExpr c s a

  EffectDefer a ->
    emitThunk ctx st (freeKeys a) \c s -> emitPerform c s a

  EffectBind _ _ _ _ ->
    emitThunk ctx st (freeKeys expr) \c s -> emitEffectBlock c s expr

  PrimEffect _ ->
    emitThunk ctx st (freeKeys expr) \c s -> emitPerform c s expr

applyAll :: Ctx -> Out -> Array TcoExpr -> Either String Out
applyAll ctx acc args = case uncons args of
  Nothing -> Right acc
  Just { head, tail } -> do
    x <- emitExpr ctx acc.st head
    applyAll ctx { text: "(try rt.apply(" <> acc.text <> ", " <> x.text <> "))", st: x.st } tail

-- | An uncurried application of no arguments still has to apply something --
-- | `runFn0` and `runEffectFn0` are thunks in this runtime, forced by unit.
emitUncurriedApp :: Ctx -> St -> TcoExpr -> Array TcoExpr -> Either String Out
emitUncurriedApp ctx st f args = do
  fo <- emitExpr ctx st f
  if null args then
    pure { text: "(try rt.apply(" <> fo.text <> ", rt.Value.mkUnit()))", st: fo.st }
  else
    applyAll ctx fo args

-- | Likewise, a nullary uncurried abstraction becomes a closure over one
-- | ignored argument, so that applying unit runs it.
emitUncurriedAbs :: Ctx -> St -> Array (Tuple (Maybe Ident) Level) -> TcoExpr -> Either String Out
emitUncurriedAbs ctx st args body =
  if null args then emitAbsChain ctx st [ Tuple Nothing (Level (-1)) ] body
  else emitAbsChain ctx st args body

emitLit :: Ctx -> St -> Literal TcoExpr -> Either String Out
emitLit ctx st literal = case literal of
  LitInt n -> Right { text: "rt.Value.mkInt(" <> show n <> ")", st }
  LitNumber n -> Right { text: "rt.Value.mkNumber(" <> show n <> ")", st }
  LitString s -> Right { text: "rt.Value.mkString(" <> Ident.stringLit s <> ")", st }
  LitBoolean b -> Right { text: "rt.Value.mkBool(" <> (if b then "true" else "false") <> ")", st }

  -- The IR carries a real Char, and ours is a u21. Emitting the code point
  -- avoids having to escape it into a Zig character literal, and is exact for
  -- everything outside the BMP too.
  LitChar c -> Right { text: "rt.Value.mkChar(" <> show (fromEnum c) <> ")", st }

  LitArray items -> do
    parts <- emitList ctx st items
    pure
      { text: "rt.Value.mkArray(rt.copyValues(&.{ " <> joinWith ", " parts.texts <> " }))"
      , st: parts.st
      }

  LitRecord props -> do
    fs <- emitProps ctx st props
    pure { text: "rt.Value.mkRecord(rt.copyFields(" <> fs.text <> "))", st: fs.st }

-- | The Zig syntax for a field slice. Field NAMES are comptime-known, so this
-- | can be a struct literal -- but the VALUES are not, so `&.{ ... }` points at
-- | a stack temporary in the enclosing frame. Whatever consumes it must copy
-- | into the arena first.
emitProps :: Ctx -> St -> Array (Prop TcoExpr) -> Either String Out
emitProps ctx st props = do
  parts <- emitList ctx st (map propValue props)
  let
    keys = map propKey props
    pairs =
      mapWithIndex
        ( \i k ->
            ".{ .name = " <> Ident.stringLit k
              <> ", .value = "
              <> fromMaybe "" (parts.texts `indexAt` i)
              <> " }"
        )
        keys
  pure { text: "&.{ " <> joinWith ", " pairs <> " }", st: parts.st }

indexAt :: Array String -> Int -> Maybe String
indexAt xs i = findMap (\p -> if p.i == i then Just p.x else Nothing) (mapWithIndex (\j x -> { i: j, x }) xs)

emitList :: Ctx -> St -> Array TcoExpr -> Either String { texts :: Array String, st :: St }
emitList ctx st items = case uncons items of
  Nothing -> Right { texts: [], st }
  Just { head, tail } -> do
    o <- emitExpr ctx st head
    rest <- emitList ctx o.st tail
    pure { texts: cons o.text rest.texts, st: rest.st }

accessorText :: BackendAccessor -> String
accessorText = case _ of
  GetProp k -> ".field(" <> Ident.stringLit k <> ")"
  GetIndex i -> ".asArray()[" <> show i <> "]"
  -- Newtype erasure is not a special case here: the optimizer resolves it
  -- before codegen, so a GetCtorField always addresses a real constructor.
  GetCtorField _ _ _ _ _ i -> ".arg(" <> show i <> ")"

-- | Lift a chain of binders to nested one-argument Zig functions. The
-- | optimizer collects `\a b c -> ...` into one `Abs`; the runtime still wants
-- | one argument per closure, so this peels the head and rebuilds the tail as
-- | a fresh `Abs` node.
emitAbsChain :: Ctx -> St -> Array (Tuple (Maybe Ident) Level) -> TcoExpr -> Either String Out
emitAbsChain ctx st args body = case uncons args of
  Nothing -> emitExpr ctx st body
  Just { head: Tuple mIdent lvl, tail } ->
    let
      inner = case NEA.fromArray tail of
        Nothing -> body
        Just rest -> TcoExpr mempty (Abs rest body)
    in
      emitAbs ctx st (keyOf mIdent lvl) inner

-- | The one genuinely non-trivial case. Lift the body to a top-level function
-- | and pass captured locals as a flat positional slice.
emitAbs :: Ctx -> St -> Key -> TcoExpr -> Either String Out
emitAbs ctx st key body =
  emitLifted ctx st key (freeKeys body) (diverges body) \c s -> emitExpr c s body

-- | Lift a function to the top level, given the free variables its body
-- | mentions and a way to emit that body in the inner scope.
-- |
-- | `emitAbs` is the ordinary case, where the body is one expression. The
-- | effect nodes need the same lifting but their bodies are composites -- a
-- | block of statements, or an expression wrapped in `rt.runEffect` -- so the
-- | body is a callback rather than a node, and the free-variable set is passed
-- | in rather than computed here.
emitLifted
  :: Ctx
  -> St
  -> Key
  -> Array Key
  -> Boolean
  -> (Ctx -> St -> Either String Out)
  -> Either String Out
emitLifted ctx st key bodyFree divergent emitBody = do
  let
    captured = orderKeys (filter (\k -> k /= key && isJust (lookupEntry ctx k)) bodyFree)

    -- Zig errors on an unused function parameter, and PureScript produces them
    -- constantly: every `\_ -> ...` and every erased dictionary argument.
    argUsed = elem key bodyFree

    fnName = Ident.lifted (ctx.prefix <> ".lam" <> show st.counter)
    argZig = zigOf key
    innerScope =
      cons { key, zig: argZig, lazy: false }
        (map (\k -> { key: k, zig: zigOf k, lazy: isLazy ctx k }) captured)

  bodyOut <- emitBody (ctx { scope = innerScope }) (st { counter = st.counter + 1 })

  let
    bindings = mapWithIndex (\i k -> "    const " <> zigOf k <> " = env[" <> show i <> "];") captured
    envDiscard = if null captured then [ "    _ = env;" ] else []
    argDiscard = if argUsed then [] else [ "    _ = " <> argZig <> ";" ]
    def =
      joinWith "\n"
        ( [ "fn " <> fnName <> "(env: []const rt.Value, " <> argZig <> ": rt.Value) rt.Error!rt.Value {" ]
            <> envDiscard
            <> argDiscard
            <> bindings
            <> [ returnStmt divergent bodyOut.text, "}", "" ]
        )
    envExpr =
      if null captured then "rt.no_env"
      else "rt.copyValues(&.{ " <> joinWith ", " (map (scopeText ctx) captured) <> " })"

  pure
    { text: "rt.Value.mkClosure(" <> fnName <> ", " <> envExpr <> ")"
    , st: bodyOut.st { lifted = snoc bodyOut.st.lifted def }
    }

-- | An unsaturated constructor: n nested one-argument closures ending in a
-- | mkData. Saturated uses are handled by `CtorSaturated` and never reach here.
emitCtorDef :: Ctx -> St -> String -> Int -> Either String Out
emitCtorDef ctx st name arity =
  if arity == 0 then
    Right { text: "rt.Value.mkData(" <> Ident.stringLit name <> ", &.{})", st }
  else
    let
      base = ctx.prefix <> ".ctor" <> show st.counter

      step i =
        let
          fnName = Ident.lifted (base <> "." <> show i)
          argZig = Ident.local ("a" <> show i)
          prior = map (\j -> "env[" <> show j <> "]") (range' 0 i)
          payload = joinWith ", " (snoc prior argZig)
          envDiscard = if i == 0 then [ "    _ = env;" ] else []
          body =
            if i == arity - 1 then
              "rt.Value.mkData(" <> Ident.stringLit name <> ", rt.copyValues(&.{ " <> payload <> " }))"
            else
              "rt.Value.mkClosure(" <> Ident.lifted (base <> "." <> show (i + 1))
                <> ", rt.copyValues(&.{ "
                <> payload
                <> " }))"
        in
          joinWith "\n"
            ( [ "fn " <> fnName <> "(env: []const rt.Value, " <> argZig <> ": rt.Value) rt.Error!rt.Value {" ]
                <> envDiscard
                <> [ "    return " <> body <> ";", "}", "" ]
            )
    in
      Right
        { text: "rt.Value.mkClosure(" <> Ident.lifted (base <> ".0") <> ", rt.no_env)"
        , st: st { counter = st.counter + 1, lifted = st.lifted <> map step (range' 0 arity) }
        }

range' :: Int -> Int -> Array Int
range' lo hi = if lo >= hi then [] else cons lo (range' (lo + 1) hi)

-- | Zig has statement-level `const`, so a Let is a labelled block. Labels share
-- | one namespace within a function, hence the counter -- a fixed `blk`
-- | collides the moment one Let nests inside another.
emitLet :: Ctx -> St -> Maybe Ident -> Level -> TcoExpr -> TcoExpr -> Either String Out
emitLet ctx st mIdent lvl e body = do
  let
    label = "blk" <> show st.counter
    key = keyOf mIdent lvl
    zig = zigOf key
  o <- emitExpr ctx (st { counter = st.counter + 1 }) e
  let ctx' = ctx { scope = cons { key, zig, lazy: false } ctx.scope }
  bodyOut <- emitExpr ctx' o.st body
  pure
    { text:
        joinWith "\n"
          [ label <> ": {"
          , "        const " <> zig <> " = " <> o.text <> ";"
          , breakStmt label body bodyOut.text
          , "    }"
          ]
    , st: bodyOut.st
    }

-- | A recursive group. Function members are lifted to top-level functions
-- | sharing one environment; a member reference within the group is
-- | `mkClosure(fn, env)` -- a VALUE, not a call, or building the capture list
-- | would re-enter the function being defined.
-- |
-- | Non-function members get a lazy cell, which is the fallback the compiler's
-- | 0.15.0 release notes specify for backends that cannot call
-- | `applyLazinessTransform`. Restricting the cheap path to function members is
-- | the "light analysis" those notes sanction.
-- | A `LetRec` group of one function that only ever tail-calls itself is the
-- | `where go = ...` idiom, and is where recursion actually lives in most
-- | PureScript. It takes the same loop treatment as a top-level binding, with
-- | one addition: a local loop may capture enclosing variables, so the loop
-- | function takes an `env` slice alongside its value parameters.
-- | A local tail-recursive group -- the `where go = ...` idiom, and where
-- | recursion actually lives in most PureScript.
-- |
-- | Same loop as the top-level case, plus captures: the members share one env
-- | slice, computed as the union of their free variables minus the members and
-- | their own parameters.
emitLocalLoop :: Ctx -> St -> Array LoopMember -> TcoExpr -> Either String Out
emitLocalLoop ctx st members body = do
  let
    n = st.counter
    label = "blk" <> show n
    envName = Ident.local ("env." <> show n)
    memberKeys = map _.key members
    allParams = concat (map _.params members)
    free = nub (concat (map (freeKeys <<< _.body) members))
    captured = orderKeys
      ( filter
          (\k -> not (elem k memberKeys) && not (elem k allParams) && isJust (lookupEntry ctx k))
          free
      )
    capCount = length captured
    envExpr =
      if capCount == 0 then "rt.no_env"
      else "rt.copyValues(&.{ " <> joinWith ", " (map (scopeText ctx) captured) <> " })"

  r <- emitLoopGroup ctx (st { counter = st.counter + 1 }) (ctx.prefix <> ".rec" <> show n) captured members

  let
    envRef = if capCount == 0 then "rt.no_env" else envName
    bindings = mapWithIndex
      ( \i m ->
          "        const " <> zigOf m.key <> " = rt.Value.mkClosure("
            <> fromMaybe "" (indexAt r.entry i)
            <> ", "
            <> envRef
            <> ");"
      )
      members
    bodyCtx = ctx
      { scope = map (\m -> { key: m.key, zig: zigOf m.key, lazy: false }) members <> ctx.scope }

  outer <- emitExpr bodyCtx (r.st { lifted = r.st.lifted <> r.lifted }) body

  pure
    { text:
        joinWith "\n"
          ( [ label <> ": {" ]
              -- With no captures every member closes over `rt.no_env` directly,
              -- so binding an empty env here would leave an unused constant.
              <> (if capCount == 0 then [] else [ "        const " <> envName <> " = " <> envExpr <> ";" ])
              <> bindings
              <> [ breakStmt label body outer.text, "    }" ]
          )
    , st: outer.st
    }

-- | The `LetRec` counterpart of `topLoopMembers`: members are `Local`, keyed by
-- | identifier at the group's shared level.
localLoopMembers :: Level -> Array (Tuple Ident TcoExpr) -> Maybe (Array LoopMember)
localLoopMembers lvl = traverse \(Tuple ident texpr) -> case unTcoExpr texpr of
  Abs args body ->
    let
      key = { name: unwrap ident, level: unwrap lvl }
    in
      Just
        { target: LoopLocal key
        , key
        , ident: unwrap ident
        , arity: NEA.length args
        , params: map (\(Tuple mIdent l) -> keyOf mIdent l) (NEA.toArray args)
        , body
        }
  _ -> Nothing

emitLetRec :: Ctx -> St -> Level -> Array (Tuple Ident TcoExpr) -> TcoExpr -> Either String Out
emitLetRec ctx st lvl bindings body = case NEA.fromArray bindings of
  Just nea
    | maybe false tcoRoleIsLoop (localTcoRefBindings lvl nea)
    , Just members <- localLoopMembers lvl bindings ->
        emitLocalLoop ctx st members body
  _ ->
    emitLetRecGeneral ctx st lvl bindings body

emitLetRecGeneral :: Ctx -> St -> Level -> Array (Tuple Ident TcoExpr) -> TcoExpr -> Either String Out
emitLetRecGeneral ctx st lvl bindings body = do
  let
    n = st.counter
    label = "blk" <> show n
    level = unwrap lvl
    keys = map (\(Tuple ident _) -> { name: unwrap ident, level }) bindings
    exprs = map snd bindings

    fnNameFor i = Ident.lifted (ctx.prefix <> ".rec" <> show n <> "." <> show i)
    cellName i = Ident.local ("lazy." <> show n <> "." <> show i)
    envName = Ident.local ("env." <> show n)

    lazyIndices = filter (\i -> not (isAbs (fromMaybe unitExpr (exprs `indexExpr` i)))) (range' 0 (length keys))

    -- The union of the members' free variables, minus the members themselves,
    -- so that every member shares one env layout and every slot index is a
    -- compile-time constant.
    allFree = nub (concat (map freeKeys exprs))
    captured = orderKeys (filter (\k -> not (elem k keys) && isJust (lookupEntry ctx k)) allFree)

    hasEnv = not (null captured) || not (null lazyIndices)
    envText = if hasEnv then envName else "rt.no_env"

    -- Env layout: captured variables first, then one slot per lazy member.
    innerBase =
      map (\k -> { key: k, zig: zigOf k, lazy: isLazy ctx k }) captured
    envBindings =
      mapWithIndex (\i k -> "    const " <> zigOf k <> " = env[" <> show i <> "];") captured
    lazySlots =
      mapWithIndex (\j i -> { i, slot: length captured + j }) lazyIndices

    innerScope =
      innerBase
        <> map
          ( \s ->
              { key: fromMaybe emptyKey (keys `indexKey` s.i)
              , zig: "env[" <> show s.slot <> "]"
              , lazy: true
              }
          )
          lazySlots
        <> map
          ( \i ->
              { key: fromMaybe emptyKey (keys `indexKey` i)
              , zig: mkClosureOf (fnNameFor i) "env"
              , lazy: false
              }
          )
          (filter (\i -> not (elem i lazyIndices)) (range' 0 (length keys)))

  defs <- emitRecMembers ctx (st { counter = st.counter + 1 }) fnNameFor innerScope envBindings keys
    (mapWithIndex (\i e -> { i, e }) exprs)

  bodyCtx <- Right
    ( ctx
        { scope =
            mapWithIndex
              ( \i k ->
                  if elem i lazyIndices then { key: k, zig: cellName i, lazy: true }
                  else { key: k, zig: mkClosureOf (fnNameFor i) envText, lazy: false }
              )
              keys
              <> ctx.scope
        }
    )

  bodyOut <- emitExpr bodyCtx defs body

  let
    -- Order is forced by a mutual dependency: the initialisers close over an
    -- environment that has to contain the cells, so cells first, then the
    -- environment, then the initialisers attached.
    cellLines =
      map
        ( \i ->
            "        const " <> cellName i <> " = rt.newLazy("
              <> Ident.stringLit (keyName (fromMaybe emptyKey (keys `indexKey` i)))
              <> ", "
              <> Ident.stringLit ctx.moduleName
              <> ");"
        )
        lazyIndices

    envSlots = map (scopeText ctx) captured <> map cellName lazyIndices
    envLine =
      if not hasEnv then []
      else [ "        const " <> envName <> " = rt.copyValues(&.{ " <> joinWith ", " envSlots <> " });" ]

    initLines =
      map
        ( \i -> "        rt.setLazyInit(" <> cellName i <> ", " <> mkClosureOf (fnNameFor i) envText <> ");" )
        lazyIndices

  pure
    { text:
        joinWith "\n"
          ( [ label <> ": {" ]
              <> cellLines
              <> envLine
              <> initLines
              <> [ breakStmt label body bodyOut.text, "    }" ]
          )
    , st: bodyOut.st
    }

mkClosureOf :: String -> String -> String
mkClosureOf fnName env = "rt.Value.mkClosure(" <> fnName <> ", " <> env <> ")"

emitRecMembers
  :: Ctx
  -> St
  -> (Int -> String)
  -> Array Scoped
  -> Array String
  -> Array Key
  -> Array { i :: Int, e :: TcoExpr }
  -> Either String St
emitRecMembers ctx st fnNameFor innerScope envBindings keys members =
  case uncons members of
    Nothing -> Right st
    Just { head, tail } -> do
      one <- emitRecMember ctx st fnNameFor innerScope envBindings keys head.i head.e
      emitRecMembers ctx one fnNameFor innerScope envBindings keys tail

emitRecMember
  :: Ctx
  -> St
  -> (Int -> String)
  -> Array Scoped
  -> Array String
  -> Array Key
  -> Int
  -> TcoExpr
  -> Either String St
emitRecMember ctx st fnNameFor innerScope envBindings keys i expr = case unTcoExpr expr of
  Abs args body -> do
    let
      { head: Tuple mIdent lvl, tail } = NEA.uncons args
      key = keyOf mIdent lvl
      argZig = zigOf key
      inner = case NEA.fromArray tail of
        Nothing -> body
        Just rest -> TcoExpr mempty (Abs rest body)
      scope = cons { key, zig: argZig, lazy: false } innerScope
    bodyOut <- emitExpr (ctx { scope = scope }) st inner
    let
      bodyFree = freeKeys inner
      argDiscard = if elem key bodyFree then [] else [ "    _ = " <> argZig <> ";" ]
      def = recDef (fnNameFor i) argZig (envLinesFor envBindings keys bodyFree) argDiscard inner bodyOut.text
    pure (bodyOut.st { lifted = snoc bodyOut.st.lifted def })

  -- Not a function, so it becomes a lazy cell's initialiser: a closure of one
  -- ignored argument, exactly the `Unit -> a` the laziness contract specifies.
  _ -> do
    let argZig = Ident.local ("lazyarg." <> show st.counter)
    bodyOut <- emitExpr (ctx { scope = innerScope }) (st { counter = st.counter + 1 }) expr
    let
      bodyFree = freeKeys expr
      def =
        recDef (fnNameFor i) argZig (envLinesFor envBindings keys bodyFree)
          [ "    _ = " <> argZig <> ";" ]
          expr
          bodyOut.text
    pure (bodyOut.st { lifted = snoc bodyOut.st.lifted def })

recDef :: String -> String -> Array String -> Array String -> TcoExpr -> String -> String
recDef fnName argZig envLines argDiscard body bodyText =
  joinWith "\n"
    ( [ "fn " <> fnName <> "(env: []const rt.Value, " <> argZig <> ": rt.Value) rt.Error!rt.Value {" ]
        <> envLines
        <> argDiscard
        <> [ returnStmt (diverges body) bodyText, "}", "" ]
    )

-- | `env` is used by more than the bindings pulled out of it: every reference
-- | to a group member -- including a self-reference -- emits
-- | `mkClosure(fn, env)`. Discarding on "no captures" alone produces a
-- | pointless discard for a recursive function that captures nothing, which
-- | `Data.Void.absurd` is exactly.
envLinesFor :: Array String -> Array Key -> Array Key -> Array String
envLinesFor envBindings keys bodyFree =
  if not (null envBindings) then envBindings
  else if not (null (filter (\k -> elem k bodyFree) keys)) then []
  else [ "    _ = env;" ]

-- | Pattern matching arrives already compiled: a list of condition/result
-- | pairs with a fallback. Conditions are ordinary Values, so each is a
-- | `.asBool()` test, and a labelled block gives the equivalent of the JS
-- | backend's early return.
-- |
-- | No reachability tracking is needed. The optimizer has already pruned
-- | unreachable alternatives, and the fallback is always emitted -- it is an
-- | expression (often `Fail`), not an optional trailing panic.
emitBranch :: Ctx -> St -> Array (Pair TcoExpr) -> TcoExpr -> Either String Out
emitBranch ctx st pairs fallback = do
  let
    n = st.counter
    label = "case" <> show n
  arms <- emitArms ctx (st { counter = st.counter + 1 }) label pairs
  fb <- emitExpr ctx arms.st fallback
  pure
    { text:
        joinWith "\n"
          ( [ label <> ": {" ]
              <> arms.lines
              <> [ breakStmt label fallback fb.text, "    }" ]
          )
    , st: fb.st
    }

emitArms :: Ctx -> St -> String -> Array (Pair TcoExpr) -> Either String { lines :: Array String, st :: St }
emitArms ctx st label pairs = case uncons pairs of
  Nothing -> Right { lines: [], st }
  Just { head: Pair cond result, tail } -> do
    c <- emitExpr ctx st cond
    r <- emitExpr ctx c.st result
    rest <- emitArms ctx r.st label tail
    pure
      { lines:
          cons ("        if (" <> c.text <> ".asBool()) " <> tailText label result r.text <> ";")
            rest.lines
      , st: rest.st
      }

-- | Primitive operations. These are new: the optimizer rewrites the prelude's
-- | foreign arithmetic, comparison and append into `PrimOp`, so most of what
-- | used to be an FFI call arrives here instead.
-- |
-- | Four operators are deliberately NOT implemented, because this backend's
-- | semantics differ from the JavaScript ones the optimizer assumes:
-- | integer division (ours is Euclidean and returns 0 on divide-by-zero), the
-- | three bit-shifts (JavaScript masks the count to 5 bits), and string
-- | ordering (the runtime has `stringEq` but no comparison). `Main.purs`
-- | filters the corresponding entries out of `coreForeignSemantics`, so those
-- | calls stay in the FFI where the semantics already match. If one of these
-- | ever fires, the filter has drifted.
emitPrimOp :: Ctx -> St -> BackendOperator TcoExpr -> Either String Out
emitPrimOp ctx st op = case op of
  Op1 o a -> do
    x <- emitExpr ctx st a
    text <- op1Text o x.text
    pure { text, st: x.st }
  Op2 o a b -> do
    x <- emitExpr ctx st a
    y <- emitExpr ctx x.st b
    text <- op2Text o x.text y.text
    pure { text, st: y.st }

op1Text :: BackendOperator1 -> String -> Either String String
op1Text o x = case o of
  OpBooleanNot -> Right ("rt.Value.mkBool(!" <> x <> ".asBool())")
  OpIntBitNot -> Right ("rt.Value.mkInt(~" <> x <> ".asInt())")
  OpIntNegate -> Right ("rt.Value.mkInt(-%" <> x <> ".asInt())")
  OpNumberNegate -> Right ("rt.Value.mkNumber(-" <> x <> ".asNumber())")
  OpArrayLength -> Right ("rt.Value.mkInt(@intCast(" <> x <> ".asArray().len))")
  OpIsTag (Qualified _ ctor) ->
    Right ("rt.Value.mkBool(" <> x <> ".hasTag(" <> Ident.stringLit (unwrap ctor) <> "))")

op2Text :: BackendOperator2 -> String -> String -> Either String String
op2Text o x y = case o of
  OpArrayIndex -> Right (x <> ".asArray()[@intCast(" <> y <> ".asInt())]")

  -- Zig's `and`/`or` short-circuit, and the right operand is part of the
  -- right-hand expression, so this stays lazy in the second argument as
  -- PureScript expects.
  OpBooleanAnd -> Right ("rt.Value.mkBool(" <> x <> ".asBool() and " <> y <> ".asBool())")
  OpBooleanOr -> Right ("rt.Value.mkBool(" <> x <> ".asBool() or " <> y <> ".asBool())")

  OpBooleanOrd ord -> Right (cmp ord ("@intFromBool(" <> x <> ".asBool())") ("@intFromBool(" <> y <> ".asBool())"))
  OpCharOrd ord -> Right (cmp ord (x <> ".asChar()") (y <> ".asChar()"))
  OpIntOrd ord -> Right (cmp ord (x <> ".asInt()") (y <> ".asInt()"))
  OpNumberOrd ord -> Right (cmp ord (x <> ".asNumber()") (y <> ".asNumber()"))

  OpStringOrd OpEq -> Right ("rt.Value.mkBool(" <> x <> ".stringEq(" <> y <> ".asString()))")
  OpStringOrd OpNotEq -> Right ("rt.Value.mkBool(!" <> x <> ".stringEq(" <> y <> ".asString()))")
  OpStringOrd _ -> Left "PrimOp: string ordering (Data.Ord.ordString should be filtered)"

  OpIntNum OpAdd -> Right (intOp "+%" x y)
  OpIntNum OpSubtract -> Right (intOp "-%" x y)
  OpIntNum OpMultiply -> Right (intOp "*%" x y)
  OpIntNum OpDivide -> Left "PrimOp: Int division (Data.EuclideanRing.intDiv should be filtered)"

  OpNumberNum OpAdd -> Right (numOp "+" x y)
  OpNumberNum OpSubtract -> Right (numOp "-" x y)
  OpNumberNum OpMultiply -> Right (numOp "*" x y)
  OpNumberNum OpDivide -> Right (numOp "/" x y)

  OpIntBitAnd -> Right (intOp "&" x y)
  OpIntBitOr -> Right (intOp "|" x y)
  OpIntBitXor -> Right (intOp "^" x y)
  OpIntBitShiftLeft -> Left "PrimOp: Int shl (Data.Int.Bits should be filtered)"
  OpIntBitShiftRight -> Left "PrimOp: Int shr (Data.Int.Bits should be filtered)"
  OpIntBitZeroFillShiftRight -> Left "PrimOp: Int zshr (Data.Int.Bits should be filtered)"

  OpStringAppend ->
    Right
      ( "rt.Value.mkString(rt.concatString(" <> x <> ".asString(), " <> y <> ".asString()))" )

-- | `Fail` becomes `@panic`, which is `noreturn`. Zig then rejects the
-- | enclosing `return` or `break` as unreachable code -- control flow has
-- | already diverted by the time it would run. So a diverging expression is
-- | emitted as a bare statement instead.
-- |
-- | This only became reachable with the optimizer: the CoreFn emitter tracked
-- | reachability itself and simply omitted the trailing panic, whereas here
-- | `Fail` arrives as an ordinary expression in the IR, in tail position of a
-- | branch, a let, or a whole binding.
diverges :: TcoExpr -> Boolean
diverges expr = case unTcoExpr expr of
  Fail _ -> true
  _ -> false

returnStmt :: Boolean -> String -> String
returnStmt divergent text =
  if divergent then "    " <> text <> ";" else "    return " <> text <> ";"

breakStmt :: String -> TcoExpr -> String -> String
breakStmt label e text = "        " <> tailText label e text <> ";"

tailText :: String -> TcoExpr -> String -> String
tailText label e text = if diverges e then text else "break :" <> label <> " " <> text

cmp :: BackendOperatorOrd -> String -> String -> String
cmp ord x y = "rt.Value.mkBool(" <> x <> " " <> ordText ord <> " " <> y <> ")"

ordText :: BackendOperatorOrd -> String
ordText = case _ of
  OpEq -> "=="
  OpNotEq -> "!="
  OpGt -> ">"
  OpGte -> ">="
  OpLt -> "<"
  OpLte -> "<="

-- | Every Int operation wraps, matching JavaScript's `| 0`. Zig's plain `+`
-- | panics on overflow in Debug, where JavaScript silently wraps.
intOp :: String -> String -> String -> String
intOp o x y = "rt.Value.mkInt(" <> x <> ".asInt() " <> o <> " " <> y <> ".asInt())"

numOp :: String -> String -> String -> String
numOp o x y = "rt.Value.mkNumber(" <> x <> ".asNumber() " <> o <> " " <> y <> ".asNumber())"

-- | Wrap a body in an `Effect` thunk: a lifted closure whose argument is
-- | ignored, so that nothing runs until `rt.runEffect` applies unit.
-- |
-- | The synthetic parameter key uses a negative level derived from the fresh
-- | counter. Negative levels cannot collide with a real binder's (the optimizer
-- | numbers from zero), and using the counter keeps nested thunks from
-- | declaring the same parameter name, which Zig rejects as shadowing.
emitThunk :: Ctx -> St -> Array Key -> (Ctx -> St -> Either String Out) -> Either String Out
emitThunk ctx st bodyFree emitBody =
  emitLifted ctx st thunkKey bodyFree false emitBody
  where
  thunkKey = { name: "eff", level: -1 - st.counter }

-- | Perform an effect *now* and yield its result.
-- |
-- | This is what makes MagicDo pay. The generic case has to build a thunk and
-- | immediately force it with `rt.runEffect`, but every node the optimizer
-- | produced structurally is known to be an effect already, so its work can be
-- | emitted inline with no closure at all. `pure x` becomes `x`; a `Ref` read
-- | becomes a pointer dereference; a nested do-block becomes a nested Zig
-- | block.
emitPerform :: Ctx -> St -> TcoExpr -> Either String Out
emitPerform ctx st expr = case unTcoExpr expr of
  EffectPure a -> emitExpr ctx st a
  EffectDefer a -> emitPerform ctx st a
  EffectBind _ _ _ _ -> emitEffectBlock ctx st expr

  PrimEffect (EffectRefNew a) -> do
    o <- emitExpr ctx st a
    pure { text: "rt.newRef(" <> o.text <> ")", st: o.st }

  PrimEffect (EffectRefRead r) -> do
    o <- emitExpr ctx st r
    pure { text: o.text <> ".asRef().*", st: o.st }

  -- A write is a statement in Zig, not an expression, so it needs a block to
  -- sit in expression position -- and `Effect Unit` still has to yield a value.
  PrimEffect (EffectRefWrite r v) -> do
    ro <- emitExpr ctx st r
    vo <- emitExpr ctx ro.st v
    let label = "eff" <> show vo.st.counter
    pure
      { text:
          joinWith "\n"
            [ label <> ": {"
            , "        " <> ro.text <> ".asRef().* = " <> vo.text <> ";"
            , "        break :" <> label <> " rt.Value.mkUnit();"
            , "    }"
            ]
      , st: vo.st { counter = vo.st.counter + 1 }
      }

  -- Any other expression is an ordinary `Effect` value -- an application, a
  -- variable, an FFI import -- so it has to be forced.
  _ -> do
    o <- emitExpr ctx st expr
    pure { text: "(try rt.runEffect(" <> o.text <> "))", st: o.st }

-- | Flatten a chain of `EffectBind`s into ONE Zig block of statements.
-- |
-- | Emitting each bind as its own thunk would allocate a closure per `>>=`,
-- | which is exactly what MagicDo exists to avoid: the optimizer has already
-- | proven the chain is a straight line, so it becomes a straight line.
-- |
-- | A bind whose result the continuation ignores is discarded rather than
-- | bound -- Zig rejects an unused local constant, and PureScript produces
-- | these constantly, since every `discard` in a do-block binds `$__unused`
-- | and the loop combinators bind a result nobody reads.
emitEffectBlock :: Ctx -> St -> TcoExpr -> Either String Out
emitEffectBlock ctx st expr = do
  let label = "eff" <> show st.counter
  r <- spine ctx (st { counter = st.counter + 1 }) [] expr
  pure
    { text:
        joinWith "\n"
          ( [ label <> ": {" ]
              <> r.stmts
              <> [ "        break :" <> label <> " " <> r.tail <> ";", "    }" ]
          )
    , st: r.st
    }
  where
  spine
    :: Ctx
    -> St
    -> Array String
    -> TcoExpr
    -> Either String { stmts :: Array String, tail :: String, st :: St }
  spine c s acc e = case unTcoExpr e of
    EffectBind mIdent lvl a b -> do
      let
        key = keyOf mIdent lvl
        zig = zigOf key
        binder = if elem key (freeKeys b) then "const " <> zig else "_"
      ao <- emitPerform c s a
      let c' = c { scope = cons { key, zig, lazy: false } c.scope }
      spine c' ao.st (snoc acc ("        " <> binder <> " = " <> ao.text <> ";")) b
    _ -> do
      o <- emitPerform c s e
      pure { stmts: acc, tail: o.text, st: o.st }

-- ---------------------------------------------------------------------------
-- Scope and keys

keyOf :: Maybe Ident -> Level -> Key
keyOf mIdent lvl = { name: maybe' mIdent, level: unwrap lvl }
  where
  maybe' = case _ of
    Just (Ident s) -> s
    Nothing -> ""

emptyKey :: Key
emptyKey = { name: "", level: -1 }

keyName :: Key -> String
keyName k = if k.name == "" then "anonymous" else k.name

keyText :: Key -> String
keyText k = keyName k <> "@" <> show k.level

-- | `@"v.<name>.<level>"`. The pair is unique by construction, so there is no
-- | shadowing to defend against and no counter suffix.
zigOf :: Key -> String
zigOf k = Ident.local ((if k.name == "" then "l" else k.name) <> "." <> show k.level)

-- | A stable capture order, so that env slot indices are deterministic.
orderKeys :: Array Key -> Array Key
orderKeys = sortWith (\k -> Tuple k.level k.name) <<< nub

lookupEntry :: Ctx -> Key -> Maybe Scoped
lookupEntry ctx key = findMap (\e -> if e.key == key then Just e else Nothing) ctx.scope

isLazy :: Ctx -> Key -> Boolean
isLazy ctx key = case lookupEntry ctx key of
  Just e -> e.lazy
  Nothing -> false

-- | How a local is written AT A USE SITE in the current scope. Not always
-- | `zigOf`: a recursive-let member is a whole `mkClosure` expression, and a
-- | captured local inside a lifted body is an `env[i]`. Anything building a
-- | capture list must go through here.
scopeText :: Ctx -> Key -> String
scopeText ctx key = case lookupEntry ctx key of
  Just e -> e.zig
  Nothing -> zigOf key

isAbs :: TcoExpr -> Boolean
isAbs expr = case unTcoExpr expr of
  Abs _ _ -> true
  _ -> false

unitExpr :: TcoExpr
unitExpr = TcoExpr mempty PrimUndefined

indexExpr :: Array TcoExpr -> Int -> Maybe TcoExpr
indexExpr xs i = findMap (\p -> if p.i == i then Just p.x else Nothing) (mapWithIndex (\j x -> { i: j, x }) xs)

indexKey :: Array Key -> Int -> Maybe Key
indexKey xs i = findMap (\p -> if p.i == i then Just p.x else Nothing) (mapWithIndex (\j x -> { i: j, x }) xs)

-- ---------------------------------------------------------------------------
-- Free variables

-- | Locals referenced in an expression but bound outside it. `Var` is never
-- | free -- it compiles to a call, not a capture.
freeKeys :: TcoExpr -> Array Key
freeKeys = nub <<< go []
  where
  go bound node = case unTcoExpr node of
    Local mIdent lvl ->
      let k = keyOf mIdent lvl
      in if elem k bound then [] else [ k ]

    Var _ -> []
    Lit literal -> goLit bound literal
    App f args -> go bound f <> concat (map (go bound) (NEA.toArray args))
    Abs args body -> go (bound <> map absKey (NEA.toArray args)) body
    UncurriedApp f args -> go bound f <> concat (map (go bound) args)
    UncurriedAbs args body -> go (bound <> map absKey args) body
    UncurriedEffectApp f args -> go bound f <> concat (map (go bound) args)
    UncurriedEffectAbs args body -> go (bound <> map absKey args) body
    Accessor e _ -> go bound e
    Update e props -> go bound e <> concat (map (go bound <<< propValue) props)
    CtorSaturated _ _ _ _ fields -> concat (map (go bound <<< snd) fields)
    CtorDef _ _ _ _ -> []

    LetRec lvl bindings body ->
      let
        inner = bound <> map (\(Tuple ident _) -> { name: unwrap ident, level: unwrap lvl })
          (NEA.toArray bindings)
      in
        concat (map (go inner <<< snd) (NEA.toArray bindings)) <> go inner body

    Let mIdent lvl e body -> go bound e <> go (cons (keyOf mIdent lvl) bound) body
    EffectBind mIdent lvl e body -> go bound e <> go (cons (keyOf mIdent lvl) bound) body
    EffectPure e -> go bound e
    EffectDefer e -> go bound e

    Branch pairs fallback ->
      concat (map (goPair bound) (NEA.toArray pairs)) <> go bound fallback

    PrimOp o -> goOp bound o
    PrimEffect e -> goEffect bound e
    PrimUndefined -> []
    Fail _ -> []

  absKey (Tuple mIdent lvl) = keyOf mIdent lvl

  goPair bound (Pair a b) = go bound a <> go bound b

  goLit bound literal = case literal of
    LitArray items -> concat (map (go bound) items)
    LitRecord props -> concat (map (go bound <<< propValue) props)
    _ -> []

  goOp bound o = case o of
    Op1 _ a -> go bound a
    Op2 _ a b -> go bound a <> go bound b

  goEffect bound e = case e of
    EffectRefNew a -> go bound a
    EffectRefRead a -> go bound a
    EffectRefWrite a b -> go bound a <> go bound b
