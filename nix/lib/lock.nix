# SPDX-License-Identifier: MIT
#
# The locked downloads and outputs of a Bundler project, from its
# Gemfile.lock and the purifier lockfile that `bundler-purifier lock`
# writes beside it.
#
# Gemfile.lock records most of what a build downloads, and gemfile-lock.nix
# reads it: each gem file's name and source, each gem's SHA-256 in its
# CHECKSUMS section when it has one, and each git source's URL, revision and
# submodules. The purifier lockfile holds only what Gemfile.lock lacks:
#
#   definitionHash  the hash of the Gemfile, Gemfile.lock and gemspecs it
#                   was made from, to tell a stale lock
#   ruby            the Ruby version the lock run used
#   bundlerHash     the hash of the gem of the Bundler of BUNDLED WITH,
#                   which CHECKSUMS never lists
#   gemHashes       the hash of each gem file that CHECKSUMS does not list,
#                   by file name
#   gemSources      the remote of each gem file whose GEM section names
#                   several remotes, by file name
#   mirrors         the other URLs of a gem file, from Bundler's mirror
#                   configuration, by file name, for the files that have
#                   any
#   gitHashes       the hash nix-prefetch-git reports for each git
#                   checkout, by revision
#   executables     the executables each gemspec of the project declares,
#                   by gem name, since gemspecs are Ruby
#   contentHash     the hash of the lockfile itself
#
# Before reading, it checks that the lockfile is a whole JSON object, that
# its format version is the one this library reads, and that its content
# matches its contentHash, which a hand edit breaks.
{
  lib,
  lockFile,
  # The text of the project's Gemfile.lock.
  gemfileLockText,
}:
let
  name = toString lockFile;
  text = builtins.readFile lockFile;
  length = builtins.stringLength text;
  # Nix's JSON parser fails with a message that names neither the file nor
  # the fix, so a truncated or emptied file is told apart first.
  whole =
    builtins.match "[[:space:]]*\\{.*" (builtins.substring 0 64 text) != null
    && builtins.match ".*}[[:space:]]*" (builtins.substring (length - 64) 64 text) != null;
  purifierLock =
    assert
      whole
      || throw "bundler-purifier: ${name} is not a whole JSON object; it was cut short or overwritten. Run `bundler-purifier lock --force`.";
    builtins.fromJSON text;

  supportedVersion = import ./lock-version.nix;

  # The hash `bundler-purifier lock` writes as contentHash: SHA-256 of the
  # JSON of the lock without contentHash, as builtins.toJSON writes it.
  contentHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (
      builtins.toJSON (builtins.removeAttrs purifierLock [ "contentHash" ])
    );
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  checked =
    assert
      (purifierLock.version or null) == supportedVersion
      || throw "bundler-purifier: ${name} has lock format version ${
        toString (purifierLock.version or "none")
      }; this library reads version ${toString supportedVersion}. Run `bundler-purifier lock --force` with the bundler-purifier version that provides this library.";
    assert
      (purifierLock.contentHash or null) == contentHash
      || throw "bundler-purifier: ${name} was changed by hand: its content does not match its contentHash. Run `bundler-purifier lock --force`.";
    purifierLock;

  gemfileLock = import ./gemfile-lock.nix {
    inherit lib;
    text = gemfileLockText;
  };

  missing =
    what:
    throw "bundler-purifier: ${name} has no ${what}, which Gemfile.lock needs. Run `bundler-purifier lock`.";

  sri =
    hex:
    builtins.convertHash {
      hash = hex;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  withSlash = url: if lib.hasSuffix "/" url then url else "${url}/";

  gemFile =
    remotes: spec:
    let
      file = "${spec.name}-${spec.version}.gem";
      key = "${spec.name} (${spec.version})";
      remote =
        if lib.length remotes == 1 then
          lib.head remotes
        else
          checked.gemSources.${file}
            or (missing "source for ${file}, whose GEM section names several remotes");
    in
    {
      path = file;
      url = "${withSlash remote}gems/${file}";
      mirrors = checked.mirrors.${file} or [ ];
      hash =
        if gemfileLock.checksums ? ${key} then
          sri gemfileLock.checksums.${key}
        else
          checked.gemHashes.${file} or (missing "hash for ${file}");
    };

  bundler = gemfileLock.bundledWith or null;
  bundlerFile = "bundler-${bundler}.gem";

  files =
    lib.concatMap (source: map (gemFile source.remotes) source.specs) gemfileLock.gemSources
    ++ lib.optional (bundler != null) {
      path = bundlerFile;
      url = "https://rubygems.org/gems/${bundlerFile}";
      mirrors = checked.mirrors.${bundlerFile} or [ ];
      hash = checked.bundlerHash or (missing "hash for ${bundlerFile}");
    };

  # A git source over SSH is fetched from the HTTPS URL of the same host and
  # path, since the Nix sandbox has no SSH keys, as the lock run records it.
  httpsGitUrl =
    url:
    let
      ssh = builtins.match "ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/(.+)" url;
      scp = builtins.match "([^@/]+@)?([^/:]+):([^/].*)" url;
    in
    if ssh != null then
      "https://${builtins.elemAt ssh 1}/${builtins.elemAt ssh 3}"
    else if scp != null && builtins.match "[a-z]+://.*" url == null then
      "https://${builtins.elemAt scp 1}/${builtins.elemAt scp 2}"
    else
      url;

  # The directory Bundler caches a git source in: the last component of its
  # URL without .git, and the first twelve characters of the revision.
  gitCheckout =
    source:
    let
      remote = lib.head source.remotes;
      rev = source.fields.revision;
    in
    {
      path = "${lib.removeSuffix ".git" (baseNameOf (lib.removeSuffix "/" remote))}-${builtins.substring 0 12 rev}";
      git = {
        url = httpsGitUrl remote;
        inherit rev;
        submodules = (source.fields.submodules or "false") == "true";
        leaveDotGit = false;
        commitObject = null;
      };
      hash = checked.gitHashes.${rev} or (missing "hash for the git checkout ${remote} at ${rev}");
    };

  gitCheckouts = lib.unique (map gitCheckout gemfileLock.gitSources);

  # A path source is outside the project when its path climbs out of the
  # project root or is absolute.
  isOutside = remote: lib.hasPrefix "/" remote || remote == ".." || lib.hasPrefix "../" remote;

  gems = lib.concatMap (
    source:
    let
      remote = lib.head source.remotes;
    in
    lib.optionals (!isOutside remote) (
      map (spec: {
        inherit (spec) name version;
        dir = if remote == "." || remote == "./" then "." else lib.removeSuffix "/" remote;
        executables = checked.executables.${spec.name} or [ ];
      }) source.specs
    )
  ) gemfileLock.pathSources;
in
{
  inherit (checked) definitionHash ruby;
  inherit
    bundler
    files
    gitCheckouts
    gems
    ;

  # Every download, as the shared library's file and git entries.
  downloads = files ++ gitCheckouts;

  externalPaths = lib.sort (a: b: a < b) (
    lib.unique (builtins.filter isOutside (map (s: lib.head s.remotes) gemfileLock.pathSources))
  );

  gemsByName = builtins.listToAttrs (
    map (gem: {
      inherit (gem) name;
      value = gem;
    }) gems
  );
}
