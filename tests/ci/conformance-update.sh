#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-update: `bundler-purifier update` moves the update fixture's
# rainbow off its pinned 3.0.0, and both lockfiles then pass the stale
# check, in the CLI and when Nix reads the lock.
source "$(dirname "$0")/common.sh"

fixture="$work/fixtures/update"
echo "== update of update"
(cd "$fixture" && "$cli" update rainbow)
if grep -q 'rainbow (3.0.0)' "$fixture/Gemfile.lock"; then
  echo "conformance-update: rainbow is still at 3.0.0" >&2
  exit 1
fi
grep 'rainbow (' "$fixture/Gemfile.lock"

echo "== the stale check, in the CLI"
(cd "$fixture" && "$cli" lock | tee "$work/lock.out")
grep -q 'is up to date' "$work/lock.out"

echo "== the stale check, in Nix"
problems=$(nix eval --impure --json --expr "
  let flake = builtins.getFlake \"git+file://$repo\";
  in (flake.lib.bundler-purifier.readLock { src = $fixture; }).problems")
echo "$problems"
[[ "$problems" == "[]" ]]
echo "conformance-update passed"
