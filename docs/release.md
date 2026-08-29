# Cutting a release

purzig is distributed as a GitHub tag tarball fetched by `build.zig.zon`. A tag
is therefore the only way a change reaches a consumer, and the bytes GitHub
serves for that tag are what their `.hash` pins.

## When

Cut a release for any change to `runtime/`, `compiler/src/`, or a vendored
package's `.zig` FFI. Those are the three things a consumer receives, and none
of them reach anyone until they are inside a tarball.

Documentation-only changes need no tag of their own, but there is no harm in
letting them ride along with the next one.

## How

**1. Bump `.version` in `build.zig.zon`** — without the leading `v` — and commit:

```zig
    .version = "0.1.2",
```

This is the only manual step. Zig builds a package's identity from `.name` and
`.version` in the manifest, **not** from the git tag, so a tag alone leaves the
version behind. `v0.1.1` shipped a manifest saying `0.1.0` because of exactly
this. The release script cannot do the edit for you, but it refuses when the two
disagree.

**2. Run the release script** from the devenv shell:

```sh
release v0.1.2
```

It refuses on a dirty tree, on a tag that already exists, and on a
manifest-versus-tag mismatch. Then it:

- rebuilds `compiler/dist/bundle.js` from scratch — the bundle is a derived file
  no diff will tell you is stale, and shipping one built from different sources
  than the tag names is the worst failure available here;
- runs `zig build test` against that fresh bundle;
- regenerates `packages.json` with the new tag as every entry's `ref`;
- `git add -f`s the bundle, since it is gitignored and lives in the tree at tags
  only. GitHub's tag tarballs contain committed files exclusively, so a bundle
  that is merely present on disk does not travel;
- commits and tags.

**3. Push the branch and the tag to both remotes:**

```sh
git push origin master
git push github master:main v0.1.2
```

`origin` is the development forge; `github` is what consumers fetch from.

**4. Get the hash:**

```sh
zig fetch https://github.com/BrianDL/purzig/archive/refs/tags/v0.1.2.tar.gz
```

Check the prefix reads `purzig-0.1.2-…`. If it says the previous version, step 1
did not happen and the script's check did not fire — investigate rather than
proceeding, because the mismatch is silent from then on.

**5. Update the README's `build.zig.zon` snippet** with the new URL and hash.
That edit necessarily lands after the tag, so it ships in the following release.

## Never move a published tag

If a release is wrong, cut the next number. A consumer's `.hash` pins the exact
bytes of the tarball; retagging changes them and breaks anyone who already
fetched it, with an error that names a hash mismatch rather than the cause.

## If a hash stops matching

GitHub generates tag tarballs on demand rather than storing them, and the bytes
have changed at least once historically — a 2023 compression change broke pinned
hashes across several ecosystems at once. If it happens, upload a tarball built
with `git archive` as a release asset and pin that URL instead; a release asset
is stored, not regenerated.

## Testing a tag without pushing

The whole distribution path can be exercised locally, which is worth doing when
changing anything about packaging:

```sh
git archive --format=tar.gz --prefix=purzig-0.1.2/ -o /tmp/purzig-0.1.2.tar.gz v0.1.2
zig fetch file:///tmp/purzig-0.1.2.tar.gz
```

`git archive` includes only committed files, exactly as GitHub's tarball does,
so this catches a missing `bundle.js` or an incomplete `.paths` before anyone
else sees it. Point a scratch project's `build.zig.zon` at the `file://` URL and
the printed hash.

Note that a `.path` dependency does **not** test this: Zig uses the directory as
it is on disk, so `.paths` is never applied and an uncommitted bundle still
works. Only a tarball enforces either.
