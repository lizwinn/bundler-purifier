# SPDX-License-Identifier: MIT
#
# The fetcher for locked downloads. The lock holds two kinds of download,
# the shapes of the shared nix-purifiers library:
#
#   { path, url, hash }
#     a file, where hash is the SRI hash of the file
#   { path, git = { url, rev, submodules }, hash }
#     a git checkout, where hash is the SRI hash that nix-prefetch-git
#     reports for it, with its submodules when `submodules` is true
#
# By default a file is a fixed-output derivation on Nix's built-in fetcher
# (the same derivation <nix/fetchurl.nix> makes). A fixed-output store
# path depends only on its name and hash, so the default fetcher and
# nixpkgs' fetchurl produce the same paths.
#
# `fetchurl`, when given, replaces the built-in fetcher for files. It is
# called with { name, url, hash } and is the place for credentials
# (nixpkgs' fetchurl takes `netrcPhase`) or mirrors.
#
# A git checkout is nixpkgs' fetchgit at the locked revision.
{
  lock,
  fetchgit,
  fetchurl ? null,
}:
download:
let
  name = lock.downloadName download;
in
if download ? git then
  fetchgit {
    inherit name;
    inherit (download.git) url rev;
    fetchSubmodules = download.git.submodules;
    inherit (download) hash;
  }
else if fetchurl != null then
  fetchurl {
    inherit name;
    inherit (download) url hash;
  }
else
  derivation {
    inherit name;
    builder = "builtin:fetchurl";
    system = "builtin";
    inherit (download) url;
    urls = [ download.url ];
    outputHash = download.hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
