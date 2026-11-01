# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  # The shared nix-purifiers library as this flake pins it, as a locked flake
  # reference: the CLI builds outside the flake and loads the library's
  # published `lib` with builtins.getFlake.
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  pinned = lock.nodes.${lock.nodes.root.inputs.purifier}.locked;
  escape = builtins.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ];
  purifierRef = "github:${pinned.owner}/${pinned.repo}/${pinned.rev}?narHash=${escape pinned.narHash}";
in
{
  # The bundler-purifier command.
  cli = callPackage ./cli {
    version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
    inherit purifierRef;
  };
}
