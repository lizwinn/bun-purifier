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
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
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

// An archive download in the shape of the shared nix-purifiers library:
// the archive at `archive.url`, whose SRI hash is `hash`, unpacked at
// `path` without its single top directory.
export type Artifact = {
  path: string;
  archive: { url: string; stripTop: true };
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

// The registry bun installs unscoped packages from when bun.lock names
// none: bunfig.toml's install.registry, else the npm registry.
function defaultRegistry(root: string): string {
  const bunfig = join(root, "bunfig.toml");
  if (existsSync(bunfig)) {
    const config = Bun.TOML.parse(readFileSync(bunfig, "utf8")) as {
      install?: { registry?: string | { url?: string } };
    };
    const registry = config.install?.registry;
    const url = typeof registry === "string" ? registry : registry?.url;
    if (url) return url.endsWith("/") ? url : `${url}/`;
  }
  return NPM_REGISTRY;
}

// bun leaves the host out of the cache name of a package from the npm
// registry.
function cacheHost(registryUrl: string): string {
  const host = new URL(registryUrl).host;
  return host === "registry.npmjs.org" ? "" : host;
}

// The package names and versions of a cache's entries, by kind. Entry
// names end in `@@@<cache version>`; a scoped package's entry sits in a
// directory named for its scope.
type Observed = {
  registry: Map<string, string>; // `${name}@${version}@@${host}` -> path
  github: Map<string, string>; // resolution id -> path
  tarball: Map<string, string[]>; // package name -> paths
};

function observe(cache: string): Observed {
  const observed: Observed = { registry: new Map(), github: new Map(), tarball: new Map() };
  const entries: string[] = [];
  for (const name of readdirSync(cache)) {
    if (/@@@\d+$/.test(name)) {
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

function lockRun(root: string, bun: string): string {
  const work = mkdtempSync(join(tmpdir(), "bun-purifier-lock-"));
  const project = join(work, "project");
  const cache = join(work, "cache");
  cpSync(root, project, {
    recursive: true,
    filter: (src) => {
      const name = basename(src);
      return name !== "node_modules" && name !== ".git";
    },
  });
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
    if (/^(workspace|link|file|root):/.test(resolution)) continue;
    if (/^git(\+|:)/.test(resolution)) {
      throw new LockError(
        `${id} is a git dependency (${resolution}). bun-purifier supports registry packages, github: dependencies and tarball URLs.`,
      );
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
      throw new LockError(`the lock run left ${id} out of the cache, so its cache path is unknown.`);
    }
    const artifact: Artifact = { path, archive: { url, stripTop: true }, hash: integrity };
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
  const work = lockRun(root, options.bun);
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
