# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope `bun-purifier` is the `default` entry of this flake's
    # package overlay registry (pkg-overlays/): the package set applies it
    # by default, and the flake exports it as `pkgOverlays` and as the
    # plain `overlays.default`. The scope holds the builder, which is a
    # function, so the `packages` output below lists the command alone.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/bun-purifier -- lock` locks the bun
  # project in the working directory.
  perSystem =
    { config, pkgs, ... }:
    {
      packages = {
        bun-purifier = pkgs.bun-purifier.bun-purifier;
        default = config.packages.bun-purifier;
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              # The fixtures take the builder from the package set that
              # the default overlay extends.
              pkgs = pkgs.extend self.overlays.default;
              inherit (self.lib.bun-purifier) readLock;
              inherit (self.packages.${system}) bun-purifier;
              realWorld = { inherit (inputs) elysia; };
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
