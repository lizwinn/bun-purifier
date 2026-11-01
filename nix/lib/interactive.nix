# SPDX-License-Identifier: MIT
#
# What the CLI builds outside a flake: `cache` for `bun-purifier install`
# and `package` for `bun-purifier publish`. The CLI passes the nixpkgs its
# flake pins and absolute paths in the project.
{
  nixpkgs,
  system ? builtins.currentSystem,
  # The project's lockfile, for `cache`.
  lockFile ? null,
  # The project root and a package name, for `package`.
  src ? null,
  package ? null,
}:
let
  pkgs = import nixpkgs { inherit system; };
in
{
  cache = pkgs.callPackage ./cache.nix {
    lockFile = /. + lockFile;
    inherit system;
  };

  package =
    let
      build = pkgs.callPackage ./build-bun-project.nix { } { src = /. + src; };
    in
    build.packages.${package};
}
