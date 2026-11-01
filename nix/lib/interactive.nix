# SPDX-License-Identifier: MIT
#
# What the CLI builds outside a flake: `cache` for `bun-purifier install`
# and `package` for `bun-purifier publish`. The CLI passes the nixpkgs its
# flake pins and absolute paths in the project.
#
# The shared nix-purifiers library comes from its flake's `lib` output, at
# the revision the flake.lock of bun-purifier pins. The CLI package keeps
# that flake.lock next to this directory.
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

  flakeLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  locked = flakeLock.nodes.${flakeLock.nodes.root.inputs.purifier}.locked;
  purifierFlake = builtins.getFlake "github:${locked.owner}/${locked.repo}/${locked.rev}?narHash=${locked.narHash}";
  inherit (purifierFlake.lib) purifier;
in
{
  cache = pkgs.callPackage ./cache.nix {
    lockFile = /. + lockFile;
    inherit purifier system;
  };

  package =
    let
      build = pkgs.callPackage ./build-bun-project.nix { inherit purifier; } { src = /. + src; };
    in
    build.packages.${package};
}
