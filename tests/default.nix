# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked packages.
{
  pkgs,
  # The flake's default package overlay, which adds buildBunProject.
  overlay,
  bun-purifier,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildBunProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildBunProject;

  # A workspace of two packages: a library with registry dependencies
  # (one scoped), and an app that depends on it through `workspace:*` and
  # bundles itself with `bun build`.
  workspace = buildBunProject { src = ./fixtures/workspace; };

  # A single package with a GitHub dependency, a tarball URL dependency,
  # and esbuild, whose native binary comes from the optional dependency
  # for the build platform.
  sources = buildBunProject { src = ./fixtures/sources; };

  # Runs a program and compares its output.
  runs =
    name: program: expected:
    pkgs.runCommand "test-${name}" { } ''
      actual=$(${lib.getExe program})
      if [ "$actual" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected}
        echo "actual:   $actual"
        exit 1
      fi
      touch $out
    '';
in
{
  workspace-program = runs "workspace-program" workspace.programs.fixture-app "3 is odd: true";

  sources-program =
    runs "sources-program" sources.programs.fixture-sources
      "plain object: true, one day: 86400000 ms";

  # The packed app names its workspace dependency by version, as the
  # registry needs it.
  workspace-package =
    pkgs.runCommand "test-workspace-package"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
          pkgs.jq
        ];
      }
      ''
        tar -xzf ${workspace.packages.fixture-app}/*.tgz package/package.json
        dep=$(jq -r '.dependencies."@fixture/lib"' package/package.json)
        if [ "$dep" != "0.1.0" ]; then
          echo "@fixture/lib is \"$dep\" in the packed package.json"
          exit 1
        fi
        test -f ${workspace.packages."@fixture/lib"}/*.tgz
        touch $out
      '';

  # `bun-purifier lock` finds the fixtures' lockfiles current without a
  # lock run, so it computes the same digest of bun.lock and the package
  # manifests as nix/lib/lock.nix.
  lock-current = pkgs.runCommand "test-lock-current" { } ''
    export HOME=$TMPDIR
    for fixture in workspace sources; do
      cp -r ${./fixtures}/$fixture $fixture
      chmod -R u+w $fixture
      (cd $fixture && ${lib.getExe bun-purifier} lock) 2> out
      grep -q "is current" out || { cat out; exit 1; }
    done
    touch $out
  '';
}
