# SPDX-License-Identifier: MIT
#
# Reads a bundler-purifier lockfile (written by `bundler-purifier lock`).
#
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

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
  lock.version == supportedVersion
  || throw "bundler-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `bundler-purifier relock` with the bundler-purifier version that provides this library.";
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
