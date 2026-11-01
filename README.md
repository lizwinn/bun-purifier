# bun-purifier

A command and a Nix library that build [bun](https://bun.sh) projects in
the Nix sandbox from their lockfiles. It is one of the
[nix-purifiers](https://nix-purifiers.github.io).

bun still resolves the project and writes `bun.lock`. bun-purifier adds a
second lockfile, `bun-purifier.lock.json`, that tells Nix where bun keeps
each package in its install cache. Nix then fetches every package, lays
out the cache and runs `bun install --offline` in the sandbox. Nothing
generated in Nix needs to be committed.

- **A lockfile.** `bun-purifier lock` writes `bun-purifier.lock.json` next
  to `bun.lock`, with every package bun downloads (by URL and integrity
  hash) and the project's packages.
- **Sandboxed builds.** `buildBunProject`, which the flake's overlay adds
  to a package set, turns a project and its lockfile into derivations: the
  installed and built project, a tarball per package, and wrappers for the
  executables of each package's `bin` field.
- **Installs from the lock.** `bun-purifier install` builds the locked
  cache with Nix and runs an offline `bun install` from it.
- **Publishing what Nix built.** `bun-purifier publish` runs
  `bun publish` with the tarball the Nix sandbox packed.

## How the lock is made

`bun.lock` names every package with its URL and integrity hash, so the
lockfile takes both from there. What `bun.lock` leaves out is the name of
each package's entry in bun's install cache, and an offline install finds
a package only under that name. bun derives some of these names with
hashes of its own, for prerelease versions and for tarball URLs.

`bun-purifier lock` therefore copies the project to a temporary directory
and installs it into an empty cache once for each platform that Nix
builds for: Linux and macOS, on x64 and arm64. It reads the name of every
cache entry and pairs it with the package's URL and hash. Packages for
other platforms, such as esbuild's Windows binary, stay out of the
lockfile.

The lockfile also records a digest of `bun.lock` and the package
manifests. `bun-purifier lock` relocks only when they changed, or with
`--force`, and a Nix build of a stale lockfile fails with a hint to
relock.

## Use

Lock the project in its root directory, and commit
`bun-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/bun-purifier -- lock
```

The flake's `overlays.default` adds `buildBunProject` to a package set,
and a package written for `callPackage` takes it by name, like any other
builder:

```nix
# package.nix
{ buildBunProject }:
(buildBunProject { src = ./.; }).programs.my-app
```

```nix
{
  inputs.bun-purifier.url = "github:nix-purifiers/bun-purifier";
  inputs.nixpkgs.follows = "bun-purifier/nixpkgs";

  outputs = { nixpkgs, bun-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          bun-purifier.overlays.default
          (final: prev: { my-app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.my-app = pkgs.my-app;
    };
}
```

`buildBunProject` returns

- `cache`: the bun install cache of the locked packages for the build's
  system.
- `project`: the project after `bun install` and the `build` script of
  every package that has one. Workspaces build in the order of their
  dependencies.
- `packages.<name>`: the tarball of package `<name>`, as `bun pm pack`
  makes it.
- `programs.<name>`: the executables of package `<name>`'s `bin` field,
  run by bun from `project`.

`nix/lib/build-bun-project.nix` documents the arguments: `buildScript`
(the script that builds a package), `doCheck` (runs each package's `test`
script), `fetchurl` (for credentials or mirrors) and `srcFilter`. The
builder takes `bun` from the package set, so `buildBunProject.override`
replaces it.

### Installing from the lock

```zsh
nix run github:nix-purifiers/bun-purifier -- install
```

`install` builds the locked cache with Nix, keeps it alive with a GC root
in `node_modules/.cache/bun-purifier`, and runs
`bun install --frozen-lockfile --offline` from it. Further arguments go to
`bun install`. A dependency that is not in the lockfile fails the install;
change dependencies with plain `bun`, then lock again.

### Publishing

```zsh
nix run github:nix-purifiers/bun-purifier -- publish --access public
```

`publish` builds the tarball of the package in the working directory, or
of the one named with `--package`, and runs `bun publish` with it.
Further arguments go to `bun publish`, and registry configuration and
credentials work as they do for `bun publish`.

## Dependencies bun-purifier supports

Registry packages, `github:` dependencies and tarball URLs lock and build.
Git dependencies (`git+https:`, `git+ssh:`) fail the lock with a message.

The lock reads the default registry from `bunfig.toml`
(`install.registry`). A package from a scoped registry carries its own
URL in `bun.lock`. A registry that needs credentials needs a `fetchurl`
with them in the Nix build.

bun runs no lifecycle scripts of dependencies, so a dependency that
downloads a binary in `postinstall` lacks it in the sandbox as it does
outside. Packages that ship binaries as optional dependencies per
platform, like esbuild, work: the lockfile holds the package of each
platform.

The lockfile records the version of bun that made it, because the names
of cache entries follow the rules of that version. A build with a bun of
another minor version prints a warning. The `bun-purifier` command runs
the bun of its own package set, so `lock`, `install` and `publish` agree
with each other.
