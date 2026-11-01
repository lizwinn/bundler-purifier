#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-rebuild: `nix build --rebuild` of the library fixture's gem
# file and of its installed app gives the same output.
source "$(dirname "$0")/common.sh"

for check in fixture-library-gem fixture-library-app; do
  echo "== rebuild of $check"
  nix build --no-link -L ".#checks.$system.$check"
  nix build --no-link --rebuild -L ".#checks.$system.$check"
done
echo "conformance-rebuild passed"
