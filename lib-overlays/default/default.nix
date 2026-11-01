# SPDX-License-Identifier: MIT
#
# The `bundler-purifier` library namespace of the nix-purifiers contract:
# `readLock` (nix/lib/read-lock.nix), the lock of a Bundler project in
# memory, and `buildBundlerProject` (nix/lib/build-bundler-project.nix),
# which fetches with the shared library's `purifier` namespace.
{ ... }:
{

  overlay = final: prev: {
    bundler-purifier = (prev.bundler-purifier or { }) // rec {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
      buildBundlerProject = import ../../nix/lib/build-bundler-project.nix {
        lib = final;
        inherit (final) purifier;
        inherit readLock;
      };
    };
  };

}
