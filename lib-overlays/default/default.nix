# SPDX-License-Identifier: MIT
#
# The `bundler-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildBundlerProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    bundler-purifier = prev.bundler-purifier or { };
  };

}
