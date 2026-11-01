# bun-purifier

A command and a Nix library that build [bun](https://bun.sh) projects in
the Nix sandbox from their lockfiles. It is one of the
[nix-purifiers](https://nix-purifiers.github.io), and it meets their
[contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).

bun still resolves the project and writes `bun.lock`. bun-purifier adds a
second lockfile, `bun-purifier.lock.json`, that tells Nix where bun keeps
each package in its install cache. Nix then fetches every package, lays
out the cache and runs `bun install --offline` in the sandbox. Nothing
generated in Nix needs to be committed.

## Quickstart

Lock the project in its root directory, and commit
`bun-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/bun-purifier -- lock
```

Build it with the builder in the flake's library:

```nix
{
  inputs.bun-purifier.url = "github:nix-purifiers/bun-purifier";
  inputs.nixpkgs.follows = "bun-purifier/nixpkgs";

  outputs = { nixpkgs, bun-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      app = bun-purifier.lib.bun-purifier.buildBunProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.default = app.packages.my-app;
    };
}
```

`buildBunProject { pkgs, src, fetchers ? { }, ... }` returns

- `packages.<name>`: package `<name>`, built: its directory in the built
  project at `lib/node_modules/<name>`, and the executables of its `bin`
  field in `bin/`, run by bun. `packages.<name>.executables.<bin>` is the
  path of each executable.
- `tests`: the `test` script of every package that has one, run in the
  sandbox on the built project.
- `release.<name>`: the tarball of package `<name>`, as `bun pm pack`
  makes it and `bun-purifier publish` uploads it.
  `release.<name>.tarball` is the path of the file.
- `fetches`: the download entries of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library that the
  build fetches on this system.

Nix knows every one of these attributes, by name, at evaluation time. The
lockfile lists the project's packages with their names, versions,
directories and `bin` fields, and Nix reads it as JSON.

`nix/lib/build-bun-project.nix` documents the other arguments:

- `root`: the project inside `src`, for `file:` dependencies outside the
  project (see Sources supported and refused).
- `lockFile` and `bunLock`: the two lockfiles, when they are not at the
  project root. A packaging flake keeps them outside `src` to build a
  project whose author does not use bun-purifier, and a `bunLock` given
  here replaces any `bun.lock` in `src`.
- `fetchers`: passed unchanged to `fetchEntry` of the shared library.
  `fetchers.fetchurl` serves a registry mirror or credentials, and
  `fetchers.fetchgit` a private git repository.
- `buildScript` and `testScript`: the package scripts that build and
  test, `build` and `test` by default.
- `srcFilter`: filters the source before it is copied into the store.

The build takes bun from `pkgs`. Executables in `node_modules` start with
`#!/usr/bin/env node`, and the sandbox has no `/usr/bin/env`, so the
build rewrites those lines to a `node` that is that bun.

### How the lock is made

`bun.lock` names every downloaded package with its URL and integrity
hash, and the lockfile takes both from there. What `bun.lock` leaves out
is the name of each package's entry in bun's install cache, and an
offline install finds a package only under that name. bun derives some of
these names with hashes of its own, for prerelease versions and for
tarball URLs.

`bun-purifier lock` therefore copies the project to a temporary directory
and installs it into an empty cache once for each system the
nix-purifiers build for, x86_64-linux and aarch64-linux. It reads the
name of every cache entry and pairs it with the package's URL and hash.
A package bun installs on neither system, such as esbuild's binary for
macOS or a dependency of a WebAssembly fallback, stays out of the
lockfile. Each package is a download entry of the shared library: an
archive entry for a tarball, a git entry for a git checkout. The library
fetches and unpacks the entries, and decides with npm's `os`, `cpu` and
`libc` filters which ones a system installs.

The lockfile holds a format `version`, a digest of `bun.lock` and the
package manifests, and a digest of its own content. `bun-purifier lock`
relocks only when `bun.lock` or a manifest changed, or with `--force`,
and a relock of an unchanged project writes the same file byte for byte.
Every command takes `--lockfile <path>` for a lockfile kept elsewhere.

## Everyday loop

The everyday loop is bun's own: `bun install`, `bun run build`,
`bun test`. Add or upgrade a dependency with `bun add`, which updates
`bun.lock` over the network, then run `bun-purifier lock`, which takes a
few seconds for a project of a few hundred packages.

`bun-purifier prefetch` refuses a lockfile older than `bun.lock` and names
`bun-purifier lock`, and so does the Nix build.

## Offline work

```zsh
nix run github:nix-purifiers/bun-purifier -- prefetch
```

`prefetch` builds, in the Nix store, every package the lockfile lists for
the current system, keeps them alive with a GC root in
`node_modules/.cache/bun-purifier`, and runs
`bun install --frozen-lockfile --offline` from them. Further arguments go
to `bun install`. After it, `bun install`, `bun run`, `bun test` and the
editor work with the network cut off. `bun add` of a package not in the
lock needs the network, as it does without bun-purifier.

## Editor

`prefetch` leaves `node_modules` with ordinary files, so an editor's
TypeScript server, and `tsc`, read the installed types as after a plain
`bun install`. bun projects bring TypeScript and their `@types` packages
as dependencies, so the lockfile holds what the editor reads, and it is
there after `prefetch`.

## Errors and fixes

Every check names the command that fixes it, in the command and in the
Nix build:

| Situation | Message ends with |
|---|---|
| `bun.lock` or a `package.json` changed after the lock | Run `bun-purifier lock`. |
| `package.json` changed, `bun.lock` was not updated | run `bun install`, then lock again. |
| `bun-purifier.lock.json` edited by hand | Run `bun-purifier lock --force` to rewrite it. |
| Merge conflict in `bun-purifier.lock.json` | Resolve the conflict in bun.lock, then run `bun-purifier lock --force` |
| `bun-purifier.lock.json` is not JSON | Run `bun-purifier lock --force` to rewrite it. |
| The lockfile lacks a package bun needs | run `bun-purifier lock --force` and commit the result. |
| A `link:` dependency | Depend on the package with file: and its path instead. |

`bun-purifier publish` builds the release tarball of the package in the
working directory, or of the one named with `--package`, and runs
`bun publish` with it in the package's directory. Registry configuration
and credentials work as they do for `bun publish`.

## Sources supported and refused

Every kind of dependency `bun.lock` records builds, except one:

- **Registry packages.** The default registry comes from the sources bun
  reads, first match winning: the `BUN_CONFIG_REGISTRY` and
  `NPM_CONFIG_REGISTRY` variables, the project's `bunfig.toml` and
  `.npmrc`, then the user's `.bunfig.toml` and `.npmrc`. A package from a
  scoped registry carries its own URL in `bun.lock`. A registry that needs
  credentials needs a `fetchers.fetchurl` with them in the Nix build.
- **`github:` dependencies and `git+https:` URLs on GitHub.** bun
  downloads these as tarballs from the GitHub API, and so does Nix.
- **Other git dependencies** (`git+https:`, `git+ssh:`, `git:`). bun
  clones them, and Nix fetches the same commit with `fetchgit`. The lock
  hashes the checkout with `nix-prefetch-git`. bun clones without
  submodules, so the lock does too. The sandbox has no SSH keys, so Nix
  fetches an SSH URL over HTTPS from the same host, as bun does when SSH
  fails. A private repository needs a `fetchers.fetchgit` with
  credentials.
- **Tarball URLs.**
- **Local directories and tarballs** (`file:` and plain paths). These
  are part of the source, and bun installs them from there. When one lies
  outside the project, pass the directory above both as `src` and the
  project's place in it as `root`.
- **Per-platform optional packages**, such as esbuild's binaries. The
  lockfile holds the package of each system the nix-purifiers build for.
- **`link:` dependencies are refused, because they cannot work.**
  `link:<name>` names a package that `bun link` registered in bun's global
  directory on one machine, and `bun.lock` records only the name. Neither
  Nix nor another machine can tell what the name pointed to, so
  `bun-purifier lock` stops with a message. A `file:` dependency on the
  same directory works.

bun runs no lifecycle scripts of dependencies, so a dependency that
downloads a binary in `postinstall` lacks it in the sandbox as it does
outside.

The lockfile records the version of bun that made it, because the names
of cache entries follow the rules of that version. A build with a bun of
another minor version prints a warning. The `bun-purifier` command runs
the bun of its own package set, so `lock`, `prefetch` and `publish` agree
with each other.

## Real-world projects

- [elysia](https://github.com/elysiajs/elysia) at `e037eca`, a bun web
  framework with 232 locked packages and a `bun.lock` in format version 1.
  It locks in a few seconds. In the sandbox it installs offline, builds
  with tsup, esbuild and `tsc`, type-checks its tests with `tsc`, and
  passes its own 1616-test suite. `nix flake check` builds it, and CI
  relocks it from a fresh checkout and compares the lockfile byte for
  byte.

elysia found three bugs, all fixed:

- Packages that only a WebAssembly fallback needs, which bun installs on
  no system the nix-purifiers build for, made the lock fail.
- Two `bun.lock` keys for the same package version wrote the same cache
  entry twice.
- `#!/usr/bin/env node` scripts in `node_modules` did not run in the
  sandbox.

The tests are in `tests/`: unit tests of the lock in `tests/unit`, a
fixture for every kind of dependency in `tests/fixtures`, broken
lockfiles in `tests/negative`, a project with its lockfiles kept outside
its source in `tests/external`, and the lockfile of elysia in
`tests/real-world`. `nix flake check` runs the sandboxed checks, the
`conformance-*` checks of the contract among them. `tests/cli.sh` runs
what needs the network or Nix itself: the relock, `prefetch` followed by
the everyday loop with the network cut, publishing, and
`nix build --rebuild`. CI runs both on x86_64-linux and aarch64-linux.

## Credits

bun-purifier follows the design of
[sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend): the build
tool keeps resolving and planning the build, a lockfile records every
download, and Nix fetches those downloads and builds offline. The
nix-purifiers were inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
