with import <nixpkgs> {};

with pkgs;

let
  pythonPkgs = python-packages: with python-packages; [
    sphinx
  ];
  python = python3.withPackages pythonPkgs;
in
  stdenv.mkDerivation {
    name = "impurePythonEnv";

    buildInputs = [
      python
    ];
}
