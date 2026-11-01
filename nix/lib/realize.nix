# SPDX-License-Identifier: MIT
#
# The builder's result for the project the CLI runs in, as the CLI builds
# it outside the flake: `bundler-purifier prefetch` keeps `gemCache` with an
# out-link and `devShell` as a shell profile, and `bundler-purifier
# publish` builds `release`.
{
  # The root of the project, as an absolute path in a string.
  root,
  # The purifier lockfile, as an absolute path in a string.
  lockFile,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared nix-purifiers library as a locked flake reference.
  purifierFlake,
}:
let
  pkgs = import nixpkgs { };
  readLock = import ./read-lock.nix { inherit (pkgs) lib; };
  buildBundlerProject = import ./build-bundler-project.nix {
    inherit (pkgs) lib;
    inherit readLock;
    inherit ((builtins.getFlake purifierFlake).lib) purifier;
  };
  src = /. + root;
  lockFile' = /. + lockFile;
  # The path sources outside the project are on disk beside it, at the
  # paths Gemfile.lock gives them.
  externalPaths = builtins.listToAttrs (
    map
      (p: {
        name = p;
        value = /. + "${root}/${p}";
      })
      (readLock {
        inherit src;
        lockFile = lockFile';
      }).bundlerLock.externalPaths
  );
in
buildBundlerProject {
  inherit pkgs src externalPaths;
  lockFile = lockFile';
}
