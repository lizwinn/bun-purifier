# SPDX-License-Identifier: MIT
#
# The bun install cache of a lockfile for one Nix system. Each artifact
# the system installs is unpacked or checked out into a store path of its
# own, and the
# cache links each one at its cache path, the directory name bun gives
# the package (`kleur@4.1.5@@@1`). A store path per package lets projects
# that lock the same package share it.
#
# bun writes into its cache directory, so a build copies this tree of
# links to a writable directory first. build-bun-project.nix does that,
# and so does the `install` command of the CLI.
#
# It is a package for callPackage, with the lockfile among its arguments.
{
  lib,
  runCommand,
  gnutar,
  gzip,
  # Fetches the git entries. It is called with the arguments of nixpkgs'
  # fetchgit, so a replacement with credentials takes the same ones.
  fetchgit,
  lockFile,
  # The Nix system whose packages the cache holds.
  system,
  # Replaces the built-in fetcher of archives; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl; };

  # An npm tarball holds the package in one top directory (`package/`
  # from the npm registry, `<owner>-<repo>-<sha>/` from GitHub). bun
  # stores the content of that directory, and the lock marks that with
  # `archive.stripTop`.
  unpack =
    artifact:
    runCommand (lock.artifactName artifact)
      {
        nativeBuildInputs = [
          gnutar
          gzip
        ];
        tarball = fetch artifact;
        stripComponents = if artifact.archive.stripTop then "1" else "0";
        preferLocalBuild = true;
      }
      ''
        mkdir $out
        tar -xzf "$tarball" -C $out --strip-components="$stripComponents" \
          --no-same-owner --no-same-permissions
        chmod -R u+rwX,go+rX $out
      '';

  # bun keeps a git dependency as the checkout of its commit, with the
  # commit in a file `.bun-tag`, and an offline install looks for that
  # file.
  checkout =
    artifact:
    runCommand (lock.artifactName artifact)
      {
        src = fetchgit {
          name = lock.artifactName artifact + "-source";
          inherit (artifact.git) url rev;
          inherit (artifact) hash;
          fetchSubmodules = artifact.git.submodules;
          inherit (artifact.git) leaveDotGit;
        };
        inherit (artifact.git) rev;
        preferLocalBuild = true;
      }
      ''
        cp -r "$src" $out
        chmod -R u+w $out
        printf %s "$rev" > $out/.bun-tag
      '';

  entry = artifact: if artifact ? git then checkout artifact else unpack artifact;
in
# The manifest goes to the builder as a file, since a large project locks
# thousands of artifacts and the list would not fit in an environment
# variable.
runCommand "bun-install-cache"
  {
    manifest = lib.concatMapStrings (a: "${a.path}\t${entry a}\n") (lock.artifactsFor system);
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
