#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-offline: after `bundler-purifier prefetch`, the everyday loop
# of the app fixture works with no network: in the dev shell that
# prefetch keeps, `bundle install` reads the prefetched gem cache, the app
# runs with `bundle exec`, and the language server starts. The loop runs
# in a network namespace of its own, with no interface but loopback, which
# needs sudo (the CI runners have it).
source "$(dirname "$0")/common.sh"

app="$work/fixtures/app"
echo "== prefetch of app"
(cd "$app" && "$cli" prefetch)

loop=$(cat <<EOF
set -euo pipefail
cd "$app"
nix develop --offline .bundler-purifier/shell --command bundle install
output=\$(nix develop --offline .bundler-purifier/shell --command bundle exec ruby main.rb)
echo "\$output"
[[ "\$output" == *"app purified"* ]]
nix develop --offline .bundler-purifier/shell --command bundle exec ruby-lsp --version
EOF
)

echo "== the everyday loop, with no network"
sudo unshare --net -- \
  setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
  env PATH="$PATH" HOME="$HOME" BUNDLE_USER_HOME="$BUNDLE_USER_HOME" bash -c "$loop"
echo "conformance-offline passed"
