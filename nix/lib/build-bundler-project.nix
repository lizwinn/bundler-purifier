# SPDX-License-Identifier: MIT
#
# buildBundlerProject: the sandboxed builds of a Bundler project, from the
# lockfile `bundler-purifier lock` writes.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# bundler-purifier overlay (`overlays.default`) adds it to the package set
# as `buildBundlerProject`, so a package written for callPackage takes it
# like any other dependency:
#
#   { buildBundlerProject }: (buildBundlerProject { src = ./.; }).packages.app
#
# and `buildBundlerProject.override` replaces what it takes from the set.
#
# The builder returns the attributes of the nix-purifiers contract:
#
#   packages.app      the project with its bundle installed in deployment
#                     mode under vendor/bundle; with external path
#                     sources, the project is at `app.projectDir` inside
#                     it, beside those sources
#   packages.bundle   `bin/bundle` for the app: the locked Bundler on the
#                     app's Gemfile, so `bundle exec` runs the app
#   packages.<gem>    the gem file built from each gemspec of the project,
#                     at <gem>-<version>.gem; `gemFile` names it
#   tests             the `app` build with `checkCommand` run after the
#                     install
#   release           what `bundler-purifier publish` pushes: the gem file
#                     of the project's gemspec, or all of them
#   fetches           the download entries of the lock, as the shared
#                     nix-purifiers library reads them
#
# and these of its own:
#
#   executables.<name>
#                     each executable the gemspecs declare, as `bin/<name>`
#                     running it with the app's bundle
#   devShell          a shell with the Ruby and libraries of the `app`
#                     build, which `bundler-purifier prefetch` keeps
#   gemCache          the gem cache of every locked download, as Bundler's
#                     `vendor/cache` holds it
#
# The lock names every one of these outputs, so Nix knows them when it
# evaluates, without building anything.
{
  lib,
  stdenv,
  gitMinimal,
  writeShellScriptBin,
  symlinkJoin,
  mkShell,
  defaultGemConfig,
  # The package set, for nixpkgs' Ruby of the minor version a lock was made
  # with (ruby_<major>_<minor>), and for the shared library's fetchers.
  pkgs,
  # The `purifier` namespace of the shared nix-purifiers library, which the
  # bundler-purifier overlay passes.
  purifier,
  # lib.bundler-purifier.readLock (read-lock.nix), which the overlay passes.
  readLock,
}:
{
  # The root of the Bundler project, where the Gemfile is.
  src,
  # The lockfile that `bundler-purifier lock` writes. It may lie outside
  # `src`, kept by the flake that calls the builder; a lockFile outside
  # `src` takes the place of any copy in it. Gemfile.lock is always the one
  # in `src`.
  lockFile ? src + "/bundler-purifier.lock.json",
  # Fetchers in place of nixpkgs' fetchers, passed to the shared library's
  # fetchEntry: `fetchurl` for a gem server that needs credentials or a
  # mirror, `fetchgit` for a private git repository.
  fetchers ? { },
  # The name of `packages.app`.
  name ? "bundler-app",
  # The Ruby that runs Bundler. The default is nixpkgs' Ruby of the minor
  # version the lock was made with.
  ruby ? null,
  # Build tools and libraries for gems with native extensions, which
  # compile in the `app` build, beyond the ones nixpkgs names for them
  # (`useGemConfig`). The libraries are on LD_LIBRARY_PATH in the shell
  # and the `bundle` wrapper, for gems that open one through FFI.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Adds the build inputs that nixpkgs' gem configuration
  # (pkgs.defaultGemConfig) names for each locked gem, such as libyaml for
  # psych, so that common native extensions compile without arguments.
  useGemConfig ? true,
  # Bundler groups that `app` leaves out, as `bundle config set without`.
  without ? [ ],
  # The test run of `tests`.
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

  # A file of the project, read without copying the whole project into the
  # store first.
  srcFile = rel: if builtins.isPath src then src + "/${rel}" else "${src}/${rel}";

  # The lock in memory (read-lock.nix), checked by the shared library:
  # evaluation fails with its problems, each naming the fix.
  readResult = readLock {
    inherit
      src
      lockFile
      externalPaths
      ;
  };
  checkedLock = purifier.checkLock readResult;
  # What the builder reads besides the entries. Its names are known without
  # the check, so the attribute names of the result are too.
  lock = readResult.bundlerLock // {
    gemsByName = builtins.listToAttrs (
      map (gem: {
        inherit (gem) name;
        value = gem;
      }) readResult.bundlerLock.gems
    );
  };
  # The downloads of this system.
  downloads = purifier.entriesFor stdenv.hostPlatform.system checkedLock;
  files = builtins.filter (d: !(d ? git)) downloads;
  gitCheckouts = builtins.filter (d: d ? git) downloads;

  # The gemspec of a gem of the project: <name>.gemspec in its directory, or
  # the directory's only gemspec.
  gemspecOf =
    gem:
    let
      inDir = lib.attrNames (
        lib.filterAttrs (n: type: type != "directory" && lib.hasSuffix ".gemspec" n) (
          builtins.readDir (srcFile gem.dir)
        )
      );
      file =
        if lib.elem "${gem.name}.gemspec" inDir then
          "${gem.name}.gemspec"
        else if lib.length inDir == 1 then
          lib.head inDir
        else
          throw "bundler-purifier: ${gem.dir} has no gemspec named ${gem.name}.gemspec.";
    in
    if gem.dir == "." then file else "${gem.dir}/${file}";

  # The build lays the project and its external path sources out at the
  # same relative positions as in the checkout: the project goes below as
  # many placeholder directories as the deepest `../` climbs, so that each
  # external path resolves inside the build's tree.
  hasExternal = lock.externalPaths != [ ];
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

  # Version control, Bundler's local state and installs, the purifier
  # lockfile (the build reads `lockFile`) and the results of nix build never
  # take part in a build. The project's .bundle/config does, since it holds
  # settings such as compile flags for native extensions
  # (BUNDLE_BUILD__<gem>). vendor/cache is the gem cache this builder
  # supplies itself.
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
      || rel == "bundler-purifier.lock.json"
      || lib.hasPrefix "result" base
    );

  filteredSrc = builtins.path {
    path = src;
    name = "bundler-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  rubyVersion = lib.versions.splitVersion (builtins.seq checkedLock lock.ruby);
  rubyAttr = "ruby_${builtins.elemAt rubyVersion 0}_${builtins.elemAt rubyVersion 1}";
  ruby' =
    if ruby != null then
      ruby
    else
      pkgs.${rubyAttr}
        or (throw "bundler-purifier: nixpkgs has no ${rubyAttr} for the Ruby ${lock.ruby} the lock was made with; pass `ruby`.");

  gemCache = import ./gem-cache.nix {
    inherit
      lib
      pkgs
      purifier
      files
      gitCheckouts
      fetchers
      ;
  };

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

  # The build inputs that nixpkgs' gem configuration names for the locked
  # gems. A gem file is named <name>-<version>[-<platform>].gem. An entry
  # that fails to evaluate for a gem adds nothing.
  gemConfigInputs = lib.concatMap (
    download:
    let
      parts = builtins.match "(.+)-([0-9][^-]*)(-.+)?\\.gem" (baseNameOf download.path);
      gemName = builtins.elemAt parts 0;
      config = defaultGemConfig.${gemName} or null;
      evaluated = builtins.tryEval (
        let
          attrs = config {
            inherit gemName;
            version = builtins.elemAt parts 1;
          };
          inputs = (attrs.buildInputs or [ ]) ++ (attrs.nativeBuildInputs or [ ]);
        in
        # Each input is forced to its outer value, so that an entry that
        # fails to evaluate fails here, inside tryEval.
        builtins.foldl' (forced: input: builtins.seq input forced) inputs inputs
      );
    in
    if parts == null || config == null || !evaluated.success then
      [ ]
    # The configuration supplies system libraries and tools. Its nixpkgs
    # gems and Rubies stay out: Bundler supplies the gems, and their setup
    # hooks would put other gem versions on RUBYLIB.
    else
      lib.filter (input: !(lib.isAttrs input && (input ? gemName || input ? rubyEngine))) evaluated.value
  ) files;

  # The libraries the gems may load at run time: gems such as ruby-vips
  # open a library through FFI by its name, so the shell and the `bundle`
  # wrapper put these on LD_LIBRARY_PATH.
  runtimeInputs = buildInputs ++ lib.optionals useGemConfig (lib.unique gemConfigInputs);
  runtimeLibraryPath = lib.makeLibraryPath runtimeInputs;

  # The project and its external path sources need a repository for their
  # gemspecs; git sources get one in setupBundler.
  usesGemspecs = lock.gems != [ ] || hasExternal;

  app = builtins.seq checkedLock (
    stdenv.mkDerivation {
      inherit name;
      src = filteredSrc;
      nativeBuildInputs = [
        ruby'
        gitMinimal
      ]
      ++ nativeBuildInputs;
      buildInputs = runtimeInputs;
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
        inherit gemCache projectDir;
      };
    }
  );

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
    export LD_LIBRARY_PATH=${runtimeLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    exec ruby "$GEM_HOME/bin/bundle" "$@"
  '';

  mkGem =
    gem:
    let
      fileName = "${gem.name}-${gem.version}.gem";
      package = builtins.seq checkedLock stdenv.mkDerivation {
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
          gem build ${lib.escapeShellArg (baseNameOf (gemspecOf gem))} --output ${lib.escapeShellArg fileName}
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

  gems = lib.mapAttrs (_: mkGem) lock.gemsByName;
  clashes = lib.filter (n: gems ? ${n}) [
    "app"
    "bundle"
  ];
in
assert
  clashes == [ ]
  || throw "bundler-purifier: a gemspec of the project builds a gem named ${lib.head clashes}, which clashes with packages.${lib.head clashes}.";
{
  packages = gems // {
    inherit app bundle;
  };

  tests = app.overrideAttrs (_: {
    name = "${name}-tests";
    doCheck = true;
  });

  release =
    if lib.length (lib.attrNames gems) == 1 then
      lib.head (lib.attrValues gems)
    else if gems != { } then
      symlinkJoin {
        name = "${name}-release";
        paths = lib.attrValues gems;
      }
    else
      throw "bundler-purifier: the project has no gemspec, so it has no release for `bundler-purifier publish` to push.";

  # Every download of the lock, for every system.
  fetches = checkedLock.entries;

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

  # A shell with the Ruby, git, build tools and libraries of the `app`
  # build, for day-to-day work: native extensions compile in it as they do
  # in the sandbox, and gems that open a library through FFI find it.
  devShell = mkShell {
    packages = [
      ruby'
      gitMinimal
    ]
    ++ nativeBuildInputs
    ++ runtimeInputs;
    LD_LIBRARY_PATH = runtimeLibraryPath;
  };

  inherit gemCache;
}
