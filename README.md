# bun-purifier

A command and a Nix library that build [bun](https://bun.sh) projects in
the Nix sandbox from their lockfiles. It is one of the
[nix-purifiers](https://nix-purifiers.github.io), and it follows the
design of [sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend):
the build tool keeps resolving and planning the build, a lockfile records
every download, and Nix fetches those downloads and builds offline.

bun still resolves the project and writes `bun.lock`. bun-purifier adds a
second lockfile, `bun-purifier.lock.json`, that tells Nix where bun keeps
each package in its install cache. Nix then fetches every package, lays
out the cache and runs `bun install --offline` in the sandbox. Nothing
generated in Nix needs to be committed.

- **A lockfile.** `bun-purifier lock` writes `bun-purifier.lock.json` next
  to `bun.lock`, with every package bun downloads and the project's
  packages.
- **Sandboxed builds.** `buildBunProject`, which the flake's overlay adds
  to a package set, turns a project and its lockfile into derivations: the
  installed and built project, a tarball per package, and wrappers for the
  executables of each package's `bin` field.
- **Installs from the lock.** `bun-purifier install` builds the locked
  cache with Nix and runs an offline `bun install` from it.
- **Publishing what Nix built.** `bun-purifier publish` runs
  `bun publish` with the tarball the Nix sandbox packed.

## How the lock is made

`bun.lock` names every downloaded package with its URL and integrity
hash, and the lockfile takes both from there. What `bun.lock` leaves out
is the name of each package's entry in bun's install cache, and an
offline install finds a package only under that name. bun derives some of
these names with hashes of its own, for prerelease versions and for
tarball URLs.

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
  makes it. `packages.<name>.tarball` is the path of the file.
- `programs.<name>`: the executables of package `<name>`'s `bin` field,
  run by bun from `project`. `programs.<name>.executables.<bin>` is the
  path of each one.

Nix knows every one of these outputs, by name, at evaluation time. The
lockfile lists the project's packages with their names, versions,
directories and `bin` fields, which `bun-purifier lock` takes from the
package manifests, and Nix reads the lockfile as JSON. Nothing is built
to find out what the project produces.

`nix/lib/build-bun-project.nix` documents the arguments:

- `src` and `root`: the source tree, and the project inside it. `root`
  is needed only for `file:` dependencies outside the project (see
  below).
- `buildScript`: the script that builds a package, `build` by default.
- `doCheck`: runs each package's `test` script.
- `fetchurl` and `fetchgit`: replace the fetchers, for credentials or
  mirrors.
- `srcFilter`: filters the source before it is copied into the store.

The builder takes `bun` from the package set, so
`buildBunProject.override` replaces it.

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
of the one named with `--package`, and runs `bun publish` with it in the
package's directory. Further arguments go to `bun publish`, and registry
configuration and credentials work as they do for `bun publish`.

## Dependencies

Every kind of dependency `bun.lock` records builds, except one:

- **Registry packages.** The default registry comes from the sources bun
  reads, first match winning: the `BUN_CONFIG_REGISTRY` and
  `NPM_CONFIG_REGISTRY` variables, the project's `bunfig.toml` and
  `.npmrc`, then the user's `.bunfig.toml` and `.npmrc`. A package from a
  scoped registry carries its own URL in `bun.lock`. A registry that needs
  credentials needs a `fetchurl` with them in the Nix build.
- **`github:` dependencies and `git+https:` URLs on GitHub.** bun
  downloads these as tarballs from the GitHub API, and so does Nix.
- **Other git dependencies** (`git+https:`, `git+ssh:`, `git:`). bun
  clones them, and Nix fetches the same commit with `fetchgit`. The lock
  hashes the checkout with `nix-prefetch-git`. bun clones without
  submodules, so the lock does too. The sandbox has no SSH keys, so Nix
  fetches an SSH URL over HTTPS from the same host, as bun does when SSH
  fails. A private repository needs a `fetchgit` with credentials.
- **Tarball URLs.**
- **Local directories and tarballs** (`file:` and plain paths). These
  are part of the source, and bun installs them from there. When one lies
  outside the project, pass the directory above both as `src` and the
  project's place in it as `root`:

  ```nix
  buildBunProject { src = ./.; root = "app"; }   # app depends on file:../shared
  ```

- **`link:` dependencies do not work, and cannot.** `link:<name>` names
  a package that `bun link` registered in bun's global directory on one
  machine, and `bun.lock` records only the name. Neither Nix nor another
  machine can tell what the name pointed to, so `bun-purifier lock` stops
  with a message. A `file:` dependency on the same directory works.

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

## Development

`nix flake check` builds every fixture under `tests/fixtures` in the
sandbox, runs its programs, and publishes a tarball to a registry inside
the sandbox. `tests/cli.sh` checks what needs the network: that relocking
each fixture reproduces its lockfile, that `install` works, and that
`publish` sends the tarball Nix built. CI runs `nix flake check` on
x86_64-linux and aarch64-linux, and `tests/cli.sh` on x86_64-linux.
