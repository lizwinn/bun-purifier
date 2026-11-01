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
  # The project root, which holds bun.lock and the package manifests.
  src,
  # The project's lockfile, which need not exist.
  lockFile,
  # A package name, for `release`.
  package ? null,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  flakeLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  locked = flakeLock.nodes.${flakeLock.nodes.root.inputs.purifier}.locked;
  purifierFlake = builtins.getFlake "github:${locked.owner}/${locked.repo}/${locked.rev}?narHash=${locked.narHash}";
  inherit (purifierFlake.lib) purifier;

  lock = import ./read-lock.nix { inherit lib purifier; } {
    src = /. + src;
    lockFile = /. + lockFile;
  };
in
{
  cache = import ./cache.nix { inherit lib purifier; } {
    inherit (pkgs) runCommand;
    fetchers = { inherit pkgs; };
    entries = purifier.entriesFor system lock;
  };

  release =
    let
      buildBunProject = pkgs.callPackage ./build-bun-project.nix { inherit purifier; };
      build = buildBunProject {
        src = /. + src;
        lockFile = /. + lockFile;
      };
    in
    build.release.${package};
}
