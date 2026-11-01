# SPDX-License-Identifier: MIT
#
# The bundler-purifier command: bin/bundler-purifier on nixpkgs' Ruby,
# with the Nix library it realizes lockfiles with, the shared nix-purifiers
# library that library fetches with, and the nixpkgs that `install` and
# `push` build with. The lock run uses the Ruby the project asks for, and
# this Ruby when the project asks for none.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  ruby,
  gitMinimal,
  nix-prefetch-git,
  path,
  version,
  # The shared nix-purifiers library as a locked flake reference, which
  # pkgs/default.nix reads from flake.lock.
  purifierRef ? null,
}:
assert
  purifierRef != null
  || throw "bundler-purifier: the CLI needs the shared nix-purifiers library; pass purifierRef, as pkgs/default.nix does.";
stdenvNoCC.mkDerivation {
  pname = "bundler-purifier";
  inherit version;
  src = ../../bin;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm644 bundler-purifier "$out/libexec/bundler-purifier.rb"
    # The user's PATH comes first, for the user's nix. git serves Bundler's
    # git sources, and nix-prefetch-git hashes them for the lock.
    makeWrapper ${ruby}/bin/ruby "$out/bin/bundler-purifier" \
      --add-flags "$out/libexec/bundler-purifier.rb" \
      --set BUNDLER_PURIFIER_LIB ${../../nix/lib} \
      --set BUNDLER_PURIFIER_SHARED_FLAKE ${lib.escapeShellArg purifierRef} \
      --set BUNDLER_PURIFIER_NIXPKGS ${path} \
      --suffix PATH : ${
        lib.makeBinPath [
          gitMinimal
          nix-prefetch-git
        ]
      }
    runHook postInstall
  '';
  meta = {
    description = "Locks the gems a Bundler project downloads, so that Nix can build it offline";
    license = lib.licenses.mit;
    mainProgram = "bundler-purifier";
  };
}
