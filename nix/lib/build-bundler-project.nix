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
#                     mode under vendor/bundle
#   bundle            `bin/bundle` for the app: the locked Bundler on the
#                     app's Gemfile, so `bundle exec` runs the app
#   packages.<name>   the gem file built from each gemspec of the project,
#                     at <name>-<version>.gem; `gemFile` names it
{
  lib,
  stdenv,
  callPackage,
  gitMinimal,
  writeShellScriptBin,
  pkgs,
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
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
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
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  # Version control, Bundler's local configuration and installs, and the
  # results of nix build never take part in a build. vendor/cache is the
  # gem cache this builder supplies itself.
  defaultSrcFilter =
    path: type:
    let
      base = baseNameOf path;
      rel = lib.removePrefix (toString src + "/") (toString path);
    in
    !(
      base == ".git"
      || base == ".bundle"
      || rel == "vendor/bundle"
      || rel == "vendor/cache"
      || lib.hasPrefix "result" base
    );

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

  gemCache = callPackage ./gem-cache.nix { inherit lockFile fetchurl; };

  # The environment shared by every build. Bundler's own configuration
  # goes to .bundle/config in the build directory, which `app` keeps.
  setupBundler = ''
    export HOME="$TMPDIR/home"
    export GEM_HOME="$TMPDIR/gems"
    # The binstub that gem install writes starts with `#!ruby`, which the
    # sandbox cannot resolve, so `bundle` runs it through Ruby. The later
    # phases run in the same shell and keep the function.
    bundle() { ruby "$GEM_HOME/bin/bundle" "$@"; }
    mkdir -p "$HOME" "$GEM_HOME" vendor
    rm -rf vendor/cache
    # Bundler copies what it installs from the cache and leaves marker
    # files in it, so the cache is a writable tree of links into the store.
    cp -r --no-preserve=mode ${gemCache} vendor/cache
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

  app = stdenv.mkDerivation {
    inherit name;
    src = filteredSrc;
    nativeBuildInputs = [ ruby' ] ++ lib.optional (lock.gems != [ ]) gitMinimal ++ nativeBuildInputs;
    inherit buildInputs doCheck;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${lib.optionalString (lock.gems != [ ]) gitRepositoryForGemspecs}
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
      rm -rf vendor/cache .git
      mkdir -p "$out"
      cp -r . "$out"
      runHook postInstall
    '';
    passthru = {
      ruby = ruby';
      inherit lock gemCache;
    };
  };

  # `bundle` for the app: the locked Bundler, on the app's Gemfile, so
  # `bundle exec` runs the app with its installed bundle.
  bundle = writeShellScriptBin "bundle" ''
    export GEM_HOME=${app}/.bundle/purifier/bundler
    export GEM_PATH="$GEM_HOME"
    export BUNDLE_GEMFILE=${app}/Gemfile
    export PATH=${ruby'}/bin:"$PATH"
    exec ruby "$GEM_HOME/bin/bundle" "$@"
  '';

  mkPackage =
    gem:
    let
      fileName = "${gem.name}-${gem.version}.gem";
      package = stdenv.mkDerivation {
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
}
