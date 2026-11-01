# SPDX-License-Identifier: MIT
#
# What the command builds outside a flake: `cache` for
# `bun-purifier prefetch` and `release` for `bun-purifier publish`. The
# command passes the nixpkgs its flake pins and absolute paths in the
# project.
#
# The shared nix-purifiers library comes from its flake's `lib` output, at
# the revision the flake.lock of bun-purifier pins. The command package
# keeps that flake.lock next to this directory.
{
  nixpkgs,
  system ? builtins.currentSystem,
  # The project's lockfile, for both.
  lockFile ? null,
  # The project root and a package name, for `release`.
  src ? null,
  package ? null,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  flakeLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  locked = flakeLock.nodes.${flakeLock.nodes.root.inputs.purifier}.locked;
  purifierFlake = builtins.getFlake "github:${locked.owner}/${locked.repo}/${locked.rev}?narHash=${locked.narHash}";
  inherit (purifierFlake.lib) purifier;
in
{
  cache = import ./cache.nix { inherit lib purifier; } {
    inherit pkgs system;
    lockFile = /. + lockFile;
  };

  release =
    let
      build = import ./build-bun-project.nix { inherit lib purifier; } {
        inherit pkgs;
        src = /. + src;
        lockFile = /. + lockFile;
      };
    in
    build.release.${package};
}
