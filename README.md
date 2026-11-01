# bundler-purifier

bundler-purifier lets Nix build a Bundler project offline, in its sandbox,
from the project's own `Gemfile.lock`. Nix reads `Gemfile.lock` when it
evaluates: each gem file's source, and its SHA-256 from the `CHECKSUMS`
section when `Gemfile.lock` has one. `bundler-purifier lock` writes
`bundler-purifier.lock.json` beside it with only what `Gemfile.lock`
lacks, such as the hashes of git checkouts. The project needs no generated
Nix files.

bundler-purifier is part of [nix-purifiers](https://nix-purifiers.github.io)
and meets its [contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).
The shared [purifier](https://github.com/nix-purifiers/purifier) library
fetches the downloads. It builds on x86_64-linux and aarch64-linux.

## Quickstart

In the project root:

```zsh
nix run github:nix-purifiers/bundler-purifier -- lock
```

Commit `bundler-purifier.lock.json`. A Nix build on Linux needs a Linux
platform in `Gemfile.lock`; `lock` warns when there is none, and
`bundle lock --add-platform x86_64-linux aarch64-linux` adds them. With
`bundle lock --add-checksums` (Bundler 2.5 and later, the default from
Bundler 4), `Gemfile.lock` records every gem's hash, and the purifier
lockfile shrinks to a few fields.

The flake publishes the builder in its library:

```nix
{
  inputs.bundler-purifier.url = "github:nix-purifiers/bundler-purifier";
  inputs.nixpkgs.follows = "bundler-purifier/nixpkgs";

  outputs = { nixpkgs, bundler-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = bundler-purifier.lib.bundler-purifier.buildBundlerProject {
        inherit pkgs;
        src = ./.;
        name = "my-app";
      };
    in
    {
      packages.${system} = project.packages;
      checks.${system}.tests = project.tests;
      devShells.${system}.default = project.devShell;
    };
}
```

`nix build '.#app'` builds the app with its bundle installed.
`nix shell '.#bundle' -c bundle exec ruby main.rb`, run in the app's store
path, runs it. The builder's result has the attributes of the contract:

- `packages.app`, the project with its bundle installed in deployment mode,
  and `packages.bundle`, the locked Bundler on the app's Gemfile.
- `packages.<gem>`, the gem file that each gemspec of the project builds.
- `tests`, the `app` build with `checkCommand` (`bundle exec rake` by
  default) run after the install.
- `release`, the gem files that `bundler-purifier publish` pushes.
- `fetches`, the download entries of the lock, for every system.

It also has `executables.<name>`, each executable the gemspecs declare, and
`devShell`, a shell with the build's Ruby and libraries.
`lib.bundler-purifier.readLock` reads the lock into the contract's shape
for tools such as SBOM generators.

`nix/lib/build-bundler-project.nix` documents the builder's arguments.
`ruby` replaces nixpkgs' Ruby of the minor version the lock was made
with. `nativeBuildInputs` and `buildInputs` give native extensions what
they compile and link against, beyond the libraries nixpkgs' gem
configuration names for the locked gems (`useGemConfig`). The libraries
are on `LD_LIBRARY_PATH` in the shell and the `bundle` wrapper, for gems
that open one through FFI, such as ruby-vips. `without` leaves Bundler
groups out of `app`. `fetchers` replaces nixpkgs' `fetchurl` or `fetchgit`,
for a gem server or a git repository that needs credentials, or a mirror.
`externalPaths` gives the trees of path sources outside the project.

A project that keeps its build outside its tree keeps the purifier
lockfile outside it and passes it as `lockFile`; `Gemfile.lock` stays in
the tree. The commands then take `--lockfile <path>` or
`BUNDLER_PURIFIER_LOCKFILE`.

## Everyday loop

Day-to-day work goes through Bundler's own commands: `bundle exec`,
`bundle exec rake`, `bundle exec rails server`. After changing the
Gemfile, or after `bundle add` or `bundle update`, run
`bundler-purifier lock`, which keeps Bundler's resolution and records
what the new gems need. `bundler-purifier update [<gem>...]` re-resolves
every gem, or the named ones, with `bundle update`, and then locks.

`lock` relocks only when the Gemfile, `Gemfile.lock` or a gemspec changed,
and `lock --force` relocks regardless; a relock of an unchanged project
writes the same lockfile byte for byte. The lock run uses the Ruby the
project asks for, in `.ruby-version` or in the `RUBY VERSION` section of
`Gemfile.lock`, and builds nixpkgs' Ruby of that minor version when it
differs from the Ruby the command runs on. The project's `.bundle/config`
applies to the lock run, except the settings that would narrow what is
locked (groups, path, frozen and deployment). The builds keep the
committed `.bundle/config` too, so settings such as compile flags for a
native extension (`BUNDLE_BUILD__<gem>`) apply in the sandbox.

`bundler-purifier publish` builds the `release` with Nix and pushes each
gem file with `gem push`. Options after `publish` go to `gem push`, and
credentials work as they do for `gem push`.

## Offline work

```zsh
nix run github:nix-purifiers/bundler-purifier -- prefetch
nix develop .bundler-purifier/shell
```

`prefetch` realizes everything the lock lists for the current system: the
gem files and git checkouts, as Bundler's gem cache, and the dev shell
with the project's Ruby and libraries. Both stay alive through GC roots in
`.bundler-purifier/` beside the purifier lockfile, which belongs in
`.gitignore`. It names that gem cache as Bundler's `cache_path` in the
project's `.bundle/config`, and runs `bundle install --local` in the shell;
arguments after `prefetch` go to `bundle install`. Afterwards
`bundle install`, `bundle exec` and the language server work in that shell
with the network cut off.

## Editor

Ruby LSP works offline when the project locks it like any other gem:

```ruby
group :development do
  gem "ruby-lsp", require: false
end
```

Then run `bundler-purifier lock` and `bundler-purifier prefetch`, and start
the editor from `nix develop .bundler-purifier/shell`, or point its Ruby
LSP extension at that shell. Ruby LSP uses the project's bundle when the
Gemfile has it, and needs no download of its own.

## Errors and fixes

Each of these fails, in the commands and when Nix evaluates the build,
with a message that names the fix:

- **The Gemfile, `Gemfile.lock` or a gemspec changed since the lock was
  made**, as after `bundle add`: run `bundler-purifier lock`.
- **The purifier lockfile lacks an entry `Gemfile.lock` needs**, such as
  the hash of a new git checkout: run `bundler-purifier lock`.
- **The purifier lockfile was edited by hand**, its content no longer
  matching its `contentHash`: run `bundler-purifier lock --force`.
- **The purifier lockfile is cut short, overwritten or of an older
  format**: run `bundler-purifier lock --force`.
- **A path source outside the project has no tree**: pass it as
  `externalPaths`.

A gem added to the Gemfile while offline fails in Bundler's own
resolution, with Bundler's message, since Bundler resolves before any hook
it offers runs. Lock while online.

## Sources supported and refused

Every kind of source a `Gemfile.lock` can name works:

- **Gem servers** (`source "https://…"`): each gem file, for every platform
  in `Gemfile.lock`, with the platform gems a system cannot install left
  out of that system's downloads. When Bundler is configured with a mirror
  for the source (`bundle config mirror.https://rubygems.org <mirror>`),
  the lock records the mirror's URL as a fallback. A gem in an old
  `Gemfile.lock` section with several remotes is locked at the remote that
  serves the file.
- **Git** (`git:`, `github:`), with `submodules: true` too. The Nix sandbox
  has no SSH keys, so a source over SSH (`git@host:owner/repo` or
  `ssh://host/owner/repo`) is fetched from the HTTPS URL of the same host
  and path; a private repository takes a credentialed `fetchers.fetchgit`.
  The lock run itself uses your SSH keys and git credential helpers.
- **Paths inside the project** (`path:`, `gemspec`). Their gemspecs build
  `packages.<gem>`. Gemspecs that list their files with `git ls-files`
  work, since the builds put the source in a fresh git repository.
- **Paths outside the project**, such as `path: "../shared"`, through
  `externalPaths`. The build lays the project and those trees out at the
  same relative positions, and `packages.app.projectDir` is the project's
  directory in the app.

Bundler has no source for a URL to an archive. Two kinds cannot work:

- **Path sources given by absolute path.** Bundler writes such a path into
  `Gemfile.lock` unchanged. A Nix build can create files only inside its
  own build directory, so it cannot put a tree at an absolute path, and
  `lock` fails with that explanation. Paths relative to the Gemfile work.
- **Bundler plugin sources** (`source "…", type: "…"`). A plugin source
  fetches through the plugin's own Ruby code: there is no URL and no
  checkout to record, only whatever files the plugin writes. A Nix build
  would have to run that code with the network, which the sandbox forbids.

Native extensions need their system libraries, which `Gemfile.lock` does
not name: nixpkgs' gem configuration supplies the common ones, and the
builder takes the rest. Bundler evaluates the gemspec of every path source
each time `bundle exec` starts; in the installed app a gemspec that calls
`git ls-files` runs outside a repository, so git prints "not a git
repository" to stderr, and the app runs normally.

## Examples

### A Rails app: Lobsters

[Lobsters](https://github.com/lobsters/lobsters), the Rails app behind
lobste.rs, asks for its own Ruby in `.ruby-version` and keeps compile flags
for sqlite3 in its `.bundle/config`. bundler-purifier takes both as they
are. In a checkout of Lobsters:

```zsh
nix run github:nix-purifiers/bundler-purifier -- lock
```

The lock run builds nixpkgs' Ruby of the version Lobsters asks for.
Lobsters' `Gemfile.lock` has a `CHECKSUMS` section, so
`bundler-purifier.lock.json` holds only a few fields. A flake beside it
builds the app. Lobsters' image processing loads libvips through FFI, so
the flake passes it in `buildInputs`:

```nix
{
  inputs.bundler-purifier.url = "github:nix-purifiers/bundler-purifier";
  inputs.nixpkgs.follows = "bundler-purifier/nixpkgs";

  outputs = { nixpkgs, bundler-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lobsters = bundler-purifier.lib.bundler-purifier.buildBundlerProject {
        inherit pkgs;
        src = ./.;
        name = "lobsters";
        buildInputs = [ pkgs.vips ];
      };
    in
    {
      packages.${system} = lobsters.packages;
      devShells.${system}.default = lobsters.devShell;
    };
}
```

`nix build '.#app'` builds Lobsters with its bundle, and
`nix shell '.#bundle' -c bundle exec rails --version`, run in the app's
store path, starts Rails from it. For day-to-day work on Lobsters:

```zsh
nix run github:nix-purifiers/bundler-purifier -- prefetch
nix develop .bundler-purifier/shell
cp config/database.yml.sample config/database.yml
RAILS_ENV=test bundle exec rails db:create db:schema:load
bundle exec rspec
```

To build Lobsters without adding files to its tree, keep the flake and
`bundler-purifier.lock.json` in a separate repository, take Lobsters as a
flake input with `flake = false`, and pass its source as `src` and the
lockfile as `lockFile`. Lock it from the checkout with
`bundler-purifier --lockfile <path> lock`.

## Credits

bundler-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): a lock run
with empty caches that records every download, a builder that runs the
tool itself in the sandbox from that lockfile, an offline mode on the same
locked files, and publishing what Nix built. The purifier idea was inspired
by nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
