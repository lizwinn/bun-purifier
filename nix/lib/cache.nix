# SPDX-License-Identifier: MIT
#
# The bun install cache of a lockfile for one Nix system. The shared
# nix-purifiers library (`purifier`) turns each download entry the system
# installs into a store path of its own: an archive entry into the
# unpacked package, a git entry into the checkout. The cache links each
# one at its cache path, the directory name bun gives the package
# (`kleur@4.1.5@@@1`). A store path per package lets projects that lock
# the same package share it.
#
# bun writes into its cache directory, so a build copies this tree of
# links to a writable directory first. build-bun-project.nix does that,
# and so does the `install` command of the CLI.
#
# It is a package for callPackage, with the lockfile among its arguments.
{
  lib,
  pkgs,
  runCommand,
  # The `purifier` library namespace: `fetchEntry` and `admits`.
  purifier,
  lockFile,
  # The Nix system whose packages the cache holds.
  system,
  # Replace nixpkgs' fetchurl and fetchgit, for credentials or mirrors.
  # Each is called with the arguments of the nixpkgs fetcher of its name.
  fetchurl ? null,
  fetchgit ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  fetchEntry = purifier.fetchEntry (
    {
      inherit pkgs;
    }
    // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
    // lib.optionalAttrs (fetchgit != null) { inherit fetchgit; }
  );

  # bun keeps a git dependency as the checkout of its commit, with the
  # commit in a file `.bun-tag`, and an offline install looks for that
  # file.
  withBunTag =
    artifact:
    runCommand (lock.artifactName artifact)
      {
        src = fetchEntry artifact;
        inherit (artifact.git) rev;
        preferLocalBuild = true;
      }
      ''
        cp -r "$src" $out
        chmod -R u+w $out
        printf %s "$rev" > $out/.bun-tag
      '';

  entry = artifact: if artifact ? git then withBunTag artifact else fetchEntry artifact;

  # The artifacts bun installs on the system: those whose npm `os`, `cpu`
  # and `libc` filters admit it.
  installed = builtins.filter (
    a:
    purifier.admits {
      os = a.os or null;
      cpu = a.cpu or null;
      libc = a.libc or null;
    } system
  ) lock.artifacts;
in
assert
  lock.integrityProblems == [ ] || throw (builtins.concatStringsSep "\n" lock.integrityProblems);
# The manifest goes to the builder as a file, since a large project locks
# thousands of artifacts and the list would not fit in an environment
# variable.
runCommand "bun-install-cache"
  {
    manifest = lib.concatMapStrings (a: "${a.path}\t${entry a}\n") installed;
    passAsFile = [ "manifest" ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit lock; };
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$out/$(dirname "$rel")"
      ln -s "$target" "$out/$rel"
    done < "$manifestPath"
  ''
