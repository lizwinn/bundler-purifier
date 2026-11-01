# SPDX-License-Identifier: MIT
#
# Reads a bundler-purifier lockfile (written by `bundler-purifier lock`),
# after the checks that tell a damaged lockfile: it is a whole JSON object,
# its format version is the one this library reads, and its content matches
# its contentHash, which a hand edit breaks.
{ lockFile }:
let
  name = toString lockFile;
  text = builtins.readFile lockFile;
  length = builtins.stringLength text;
  # Nix's JSON parser fails with a message that names neither the file nor
  # the fix, so a truncated or emptied file is told apart first.
  whole =
    builtins.match "[[:space:]]*\\{.*" (builtins.substring 0 64 text) != null
    && builtins.match ".*}[[:space:]]*" (builtins.substring (length - 64) 64 text) != null;
  lock =
    assert
      whole
      || throw "bundler-purifier: ${name} is not a whole JSON object; it was cut short or overwritten. Run `bundler-purifier relock`.";
    builtins.fromJSON text;

  supportedVersion = import ./lock-version.nix;

  # The hash `bundler-purifier lock` writes as contentHash: SHA-256 of the
  # JSON of the lock without contentHash, as builtins.toJSON writes it.
  contentHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ]));
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_".
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;
in
assert
  (lock.version or null) == supportedVersion
  || throw "bundler-purifier: ${name} has lock format version ${
    toString (lock.version or "none")
  }; this library reads version ${toString supportedVersion}. Run `bundler-purifier relock` with the bundler-purifier version that provides this library.";
assert
  (lock.contentHash or null) == contentHash
  || throw "bundler-purifier: ${name} was changed by hand: its content does not match its contentHash. Run `bundler-purifier relock`.";
lock
// {
  inherit storeName;

  # The fetch name of a download: its file name, made a valid store name.
  downloadName = download: storeName (baseNameOf download.path);

  # The two kinds of download (see fetch.nix).
  files = builtins.filter (d: !(d ? git)) lock.downloads;
  gitCheckouts = builtins.filter (d: d ? git) lock.downloads;

  gemsByName = builtins.listToAttrs (
    map (gem: {
      inherit (gem) name;
      value = gem;
    }) lock.gems
  );
}
