# SPDX-License-Identifier: MIT
#
# The gem cache of a lockfile: the directory Bundler reads with
# `bundle install --local` (its `vendor/cache`). Each locked gem file is a
# link into the store. Each git source is a copy of its checkout with the
# `.bundlecache` marker that Bundler leaves in a cached git source. It is a
# package for callPackage, with the lockfile among its arguments.
{
  lib,
  runCommand,
  fetchurl,
  fetchgit,
  lockFile,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl fetchgit; };
in
# The manifests go to the builder as files, since a large bundle locks
# hundreds of gems and the list would not fit in an environment variable.
runCommand "bundler-gem-cache"
  {
    files = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") lock.files;
    gitCheckouts = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") lock.gitCheckouts;
    passAsFile = [
      "files"
      "gitCheckouts"
    ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit lock; };
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      ln -s "$target" "$out/$rel"
    done < "$filesPath"
    while IFS=$'\t' read -r rel target; do
      cp -r "$target" "$out/$rel"
      chmod -R u+w "$out/$rel"
      touch "$out/$rel/.bundlecache"
    done < "$gitCheckoutsPath"
  ''
