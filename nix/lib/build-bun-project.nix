# SPDX-License-Identifier: MIT
#
# buildBunProject: the sandboxed builds of a bun project, from the
# lockfile `bun-purifier lock` writes next to bun.lock.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# bun-purifier overlay (`overlays.default`) adds it to the package set as
# `buildBunProject`, so a package written for callPackage takes it like any
# other dependency:
#
#   { buildBunProject }: (buildBunProject { src = ./.; }).programs.app
#
# and `buildBunProject.override` replaces what it takes from the set. The
# builder returns
#
#   cache             the bun install cache of the locked packages that
#                     this system installs
#   project           the project after `bun install` and the `build`
#                     script of each package that has one
#   packages.<name>   the tarball of package <name>, as `bun pm pack` makes
#                     it and `bun publish` sends it
#   programs.<name>   the executables of package <name>'s `bin` field,
#                     run by bun from `project`
{
  lib,
  stdenvNoCC,
  runCommand,
  callPackage,
  runtimeShell,
  # The bun that installs, builds and runs the project. bun names cache
  # entries by its own rules, so the lock records the bun version it was
  # made with, and a different minor version draws a warning.
  bun,
}:
{
  # The source tree: the bun project, the directory of bun.lock, or a
  # directory above it that also holds the `file:` dependencies outside
  # the project.
  src,
  # The project inside `src`, as a relative path; "" when `src` is the
  # project.
  root ? "",
  # The lockfile; null names the one `bun-purifier lock` writes at the
  # project root.
  lockFile ? null,
  # Replaces the built-in fetcher of archives; see fetch.nix.
  fetchurl ? null,
  # Replaces nixpkgs' fetchgit for git dependencies, for a private
  # repository that needs credentials. It is called with the arguments of
  # nixpkgs' fetchgit.
  fetchgit ? null,
  # The package script that builds a package. Packages without it are
  # installed only.
  buildScript ? "build",
  # Runs each package's `checkScript` after the build.
  doCheck ? false,
  # The package script `doCheck` runs.
  checkScript ? "test",
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out node_modules, build
  # outputs of bun-purifier and editor state.
  srcFilter ? null,
}:
let
  projectSrc = if root == "" then src else src + "/${root}";
  # The project directory in the build and in `project`.
  rootPrefix = if root == "" then "" else "${root}/";
  lockPath = if lockFile != null then lockFile else projectSrc + "/bun-purifier.lock.json";
  lockName = baseNameOf (toString lockPath);

  lock = import ./lock.nix {
    lockFile = lockPath;
    root = projectSrc;
  };
  system = stdenvNoCC.hostPlatform.system;

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (type == "directory" && (name == "node_modules" || name == ".git"))
      || (type == "symlink" && lib.hasPrefix "result" name)
    );

  filteredSrc = builtins.path {
    path = src;
    name = "source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  minorVersion = v: lib.versions.majorMinor v;
  checkedBun =
    lib.warnIf (minorVersion bun.version != minorVersion lock.bunVersion)
      "bun-purifier: ${toString lockPath} was made with bun ${lock.bunVersion}, and this build runs bun ${bun.version}. bun names its cache entries by version-specific rules; if the install fails, relock with this bun."
      bun;

  # Executables in node_modules start with `#!/usr/bin/env node`, and the
  # sandbox has no /usr/bin/env. The build rewrites those lines to this
  # `node`, which is the build's bun under that name, so the scripts run on
  # the bun the project runs on, inside the sandbox and in the output.
  bunAsNode = runCommand "bun-as-node" { } ''
    mkdir -p $out/bin
    ln -s ${checkedBun}/bin/bun $out/bin/node
  '';

  cache = callPackage ./cache.nix (
    {
      lockFile = lockPath;
      inherit system fetchurl;
    }
    // lib.optionalAttrs (fetchgit != null) { inherit fetchgit; }
  );

  # The offline install, run in the project directory. bun writes into its
  # cache directory, so it gets a writable copy of the tree of links to the
  # unpacked packages.
  installScript = ''
    cp -r --no-dereference ${cache} $TMPDIR/bun-cache
    chmod -R u+w $TMPDIR/bun-cache
    bun install --frozen-lockfile --offline --no-progress \
      --cache-dir=$TMPDIR/bun-cache --backend=copyfile || {
      echo "bun-purifier: bun could not install offline from the packages of ${lockName}. The lockfile lacks a package that bun.lock needs; run \`bun-purifier lock --force\` and commit the result." >&2
      exit 1
    }
  '';

  # Packages with a name and a version: the ones `bun pm pack` can pack.
  namedPackages = lib.attrValues lock.packagesByName;
  workspacePackages = builtins.filter (p: p.path != "") lock.packages;
  rootPackage = lib.findFirst (p: p.path == "") null lock.packages;

  hasScript = script: p: builtins.elem script (p.scripts or [ ]);

  # Runs `script` in every package that has it: the workspaces through
  # `bun run --filter`, which orders them by their dependencies, then the
  # root package.
  runScript =
    script:
    lib.optionalString (builtins.any (hasScript script) workspacePackages) ''
      bun run --filter '*' --elide-lines=0 ${lib.escapeShellArg script}
    ''
    + lib.optionalString (rootPackage != null && hasScript script rootPackage) ''
      bun run ${lib.escapeShellArg script}
    '';

  packDir = p: lock.storeName p.name;

  project = stdenvNoCC.mkDerivation {
    pname = lock.storeName (
      if rootPackage != null && rootPackage ? name then rootPackage.name else "bun-project"
    );
    version = if rootPackage != null && rootPackage ? version then rootPackage.version else "0";
    src = filteredSrc;
    outputs = [
      "out"
      "packs"
    ];
    nativeBuildInputs = [
      checkedBun
      bunAsNode
    ];
    inherit doCheck;

    configurePhase = ''
      runHook preConfigure
      # The phases run in one shell, so the build and install phases start
      # in the project too.
      cd ./${rootPrefix}
      export HOME=$TMPDIR/home DO_NOT_TRACK=1
      mkdir -p $HOME
      ${installScript}
      patchShebangs --build $(find . -name node_modules -type d -prune)
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      ${runScript buildScript}
      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck
      ${runScript checkScript}
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      ${lib.concatMapStrings (p: ''
        mkdir -p $packs/${packDir p}
        (cd ./${p.path} && bun pm pack --ignore-scripts --quiet --destination $packs/${packDir p})
      '') namedPackages}
      # The whole source tree, so file: dependencies outside the project
      # come along. bun installs such a dependency as links to its files
      # in the build directory; each link into the build directory points
      # to the same file in $out instead.
      mkdir -p $out
      build=$NIX_BUILD_TOP/$sourceRoot
      cp -r $build/. $out/
      find $out -type l | while IFS= read -r link; do
        target=$(readlink "$link")
        case "$target" in
          "$build"/*) ln -sfn "$out/''${target#"$build"/}" "$link" ;;
        esac
      done
      runHook postInstall
    '';

    dontFixup = true;
    passthru = { inherit lock cache installScript; };
  };

  # The file name `bun pm pack` gives a package's tarball: the name without
  # a leading "@" and with "/" as "-", then the version.
  packFile =
    p: "${builtins.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "@" p.name)}-${p.version}.tgz";

  # Each package holds its tarball, and its `tarball` attribute is the path
  # of that file, known from the lockfile without building. The build fails
  # if bun named the file otherwise.
  packages = lib.mapAttrs (
    name: p:
    let
      drv = runCommand "${packDir p}-${p.version}.tgz" { passthru = { inherit project; }; } ''
        mkdir $out
        ln -s ${project.packs}/${packDir p}/${lib.escapeShellArg (packFile p)} $out/
        test -e $out/${lib.escapeShellArg (packFile p)}
      '';
    in
    lib.extendDerivation true { tarball = "${drv}/${packFile p}"; } drv
  ) lock.packagesByName;

  # The `bin` field of a package, as a set from executable name to path.
  bins =
    p:
    if !(p ? bin) then
      { }
    else if builtins.isString p.bin then
      { ${lib.last (lib.splitString "/" p.name)} = p.bin; }
    else
      p.bin;

  # Each program holds the executables of a package's `bin` field, and its
  # `executables.<bin>` attribute is the path of each one.
  programs = lib.mapAttrs (
    name: p:
    let
      drv = program name p;
    in
    lib.extendDerivation true {
      executables = lib.mapAttrs (bin: _: "${drv}/bin/${bin}") (bins p);
    } drv
  ) (lib.filterAttrs (_: p: bins p != { }) lock.packagesByName);

  program =
    name: p:
    runCommand "${packDir p}-${p.version}"
      {
        meta.mainProgram = lib.head (lib.attrNames (bins p) ++ [ name ]);
        passthru = { inherit project; };
      }
      ''
        mkdir -p $out/bin
        ${lib.concatStrings (
          lib.mapAttrsToList (bin: target: ''
            cat > $out/bin/${lib.escapeShellArg bin} <<EOF
            #!${runtimeShell}
            exec ${checkedBun}/bin/bun ${project}/${rootPrefix}${
              if p.path == "" then "" else "${p.path}/"
            }${target} "\$@"
            EOF
            chmod +x $out/bin/${lib.escapeShellArg bin}
          '') (bins p)
        )}
      '';
in
assert lock.problems == [ ] || throw (builtins.concatStringsSep "\n" lock.problems);
{
  inherit
    cache
    project
    packages
    programs
    ;
}
