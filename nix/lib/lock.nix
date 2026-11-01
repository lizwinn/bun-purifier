# SPDX-License-Identifier: MIT
#
# Reads a bun-purifier lockfile (written by `bun-purifier lock`).
#
# Needs no nixpkgs: the interactive mode of the CLI evaluates this with
# nothing but the Nix installation it runs.
{
  lockFile,
  # The root the lockfile's package paths are relative to.
  root ? dirOf lockFile,
}:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_".
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;

  # The bun names of a Nix system's operating system and CPU, as package
  # manifests write them in `os` and `cpu`.
  platforms = {
    "x86_64-linux" = {
      os = "linux";
      cpu = "x64";
    };
    "aarch64-linux" = {
      os = "linux";
      cpu = "arm64";
    };
    "x86_64-darwin" = {
      os = "darwin";
      cpu = "x64";
    };
    "aarch64-darwin" = {
      os = "darwin";
      cpu = "arm64";
    };
  };

  # Whether a manifest's `os` or `cpu` field admits a value. The field is
  # absent, a string or a list. Entries that start with "!" exclude a
  # value. When the field has entries without "!", the value must be one of
  # them. bun writes "none" for a list that names only platforms it does
  # not know, and "none" admits nothing.
  admits =
    field: value:
    let
      entries =
        if field == null then
          [ ]
        else if builtins.isList field then
          field
        else
          [ field ];
      isExclusion = e: builtins.substring 0 1 e == "!";
      exclusions = builtins.filter isExclusion entries;
      inclusions = builtins.filter (e: !isExclusion e) entries;
    in
    !(builtins.elem "!${value}" exclusions) && (inclusions == [ ] || builtins.elem value inclusions);

  # The digest that `bun-purifier lock` records as `inputsHash`: SHA-256 of
  # bun.lock and every package manifest of the lock, each as its path, a
  # newline, its content and a newline. src/lock.ts computes it the same
  # way.
  inputsHash =
    let
      files = [ "bun.lock" ] ++ map (p: manifestPath p.path) lock.packages;
      manifestPath = path: if path == "" then "package.json" else "${path}/package.json";
    in
    builtins.hashString "sha256" (
      builtins.concatStringsSep "" (map (f: "${f}\n${builtins.readFile (root + "/${f}")}\n") files)
    );
in
assert
  lock.version == supportedVersion
  || throw "bun-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `bun-purifier lock` with the bun-purifier that provides this library.";
lock
// {
  inherit storeName inputsHash;

  # Whether bun.lock or a package manifest changed since the lock was made.
  stale = inputsHash != lock.inputsHash;

  # The fetch name of an artifact: the last component of its cache path.
  artifactName = artifact: storeName (baseNameOf artifact.path);

  # The artifacts bun installs on a Nix system: those whose `os` and `cpu`
  # admit the system's platform.
  artifactsFor =
    system:
    let
      platform =
        platforms.${system}
          or (throw "bun-purifier: no bun platform is known for the Nix system ${system}.");
    in
    builtins.filter (
      a: admits (a.os or null) platform.os && admits (a.cpu or null) platform.cpu
    ) lock.artifacts;

  packagesByName = builtins.listToAttrs (
    map (p: {
      inherit (p) name;
      value = p;
    }) (builtins.filter (p: p ? name && p ? version) lock.packages)
  );
}
