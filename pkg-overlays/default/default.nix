# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.bundler-purifier` (`.cli`), and the builder
# `pkgs.buildBundlerProject` (nix/lib/build-bundler-project.nix) beside
# them, where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `bundler-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "bundler-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildBundlerProject = final.callPackage ../../nix/lib/build-bundler-project.nix { };
    };
}
