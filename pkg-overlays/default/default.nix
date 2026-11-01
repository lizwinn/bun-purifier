# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.bun-purifier`: `.bun-purifier`, the command. The builder is in the
# library, as `lib.bun-purifier.buildBunProject`. A consumer that lists
# this flake in `projects` holds it as `bun-purifier/default`, which its
# package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "bun-purifier";
}
