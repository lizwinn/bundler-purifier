# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.bundler-purifier` (`.cli`). A consumer that lists this flake in
# `projects` holds it as `bundler-purifier/default`, which its package sets
# apply by default. The builder is in the library, as
# `lib.bundler-purifier.buildBundlerProject`.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "bundler-purifier";
}
