# SPDX-License-Identifier: MIT
#
# The fetcher for locked downloads. The lock holds two kinds of download,
# the shapes of the shared nix-purifiers library:
#
#   { path, url, mirrors, hash }
#     a file, where hash is the SRI hash of the file, and mirrors lists
#     other URLs that serve the same file
#   { path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash }
#     a git checkout, where hash is the SRI hash that nix-prefetch-git
#     reports for it, with its submodules when `submodules` is true;
#     bundler-purifier writes leaveDotGit = false and commitObject = null,
#     since Bundler needs no .git in a cached checkout
#
# A file is fetched with `fetchurl` from its URL and then its mirrors. A
# git checkout is fetched with `fetchgit` at the locked revision. Both are
# nixpkgs' fetchers by default; the builder's `fetchurl` and `fetchgit`
# arguments replace them, for credentials or other mirrors.
{
  lock,
  fetchurl,
  fetchgit,
}:
download:
let
  name = lock.downloadName download;
in
if download ? git then
  assert
    !download.git.leaveDotGit
    || throw "bundler-purifier: ${download.path} asks for a .git, which bundler-purifier does not write";
  fetchgit {
    inherit name;
    inherit (download.git) url rev;
    fetchSubmodules = download.git.submodules;
    inherit (download) hash;
  }
else
  fetchurl {
    inherit name;
    urls = [ download.url ] ++ download.mirrors;
    inherit (download) hash;
  }
