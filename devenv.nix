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

  # The runtime is deliberately independent of the PureScript pipeline, so this
  # passes without exercising spago or purs at all.
  enterTest = ''
    zig build test-runtime
  '';
}
