# SPDX-License-Identifier: MIT
#
# The `bundler-purifier` library namespace of the nix-purifiers contract:
# `readLock` (nix/lib/read-lock.nix), the lock of a Bundler project in
# memory. The builder is a package, which the package overlay adds as
# `buildBundlerProject`.
{ ... }:
{

  overlay = final: prev: {
    bundler-purifier = (prev.bundler-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
