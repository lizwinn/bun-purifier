# SPDX-License-Identifier: MIT
{
  inputs.caisson.url = "github:nix-caisson/caisson";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  # Same channel as the main flake, so dev-partition evals agree with the
  # exported pkgSet.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  # Real-world projects the integration checks build, pinned to a commit.
  # tests/real-world holds the lockfile of each.
  inputs.elysia.url = "github:elysiajs/elysia/e037eca710e7ad193be09cc6615ab0dbe54af914";
  inputs.elysia.flake = false;
  outputs = { ... }: { };
}
