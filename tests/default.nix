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

  # Local dependencies and a git dependency: a file: directory inside the
  # project, one outside it (so `src` is the directory above the project),
  # a local tarball, and a git+ssh: repository, which Nix fetches over
  # HTTPS.
  paths = buildBunProject {
    src = ./fixtures/paths;
    root = "app";
  };

  # Packages from the default registry an .npmrc names and from a scoped
  # registry.
  registries = buildBunProject { src = ./fixtures/registries; };

  # Runs an executable, by the path its program names for it, and compares
  # its output.
  runs =
    name: executable: expected:
    pkgs.runCommand "test-${name}" { } ''
      actual=$(${executable})
      if [ "$actual" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected}
        echo "actual:   $actual"
        exit 1
      fi
      touch $out
    '';
in
{
  workspace-program =
    runs "workspace-program" workspace.programs.fixture-app.executables.fixture-app
      "3 is odd: true";

  sources-program =
    runs "sources-program" sources.programs.fixture-sources.executables.fixture-sources
      "plain object: true, one day: 86400000 ms";

  paths-program =
    runs "paths-program" paths.programs.fixture-paths.executables.fixture-paths
      "shared vendored packed plain:true";

  registries-program =
    runs "registries-program" registries.programs.fixture-registries.executables.fixture-registries
      "number: true";

  # `bun publish` sends the tarball Nix packed, as `bun-purifier publish`
  # runs it, to a registry in the sandbox, which receives the package with
  # that tarball attached.
  publish =
    pkgs.runCommand "test-publish"
      {
        nativeBuildInputs = [
          withOverlay.bun
          pkgs.jq
          pkgs.coreutils
          pkgs.diffutils
        ];
      }
      ''
        export HOME=$TMPDIR
        tarball=${workspace.packages.fixture-app.tarball}
        bun ${./registry.ts} 4873 request.json &
        for i in $(seq 50); do
          (exec 3<>/dev/tcp/127.0.0.1/4873) 2>/dev/null && break
          sleep 0.1
        done
        # bun publish runs in the directory of the package, as the CLI runs
        # it, and wants the package manifest there.
        cp ${workspace.project}/packages/app/package.json .
        chmod u+w package.json
        NPM_CONFIG_TOKEN=test bun publish "$tarball" --registry http://127.0.0.1:4873/
        wait
        name=$(jq -r .name request.json)
        version=$(jq -r '.versions | keys[0]' request.json)
        if [ "$name" != fixture-app ] || [ "$version" != 1.0.0 ]; then
          echo "published $name $version"
          exit 1
        fi
        jq -r '._attachments[].data' request.json | base64 -d > sent.tgz
        cmp sent.tgz "$tarball"
        touch $out
      '';

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
        tar -xzf ${workspace.packages.fixture-app.tarball} package/package.json
        dep=$(jq -r '.dependencies."@fixture/lib"' package/package.json)
        if [ "$dep" != "0.1.0" ]; then
          echo "@fixture/lib is \"$dep\" in the packed package.json"
          exit 1
        fi
        test -f ${workspace.packages."@fixture/lib".tarball}
        touch $out
      '';

  # `bun-purifier lock` finds the fixtures' lockfiles current without a
  # lock run, so it computes the same digest of bun.lock and the package
  # manifests as nix/lib/lock.nix.
  lock-current = pkgs.runCommand "test-lock-current" { } ''
    export HOME=$TMPDIR
    cp -r ${./fixtures} fixtures
    chmod -R u+w fixtures
    for fixture in workspace sources paths/app registries; do
      (cd fixtures/$fixture && ${lib.getExe bun-purifier} lock) 2> out
      grep -q "is current" out || { cat out; exit 1; }
    done
    touch $out
  '';
}
