# SPDX-License-Identifier: MIT
#
# The bun-purifier command (src/main.ts), run by the package set's bun.
# The lock records the version of that bun, and the cache names it
# observes come from that bun, so `install` and `publish` run the same
# bun.
#
# BUN_PURIFIER_LIB names nix/lib, which `install` and `publish` build
# from, and BUN_PURIFIER_NIXPKGS names the nixpkgs of this package set,
# which those builds import. The builds run the `nix` on the user's PATH.
# `lock` hashes git dependencies with nix-prefetch-git, which comes with
# the package.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  bun,
  nix-prefetch-git,
  path,
}:
stdenvNoCC.mkDerivation {
  pname = "bun-purifier";
  version = lib.removeSuffix "\n" (builtins.readFile ../../version.txt);

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../src
      ../../nix/lib
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/bun-purifier
    cp -r src nix $out/share/bun-purifier/
    makeWrapper ${lib.getExe bun} $out/bin/bun-purifier \
      --add-flags $out/share/bun-purifier/src/main.ts \
      --set BUN_PURIFIER_LIB $out/share/bun-purifier/nix/lib \
      --set BUN_PURIFIER_NIXPKGS ${path} \
      --prefix PATH : ${lib.makeBinPath [ nix-prefetch-git ]}
    runHook postInstall
  '';

  passthru = { inherit bun; };

  meta = {
    description = "Locks bun projects for sandboxed Nix builds, and installs and publishes from the lock";
    license = lib.licenses.mit;
    mainProgram = "bun-purifier";
  };
}
