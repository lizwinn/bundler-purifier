# SPDX-License-Identifier: MIT
#
# buildBundlerProject: the sandboxed builds of a Bundler project, from the
# lockfile `bundler-purifier lock` writes at the project root.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# bundler-purifier overlay (`overlays.default`) adds it to the package set
# as `buildBundlerProject`, so a package written for callPackage takes it
# like any other dependency:
#
#   { buildBundlerProject }: (buildBundlerProject { src = ./.; }).app
#
# and `buildBundlerProject.override` replaces what it takes from the set.
# The builder returns
#
#   gemCache          the gem cache of every locked gem and git source, as
#                     Bundler's `vendor/cache` holds them
#   app               the project with its bundle installed in deployment
#                     mode under vendor/bundle; with external path
#                     sources, the project is at `app.projectDir` inside
#                     it, beside those sources
#   bundle            `bin/bundle` for the app: the locked Bundler on the
#                     app's Gemfile, so `bundle exec` runs the app
#   packages.<name>   the gem file built from each gemspec of the project,
#                     at <name>-<version>.gem; `gemFile` names it
#   executables.<name>
#                     each executable those gemspecs declare, as
#                     `bin/<name>` running it with the app's bundle
#
# The lock names every one of these outputs, so Nix knows them when it
# evaluates, without building anything.
{
  lib,
  stdenv,
  callPackage,
  gitMinimal,
  writeShellScriptBin,
  pkgs,
  # The `purifier` namespace of the shared nix-purifiers library, which
  # fetches the locked downloads. The bundler-purifier overlay passes it.
  purifier,
}:
{
  # The root of the Bundler project, where Gemfile and Gemfile.lock are.
  src,
  # The lockfile; the default is the one `bundler-purifier lock` writes at
  # the project root.
  lockFile ? src + "/bundler-purifier.lock.json",
  # The name of `app`.
  name ? "bundler-app",
  # The Ruby that runs Bundler. The default is nixpkgs' Ruby of the minor
  # version the lock was made with.
  ruby ? null,
  # Replaces nixpkgs' fetchurl for gem files, as for a gem server that
  # needs credentials. It is called with { name, urls, hash }.
  fetchurl ? null,
  # Replaces nixpkgs' fetchgit for git sources, as for a private repository
  # that needs credentials. It is called with the arguments of fetchgit.
  fetchgit ? null,
  # Build tools and libraries for gems with native extensions, which
  # compile in the `app` build: pkg-config and libpq for pg, for example.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Bundler groups that `app` leaves out, as `bundle config set without`.
  without ? [ ],
  # Runs `checkCommand` in the `app` build after the install.
  doCheck ? false,
  checkCommand ? "bundle exec rake",
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out version control,
  # Bundler's local state and build outputs.
  srcFilter ? null,
  # The trees of the path sources outside the project, by the path
  # Gemfile.lock gives them (relative to the project root), such as
  # { "../shared" = inputs.shared; }. The lock lists them as externalPaths.
  externalPaths ? { },
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  # The build lays the project and its external path sources out at the
  # same relative positions as in the checkout: the project goes below as
  # many placeholder directories as the deepest `../` climbs, so that each
  # external path resolves inside the build's tree.
  hasExternal = lock.externalPaths != [ ];
  missingExternal = lib.filter (p: !(externalPaths ? ${p})) lock.externalPaths;
  # The number of leading `..` segments of a path.
  climbs =
    p:
    let
      count =
        segments: if segments != [ ] && lib.head segments == ".." then 1 + count (lib.tail segments) else 0;
    in
    count (lib.splitString "/" p);
  depth = lib.foldl' lib.max 0 (map climbs lock.externalPaths);
  # The project's directory in `app` (and in the build's tree).
  projectDir =
    if hasExternal then
      lib.concatMapStrings (i: "_parent${toString i}/") (lib.range 1 depth) + "project"
    else
      ".";
  placeExternalPaths = ''
    tree="$TMPDIR/tree"
    mkdir -p "$tree/${projectDir}"
    cp -r . "$tree/${projectDir}"
    ${lib.concatMapStrings (p: ''
      mkdir -p "$(dirname "$tree/${projectDir}/${p}")"
      cp -r --no-preserve=mode ${externalPaths.${p}} "$tree/${projectDir}/${p}"
    '') lock.externalPaths}
    cd "$tree/${projectDir}"
  '';

  # Version control, Bundler's local state and installs, and the results of
  # nix build never take part in a build. The project's .bundle/config
  # does, since it holds settings such as compile flags for native
  # extensions (BUNDLE_BUILD__<gem>). vendor/cache is the gem cache this
  # builder supplies itself.
  defaultSrcFilter =
    path: type:
    let
      base = baseNameOf path;
      rel = lib.removePrefix (toString src + "/") (toString path);
    in
    !(
      base == ".git"
      || (lib.hasPrefix ".bundle/" rel && rel != ".bundle/config")
      || rel == "vendor/bundle"
      || rel == "vendor/cache"
      || lib.hasPrefix "result" base
    );

  # A file of the project, read without copying the whole project into the
  # store first.
  srcFile = rel: if builtins.isPath src then src + "/${rel}" else "${src}/${rel}";

  # The definition hash of the project as it is now, computed as
  # `bundler-purifier lock` computes it (see definition_hash there): the
  # Gemfile, Gemfile.lock, every gemspec outside hidden directories and
  # vendor/, and the gemspecs at the top of each external path source.
  gemspecsIn =
    dir: rel:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        let
          path = if rel == "" then name else "${rel}/${name}";
        in
        if lib.hasPrefix "." name then
          [ ]
        else if type == "directory" then
          (if path == "vendor" then [ ] else gemspecsIn "${dir}/${name}" path)
        else if lib.hasSuffix ".gemspec" name then
          [ path ]
        else
          [ ]
      ) (builtins.readDir dir)
    );
  definitionFiles =
    map
      (rel: {
        inherit rel;
        file = srcFile rel;
      })
      (
        [ "Gemfile" ]
        ++ lib.optional (builtins.pathExists (srcFile "Gemfile.lock")) "Gemfile.lock"
        ++ gemspecsIn (srcFile "") ""
      )
    ++ lib.concatMap (
      p:
      map
        (name: {
          rel = "${p}/${name}";
          file = "${externalPaths.${p}}/${name}";
        })
        (
          lib.attrNames (
            lib.filterAttrs (name: type: type != "directory" && lib.hasSuffix ".gemspec" name) (
              builtins.readDir externalPaths.${p}
            )
          )
        )
    ) (lib.filter (p: externalPaths ? ${p}) lock.externalPaths);
  definitionHash = builtins.convertHash {
    hash = builtins.hashString "sha256" (
      lib.concatMapStrings (
        f:
        let
          content = builtins.readFile f.file;
        in
        "${f.rel}\n${toString (builtins.stringLength content)}\n${content}\n"
      ) (lib.sort (a: b: a.rel < b.rel) (lib.unique definitionFiles))
    );
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
  definitionCurrent =
    definitionHash == lock.definitionHash
    || throw "bundler-purifier: the Gemfile, Gemfile.lock or a gemspec changed since ${baseNameOf (toString lockFile)} was made. Run `bundler-purifier lock` in the project root.";

  filteredSrc = builtins.path {
    path = src;
    name = "bundler-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  rubyVersion = lib.versions.splitVersion lock.ruby;
  rubyAttr = "ruby_${builtins.elemAt rubyVersion 0}_${builtins.elemAt rubyVersion 1}";
  ruby' =
    if ruby != null then
      ruby
    else
      pkgs.${rubyAttr}
        or (throw "bundler-purifier: nixpkgs has no ${rubyAttr} for the Ruby ${lock.ruby} the lock was made with; pass `ruby`.");

  gemCache = callPackage ./gem-cache.nix (
    {
      inherit lockFile purifier;
    }
    // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
    // lib.optionalAttrs (fetchgit != null) { inherit fetchgit; }
  );

  # The environment shared by every build. Bundler's own configuration
  # goes to .bundle/config in the build directory, which `app` keeps.
  setupBundler = ''
    export HOME="$TMPDIR/home"
    export GEM_HOME="$TMPDIR/gems"
    # The sandbox sets no locale, and Ruby would read gemspecs and file
    # lists as US-ASCII.
    export LC_ALL=C.UTF-8
    # The binstub that gem install writes starts with `#!ruby`, which the
    # sandbox cannot resolve, so `bundle` runs it through Ruby. The later
    # phases run in the same shell and keep the function.
    bundle() { ruby "$GEM_HOME/bin/bundle" "$@"; }
    mkdir -p "$HOME" "$GEM_HOME" vendor
    rm -rf vendor/cache
    # Bundler copies what it installs from the cache and leaves marker
    # files in it, so the cache is a writable tree of links into the store.
    cp -r --no-preserve=mode ${gemCache} vendor/cache
    # Bundler loads the gemspec of a git source from its cached checkout,
    # and many of those gemspecs call `git ls-files`. Each checkout becomes
    # a repository of its files, submodule contents included.
    for checkout in vendor/cache/*/.bundlecache; do
      if [ -e "$checkout" ]; then
        (cd "$(dirname "$checkout")" && ${gitRepositoryForGemspecs})
      fi
    done
    # The locked Bundler, installed from the cache, so the build runs the
    # Bundler version of BUNDLED WITH and Bundler has nothing to fetch.
    gem install --local --no-document --install-dir "$GEM_HOME" --bindir "$GEM_HOME/bin" \
      vendor/cache/bundler-${lock.bundler}.gem
    bundle config set --local deployment true
    bundle config set --local frozen true
    bundle config set --local path vendor/bundle
    ${lib.optionalString (without != [ ]) ''
      bundle config set --local without ${lib.escapeShellArg (lib.concatStringsSep ":" without)}
    ''}
  '';

  # Many gemspecs list their files with `git ls-files`. The source of a
  # flake holds the tracked files, so a repository of all of them gives
  # `git ls-files` the same list.
  gitRepositoryForGemspecs = ''
    git init -q
    git add -A
  '';

  # The project and its external path sources need a repository for their
  # gemspecs; git sources get one in setupBundler.
  usesGemspecs = lock.gems != [ ] || hasExternal;

  app =
    assert
      missingExternal == [ ]
      || throw "bundler-purifier: Gemfile.lock has path sources outside the project (${lib.concatStringsSep ", " missingExternal}); pass their trees as `externalPaths`.";
    assert definitionCurrent;
    stdenv.mkDerivation {
      inherit name;
      src = filteredSrc;
      nativeBuildInputs = [
        ruby'
        gitMinimal
      ]
      ++ nativeBuildInputs;
      inherit buildInputs doCheck;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${lib.optionalString hasExternal placeExternalPaths}
        ${lib.optionalString usesGemspecs ''
          # The repository covers the external path sources too, which sit
          # beside the project in the build's tree.
          (cd ${if hasExternal then ''"$tree"'' else "."} && ${gitRepositoryForGemspecs})
        ''}
        ${setupBundler}
        bundle install --local
        # RubyGems writes gem executables with `#! ruby`, which no kernel
        # resolves, so `bundle exec` could not start them. They get the
        # absolute path of this Ruby.
        for bin in vendor/bundle/ruby/*/bin/*; do
          if [ -f "$bin" ]; then
            sed -i -E '1s|^#! ?ruby( .*)?$|#!${ruby'}/bin/ruby\1|' "$bin"
          fi
        done
        runHook postBuild
      '';
      checkPhase = ''
        runHook preCheck
        ${checkCommand}
        runHook postCheck
      '';
      installPhase = ''
        runHook preInstall
        # The locked Bundler, for the `bundle` wrapper to run the app with.
        gem install --local --no-document --install-dir .bundle/purifier/bundler \
          vendor/cache/bundler-${lock.bundler}.gem
        # The gem cache served the install; the output keeps the installed
        # bundle under vendor/bundle. The repository for the gemspecs goes.
        rm -rf vendor/cache
        mkdir -p "$out"
        ${
          if hasExternal then
            ''
              rm -rf "$tree/.git"
              cp -r "$tree/." "$out"
            ''
          else
            ''
              rm -rf .git
              cp -r . "$out"
            ''
        }
        runHook postInstall
      '';
      passthru = {
        ruby = ruby';
        inherit lock gemCache projectDir;
      };
    };

  # `bundle` for the app: the locked Bundler, on the app's Gemfile, so
  # `bundle exec` runs the app with its installed bundle.
  bundle = writeShellScriptBin "bundle" ''
    export GEM_HOME=${app}/${projectDir}/.bundle/purifier/bundler
    export GEM_PATH="$GEM_HOME"
    export BUNDLE_GEMFILE=${app}/${projectDir}/Gemfile
    if [ -z "''${LC_ALL:-}''${LANG:-}" ]; then
      export LANG=C.UTF-8
    fi
    # Bundler evaluates the gemspecs of path sources on every run, and many
    # of them call `git ls-files`.
    export PATH=${ruby'}/bin:"$PATH":${gitMinimal}/bin
    exec ruby "$GEM_HOME/bin/bundle" "$@"
  '';

  mkPackage =
    gem:
    let
      fileName = "${gem.name}-${gem.version}.gem";
      package =
        assert definitionCurrent;
        stdenv.mkDerivation {
          pname = gem.name;
          inherit (gem) version;
          src = filteredSrc;
          nativeBuildInputs = [
            ruby'
            gitMinimal
          ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            ${gitRepositoryForGemspecs}
            cd ${lib.escapeShellArg gem.dir}
            gem build ${lib.escapeShellArg (baseNameOf gem.gemspec)} --output ${lib.escapeShellArg fileName}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp ${lib.escapeShellArg fileName} "$out/"
            runHook postInstall
          '';
          passthru = {
            gemFile = "${package}/${fileName}";
          };
        };
    in
    package;
in
{
  inherit gemCache app bundle;
  packages = lib.mapAttrs (_: mkPackage) lock.gemsByName;
  # Each executable that a gemspec of the project declares, run with the
  # app's bundle: `bin/<name>`.
  executables = lib.listToAttrs (
    lib.concatMap (
      gem:
      map (executable: {
        name = executable;
        value = writeShellScriptBin executable ''
          exec ${bundle}/bin/bundle exec ${lib.escapeShellArg executable} "$@"
        '';
      }) gem.executables
    ) lock.gems
  );
}
