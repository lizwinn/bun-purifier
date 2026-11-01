# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.bun-purifier`, which holds the packages of pkgs/, the
# command `pkgs.bun-purifier.bun-purifier` and the builder
# `pkgs.bun-purifier.buildBunProject`. A package written for callPackage
# takes the scope by name, as `{ bun-purifier }:`. A consumer that lists
# this flake in `projects` holds the overlay as `bun-purifier/default`,
# which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "bun-purifier";
}
