#!/bin/sh
# Regenerate packages.json: an upstream registry package set with every locally
# vendored package overridden to point at this repo.
#
# A custom `packageSet.url` REPLACES the registry set rather than patching it,
# so the file has to be complete -- every package a downstream user might name,
# not just the seventeen we carry. Hence the merge instead of a hand-written
# file. purerl's forked package set is the same construction.
#
# Each override is a `{git, ref, subdir}` entry. `dependencies` is deliberately
# omitted: spago reads them from the package's own spago.yaml in that subdir,
# so the dependency graph stays in one place instead of being duplicated here.
#
#   usage: tools/mkpackageset.sh <git-tag> [registry-set-version]
#
# The tag must be one that EXISTS or is about to exist: it is what a user pins
# in both packageSet.url and build.zig.zon, and the FFI in packages/ is compiled
# against the runtime/ of that same commit.
set -eu

REPO="https://github.com/YOUR-USER/purzig.git"
TAG="${1:?usage: mkpackageset.sh <git-tag> [registry-set-version]}"
SET="${2:-66.0.0}"

command -v jq  >/dev/null || { echo "need jq";  exit 1; }
command -v curl >/dev/null || { echo "need curl"; exit 1; }

UPSTREAM="https://raw.githubusercontent.com/purescript/registry/main/package-sets/${SET}.json"

echo "base set:  $SET"
echo "overrides: $(ls -d packages/purescript-* | wc -l | tr -d ' ')"
echo "tag:       $TAG"

# name -> subdir, read from each package's own spago.yaml so a rename cannot
# desynchronise the set from the packages.
overrides=$(
    for d in packages/purescript-*; do
        name=$(sed -n 's/^  name: *\([a-z0-9-]*\).*/\1/p' "$d/spago.yaml" | head -1)
        test -n "$name" || { echo "no package name in $d/spago.yaml" >&2; exit 1; }
        jq -nc --arg n "$name" --arg r "$REPO" --arg t "$TAG" --arg s "$d" \
           '{($n): {git: $r, ref: $t, subdir: $s}}'
    done | jq -sc 'add'
)

curl -fsSL "$UPSTREAM" \
| jq --argjson ov "$overrides" '.packages = (.packages + $ov)' \
> packages.json

echo "wrote packages.json ($(jq '.packages | length' < packages.json) packages)"
