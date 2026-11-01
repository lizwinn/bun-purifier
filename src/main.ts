// SPDX-License-Identifier: MIT
//
// The bun-purifier command.
//
//   bun-purifier lock [--force]
//     Writes bun-purifier.lock.json from bun.lock (src/lock.ts).
//   bun-purifier install [bun install flags]
//     Builds the locked install cache with Nix and runs an offline
//     `bun install` from it.
//   bun-purifier publish [--package <name>] [bun publish flags]
//     Builds the package's tarball in the Nix sandbox and runs
//     `bun publish` with it.
//
// The Nix package (pkgs/bun-purifier) runs this file with the bun the lock
// is made with, and sets BUN_PURIFIER_LIB to nix/lib and
// BUN_PURIFIER_NIXPKGS to the nixpkgs the flake pins.

import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readlinkSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { isCurrent, LOCK_FILE, LockError, lock, readLock } from "./lock";

const usage = `usage:
  bun-purifier lock [--force]
  bun-purifier install [bun install flags]
  bun-purifier publish [--package <name>] [bun publish flags]`;

function fail(message: string): never {
  console.error(`bun-purifier: ${message}`);
  process.exit(1);
}

function env(name: string): string {
  return process.env[name] ?? fail(`${name} is not set; run bun-purifier through its Nix package.`);
}

// The project root: the nearest directory upward with a bun.lock.
function findRoot(): string {
  let dir = process.cwd();
  for (;;) {
    if (existsSync(join(dir, "bun.lock")) || existsSync(join(dir, "bun.lockb"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) fail("no bun.lock in this directory or above it.");
    dir = parent;
  }
}

function run(argv: string[], cwd: string): void {
  const result = Bun.spawnSync(argv, { cwd, stdout: "inherit", stderr: "inherit", stdin: "inherit" });
  if (result.exitCode !== 0) process.exit(result.exitCode ?? 1);
}

function nixBuild(root: string, args: string[], outLink?: string): string {
  const argv = [
    "nix",
    "build",
    "--print-out-paths",
    "--file",
    join(env("BUN_PURIFIER_LIB"), "interactive.nix"),
    "--argstr",
    "nixpkgs",
    env("BUN_PURIFIER_NIXPKGS"),
    ...args,
    ...(outLink ? ["--out-link", outLink] : ["--no-link"]),
  ];
  const result = Bun.spawnSync(argv, { cwd: root, stdout: "pipe", stderr: "inherit" });
  if (result.exitCode !== 0) fail("the Nix build failed.");
  return result.stdout.toString().trim().split("\n")[0];
}

function requireCurrentLock(root: string): void {
  if (!isCurrent(root, readLock(root))) {
    fail(`${LOCK_FILE} is missing or older than bun.lock and the package manifests. Run \`bun-purifier lock\`.`);
  }
}

// Recreates the directories of a tree of links with default permissions,
// and links each of its symlinks to the same target. A recursive copy
// would keep the read-only modes of the store.
function linkTree(from: string, to: string): void {
  mkdirSync(to, { recursive: true });
  for (const name of readdirSync(from)) {
    const source = join(from, name);
    if (lstatSync(source).isSymbolicLink()) {
      symlinkSync(readlinkSync(source), join(to, name));
    } else {
      linkTree(source, join(to, name));
    }
  }
}

// Gives the owner write permission on every directory of a tree, so it
// can be removed.
function makeRemovable(dir: string): void {
  if (!existsSync(dir) || lstatSync(dir).isSymbolicLink() || !lstatSync(dir).isDirectory()) return;
  chmodSync(dir, 0o755);
  for (const name of readdirSync(dir)) makeRemovable(join(dir, name));
}

function install(root: string, args: string[]): void {
  requireCurrentLock(root);
  // The Nix build's result link is a GC root, so the cache stays in the
  // store while the project uses it.
  const dir = join(root, "node_modules", ".cache", "bun-purifier");
  mkdirSync(dir, { recursive: true });
  const cache = nixBuild(root, ["--argstr", "lockFile", join(root, LOCK_FILE), "cache"], join(dir, "result"));
  // bun writes into its cache directory: a writable copy of the tree of
  // links to the unpacked packages.
  const writable = join(dir, "bun-cache");
  makeRemovable(writable);
  rmSync(writable, { recursive: true, force: true });
  linkTree(cache, writable);
  run([process.execPath, "install", "--frozen-lockfile", "--offline", `--cache-dir=${writable}`, ...args], root);
}

function publish(root: string, args: string[]): void {
  requireCurrentLock(root);
  const lockfile = readLock(root)!;
  let name: string | undefined;
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--package") name = args[++i];
    else if (args[i].startsWith("--package=")) name = args[i].slice("--package=".length);
    else rest.push(args[i]);
  }
  if (name === undefined) {
    // The package of the working directory.
    const path = relative(root, process.cwd());
    name =
      lockfile.packages.find((p) => p.path === path)?.name ??
      fail(`no package of ${LOCK_FILE} is at ${path || "the project root"}; name one with --package.`);
  }
  const pkg =
    lockfile.packages.find((p) => p.name === name && p.version) ??
    fail(`${LOCK_FILE} has no package named ${name} with a version.`);
  const out = nixBuild(root, ["--argstr", "src", root, "--argstr", "package", name!, "package"]);
  const tarball = readdirSync(out).find((f) => f.endsWith(".tgz")) ?? fail(`the build of ${name} made no tarball.`);
  // bun publish runs in the directory of the package, so it reads the
  // registry configuration there, as it does for a package it packs.
  run([process.execPath, "publish", join(out, tarball), ...rest], join(root, pkg.path));
}

const [command, ...args] = process.argv.slice(2);
try {
  const root = command === undefined ? "" : findRoot();
  switch (command) {
    case "lock": {
      const wrote = lock(root, { force: args.includes("--force"), bun: process.execPath });
      console.error(wrote ? `bun-purifier: wrote ${resolve(root, LOCK_FILE)}` : `bun-purifier: ${LOCK_FILE} is current.`);
      break;
    }
    case "install":
      install(root, args);
      break;
    case "publish":
      publish(root, args);
      break;
    default:
      console.error(usage);
      process.exit(command === undefined || command === "--help" ? 0 : 2);
  }
} catch (e) {
  if (e instanceof LockError) fail(e.message);
  throw e;
}
