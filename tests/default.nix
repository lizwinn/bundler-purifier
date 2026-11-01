# SPDX-License-Identifier: MIT
#
# The checks: sandboxed builds of the fixtures under fixtures/, from their
# committed lockfiles, and a run of what each build produced. Each
# fixture's bundler-purifier.lock.json is written by `bundler-purifier
# lock` in the fixture's directory. tests/interactive.sh covers what runs
# outside the sandbox: the lock run, `install` and `push`.
{
  pkgs,
  overlay,
  cli,
}:
let
  purified = pkgs.extend overlay;

  # Runs `bundle exec ruby main.rb` in the project of a build and checks
  # its output.
  runsMain =
    name: project: expected:
    purified.runCommand name
      {
        nativeBuildInputs = [ project.bundle ];
      }
      ''
        export HOME="$TMPDIR"
        cd ${project.app}/${project.app.projectDir}
        output=$(bundle exec ruby main.rb)
        echo "$output"
        case "$output" in
          *${lib.escapeShellArg expected}*) ;;
          *) echo "${name}: expected ${expected}" >&2; exit 1 ;;
        esac
        touch "$out"
      '';

  inherit (purified) lib;

  app = purified.buildBundlerProject {
    src = ./fixtures/app;
    name = "fixture-app";
    externalPaths."../shared-gem" = ./fixtures/shared-gem;
  };

  library = purified.buildBundlerProject {
    src = ./fixtures/library;
    name = "fixture-library";
    doCheck = true;
  };

  submodules = purified.buildBundlerProject {
    src = ./fixtures/submodules;
    name = "fixture-submodules";
  };
in
{
  inherit cli;

  # The app's bundle compiles msgpack, takes nokogiri precompiled for this
  # platform, rainbow from its git source, helper from a path inside the
  # project and shared from a path outside it, all without a network.
  fixture-app = runsMain "fixture-app-runs" app "app purified";

  # The gem file of the path gem inside the app.
  fixture-app-helper-gem =
    purified.runCommand "fixture-app-helper-gem"
      {
        nativeBuildInputs = [ app.app.ruby ];
        gem = app.packages.helper.gemFile;
      }
      ''
        export HOME="$TMPDIR"
        gem specification "$gem" version | grep -q 1.0.0
        touch "$out"
      '';

  # sassc comes from a git source whose libsass is a submodule; its native
  # extension compiles libsass from the submodule's checkout.
  fixture-submodules = runsMain "fixture-submodules-runs" submodules ".purified{width:3px}";

  # The executable that the library's gemspec declares, which the lock
  # names, runs with the library's bundle.
  fixture-library-executable =
    purified.runCommand "fixture-library-executable"
      {
        nativeBuildInputs = [ library.executables.greet ];
      }
      ''
        export HOME="$TMPDIR"
        output=$(greet nix)
        echo "$output"
        case "$output" in
          *"hello, nix"*) ;;
          *) echo "unexpected output from greet" >&2; exit 1 ;;
        esac
        touch "$out"
      '';

  # The library's `app` build runs its tests; its package is the gem file
  # its gemspec builds, with the files `git ls-files` lists.
  fixture-library =
    purified.runCommand "fixture-library-gem"
      {
        nativeBuildInputs = [ library.app.ruby ];
        gem = library.packages.greeting.gemFile;
        checked = library.app;
      }
      ''
        export HOME="$TMPDIR"
        gem specification "$gem" version | grep -q 0.2.0
        files=$(gem specification "$gem" files)
        echo "$files"
        echo "$files" | grep -q lib/greeting.rb
        echo "$files" | grep -q lib/greeting/version.rb
        echo "$files" | grep -q exe/greet
        touch "$out"
      '';
}
