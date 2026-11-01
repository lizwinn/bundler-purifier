# SPDX-License-Identifier: MIT
#
# The checks: sandboxed builds of the fixtures under fixtures/, from their
# committed lockfiles, and a run of what each build produced. Each
# fixture's bundler-purifier.lock.json is written by `bundler-purifier
# lock` in the fixture's directory.
{
  pkgs,
  overlay,
  cli,
}:
let
  purified = pkgs.extend overlay;

  app = purified.buildBundlerProject {
    src = ./fixtures/app;
    name = "fixture-app";
  };

  library = purified.buildBundlerProject {
    src = ./fixtures/library;
    name = "fixture-library";
    doCheck = true;
  };
in
{
  inherit cli;

  # The app's bundle compiles msgpack, takes nokogiri precompiled for this
  # platform and rainbow from its git source, all from the gem cache.
  fixture-app =
    purified.runCommand "fixture-app-runs"
      {
        nativeBuildInputs = [ app.bundle ];
      }
      ''
        export HOME="$TMPDIR"
        cd ${app.app}
        output=$(bundle exec ruby main.rb)
        echo "$output"
        case "$output" in
          *"app purified"*) ;;
          *) echo "unexpected output from the fixture app" >&2; exit 1 ;;
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
        touch "$out"
      '';
}
