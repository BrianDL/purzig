# Conversation Handoff: purzig — repository reorganised for distribution

> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.
>
> **This handoff is additive.** It assumes the 2026-08-06 through 08-16 handoffs plus `docs/codegen.md` are already in your context and does not repeat their content. Read those first. Where it says **Supersedes**, the statement here wins.

**Date:** 2026-08-17
**Original session purpose:** Step 4 of the roadmap — make this project consumable as a library.
**Status:** Reorganisation done, `zig build test` green. Distribution mechanism built but unproven from the outside; three design questions open (see Open questions).

---

## Mission

Unchanged. Step 4 is now understood concretely: **`purzig` ships as one public Zig package.** A downstream user's whole checked-in project is `build.zig`, `build.zig.zon`, `spago.yaml`, `src/`, `test/` — the same shape any other PureScript backend gives them, plus the two Zig files that replace what would be a bundler config.

The project is now **named `purzig`** everywhere: the Zig package, the npm-free backend executable, `compiler/spago.yaml`'s `package.name`, and `backend.cmd`.

## Next actions

1. **Build the downstream smoke project.** This is the only thing that tests the distribution path, and none of it has run yet: a scratch directory with `spago init`, one `Main.purs`, and a `build.zig.zon` naming purzig as a **local `.path` dependency** on `../purzig` rather than a URL. That exercises the `opts.purzig = dep` branch of `addExecutable`, the `pb` vs `b` path split inside it (the part most likely to be wrong), the `.paths` list in `build.zig.zon`, and the `access("example/spago.yaml") catch return` guard's early-return path. Then flip it to `packageSet.url` + a real tag.
2. **Run `tools/mkpackageset.sh` once.** `packages.json` has never been generated. Needs `jq` and `curl` added to `devenv.nix`, and `REPO=` at the top of the script is still the placeholder `https://github.com/YOUR-USER/purzig.git`.
3. **Resolve the three open design questions below** — the user raised all three at the end of the session and they are the next discussion, not code.
4. Unchanged from 08-16: `codegen.md`'s PrimOp table lists ten operators where `emitPrimOp` implements eighteen; the `Value` type list is missing the `marray` row. Neither was touched this session.

## Status right now

`zig build test` is green after the move. Both steps ran from a clean slate — `tools/reorg.sh` deleted `output-zig/` and the old `bundle.js`, so the whole chain regenerated: `spago bundle` in `compiler/`, the `purzig` shim into `.zig-cache/purzig-bin/`, `spago build` in `example/` emitting all 89 modules, then the Zig compile of `example/output-zig/Main.zig`. `Scratch.purs`'s 231 checks pass, so `test-e2e`'s `Hello, Zig\n` assertion covers them as before.

Changes are staged but **not yet committed**. Two files still need deleting before the commit (see Constraints).

## The new layout

```
purzig/
├── build.zig              thin; re-exports the API, then wires the example as its first client
├── build.zig.zon          .name = .purzig, no dependencies, restricted .paths
├── build/purzig.zig       THE PUBLIC API: addExecutable, addRuntimeTests, Options, Artifacts
├── runtime/               unchanged
├── compiler/              was purs/compiler; bundle now at compiler/dist/bundle.js
├── packages/purescript-*/ was purs/lib/*, seventeen packages, unchanged contents
├── example/               was purs/example; still the dev fixture, still uses extraPackages
├── tools/mkpackageset.sh  generates packages.json
└── docs/
```

A downstream user writes `purzig.addExecutable(b, .{ .name = …, .purzig = b.dependency("purzig", .{}), … })`, `packageSet: url:` pointing at `packages.json` at a tag, and `backend: cmd: purzig`.

## Decisions (settled — do not relitigate)

- **The runtime and the emitter ship together, in one repo, at one tag.** Not an ordinary dependency: the generated `.zig` sits between them and is regenerated from scratch every build, so there is no old artifact a user can hold onto — bump the emitter and every file changes shape at once. `Fn1` is an ABI, not an API. Neither half has a consumer without the other. **Supersedes** the ABI-version-check idea floated earlier in this session: with one tarball carrying both, they cannot skew.
- **No npm.** Distribution is `build.zig.zon` fetching a GitHub tag tarball by URL and hash. The prebuilt `bundle.js` travels inside it, so a downstream user never runs `spago bundle` on the compiler workspace and never fetches the optimizer's git dependency. Node is still required to *run* the bundle; avoiding npm is not avoiding node. PureC is the precedent — one repo holding `src/` (a PureScript backend), `runtime/` (a real C runtime), `mk/` (build fragments), and `package-sets/`. Nobody in this corner of the ecosystem ships through a package registry.
- **`build.zig.zon` now exists.** The 08-05 "no `build.zig.zon`" decision was conditioned on nothing fetching an external Zig package; downstream, purzig *is* one, so the precondition is gone and the standard mechanism is the simplest thing.
- **`backend.cmd: purzig` resolved via a generated shim.** `spago.yaml` is static text and cannot interpolate a path the Zig build computed, so `build/purzig.zig` writes `#!/bin/sh\nexec node <abs bundle> "$@"` into `.zig-cache/purzig-bin/purzig` and calls `codegen.addPathDir(bin_dir)`. POSIX only. The user's `spago.yaml` therefore contains no paths and is identical in shape to ours.
- **`example/` keeps its `extraPackages` block.** Step 4 deletes `extraPackages` from a *user's* config, not from the fixture. Pointing the fixture at `packageSet.url` would mean every FFI fix needed a tag and a push before it could be tested. **Refines** the 08-16 note that "twelve `extraPackages` entries … is the thing step 4 deletes."
- **`build.zig` returns early unless `example/spago.yaml` exists.** A consumer's `b.dependency("purzig", .{})` *runs* our `build()`, and the tarball ships no `example/`. The guard is a file test rather than an inspection of builder internals so it survives Zig versions and explains itself.
- **Spago's git package-set entries accept `subdir`,** verified against the spago README: `git` and `ref` required, `subdir` optional "if you'd like to use a package that is not located in the root of the repo", `dependencies` optional when the package has its own `spago.yaml`. A `RemotePackageSet`'s `packages` map takes the same shapes as `extraPackages`. **This is what makes one repo possible** — it was flagged as the pivot that decided the layout.
- **The package set must be complete, not a patch.** `packageSet.url` *replaces* the registry set, so `mkpackageset.sh` merges overrides over an upstream registry set (default 66.0.0) rather than hand-listing. It reads each package's name from its own `spago.yaml`, so a rename cannot desync the set — the 08-08 lesson about hand-built FFI lists.
- **Forks cannot be published to the registry** (`prelude` etc. are taken), so a git-based custom set is the only route. Same reason purerl forked a whole set.
- **`bundle.js` is gitignored and committed only at tags** with `git add -f`, via the `release` devenv script. It must be *committed* rather than attached as a release asset, because `build.zig.zon` fetches GitHub's auto-generated `archive/refs/tags/<tag>.tar.gz`, which contains only committed files.

## Constraints and facts

- **Two dead files came through the move and must be deleted:** `compiler/src/CoreFn/Decode.purs` and `compiler/src/CoreFn/Types.purs`. The 08-12 optimizer session replaced them with `CoreFn.Json.decodeModule`; nothing imports them, and `pedanticPackages` is off for that workspace so nothing complained.
- **`compiler/dist/.gitkeep` must stay**, or the directory is absent on a fresh clone and the shim points inside a missing directory — the failure surfaces as node's error, not the build's.
- Zig 0.16 API corrections that cost one build cycle each, all now in the code: `Dir.access` takes an `io` (use `b.graph.io`); `std.process.getEnvVarOwned` is **gone** because environment variables became non-global, and `Build.Graph` has no `env_map` at 0.16.0 — use `Step.Run.addPathDir`; `std.fs.cwd` → `std.Io.Dir.cwd`; `std.process.getCwdAlloc` → `std.process.currentPathAlloc(io, allocator)`.
- `addPathDir` **appends** to PATH, so a globally installed `purzig` would shadow the shim. Not a concern today; the fix would be `setEnvironmentVariable` built from the step's own map.
- `.fingerprint` in `build.zig.zon` is set; Zig printed the value. Never change it — consumer caches key on it.
- A release is not just `git tag`: rebuild the bundle, `zig build test`, regenerate `packages.json` with the tag, `git add -f` the bundle, tag. The `release` devenv script does all of it and refuses on a dirty tree.
- The tag appears in two places a user must keep in sync — `build.zig.zon` and the `packageSet` URL. See Open questions.
- Non-vendored FFI-bearing registry packages (`aff`, `node-fs`, …) will resolve through the set and then fail at `MISSING FFI`. Decided to leave them in and ship a `docs/SUPPORTED.md`; that file is **not yet written**.

## Open questions

Three the user raised at the very end of the session, all still to discuss:

- **Setting the tag once.** It currently appears in `build.zig.zon` and in `packageSet.url`; a mismatch pairs an emitter with a package set whose FFI targets a different runtime. Candidate directions: a `zig build init` scaffolder in the helper that writes both; the helper reading its own version and warning; or the set URL being derived rather than written. *Blocked on: discussion.*
- **The arena that never frees.** Standing since 08-05 as "a v2 problem". The user wants to know whether it is still needed, and what the worst outcome is. Relevant facts already established: `forE`/`whileE`/`foreachE` make unbounded allocation reachable, and a `Ref` written in a loop costs memory proportional to the number of *writes*. *Blocked on: discussion.*
- **Licensing.** Every vendored package carries the upstream PureScript `LICENSE` (copied deliberately, 08-08, as "the price of vendoring"). The user wants **the project's own code to be AGPL** and is asking why those licences are there. Note the distinction that has not yet been drawn out: the vendored `.purs` are upstream's work under their licence, while the `.zig` FFI beside them, the runtime, and the emitter are this project's. *Blocked on: discussion.*

Unchanged and still open from 08-16: `diverges` tests only for a literal `Fail`; `ordString` could leave `unsupported`; `sourceSpan` reaches nothing; memoisation, integer tags, block indentation, redundant `try` parens.

## Artifacts and references

| Item | Location | Notes |
|---|---|---|
| Public build API | `build/purzig.zig` | The whole downstream surface; read its header comment |
| Set generator | `tools/mkpackageset.sh` | Unrun; `REPO=` is a placeholder |
| Release script | `devenv.nix`, `scripts.release` | `release v0.1.0` |
| Spago config reference | https://github.com/purescript/spago | `extraPackages` shapes (2)(3)(4), `RemotePackageSet`, `subdir` |
| PureC | https://github.com/pure-c/purec | The layout precedent: backend + runtime + package set in one repo |
| Zig 0.16 release notes | https://ziglang.org/download/0.16.0/release-notes.html | Authoritative for the API renames above |

## Dead ends (do not repeat)

- **npm distribution of the backend.** Rejected by the user outright. `purs-backend-es` does it, but that backend has no runtime to keep in sync and no reason to care.
- **Splitting the runtime into its own repo/package.** Considered and rejected once the coupling was examined; see Decisions.
- **Reading `std.Build.Graph` fields from the master-branch source when 0.16.0 is pinned.** `env_map` exists on master and not at 0.16.0 — the same mistake as reading the optimizer's `main` in 08-12, and the user called it out: *"stop guessing. Search the web for the exact module names you need using the zig version."*
- **`!compiler/dist/bundle.js` as a gitignore negation.** Un-ignores the file permanently, so a derived artifact sits untracked on every commit inviting accidental staging. Plain `bundle.js` ignore plus `git add -f` at tags is correct.
- **Shipping the reorganised tree as a tarball of moved files.** The user's correction: if files are only moving, give the `git mv` commands.

## User preferences and communication style

Additive to the earlier lists:

- **Be precise about file and line when suggesting an edit.** Verbatim: *"be precise with the file and line of the change you are suggesting"*. Name the file, the line numbers, the exact text being replaced, and what surrounds it.
- **Search the web for the exact API at the pinned version rather than recalling it.** Said explicitly this session after two consecutive wrong std names. The release notes and the tagged source are the sources; a nearby version is not.
- **If the change is a move, give the command, not a package of files.**
- Asks *why* a coupling or constraint exists and expects the reasoning, not a restatement of the conclusion.
