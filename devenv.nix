{ pkgs, ... }:

{
  packages = [
    pkgs.zig
    pkgs.purescript
    pkgs.esbuild
    pkgs.git
  ];

  # Node is needed twice over: spago (the PureScript rewrite) ships on npm, and
  # the backend compiler is itself a Node program.
  #
  # `npm.install.enable` runs the install on shell entry from the root
  # package.json, so spago lands in ./node_modules -- project-local, pinned in
  # the repo, no global state.
  languages.javascript = {
    enable = true;
    npm = {
      enable = true;
      install.enable = true;
    };
  };

  # Put the locally-installed binaries ahead of anything ambient, so `spago`
  # always means the pinned one.
  enterShell = ''
    export PATH="$DEVENV_ROOT/node_modules/.bin:$PATH"
    check-tools
  '';

  scripts.build-all = {
    exec = ''zig build "$@"'';
    description = "Run the whole pipeline: compiler -> codegen -> native binary";
  };

  scripts.codegen = {
    exec = ''
      zig build codegen && cat purs/example/output-zig/Main.zig
    '';
    description = "Generate Zig from PureScript and print it";
  };

  scripts.check-tools = {
    exec = ''
      echo "zig     $(zig version)"
      echo "purs    $(purs --version)"
      echo "spago   $(spago --version)"
      echo "node    $(node --version)"
      echo "esbuild $(esbuild --version)"
    '';
    description = "Report versions of the toolchain";
  };

  scripts.release = {
    description = "Tag a purzig release: rebuild the bundle, commit it, tag";
    exec = ''
      set -euo pipefail

      TAG="''${1:-}"
      if [ -z "$TAG" ]; then
        echo "usage: release <tag>   e.g. release v0.1.0" >&2
        exit 1
      fi

      cd "$DEVENV_ROOT"

      # A dirty tree means the bundle about to be committed was built from
      # sources that are not the ones the tag names.
      if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        echo "working tree is dirty -- commit or stash first" >&2
        exit 1
      fi
      if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        echo "tag $TAG already exists" >&2
        exit 1
      fi

      # Rebuild from scratch: the bundle is the artifact downstream consumes,
      # and a stale one is the worst possible thing to ship.
      rm -f compiler/dist/bundle.js
      zig build compiler
      test -s compiler/dist/bundle.js

      # Green before tagging. This exercises the bundle just built.
      zig build test

      # Regenerate the package set against this tag, so the set and the runtime
      # its FFI compiles against are the same commit.
      tools/mkpackageset.sh "$TAG"

      # -f because bundle.js is gitignored: it lives in the tree at tags only.
      git add -f compiler/dist/bundle.js
      git add packages.json
      git commit -m "release $TAG"
      git tag -a "$TAG" -m "purzig $TAG"

      echo
      echo "Tagged $TAG locally. To publish:"
      echo "  git push github main \"$TAG\""
      echo
      echo "Then get the hash for a consumer's build.zig.zon:"
      echo "  zig fetch https://github.com/BrianDL/purzig/archive/refs/tags/$TAG.tar.gz"
    '';
  };

  # The runtime is deliberately independent of the PureScript pipeline, so this
  # passes without exercising spago or purs at all.
  enterTest = ''
    zig build test-runtime
  '';
}
