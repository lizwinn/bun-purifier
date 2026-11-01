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
  # The project's bun.lock, which may lie outside `root`.
  bunLock ? root + "/bun.lock",
}:
let
  text = builtins.readFile lockFile;

  # A merge that conflicted in the lockfile leaves conflict markers, which
  # are not JSON. They are looked for before the text is parsed, so the
  # error names the conflict rather than a JSON syntax error.
  conflicted = builtins.length (builtins.split "\n<<<<<<< " ("\n" + text)) > 1;

  supportedVersion = import ./lock-version.nix;

  lock =
    if conflicted then
      {
        version = supportedVersion;
        bunVersion = "";
        inputsHash = "";
        contentHash = "";
        packages = [ ];
        artifacts = [ ];
      }
    else
      # A parse error cannot be caught, so the context it carries names the
      # command that rewrites the file.
      builtins.addErrorContext
        "bun-purifier: ${toString lockFile} is not valid JSON. Run `bun-purifier lock --force` to rewrite it."
        (builtins.fromJSON text);

  # The digest that `bun-purifier lock` records as `contentHash`: SHA-256
  # of the rest of the lockfile as JSON with sorted keys and no whitespace,
  # the way builtins.toJSON writes it. src/lock.ts computes it the same
  # way. A lockfile edited by hand no longer matches it.
  contentHash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "contentHash" ]));

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

  # The digest that `bun-purifier lock` records as `inputsHash`: SHA-256 of
  # bun.lock and every package manifest of the lock, each as its path, a
  # newline, its content and a newline. src/lock.ts computes it the same
  # way.
  inputsHash =
    let
      manifestPath = path: if path == "" then "package.json" else "${path}/package.json";
      files = [
        {
          name = "bun.lock";
          file = bunLock;
        }
      ]
      ++ map (p: {
        name = manifestPath p.path;
        file = root + "/${manifestPath p.path}";
      }) lock.packages;
    in
    builtins.hashString "sha256" (
      builtins.concatStringsSep "" (map (f: "${f.name}\n${builtins.readFile f.file}\n") files)
    );
  name = toString lockFile;

  # What makes the lockfile unusable, each as a message that names the
  # command to run.
  integrityProblems =
    if conflicted then
      [
        "bun-purifier: ${name} has merge conflict markers. Resolve the conflict in bun.lock, then run `bun-purifier lock --force` to rewrite ${baseNameOf name}."
      ]
    else if lock.version or null != supportedVersion then
      [
        "bun-purifier: ${name} has lock format version ${
          toString (lock.version or "none")
        }; this library reads version ${toString supportedVersion}. Run `bun-purifier lock --force` with the bun-purifier that provides this library."
      ]
    else if contentHash != lock.contentHash or null then
      [
        "bun-purifier: the content of ${name} does not match the digest `bun-purifier lock` recorded, so the file was edited after the lock. Run `bun-purifier lock --force` to rewrite it."
      ]
    else
      [ ];

  # Whether bun.lock or a package manifest changed since the lock was made.
  stale = integrityProblems == [ ] && inputsHash != lock.inputsHash;
in
lock
// {
  inherit
    storeName
    inputsHash
    integrityProblems
    stale
    ;

  # Every problem of the lockfile for a build: the integrity problems, and
  # a lockfile older than bun.lock or a package manifest.
  problems =
    integrityProblems
    ++ (
      if stale then
        [
          "bun-purifier: bun.lock or a package manifest under ${toString root} changed since ${name} was made. Run `bun-purifier lock`."
        ]
      else
        [ ]
    );

  # The fetch name of an artifact: the last component of its cache path.
  artifactName = artifact: storeName (baseNameOf artifact.path);

  packagesByName = builtins.listToAttrs (
    map (p: {
      inherit (p) name;
      value = p;
    }) (builtins.filter (p: p ? name && p ? version) lock.packages)
  );
}
