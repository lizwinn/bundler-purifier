#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-relock: relocking each fixture reproduces its Gemfile.lock and
# its purifier lockfile byte for byte. The external fixture is relocked
# from its Gemfile.lock and with --lockfile, as a project kept outside
# its source is.
source "$(dirname "$0")/common.sh"

for fixture in app library submodules update; do
  echo "== relock of $fixture"
  (cd "$work/fixtures/$fixture" && "$cli" lock --force)
  diff -u "$repo/tests/fixtures/$fixture/Gemfile.lock" "$work/fixtures/$fixture/Gemfile.lock"
  diff -u "$repo/tests/fixtures/$fixture/bundler-purifier.lock.json" \
    "$work/fixtures/$fixture/bundler-purifier.lock.json"
done

echo "== relock of external"
(cd "$work/fixtures/external/project" && "$cli" --lockfile ../bundler-purifier.lock.json lock --force)
diff -u "$repo/tests/fixtures/external/project/Gemfile.lock" "$work/fixtures/external/project/Gemfile.lock"
diff -u "$repo/tests/fixtures/external/bundler-purifier.lock.json" \
  "$work/fixtures/external/bundler-purifier.lock.json"
echo "conformance-relock passed"
