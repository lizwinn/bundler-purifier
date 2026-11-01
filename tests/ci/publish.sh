#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# publish: `bundler-purifier publish` uploads the library fixture's
# release, the gem file Nix built, which tests/fake-gem-server.rb receives
# in place of a gem host.
source "$(dirname "$0")/common.sh"

"$ruby/ruby" "$repo/tests/fake-gem-server.rb" "$work/port" "$work/upload" &
server=$!
trap 'kill "$server" 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
(cd "$work/fixtures/library" &&
  GEM_HOST_API_KEY=fake-key "$cli" publish --host "http://127.0.0.1:$(cat "$work/port")")
built=$(nix build --no-link --print-out-paths ".#checks.$system.fixture-library-gem")
cmp "$work/upload" "$built/greeting-0.2.0.gem"
echo "publish passed"
