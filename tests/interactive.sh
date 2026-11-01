#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The tests of what runs outside the Nix sandbox, which `nix flake check`
# cannot run: the lock run, `install` and `push`. CI runs this after the
# flake's checks. It needs nix and the network.
#
# 1. The lock run of each fixture writes the committed lockfiles again.
# 2. `install` installs the app fixture from the locked gems, and the app
#    runs on that install.
# 3. `push` builds the library fixture's gem with Nix and uploads that
#    file, which tests/fake-gem-server.rb receives in place of a gem host.
# 4. A stale lock, an entry missing from the lock, a tampered hash, a
#    malformed lockfile and an old lock format each fail with a message
#    that names the fix.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
cli="$(nix build --no-link --print-out-paths '.#cli')/bin/bundler-purifier"
# The Ruby the CLI runs on comes first on PATH, so `install` and `push` use
# it rather than a Ruby the machine has.
ruby=$(grep -o '/nix/store/[^"]*-ruby-[^/"]*/bin' "$cli" | head -n 1)
nixpkgs=$(grep -o "BUNDLER_PURIFIER_NIXPKGS='[^']*'" "$cli" | cut -d"'" -f2)
# Native extensions compile against that Ruby, which only nixpkgs' C
# toolchain links with; a machine's own compiler does not.
toolchain=$(nix-build "$nixpkgs" -A stdenv.cc -A gnumake --no-out-link | sed 's|$|/bin|' | paste -sd:)
export PATH="$ruby:$toolchain:$PATH"
work=$(mktemp -d)
trap 'kill "${server:-}" 2>/dev/null || true; rm -rf "$work"' EXIT
export BUNDLE_USER_HOME="$work/bundle-home"

# The fixtures' tracked files are copied together, since the app reaches
# ../shared-gem.
git -C "$repo" ls-files -z -- tests/fixtures | tar --null -T - -cf - | tar -xf - -C "$work"
mv "$work/tests/fixtures" "$work/fixtures"

for fixture in app library submodules; do
  echo "== lock run of $fixture"
  (cd "$work/fixtures/$fixture" && "$cli" relock)
  diff -u "$repo/tests/fixtures/$fixture/Gemfile.lock" "$work/fixtures/$fixture/Gemfile.lock"
  diff -u "$repo/tests/fixtures/$fixture/bundler-purifier.lock.json" \
    "$work/fixtures/$fixture/bundler-purifier.lock.json"
done

echo "== install of app"
export BUNDLE_PATH="$work/bundle"
(cd "$work/fixtures/app" && "$cli" install)
output=$(cd "$work/fixtures/app" && bundle exec ruby main.rb)
echo "$output"
[[ "$output" == *"app purified"* ]]
unset BUNDLE_PATH

echo "== push of greeting"
"$ruby/ruby" "$repo/tests/fake-gem-server.rb" "$work/port" "$work/upload" &
server=$!
for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
(cd "$work/fixtures/library" &&
  GEM_HOST_API_KEY=fake-key "$cli" push greeting --host "http://127.0.0.1:$(cat "$work/port")")
built=$(nix-build --no-out-link --expr "
  let pkgs = import $nixpkgs { };
  in ((pkgs.callPackage $repo/nix/lib/build-bundler-project.nix { }) {
    src = $work/fixtures/library;
  }).packages.greeting")
cmp "$work/upload" "$built/greeting-0.2.0.gem"

# 4. Each common mistake fails with a message that says what went wrong and
#    which command fixes it, both when Nix evaluates the build and in the
#    CLI. Each case works on a fresh copy of the library fixture.
fresh() {
  rm -rf "$work/broken"
  cp -r "$work/fixtures/library" "$work/broken"
}
expect_failure() {
  local what=$1 expected=$2
  shift 2
  local output
  if output=$("$@" 2>&1); then
    echo "$what: expected a failure, but it succeeded" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "$what: expected the message to contain: $expected" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "ok: $what"
}
evaluate() {
  nix-instantiate --expr "
    let pkgs = import $nixpkgs { };
    in ((pkgs.callPackage $repo/nix/lib/build-bundler-project.nix { }) {
      src = $work/broken;
    }).app"
}
edit_lock() {
  ruby -rjson -e 'path = ARGV[0]; lock = JSON.parse(File.read(path)); eval(ARGV[1]); File.write(path, JSON.pretty_generate(lock))' \
    "$work/broken/bundler-purifier.lock.json" "$1"
}
install_broken() { (cd "$work/broken" && "$cli" install); }

echo "== common mistakes"
fresh
echo 'gem "rack"' >> "$work/broken/Gemfile"
expect_failure "stale lock, Nix" 'Run `bundler-purifier lock`' evaluate
expect_failure "stale lock, CLI" "run bundler-purifier lock" install_broken

fresh
edit_lock 'lock["downloads"].reject! { |d| d["path"].start_with?("rake-") }'
expect_failure "entry missing from the lock, Nix" 'was changed by hand' evaluate
expect_failure "entry missing from the lock, CLI" "was changed by hand" install_broken

fresh
edit_lock 'lock["downloads"][0]["hash"] = "sha256-" + "A" * 43 + "="'
expect_failure "tampered hash, Nix" 'was changed by hand' evaluate
expect_failure "tampered hash, CLI" "was changed by hand" install_broken

fresh
head -c 200 "$work/fixtures/library/bundler-purifier.lock.json" > "$work/broken/bundler-purifier.lock.json"
expect_failure "malformed lockfile, Nix" 'is not a whole JSON object' evaluate
expect_failure "malformed lockfile, CLI" "is not valid JSON" install_broken

fresh
edit_lock 'lock["version"] = 1'
expect_failure "old lock format, Nix" 'Run `bundler-purifier relock`' evaluate

echo "interactive tests passed"
