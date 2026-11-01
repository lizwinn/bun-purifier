# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked packages.
{
  pkgs,
  # The flake's default package overlay, which adds buildBunProject.
  overlay,
  bun-purifier,
  # The sources of the real-world projects, pinned in
  # tests/dependencies/flake.lock.
  realWorld,
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

  # Elysia, a bun web framework, at a pinned commit. Its build bundles with
  # tsup and esbuild and writes type declarations with tsc. Its `test`
  # script also installs from npm over the network, so the check runs the
  # type check of its tests, the same checking an editor's TypeScript
  # server does, and the integration check below runs `bun test`.
  elysia = buildBunProject {
    src = realWorld.elysia;
    lockFile = ./real-world/elysia/bun-purifier.lock.json;
    doCheck = true;
    checkScript = "test:types";
  };

  # Lockfiles broken the ways a developer breaks them, each a copy of the
  # workspace fixture: a manifest changed after the lock, a hash edited by
  # hand, a merge conflict, and an entry missing with the digest
  # recomputed, as a bug in the lock would leave it.
  negativeLock =
    name:
    import ../nix/lib/lock.nix {
      lockFile = ./negative/${name}/bun-purifier.lock.json;
      root = ./negative/${name};
    };
  expectProblem =
    name: text:
    lib.assertMsg (builtins.any (lib.hasInfix text) (negativeLock name).problems) "the problems of tests/negative/${name} do not mention: ${text}";
  fails =
    name: !(builtins.tryEval (buildBunProject { src = ./negative/${name}; }).project.drvPath).success;
  missingEntry = buildBunProject { src = ./negative/missing-entry; };

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

  # The unit tests of the lock (tests/unit).
  unit =
    pkgs.runCommand "test-unit"
      {
        nativeBuildInputs = [ withOverlay.bun ];
        src = lib.fileset.toSource {
          root = ../.;
          fileset = lib.fileset.unions [
            ../src
            ./unit
          ];
        };
      }
      ''
        export HOME=$TMPDIR
        cp -r $src/. .
        bun test ./tests/unit
        touch $out
      '';

  # Each broken lockfile stops the build with a message that names the
  # problem and the command that fixes it.
  lock-problems =
    assert expectProblem "stale" "changed since";
    assert expectProblem "stale" "Run `bun-purifier lock`";
    assert expectProblem "tampered" "edited after the lock";
    assert expectProblem "tampered" "bun-purifier lock --force";
    assert expectProblem "conflicted" "merge conflict markers";
    assert expectProblem "conflicted" "bun-purifier lock --force";
    assert (negativeLock "missing-entry").problems == [ ];
    assert lib.assertMsg (lib.all fails [
      "stale"
      "tampered"
      "conflicted"
    ]) "a broken lockfile did not stop the build";
    pkgs.runCommand "test-lock-problems" { } "touch $out";

  # A lockfile without a package bun needs passes the digest check, and
  # the offline install then fails with a message that says to relock.
  missing-entry =
    pkgs.runCommand "test-missing-entry"
      {
        nativeBuildInputs = [ withOverlay.bun ];
      }
      ''
        export HOME=$TMPDIR
        cp -r ${./negative/missing-entry} project
        chmod -R u+w project
        cd project
        if (${missingEntry.project.installScript}) 2> err; then
          echo "the install succeeded without is-number"
          exit 1
        fi
        cat err
        grep 'run `bun-purifier lock --force`' err
        touch $out
      '';

  # Elysia builds, type-checks, packs, and passes its own test suite.
  elysia =
    pkgs.runCommand "test-elysia"
      {
        nativeBuildInputs = [
          withOverlay.bun
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        export HOME=$TMPDIR
        tar -tzf ${elysia.packages.elysia.tarball} | grep '^package/dist/index.mjs$' > /dev/null
        cp -r ${elysia.project} elysia
        chmod -R u+w elysia
        cd elysia
        bun test
        touch $out
      '';

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
