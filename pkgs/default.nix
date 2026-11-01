# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The bundler-purifier command.
  cli = callPackage ./cli {
    version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
  };
}
