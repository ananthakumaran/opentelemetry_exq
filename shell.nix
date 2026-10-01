{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell { nativeBuildInputs = [ pkgs.beam29Packages.elixir_1_20 ]; }
