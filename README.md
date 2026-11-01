# bundler-purifier

A command and a Nix library that let Nix build a Bundler project offline,
in its sandbox. The command records the files Bundler wants to download in
a lockfile, and reuses the project's existing `Gemfile.lock` for the
resolution. Nix then builds the project from that lockfile. The project
does not need generated Nix files of its own.

bundler-purifier is part of [nix-purifiers](https://nix-purifiers.github.io).

- **A lockfile.** `bundler-purifier lock` writes `bundler-purifier.lock.json`
  at the project root. It holds every gem file Bundler fetches, for every
  platform in `Gemfile.lock`, by URL and SHA-256. It also holds each git
  source at its locked revision, the Bundler version of `BUNDLED WITH`, and
  the gems the project's own gemspecs build.
- **Sandboxed builds.** `buildBundlerProject`, which the flake's overlay
  adds to a package set, turns a project and its lockfile into derivations.
  `app` is the project with its bundle installed in deployment mode, and
  `bundle` runs it. `packages.<gem>` is the gem file that a gemspec of the
  project builds, and `executables.<name>` runs each executable those
  gemspecs declare. The lockfile names every one of these outputs, so Nix
  knows them when it evaluates the flake, without building anything and
  without generated Nix files.
- **Offline installs during development.** `bundler-purifier install` runs
  `bundle install --local` against the locked files, which Nix fetches.
- **Publishing what Nix built.** `bundler-purifier push <gem>` builds the gem
  in the sandbox and pushes that file with `gem push`.

## How the lock is made

`bundler-purifier lock` runs Bundler in the project with empty gem, user,
configuration and cache directories, so the project's own `.bundle/config`
does not apply and every group is locked. When the project has no
`Gemfile.lock`, Bundler resolves one first. Bundler then caches every
locked gem for every platform (`bundle cache --all-platforms`) into the
empty cache. The lockfile records each cached gem file with the URL it came
from, which is the gem's source plus `gems/<file>`. When an old
`Gemfile.lock` merges several remotes into one source, the command asks
each remote for the file and locks the one whose file has the cached
file's hash. Each git source is recorded at its locked revision, with its
submodules when the Gemfile asks for them, and with the hash that
`nix-prefetch-git` reports for the checkout. The command also fetches the
Bundler version that `BUNDLED WITH` names, so a Nix build runs that Bundler
and fetches nothing.

`bundler-purifier lock` relocks only when the `Gemfile`, `Gemfile.lock` or a
gemspec of the project changed. `bundler-purifier relock` relocks
regardless.

The lock run uses the Ruby the project asks for, in its `.ruby-version` or
in the `RUBY VERSION` section of `Gemfile.lock`. When that differs from
the Ruby the command runs on, the command builds nixpkgs' Ruby of that
minor version. The project's `.bundle/config` applies to the lock run,
except the settings that would narrow what is locked (groups, path,
frozen and deployment), so every group is locked. The builds keep the
committed `.bundle/config` too, so settings such as compile flags for a
native extension (`BUNDLE_BUILD__<gem>`) apply in the sandbox.

## Use

In the project root:

```zsh
nix run github:nix-purifiers/bundler-purifier -- lock
```

Commit `bundler-purifier.lock.json`. A Nix build on Linux needs a Linux
platform in `Gemfile.lock`. The command warns when there is none, and
`bundle lock --add-platform x86_64-linux aarch64-linux` adds them.

The flake's `overlays.default` adds `buildBundlerProject` to a package set,
and a package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildBundlerProject, pkg-config, libpq }:
buildBundlerProject {
  src = ./.;
  name = "my-app";
  # Native extensions compile in the build; pg needs these.
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libpq ];
}
```

```nix
{
  inputs.bundler-purifier.url = "github:nix-purifiers/bundler-purifier";
  inputs.nixpkgs.follows = "bundler-purifier/nixpkgs";

  outputs = { nixpkgs, bundler-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ bundler-purifier.overlays.default ];
      };
      project = pkgs.callPackage ./package.nix { };
    in
    {
      packages.${system} = {
        default = project.app;
        bundle = project.bundle;
      };
    };
}
```

`nix build` builds the app. `nix shell '.#bundle' -c bundle exec ruby
main.rb`, run in the app's store path, runs it. `nix/lib/build-bundler-project.nix`
documents the builder's arguments: `ruby` (the default is nixpkgs' Ruby of
the minor version the lock was made with), `nativeBuildInputs` and
`buildInputs` for native extensions, `without` for Bundler groups to leave
out, `doCheck` with `checkCommand` (`bundle exec rake` by default),
`fetchurl` for credentials or mirrors, `externalPaths` for path sources
outside the project, and `srcFilter`.

### Sources

Every kind of source a `Gemfile.lock` can name works:

- **Gem servers** (`source "https://…"`): each gem file, for every platform
  in `Gemfile.lock`. When Bundler is configured with a mirror for the
  source (`bundle config mirror.https://rubygems.org <mirror>`), the lock
  records the mirror's URL as a fallback for each file. A server that
  needs credentials takes them through the builder's `fetchurl` argument.
- **Git** (`git:`, `github:`), with `submodules: true` too. The Nix sandbox
  has no SSH keys, so a source over SSH (`git@host:owner/repo` or
  `ssh://host/owner/repo`) is locked at the HTTPS URL of the same host
  and path. A private repository takes a credentialed fetcher through the
  builder's `fetchgit` argument, which is called with the arguments of
  nixpkgs' `fetchgit`. The lock run itself uses your SSH keys and git
  credential helpers.
- **Paths inside the project** (`path:`, `gemspec`). Their gemspecs build
  `packages.<gem>`.
- **Paths outside the project**, such as `path: "../shared"`. The lock lists
  them as `externalPaths`, and the build takes each tree as an argument,
  keyed by the path `Gemfile.lock` gives it:

  ```nix
  buildBundlerProject {
    src = ./.;
    externalPaths."../shared" = inputs.shared;
  }
  ```

  The build lays the project and those trees out at the same relative
  positions, and `app.projectDir` is the project's directory in `app`.

Bundler has no source for a URL to an archive, so there is nothing of that
kind to lock.

### Gemspecs that call `git ls-files`

Many gemspecs list their files with `git ls-files`. The source of a flake
holds only the tracked files, so the builds put the source, each external
path and each git checkout in a fresh git repository, and `git ls-files`
lists the same files it lists in a checkout.

### Development

```zsh
nix run github:nix-purifiers/bundler-purifier -- install
```

This fetches the locked gems through Nix into `.bundle/purifier/` and runs
`bundle install --local` with that directory as Bundler's gem cache. It
uses the `bundle` on your `PATH`, and the command's own Ruby when there is
none. Arguments after `install` go to `bundle install`. The link
`.bundle/purifier/gem-cache` is the GC root that keeps the locked files in
the store.

### Publishing

```zsh
nix run github:nix-purifiers/bundler-purifier -- push my-gem
```

This builds `packages.my-gem` and pushes the gem file with `gem push`.
Options after the gem name go to `gem push`, and credentials work as they
do for `gem push`.

## Troubleshooting

Each of these mistakes fails, when Nix evaluates the build and in the
command, with a message that says what went wrong:

- **The Gemfile, `Gemfile.lock` or a gemspec changed since the lock was
  made**, for example after `bundle add` or `bundle update`: run
  `bundler-purifier lock`.
- **`bundler-purifier.lock.json` was edited by hand**, with an entry removed
  or a hash changed: its content no longer matches its `contentHash`. Run
  `bundler-purifier relock`.
- **`bundler-purifier.lock.json` is cut short or overwritten**: run
  `bundler-purifier relock`.
- **The lockfile has an older lock format**: run `bundler-purifier relock`
  with the current bundler-purifier.

## Limits

- **Path sources given by absolute path.** Bundler writes such a path into
  `Gemfile.lock` unchanged. A Nix build can create files only inside its
  own build directory, so it cannot put a tree at an absolute path, and
  `lock` fails with that explanation. Paths relative to the Gemfile work.
- **Bundler plugin sources** (`source "…", type: "…"`). A plugin source
  fetches through the plugin's own Ruby code, which the lock run cannot
  see into: there is no URL and no checkout to record, only whatever files
  the plugin writes. A Nix build would have to run that plugin code with
  the network, which the sandbox forbids.
- **Native extensions need their libraries.** `Gemfile.lock` does not name
  the system libraries an extension links against, so the builder takes
  them as `nativeBuildInputs` and `buildInputs`.
- **Gemspecs that call `git ls-files` at run time.** Bundler evaluates the
  gemspec of every path source each time `bundle exec` starts. In the
  installed app such a gemspec runs outside a repository, so git prints
  "not a git repository" to stderr. Bundler needs a gem's file list only
  to package it, so the app runs normally.

## Credit

bundler-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): a lock run
with empty caches that records every download, a builder that runs the
tool itself in the sandbox from that lockfile, an offline interactive mode
on the same locked files, and publishing what Nix built. The purifier idea
was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## Tests

`nix flake check` runs the unit tests of the lock run's logic
(`tests/unit`), and builds and runs the fixtures under `tests/fixtures` in
the sandbox. The fixtures cover every kind of source: gem servers, with
native extensions and precompiled platform gems, git, git with
submodules, and paths inside and outside the project. `tests/interactive.sh`
tests what runs outside the sandbox. It relocks each fixture and compares
the result with the committed lockfiles byte for byte, installs the app
fixture with `install` and runs it, pushes the library fixture's gem to a
stand-in gem host (`tests/fake-gem-server.rb`), and checks that each
mistake under Troubleshooting fails with its message. CI runs both on
x86_64-linux and aarch64-linux.

## License

MIT
