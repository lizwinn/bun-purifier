// SPDX-License-Identifier: MIT
// Native Bun consumes an installation view; publication keeps the original
// namespaced archives. Manifest edits exist only during the native command.
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { canonicalJson, copyProject, readBunLock } from "./lock";

type Module = {
  name: string;
  version: string;
  primary?: boolean;
  archive: string;
  integrity: string;
};
export type Repository = { repository: string; catalog: string };

export function withNpmInputs<T>(root: string, views: Repository[], body: () => T, persistChanges = false): T {
  if (views.length === 0) return body();
  const modules = new Map<string, (Module & { repository: string })[]>();
  for (const view of views) {
    const catalog = JSON.parse(readFileSync(view.catalog, "utf8"));
    for (const item of catalog.modules as Module[]) {
      const versions = modules.get(item.name) ?? [];
      const same = versions.find(previous => previous.version === item.version);
      if (same && same.integrity !== item.integrity)
        throw new Error(`conflicting Nix repositories supply ${item.name}@${item.version}`);
      if (!same) versions.push({ ...item, repository: view.repository });
      else if (item.primary) same.primary = true;
      modules.set(item.name, versions);
    }
  }
  const paths = new Set([join(root, "package.json")]);
  if (existsSync(join(root, "bun.lock"))) {
    for (const workspace of Object.keys(readBunLock(root).workspaces))
      paths.add(join(root, workspace, "package.json"));
  }
  const rootManifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  const workspaces: string[] = Array.isArray(rootManifest.workspaces)
    ? rootManifest.workspaces : rootManifest.workspaces?.packages ?? [];
  const excluded = workspaces.filter(pattern => pattern.startsWith("!"))
    .map(pattern => new Bun.Glob(`${pattern.slice(1)}/package.json`));
  for (const pattern of workspaces.filter(pattern => !pattern.startsWith("!"))) {
    for (const path of new Bun.Glob(`${pattern}/package.json`).scanSync({ cwd: root, onlyFiles: true, followSymlinks: false }))
      if (!excluded.some(glob => glob.match(path))) paths.add(join(root, path));
  }
  const saved = new Map<string, Buffer>();
  const bound = new Map<string, Record<string, any>>();
  let succeeded = false;
  try {
    for (const path of paths) {
      if (!existsSync(path)) continue;
      const bytes = readFileSync(path);
      const manifest = JSON.parse(bytes.toString());
      let changed = false;
      for (const kind of ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]) {
        for (const [name, request] of Object.entries(manifest[kind] ?? {})) {
          if (typeof request !== "string" || request.startsWith("workspace:")) continue;
          const alias = /^npm:(@[^/]+\/[^@]+|[^@]+)@(.+)$/.exec(request);
          const actual = alias ? alias[1] : name;
          const versions = modules.get(actual);
          if (!versions) continue;
          const wanted = alias ? alias[2] : request;
          const exact = versions.find(item => item.version === wanted);
          const primary = versions.filter(item => item.primary);
          const selected = exact ?? (primary.length === 1 ? primary[0] : versions.length === 1 ? versions[0] : undefined);
          if (!selected) throw new Error(`Nix repositories supply multiple versions of ${actual}; no unique producer is selected`);
          manifest[kind][name] = `file:${join(selected.repository, selected.archive)}`;
          changed = true;
        }
      }
      if (changed) {
        saved.set(path, bytes);
        bound.set(path, structuredClone(manifest));
        writeFileSync(path, JSON.stringify(manifest, null, 2) + "\n");
      }
    }
    const result = body();
    succeeded = true;
    return result;
  } finally {
    for (const [path, bytes] of saved) {
      if (persistChanges && succeeded) {
        const original = JSON.parse(bytes.toString());
        const after = JSON.parse(readFileSync(path, "utf8"));
        for (const kind of ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"])
          for (const [name, request] of Object.entries(bound.get(path)?.[kind] ?? {}))
            if (after[kind]?.[name] === request && original[kind]?.[name] !== undefined)
              after[kind][name] = original[kind][name];
        writeFileSync(path, canonicalJson(after) === canonicalJson(original) ? bytes : JSON.stringify(after, null, 2) + "\n");
      } else writeFileSync(path, bytes);
    }
  }
}

// Resolve changed supplied identities in an owned copy, then lend the native
// lock to install. The committed lock remains byte-for-byte unchanged.
export function withBoundNpmLock<T>(root: string, views: Repository[], body: () => T): T {
  if (views.length === 0) return body();
  const file = join(root, "bun.lock");
  const saved = readFileSync(file);
  const work = mkdtempSync(join(tmpdir(), "bun-input-lock-"));
  try {
    const project = copyProject(root, readBunLock(root), work);
    const result = Bun.spawnSync([process.execPath, "install", "--lockfile-only", "--offline", "--ignore-scripts", "--no-progress"], {
      cwd: project, stdin: "inherit", stdout: "inherit", stderr: "inherit",
    });
    if (result.exitCode !== 0) throw new Error("Bun could not bind the Nix-supplied dependencies offline");
    writeFileSync(file, readFileSync(join(project, "bun.lock")));
    return body();
  } finally {
    writeFileSync(file, saved);
    rmSync(work, { recursive: true, force: true });
  }
}
