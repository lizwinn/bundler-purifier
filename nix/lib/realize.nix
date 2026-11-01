# SPDX-License-Identifier: MIT
#
# What `bundler-purifier install` builds for the interactive mode: the gem
# cache of the lockfile, the same derivation the sandboxed build uses. The
# CLI builds it with an out-link, which is the GC root that keeps every
# locked file alive, and installs from a writable copy of it.
{
  lockFile,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared nix-purifiers library as a locked flake reference.
  purifierFlake,
}:
let
  pkgs = import nixpkgs { };
in
pkgs.callPackage ./gem-cache.nix {
  inherit lockFile;
  inherit ((builtins.getFlake purifierFlake).lib) purifier;
}
