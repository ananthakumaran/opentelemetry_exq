let
  pkgs = import (builtins.fetchTarball {
    url =
      "https://github.com/NixOS/nixpkgs/archive/c82b46413401efa740a0b994f52e9903a4f6dcd5.tar.gz";
  }) { };

  elixir = (pkgs.beam.packagesWith pkgs.erlangR23).elixir_1_10;

in pkgs.mkShell { nativeBuildInputs = [ elixir ]; }
