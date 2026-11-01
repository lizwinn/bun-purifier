# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.bun-purifier` (`.bun-purifier`, the CLI), and the builder
# `pkgs.buildBunProject` (nix/lib/build-bun-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `bun-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "bun-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildBunProject = final.callPackage ../../nix/lib/build-bun-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
