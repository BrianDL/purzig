# Conversation Handoff: purzig — distribution path proven end to end

> **For the receiving Claude:** This file is a deliberate compaction of a prior conversation, written so you can continue the work without seeing the original transcript. Read top-to-bottom before responding. Resume from the **Next actions** section. Treat **Decisions** and **Constraints** as settled — don't relitigate them. Treat **Dead ends** as off-limits unless explicitly revisited by the user.
>
> **This handoff is additive.** It assumes the 2026-08-06 through 08-17 handoffs plus `docs/codegen.md` are already in your context and does not repeat their content. Read those first. Where it says **Supersedes**, the statement here wins.

**Date:** 2026-08-22
**Original session purpose:** Resolve the three open design questions from 08-17, then prove the distribution path with a downstream smoke project.
**Status:** **Step 4 is done.** A project outside this repo compiled and ran a PureScript program whose only relationship to purzig is a hash in `build.zig.zon`. Licensing settled. The tag now appears in exactly one place. Remaining work is publishing, not mechanism.

---

## Mission

Unchanged. The four-step roadmap is complete: (1) `Effect` 08-09; (2) the optimizer 08-12/08-14; (3) commonly-used libraries 08-16; (4) **importable library — this session**.

What is left is making it reachable by someone else: a public host, a real tag, and documentation.

## Next actions

1. **Push to GitHub and cut a real tag.** The forge (`git.tensorial.space`) is behind a Netbird overlay and was unreachable during this session, so `v0.1.0` was tested from a local `git archive` tarball over `file://`. Sequence: add the `github` remote, push `master` (as `main` if GitHub insists), set `REPO=` in `tools/mkpackageset.sh` to the GitHub clone URL, regenerate `packages.json`, tag `v0.1.1` rather than moving `v0.1.0`, then `zig fetch` the GitHub tarball for a real hash and repoint the smoke project at it.
2. **Ship `"type": "module"` inside `compiler/dist/`.** Every downstream build currently prints `MODULE_TYPELESS_PACKAGE_JSON` naming the *user's* `package.json`. The fix is a two-line `package.json` beside the bundle so node resolves the module type there instead of walking up into the consumer's project — the same fix applied to the compiler workspace in 08-06, one directory lower. `compiler/dist` is already in `.paths`.
3. **Write `docs/SUPPORTED.md` and a README consumer section.** Both now have content to describe: what a consumer needs installed (zig, purs, node, **and their own spago via `package.json`** — purzig does not provide it), the four-file project shape, and which registry packages resolve but fail at `MISSING FFI`.
4. **The arena.** The last of the three 08-17 questions, deliberately deferred: still open, still "is it needed, what is the worst outcome". Now has a real consumer story to reason about.
5. Unchanged from 08-16: `codegen.md`'s PrimOp table lists ten operators where `emitPrimOp` implements eighteen; the `Value` type list is missing the `marray` row. `codegen.md` line 6 still says `purs/example/output-zig/` and should say `example/output-zig/`.

## Status right now

`~/purzig-smoke` — a sibling scratch directory containing only `build.zig`, `build.zig.zon`, `spago.yaml`, `src/Main.purs`, `test/Test/Main.purs` — ran `zig build run` and printed `smoke`. The log confirms three things that could not be asserted before:

- **The tarball is self-sufficient.** `bundle.js` executed from `zig-pkg/purzig-0.1.0-<hash>/compiler/dist/`, so `.paths` omits nothing the helper needs and the bundle was genuinely committed at the tag.
- **FFI reaches git-cloned packages.** Every `(ffi)` line in the driver output — `Data.Array.ST.ffi.zig`, `Data.String.CodePoints.ffi.zig`, and the rest — means the driver found each `.zig` beside its `.purs` inside spago's clone rather than in a local path override. This was the last genuine unknown in the design.
- **The local package set was read**: spago logged "Read the package set from local path" and regenerated the lockfile citing "package set is local".

167 of 176 module directories decoded; the nine are the `Prim` family, which have no `corefn.json`. `zig build test` in the purzig repo remains green.

## What changed

### Licensing — settled
AGPL-3.0-or-later, plain, with **no linking exception**, deliberately. The runtime links into every binary purzig produces, so a purzig-built program is a combined work and must be AGPL too, including AGPL §13's source-offer obligation for network services. That is the intended effect and belongs in the README where a user sees it before investing.

Scope was over-engineered and then cut back at the user's direction. What is actually needed: the root `LICENSE`, a `NOTICE` for `bundle.js` (`cat compiler/.spago/p/*/LICENSE > NOTICE`, since the committed bundle is a binary redistribution of permissively-licensed packages whose attribution must travel with it), `"NOTICE"` added to `.paths`, and three README lines stating that `packages/*/src/**.purs` are upstream's under each package's own `LICENSE` while everything else is AGPL.

### The tag appears once
**Supersedes** the 08-17 open question. Spago accepts `packageSet: path:` as well as `url:`, and a set loaded from a path still resolves `{git, ref, subdir}` entries normally — the entries are parsed independently of where the file came from. So `build/purzig.zig` copies the dependency's `packages.json` into `<project>/.purzig/packages.json` in the same step that writes the shim, and a consumer's `spago.yaml` names that fixed path. The tag lives only in `build.zig.zon`; skew is impossible rather than detected. The copy tolerates a missing set (`|| true`) so the in-repo fixture, which resolves by path, still builds.

### Distribution moves to GitHub
The self-hosted Forgejo instance resolves publicly but its address is in the CGNAT range Netbird hands out, and the forge peer is relay-only — 100% packet loss during this session despite Netbird reporting it Connected. Since a `build.zig.zon` URL and hash are frozen into a tag forever, a host only reachable over a VPN makes a poor thing to pin. Decision: **GitHub is the publishing remote, the forge stays canonical for development.** Two remotes on one branch rather than a separate publishing branch — a diverging `main` would make `git describe` on `master` meaningless and impose merge discipline forever, for no gain the second remote does not already give.

Note the archive URL differs by host: Forgejo/Gitea is `/{owner}/{repo}/archive/{tag}.tar.gz`, GitHub is `/{owner}/{repo}/archive/refs/tags/{tag}.tar.gz`. Easy to carry the wrong one across.

## Decisions (settled — do not relitigate)

- **AGPL-3.0-or-later, no linking exception.** See above. If software under other terms is ever wanted, purzig is not the toolchain for it — that is the point, not an oversight.
- **`packageSet: path: .purzig/packages.json`,** written by the build, rather than a `url:` carrying the tag. **Supersedes** the 08-17 plan of a configure-time consistency check between two tag occurrences: there is now only one occurrence.
- **The set is copied into the project directory, not the Zig cache.** Spago resolves the path relative to the project, which is not necessarily the build root, so a cache path would force `../` segments the user has to get right. Costs one generated directory beside their sources, which their `.gitignore` covers.
- **GitHub as publishing remote, forge as development origin.** One branch, two remotes; `release` gains a push to both.
- **A consumer needs their own spago.** purzig ships the prebuilt bundle so nobody rebuilds the backend, but `spago build` still runs on the user's sources and nothing in the Zig dependency provides it. Consumers pin spago in their own `package.json` exactly as this repo does. The "no npm" decision was about purzig's *distribution*, never about avoiding node or npm entirely.

## Constraints and facts

- A local `.path` dependency does **not** exercise `.paths` in `build.zig.zon` — Zig uses the directory as-is. Only a fetched tarball enforces the list. That is why phase 1 (path dependency) and phase 2 (tarball) had to be separate, and both were worth running.
- `git archive` and both forges' tag tarballs contain **only committed files**, which is what makes the `git add -f` of `bundle.js` at tags load-bearing. Building a local tarball from a tag is a cheap way to catch a missing bundle before publishing.
- A downstream project does not inherit the purzig devenv shell by `cd`-ing to a sibling — direnv unloads. Either `devenv shell` first or copy `devenv.nix`, `devenv.lock`, `devenv.yaml`, `.envrc` **and `package.json`/`package-lock.json`**, since spago comes from npm into a per-project `node_modules`.
- GitHub's auto-generated tag tarballs are regenerated on demand and have changed bytes at least once historically (a 2023 compression change broke hashes across several ecosystems). If a pinned hash ever stops matching, the fix is uploading a `git archive` tarball as a release asset and pinning that instead.
- `spago init` scaffolds `test/Test/Main.purs`, and `spago build` compiles the whole workspace, so `Test.Main.zig` is generated but never run. Decide whether `test/` belongs in a published example before users ask.

## Open questions

- **The arena that never frees.** Unchanged from 08-17 and now the only one of the three left. Established facts: `forE`/`whileE`/`foreachE` make unbounded allocation reachable; a `Ref` written in a loop costs memory proportional to writes; a process that exits has the OS reclaim everything, which is why nothing has hurt in seventeen days. What changes the calculus is a long-running process. *Blocked on: what the user intends to write in purzig.*
- Unchanged from 08-16: `diverges` tests only for a literal `Fail`; `ordString` could leave `unsupported`; `sourceSpan` reaches nothing; memoisation, integer tags, block indentation, redundant `try` parens.

## Artifacts and references

| Item | Location | Notes |
|---|---|---|
| Smoke project | `~/purzig-smoke` | Four files; the proof that step 4 works |
| Public build API | `build/purzig.zig` | Now also copies the package set |
| Set generator | `tools/mkpackageset.sh` | `REPO=` still a placeholder; run once against GitHub |
| Spago package sets | https://github.com/purescript/spago | `packageSet: path:` and `url:`, `RemotePackageSet` shapes |

## Dead ends (do not repeat)

- **A separate `main` publishing branch.** Rejected in favour of a second remote on one branch: a diverging branch makes tags ambiguous and `git describe` useless on the development branch.
- **`LICENSES.md`, SPDX header scripts, a generated-NOTICE tool.** Built, then cut as over-engineering. The per-package `LICENSE` files already sitting in each directory are the conventional signal; a `cat` and three README lines cover the rest. The user's correction: *"we are over engineering this"*.
- **Pinning a `build.zig.zon` URL at a host only reachable over a VPN.** A URL plus hash is frozen into a tag forever.
- **Assuming a sibling directory inherits the devenv shell.** direnv unloads on `cd`.

## User preferences and communication style

Additive to the earlier lists:

- **Do the search rather than offering to.** Verbatim: *"should have done without asking, since it's only a search"*. If a question is answerable by searching, search in the same turn.
- **Push back on scope.** The licensing work was cut roughly in half by the user asking what it actually bought. Propose the minimum that closes a real gap, and say plainly when something is clarity rather than protection.
- **Full files when a file changes shape**, not fragments to splice — asked explicitly during the smoke-project setup.
