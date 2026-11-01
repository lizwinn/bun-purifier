# SPDX-License-Identifier: MIT
#
# The `bun-purifier` library namespace: the builder `buildBunProject`
# (nix/lib/build-bun-project.nix), on the `purifier` namespace of the
# shared nix-purifiers library.
{ ... }:
{

  overlay = final: prev: {
    bun-purifier = (prev.bun-purifier or { }) // {
      buildBunProject = import ../../nix/lib/build-bun-project.nix {
        lib = final;
        inherit (final) purifier;
      };
    };
  };

}
