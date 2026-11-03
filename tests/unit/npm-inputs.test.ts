// SPDX-License-Identifier: MIT
import { test, expect } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { withNpmInputs } from "../../src/npm-inputs";

test("native manifest bindings restore exact bytes when Bun fails", () => {
  const root = mkdtempSync(join(tmpdir(), "bun-nix-inputs-"));
  try {
    const path = join(root, "package.json");
    const bytes = '{"name":"consumer", "dependencies":{"alias":"npm:provided@^99", "ordinary":"^1"}}\n';
    writeFileSync(path, bytes);
    const catalog = join(root, "catalog.json");
    writeFileSync(catalog, JSON.stringify({ modules: [{ name: "provided", version: "1.0.0-nix.abc", primary: true, integrity: "sha512-test", archive: "tarballs/provided.tgz" }] }));
    const views = [{ repository: "/nix/store/fixture", catalog }];
    expect(() => withNpmInputs(root, views, () => {
      expect(JSON.parse(readFileSync(path, "utf8")).dependencies).toEqual({ alias: "file:/nix/store/fixture/tarballs/provided.tgz", ordinary: "^1" });
      throw new Error("native install failed");
    })).toThrow("native install failed");
    expect(readFileSync(path, "utf8")).toBe(bytes);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("first lock binds workspace manifests and respects workspace exclusions", () => {
  const root = mkdtempSync(join(tmpdir(), "bun-nix-workspaces-"));
  try {
    writeFileSync(join(root, "package.json"), JSON.stringify({ name: "workspace", workspaces: ["packages/*", "!packages/excluded"] }));
    const original = '{"name":"consumer","dependencies":{"provided":">=99"}}\n';
    for (const name of ["included", "excluded"]) {
      mkdirSync(join(root, "packages", name), { recursive: true });
      writeFileSync(join(root, "packages", name, "package.json"), original);
    }
    const catalog = join(root, "catalog.json");
    writeFileSync(catalog, JSON.stringify({ modules: [{ name: "provided", version: "1.0.0-nix.abc", primary: true, integrity: "sha512-test", archive: "tarballs/provided.tgz" }] }));
    const included = join(root, "packages/included/package.json");
    const excluded = join(root, "packages/excluded/package.json");
    withNpmInputs(root, [{ repository: "/nix/store/fixture", catalog }], () => {
      expect(JSON.parse(readFileSync(included, "utf8")).dependencies.provided).toBe("file:/nix/store/fixture/tarballs/provided.tgz");
      expect(readFileSync(excluded, "utf8")).toBe(original);
    });
    expect(readFileSync(included, "utf8")).toBe(original);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
