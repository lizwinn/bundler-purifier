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
  project builds.
- **Offline installs during development.** `bundler-purifier install` runs
  `bundle install --local` against the locked files, which Nix fetches.
- **Publishing what Nix built.** `bundler-purifier push <gem>` builds the gem
  in the sandbox and pushes that file with `gem push`.

## How the lock is made

`bundler-purifier lock` copies the project to a temporary directory and runs
Bundler there with empty gem, user and configuration directories. When the
project has no `Gemfile.lock`, Bundler resolves one first, and the command
copies it back. Bundler then caches every locked gem for every platform
(`bundle cache --all-platforms`). The lockfile records each cached gem file
with the URL it came from, which is the gem's source plus `gems/<file>`.
Each git source is recorded at its locked revision, with the hash that
`nix-prefetch-git` reports for the checkout. The command also fetches the
Bundler version that `BUNDLED WITH` names, so a Nix build runs that Bundler
and fetches nothing.

`bundler-purifier lock` relocks only when the `Gemfile`, `Gemfile.lock` or a
gemspec of the project changed. `bundler-purifier relock` relocks
regardless.

The lock run uses the Ruby that the command runs on. For a project that
requires another Ruby, override the package:
`bundler-purifier.cli.override { ruby = pkgs.ruby_3_3; }`.

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
`fetchurl` for credentials or mirrors, and `srcFilter`.

### Gemspecs that call `git ls-files`

Many gemspecs list their files with `git ls-files`. The source of a flake
holds only the tracked files, so the builds put the source in a fresh git
repository, and `git ls-files` lists the same files it lists in a checkout.

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

## Limits

- A path gem outside the project root cannot be reached from the Nix
  sandbox. `lock` warns about each one.
- A gem source with several remotes is locked at its first remote.
- Native extensions need their libraries passed to the builder. The
  lockfile does not name them.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
