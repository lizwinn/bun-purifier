// SPDX-License-Identifier: MIT
//
// `bun-purifier lock`: writes bun-purifier.lock.json from bun.lock.
//
// bun.lock already names every package with its integrity hash. What it
// leaves out is where bun keeps each package in its install cache: bun
// names a cache entry by internal rules that include hashes (a prerelease
// version, a tarball URL), and an offline install finds packages only
// under those names. The lock run finds them out: it installs a copy of
// the project into an empty cache once per platform that Nix builds for,
// and reads the names bun gave the entries. The lockfile pairs each
// package's cache path with its URL and hash, so Nix can fetch every
// package and lay the cache out without running bun. Each package is an
// archive entry in the shape of the shared nix-purifiers library.

import { createHash } from "node:crypto";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, normalize, relative, resolve } from "node:path";
import { parseJsonc } from "./jsonc";

// nix/lib/lock-version.nix holds the same number.
export const LOCK_VERSION = 1;
export const LOCK_FILE = "bun-purifier.lock.json";

const NPM_REGISTRY = "https://registry.npmjs.org/";

// The bun platforms of the Nix systems the lock serves, as nix/lib/lock.nix
// maps them.
const PLATFORMS: [os: string, cpu: string][] = [
  ["linux", "x64"],
  ["linux", "arm64"],
  ["darwin", "x64"],
  ["darwin", "arm64"],
];

type Meta = { os?: string | string[]; cpu?: string | string[] };

// A download in the shapes of the shared nix-purifiers library. An
// archive entry is the archive at `archive.url`, whose SRI hash is
// `hash`, unpacked at `path` without its single top directory;
// `archive.mirrors` lists other URLs of the same bytes. A git entry is
// the checkout of `git.rev`, whose NAR hash is `hash`, at `path`.
//
// An npm registry keeps every published tarball at its URL, and bun.lock
// records one URL per package, so bun's archive entries have no mirrors.
export type Artifact = {
  path: string;
  archive?: { url: string; mirrors: string[]; stripTop: true };
  // bun keeps the checkout without .git, so `leaveDotGit` is false and
  // there is no commit object to rebuild .git from.
  git?: { url: string; rev: string; submodules: false; leaveDotGit: false; commitObject: null };
  hash: string;
  os?: string | string[];
  cpu?: string | string[];
};

export type LockedPackage = {
  path: string;
  name?: string;
  version?: string;
  private?: boolean;
  bin?: string | Record<string, string>;
  scripts?: string[];
};

export type Lock = {
  version: number;
  bunVersion: string;
  inputsHash: string;
  packages: LockedPackage[];
  artifacts: Artifact[];
};

type BunLock = {
  lockfileVersion: number;
  workspaces: Record<string, unknown>;
  packages: Record<string, unknown[]>;
};

export class LockError extends Error {}

export function readBunLock(root: string): BunLock {
  const file = join(root, "bun.lock");
  if (!existsSync(file)) {
    if (existsSync(join(root, "bun.lockb"))) {
      throw new LockError(
        "this project has the binary bun.lockb. Run `bun install --save-text-lockfile` to write bun.lock, then lock again.",
      );
    }
    throw new LockError(`no bun.lock in ${root}. Run \`bun install\` first.`);
  }
  return parseJsonc(readFileSync(file, "utf8")) as BunLock;
}

function manifestPath(path: string): string {
  return path === "" ? "package.json" : `${path}/package.json`;
}

// The digest nix/lib/lock.nix recomputes to tell a stale lock: SHA-256 of
// bun.lock and every package manifest, each as its path, a newline, its
// content and a newline.
export function inputsHash(root: string, packages: LockedPackage[]): string {
  const hash = createHash("sha256");
  for (const file of ["bun.lock", ...packages.map((p) => manifestPath(p.path))]) {
    hash.update(`${file}\n`);
    hash.update(readFileSync(join(root, file)));
    hash.update("\n");
  }
  return hash.digest("hex");
}

// The packages are the workspaces of bun.lock. Their fields come from
// their manifests, because bun.lock leaves the version and `bin` of the
// root package out.
export function lockedPackages(root: string, bunLock: BunLock): LockedPackage[] {
  return Object.keys(bunLock.workspaces)
    .sort((a, b) => a.localeCompare(b))
    .map((path) => {
      const manifest = JSON.parse(readFileSync(join(root, manifestPath(path)), "utf8"));
      const pkg: LockedPackage = { path };
      if (typeof manifest.name === "string") pkg.name = manifest.name;
      if (typeof manifest.version === "string") pkg.version = manifest.version;
      if (manifest.private === true) pkg.private = true;
      if (manifest.bin !== undefined) pkg.bin = manifest.bin;
      const scripts = Object.keys(manifest.scripts ?? {}).sort();
      if (scripts.length > 0) pkg.scripts = scripts;
      return pkg;
    });
}

function bunfigRegistry(file: string): string | undefined {
  if (!existsSync(file)) return undefined;
  const config = Bun.TOML.parse(readFileSync(file, "utf8")) as {
    install?: { registry?: string | { url?: string } };
  };
  const registry = config.install?.registry;
  return typeof registry === "string" ? registry : registry?.url;
}

// The `registry=` line of an .npmrc, with `${VAR}` references expanded
// from the environment as npm and bun expand them.
function npmrcRegistry(file: string): string | undefined {
  if (!existsSync(file)) return undefined;
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const match = /^\s*registry\s*=\s*(.+?)\s*$/.exec(line);
    if (match) return match[1].replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] ?? "");
  }
  return undefined;
}

// The registry bun installs unscoped packages from when bun.lock names
// none, from the same sources bun reads, first match winning: the
// BUN_CONFIG_REGISTRY and NPM_CONFIG_REGISTRY variables, the project's
// bunfig.toml and .npmrc, the user's .bunfig.toml and .npmrc, and else the
// npm registry. A scoped package needs none of this: bun.lock records the
// tarball URL of every package from a registry other than the default.
function defaultRegistry(root: string): string {
  const home = homedir();
  const xdg = process.env.XDG_CONFIG_HOME ?? join(home, ".config");
  const url =
    process.env.BUN_CONFIG_REGISTRY ||
    process.env.NPM_CONFIG_REGISTRY ||
    process.env.npm_config_registry ||
    bunfigRegistry(join(root, "bunfig.toml")) ||
    npmrcRegistry(join(root, ".npmrc")) ||
    bunfigRegistry(join(xdg, ".bunfig.toml")) ||
    bunfigRegistry(join(home, ".bunfig.toml")) ||
    npmrcRegistry(join(home, ".npmrc")) ||
    NPM_REGISTRY;
  return url.endsWith("/") ? url : `${url}/`;
}

// The URL Nix fetches a git dependency from. The sandbox has no SSH keys,
// so an SSH URL becomes the HTTPS URL of the same repository, which is
// what bun falls back to as well. A private repository needs a `fetchgit`
// with credentials in the Nix build.
function gitFetchUrl(resolution: string): string {
  const url = resolution.replace(/^git\+/, "").replace(/#.*$/, "");
  const ssh = /^ssh:\/\/(?:[^@/]+@)?([^/:]+)(?::\d+)?\/(.+)$/.exec(url);
  if (ssh) return `https://${ssh[1]}/${ssh[2]}`;
  const scp = /^(?:[^@/]+@)?([^/:]+):(?!\/)(.+)$/.exec(url);
  if (scp && !/^[a-z]+:\/\//.test(url)) return `https://${scp[1]}/${scp[2]}`;
  return url;
}

// The NAR hash of a git checkout without submodules, as nixpkgs' fetchgit
// computes it. bun clones without submodules (a bare clone, then a
// checkout of the commit), so the entry says `submodules: false`.
function gitHash(url: string, rev: string): string {
  const run = Bun.spawnSync(["nix-prefetch-git", "--url", url, "--rev", rev, "--quiet"], {
    stdout: "pipe",
    stderr: "inherit",
  });
  if (run.exitCode !== 0) throw new LockError(`nix-prefetch-git could not fetch ${url} at ${rev}.`);
  return JSON.parse(run.stdout.toString()).hash;
}

// bun leaves the host out of the cache name of a package from the npm
// registry.
function cacheHost(registryUrl: string): string {
  const host = new URL(registryUrl).host;
  return host === "registry.npmjs.org" ? "" : host;
}

// The package names and versions of a cache's entries, by kind. Entry
// names of downloaded archives end in `@@@<cache version>`, and a scoped
// package's entry sits in a directory named for its scope. A git checkout
// is `@G@<commit>`.
type Observed = {
  registry: Map<string, string>; // `${name}@${version}@@${host}` -> path
  github: Map<string, string>; // resolution id -> path
  tarball: Map<string, string[]>; // package name -> paths
  git: Map<string, string>; // commit -> path
};

function observe(cache: string): Observed {
  const observed: Observed = { registry: new Map(), github: new Map(), tarball: new Map(), git: new Map() };
  const entries: string[] = [];
  for (const name of readdirSync(cache)) {
    if (name.startsWith("@G@")) {
      observed.git.set(name.slice(3), name);
    } else if (/@@@\d+$/.test(name)) {
      entries.push(name);
    } else if (name.startsWith("@") && !name.includes("@@")) {
      for (const inner of readdirSync(join(cache, name))) {
        if (/@@@\d+$/.test(inner)) entries.push(`${name}/${inner}`);
      }
    }
  }
  for (const path of entries) {
    const entry = basename(path).replace(/@@@\d+$/, "");
    if (entry.startsWith("@GH@")) {
      observed.github.set(entry.slice(4), path);
      continue;
    }
    const manifestFile = join(cache, path, "package.json");
    if (!existsSync(manifestFile)) continue;
    const manifest = JSON.parse(readFileSync(manifestFile, "utf8"));
    if (entry.startsWith("@T@")) {
      const paths = observed.tarball.get(manifest.name) ?? [];
      observed.tarball.set(manifest.name, [...paths, path]);
      continue;
    }
    const host = entry.includes("@@") ? entry.slice(entry.indexOf("@@") + 2) : "";
    observed.registry.set(`${manifest.name}@${manifest.version}@@${host}`, path);
  }
  return observed;
}

// The path of a dependency on a local directory or tarball, relative to
// the project root, or undefined for any other dependency. bun.lock
// writes a directory as `file:<path>` and a tarball as the bare path.
function localPath(resolution: string): string | undefined {
  if (resolution.startsWith("file:")) return normalize(resolution.slice("file:".length));
  if (/^(\.\.?\/|\/)/.test(resolution)) return normalize(resolution);
  return undefined;
}

// The local dependencies outside the project, relative to the project
// root.
export function outsidePaths(bunLock: BunLock): string[] {
  const paths = new Set<string>();
  for (const entry of Object.values(bunLock.packages)) {
    const path = localPath(splitKey(entry[0] as string)[1]);
    if (path !== undefined && (path === ".." || path.startsWith("../") || path.startsWith("/"))) {
      paths.add(path);
    }
  }
  return [...paths].sort();
}

// Copies the project, and each `file:` dependency outside it at the same
// place relative to it, into `work`. Returns the copy of the project.
function copyProject(root: string, bunLock: BunLock, work: string): string {
  const outside = outsidePaths(bunLock).map((p) => resolve(root, p));
  // The deepest directory that holds the project and every outside path.
  let anchor = root;
  while (outside.some((p) => relative(anchor, p).startsWith(".."))) anchor = dirname(anchor);
  const filter = (src: string) => {
    const name = basename(src);
    return name !== "node_modules" && name !== ".git";
  };
  for (const dir of [root, ...outside]) {
    cpSync(dir, join(work, "source", relative(anchor, dir)), { recursive: true, filter });
  }
  return join(work, "source", relative(anchor, root));
}

function lockRun(root: string, bunLock: BunLock, bun: string): string {
  const work = mkdtempSync(join(tmpdir(), "bun-purifier-lock-"));
  const cache = join(work, "cache");
  const project = copyProject(root, bunLock, work);
  for (const [os, cpu] of PLATFORMS) {
    const run = Bun.spawnSync(
      [
        bun,
        "install",
        "--frozen-lockfile",
        "--ignore-scripts",
        "--no-progress",
        `--cache-dir=${cache}`,
        `--os=${os}`,
        `--cpu=${cpu}`,
      ],
      { cwd: project, stdout: "inherit", stderr: "inherit" },
    );
    if (run.exitCode !== 0) {
      rmSync(work, { recursive: true, force: true });
      throw new LockError(`the lock run's bun install for ${os}-${cpu} failed.`);
    }
  }
  return work;
}

function admitsAnyPlatform(meta: Meta): boolean {
  const admits = (field: string | string[] | undefined, value: string) => {
    const entries = field === undefined ? [] : Array.isArray(field) ? field : [field];
    const exclusions = entries.filter((e) => e.startsWith("!"));
    const inclusions = entries.filter((e) => !e.startsWith("!"));
    return !exclusions.includes(`!${value}`) && (inclusions.length === 0 || inclusions.includes(value));
  };
  return PLATFORMS.some(([os, cpu]) => admits(meta.os, os) && admits(meta.cpu, cpu));
}

// Whether a registry entry of bun.lock comes from the default registry,
// which bun.lock writes as "".
function tarballFromDefault(entry: unknown[]): boolean {
  return entry.length === 4 && entry[1] === "";
}

// Splits a bun.lock package key, `<name>@<resolution>`, where a scoped
// name starts with "@" itself.
function splitKey(key: string): [name: string, resolution: string] {
  const at = key.indexOf("@", key.startsWith("@") ? 1 : 0);
  return [key.slice(0, at), key.slice(at + 1)];
}

function artifacts(root: string, bunLock: BunLock, observed: Observed): Artifact[] {
  const registry = defaultRegistry(root);
  const result: Artifact[] = [];
  for (const [id, entry] of Object.entries(bunLock.packages)) {
    const [name, resolution] = splitKey(entry[0] as string);
    // Workspaces, the root and local directories and tarballs are part of
    // the source. An offline install extracts a local tarball from the
    // file itself.
    if (/^(workspace|root):/.test(resolution) || localPath(resolution) !== undefined) continue;
    if (resolution.startsWith("link:")) {
      throw new LockError(
        `${id} is a link: dependency. It names a package registered with \`bun link\` in bun's global directory on this machine, and bun.lock records only the name, so no other machine and no Nix build can resolve it. Depend on the package with file: and its path instead.`,
      );
    }
    if (/^git(\+|:)/.test(resolution)) {
      // [key, meta, commit]
      const rev = entry[2] as string;
      const path = observed.git.get(rev);
      if (path === undefined) throw new LockError(`the lock run left ${id} out of the cache, so its cache path is unknown.`);
      const url = gitFetchUrl(resolution);
      const artifact: Artifact = {
        path,
        git: { url, rev, submodules: false, leaveDotGit: false, commitObject: null },
        hash: gitHash(url, rev),
      };
      const meta = entry[1] as Meta;
      if (meta?.os !== undefined) artifact.os = meta.os;
      if (meta?.cpu !== undefined) artifact.cpu = meta.cpu;
      result.push(artifact);
      continue;
    }
    let url: string;
    let meta: Meta;
    let integrity: unknown;
    let path: string | undefined;
    if (resolution.startsWith("github:")) {
      // [key, meta, resolution id, integrity]
      const match = /^github:([^/]+)\/([^#]+)#(.+)$/.exec(resolution);
      if (!match) throw new LockError(`cannot read the GitHub resolution of ${id}: ${resolution}`);
      const [, owner, repo, ref] = match;
      url = `https://api.github.com/repos/${owner}/${repo}/tarball/${ref}`;
      meta = entry[1] as Meta;
      integrity = entry[3];
      path = observed.github.get(entry[2] as string);
    } else if (/^https?:\/\//.test(resolution)) {
      // [key, meta, integrity]
      url = resolution;
      meta = entry[1] as Meta;
      integrity = entry[2];
      const paths = observed.tarball.get(name) ?? [];
      if (paths.length > 1) {
        throw new LockError(`${name} comes from more than one tarball URL, and bun-purifier cannot tell their cache entries apart.`);
      }
      path = paths[0];
    } else {
      // [key, registry tarball URL or "", meta, integrity]
      const tarball = entry[1] as string;
      const unscoped = name.slice(name.lastIndexOf("/") + 1);
      url = tarball !== "" ? tarball : `${registry}${name}/-/${unscoped}-${resolution}.tgz`;
      meta = entry[2] as Meta;
      integrity = entry[3];
      const host = cacheHost(tarball !== "" ? tarball : registry);
      path = observed.registry.get(`${name}@${resolution}@@${host}`);
    }
    if (typeof integrity !== "string") {
      throw new LockError(`bun.lock has no integrity hash for ${id}.`);
    }
    if (path === undefined) {
      if (!admitsAnyPlatform(meta ?? {})) continue;
      if (tarballFromDefault(entry)) {
        throw new LockError(
          `the lock run left ${id} out of the cache under the registry ${registry}. bun may have installed it from another default registry; set it in bunfig.toml or .npmrc.`,
        );
      }
      throw new LockError(`the lock run left ${id} out of the cache, so its cache path is unknown.`);
    }
    const artifact: Artifact = { path, archive: { url, mirrors: [], stripTop: true }, hash: integrity };
    if (meta?.os !== undefined) artifact.os = meta.os;
    if (meta?.cpu !== undefined) artifact.cpu = meta.cpu;
    result.push(artifact);
  }
  return result.sort((a, b) => a.path.localeCompare(b.path));
}

export function readLock(root: string): Lock | undefined {
  const file = join(root, LOCK_FILE);
  return existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Lock) : undefined;
}

export function isCurrent(root: string, lock: Lock | undefined): boolean {
  if (lock === undefined || lock.version !== LOCK_VERSION || lock.bunVersion !== Bun.version) return false;
  return inputsHash(root, lock.packages) === lock.inputsHash;
}

// Writes the lockfile, or leaves a current one alone unless `force`.
// Returns whether it wrote.
export function lock(root: string, options: { force?: boolean; bun: string }): boolean {
  const bunLock = readBunLock(root);
  if (!options.force && isCurrent(root, readLock(root))) return false;
  const packages = lockedPackages(root, bunLock);
  const work = lockRun(root, bunLock, options.bun);
  try {
    const result: Lock = {
      version: LOCK_VERSION,
      bunVersion: Bun.version,
      inputsHash: inputsHash(root, packages),
      packages,
      artifacts: artifacts(root, bunLock, observe(join(work, "cache"))),
    };
    writeFileSync(join(root, LOCK_FILE), `${JSON.stringify(result, null, 2)}\n`);
    return true;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
