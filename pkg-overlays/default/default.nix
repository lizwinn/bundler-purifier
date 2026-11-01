# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.bundler-purifier` (`.cli`), and the builder
# (nix/lib/build-bundler-project.nix) as `pkgs.buildBundlerProject`. A
# consumer that lists this flake in `projects` holds it as
# `bundler-purifier/default`, which its package sets apply by default; the
# flake also exports it as `overlays.default`.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "bundler-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildBundlerProject = final.callPackage ../../nix/lib/build-bundler-project.nix {
        inherit (closure-lib) purifier;
        inherit (closure-lib.bundler-purifier) readLock;
      };
    };
}
