# SPDX-License-Identifier: MIT
#
# The `bundler-purifier` library namespace: the builder of the
# nix-purifiers contract, `buildBundlerProject` (nix/lib/build-bundler-project.nix),
# which fetches with the shared library's `purifier` namespace.
{ ... }:
{

  overlay = final: prev: {
    bundler-purifier = (prev.bundler-purifier or { }) // {
      buildBundlerProject = import ../../nix/lib/build-bundler-project.nix {
        lib = final;
        inherit (final) purifier;
      };
    };
  };

}
