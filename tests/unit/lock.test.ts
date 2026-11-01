// SPDX-License-Identifier: MIT
//
// Unit tests of the lock: reading bun.lock, choosing registries and URLs,
// mapping the cache entries of a lock run to packages, and reading a
// bun-purifier lockfile. `nix flake check` runs them with `bun test`.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseJsonc } from "../../src/jsonc";
import {
  type BunLock,
  LOCK_FILE,
  LOCK_VERSION,
  LockError,
  artifacts,
  cacheHost,
  contentHash,
  canonicalJson,
  defaultRegistry,
  gitFetchUrl,
  inputsHash,
  localPath,
  observe,
  outsidePaths,
  readLock,
  splitKey,
} from "../../src/lock";

let dir: string;
const env = { ...process.env };

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "bun-purifier-test-"));
  process.env = { ...env, HOME: join(dir, "home"), XDG_CONFIG_HOME: join(dir, "xdg") };
  delete process.env.BUN_CONFIG_REGISTRY;
  delete process.env.NPM_CONFIG_REGISTRY;
  delete process.env.npm_config_registry;
});

afterEach(() => {
  process.env = env;
  rmSync(dir, { recursive: true, force: true });
});

function write(path: string, content: string): void {
  mkdirSync(join(dir, path, ".."), { recursive: true });
  writeFileSync(join(dir, path), content);
}

// A cache entry of the lock run: a directory with the package manifest.
function entry(cache: string, path: string, name: string, version: string): void {
  write(`${cache}/${path}/package.json`, JSON.stringify({ name, version }));
}

describe("parseJsonc", () => {
  test("drops trailing commas", () => {
    expect(parseJsonc('{ "a": [1, 2, ], "b": { "c": 3, }, }')).toEqual({ a: [1, 2], b: { c: 3 } });
  });
  test("keeps commas and brackets inside strings", () => {
    expect(parseJsonc('{ "a": ", }", "b": "\\", ]", }')).toEqual({ a: ", }", b: '", ]' });
  });
});

describe("splitKey", () => {
  test("splits a plain name", () => expect(splitKey("kleur@4.1.5")).toEqual(["kleur", "4.1.5"]));
  test("splits a scoped name", () => expect(splitKey("@scope/pkg@1.0.0")).toEqual(["@scope/pkg", "1.0.0"]));
  test("keeps the rest of a resolution", () =>
    expect(splitKey("x@github:owner/repo#abc")).toEqual(["x", "github:owner/repo#abc"]));
});

describe("localPath", () => {
  test("reads file: directories", () => expect(localPath("file:../shared")).toBe("../shared"));
  test("reads plain tarball paths", () => expect(localPath("./vendor/a-1.0.0.tgz")).toBe("vendor/a-1.0.0.tgz"));
  test("leaves versions alone", () => expect(localPath("1.0.0")).toBeUndefined());
  test("leaves URLs alone", () => expect(localPath("https://example.com/a.tgz")).toBeUndefined());
});

describe("outsidePaths", () => {
  test("lists only paths outside the project", () => {
    const bunLock: BunLock = {
      lockfileVersion: 1,
      workspaces: {},
      packages: {
        a: ["a@file:../shared", {}],
        b: ["b@file:vendor/b", {}],
        c: ["c@../c-1.0.0.tgz", {}, "sha512-x"],
      },
    };
    expect(outsidePaths(bunLock)).toEqual(["../c-1.0.0.tgz", "../shared"]);
  });
});

describe("gitFetchUrl", () => {
  test("turns an SSH URL into HTTPS", () =>
    expect(gitFetchUrl("git+ssh://git@github.com/a/b.git#abc")).toBe("https://github.com/a/b.git"));
  test("turns an scp-style address into HTTPS", () =>
    expect(gitFetchUrl("git+git@gitlab.com:a/b.git#abc")).toBe("https://gitlab.com/a/b.git"));
  test("keeps an HTTPS URL", () =>
    expect(gitFetchUrl("git+https://gitlab.com/a/b.git#abc")).toBe("https://gitlab.com/a/b.git"));
  test("keeps a git: URL", () => expect(gitFetchUrl("git://example.com/a.git#abc")).toBe("git://example.com/a.git"));
});

describe("registries", () => {
  test("bun leaves the npm registry out of cache names", () => {
    expect(cacheHost("https://registry.npmjs.org/")).toBe("");
    expect(cacheHost("https://registry.yarnpkg.com/")).toBe("registry.yarnpkg.com");
  });
  test("the default is the npm registry", () => expect(defaultRegistry(dir)).toBe("https://registry.npmjs.org/"));
  test("the user's .npmrc applies", () => {
    write("home/.npmrc", "registry=https://user.example/\n");
    expect(defaultRegistry(dir)).toBe("https://user.example/");
  });
  test("the project's .npmrc wins over the user's", () => {
    write("home/.npmrc", "registry=https://user.example/\n");
    write(".npmrc", "registry=https://project.example\n");
    expect(defaultRegistry(dir)).toBe("https://project.example/");
  });
  test("the project's bunfig.toml wins over its .npmrc", () => {
    write(".npmrc", "registry=https://npmrc.example/\n");
    write("bunfig.toml", '[install]\nregistry = { url = "https://bunfig.example/" }\n');
    expect(defaultRegistry(dir)).toBe("https://bunfig.example/");
  });
  test("the environment wins over everything", () => {
    write("bunfig.toml", '[install]\nregistry = "https://bunfig.example/"\n');
    process.env.NPM_CONFIG_REGISTRY = "https://env.example/";
    expect(defaultRegistry(dir)).toBe("https://env.example/");
  });
  test("an .npmrc expands environment variables", () => {
    process.env.REGISTRY_HOST = "expanded.example";
    write(".npmrc", "registry=https://${REGISTRY_HOST}/\n");
    expect(defaultRegistry(dir)).toBe("https://expanded.example/");
  });
});

describe("artifacts", () => {
  // A lock run's cache for a bun.lock with one package of each kind.
  function project(): { bunLock: BunLock; cache: string } {
    const cache = "cache";
    entry(cache, "kleur@4.1.5@@@1", "kleur", "4.1.5");
    entry(cache, "@scope/is@1.0.0@@registry.example.com@@@1", "@scope/is", "1.0.0");
    entry(cache, "ms@3.0.0-684001923c4f8651@@@1", "ms", "3.0.0-canary.1");
    entry(cache, "@GH@owner-repo-abc1234@@@1", "repo", "1.0.0");
    entry(cache, "@T@3b435a0b1ceadc74@@@1", "tarred", "2.0.0");
    // bun extracts a local tarball into the cache too.
    entry(cache, "@T@9895b98ad6776dd3@@@1", "packed", "1.0.0");
    const bunLock: BunLock = {
      lockfileVersion: 1,
      workspaces: {},
      packages: {
        app: ["app@workspace:packages/app"],
        kleur: ["kleur@4.1.5", "", {}, "sha512-kleur"],
        "app/kleur": ["kleur@4.1.5", "", {}, "sha512-kleur"],
        "@scope/is": ["@scope/is@1.0.0", "https://registry.example.com/@scope/is/-/is-1.0.0.tgz", {}, "sha512-is"],
        ms: ["ms@3.0.0-canary.1", "", {}, "sha512-ms"],
        repo: ["repo@github:owner/repo#abc1234", {}, "owner-repo-abc1234", "sha512-repo"],
        tarred: ["tarred@https://example.com/tarred-2.0.0.tgz", {}, "sha512-tarred"],
        local: ["local@file:vendor/local", {}],
        packed: ["packed@./vendor/packed-1.0.0.tgz", {}, "sha512-packed"],
        wasm: ["wasm@1.0.0", "", { cpu: "none" }, "sha512-wasm"],
      },
    };
    return { bunLock, cache: join(dir, cache) };
  }

  test("maps every downloaded package to its cache path and URL", () => {
    const { bunLock, cache } = project();
    const locked = artifacts(dir, bunLock, observe(cache));
    expect(locked.map((a) => [a.path, a.archive?.url, a.hash])).toEqual([
      [
        "@GH@owner-repo-abc1234@@@1",
        "https://api.github.com/repos/owner/repo/tarball/abc1234",
        "sha512-repo",
      ],
      ["@scope/is@1.0.0@@registry.example.com@@@1", "https://registry.example.com/@scope/is/-/is-1.0.0.tgz", "sha512-is"],
      ["@T@3b435a0b1ceadc74@@@1", "https://example.com/tarred-2.0.0.tgz", "sha512-tarred"],
      ["kleur@4.1.5@@@1", "https://registry.npmjs.org/kleur/-/kleur-4.1.5.tgz", "sha512-kleur"],
      ["ms@3.0.0-684001923c4f8651@@@1", "https://registry.npmjs.org/ms/-/ms-3.0.0-canary.1.tgz", "sha512-ms"],
    ]);
  });

  test("every archive entry strips its top directory and has no mirrors", () => {
    const { bunLock, cache } = project();
    for (const a of artifacts(dir, bunLock, observe(cache))) {
      expect(a.archive).toMatchObject({ mirrors: [], stripTop: true });
    }
  });

  test("leaves out packages the lock run did not install", () => {
    const { bunLock, cache } = project();
    expect(artifacts(dir, bunLock, observe(cache)).some((a) => a.path.startsWith("wasm"))).toBe(false);
  });

  test("rejects a cache entry that matches no package", () => {
    const { bunLock, cache } = project();
    entry("cache", "stray@1.0.0@@@1", "stray", "1.0.0");
    expect(() => artifacts(dir, bunLock, observe(cache))).toThrow(/match no entry of bun.lock/);
  });

  test("rejects two entries for one cache path that disagree", () => {
    const { bunLock, cache } = project();
    bunLock.packages["app/kleur"] = ["kleur@4.1.5", "", {}, "sha512-other"];
    expect(() => artifacts(dir, bunLock, observe(cache))).toThrow(/two entries for the cache entry/);
  });

  test("rejects link: dependencies with the reason", () => {
    const { bunLock, cache } = project();
    bunLock.packages.linked = ["linked@link:linked", {}];
    expect(() => artifacts(dir, bunLock, observe(cache))).toThrow(/registered with `bun link`/);
  });

  test("rejects a package without an integrity hash", () => {
    const { bunLock, cache } = project();
    bunLock.packages.kleur = ["kleur@4.1.5", "", {}];
    delete bunLock.packages["app/kleur"];
    expect(() => artifacts(dir, bunLock, observe(cache))).toThrow(/no integrity hash/);
  });
});

describe("digests", () => {
  test("canonical JSON sorts keys and drops whitespace, as builtins.toJSON does", () => {
    expect(canonicalJson({ b: [1, { d: null, c: "x" }], a: true })).toBe('{"a":true,"b":[1,{"c":"x","d":null}]}');
  });

  test("the inputs digest changes with a manifest", () => {
    write("bun.lock", "{}");
    write("package.json", '{ "name": "a" }');
    const before = inputsHash(dir, [{ path: "" }]);
    write("package.json", '{ "name": "b" }');
    expect(inputsHash(dir, [{ path: "" }])).not.toBe(before);
  });
});

describe("readLock", () => {
  function lockfile(edit: (lock: Record<string, unknown>) => void = () => {}): void {
    const artifacts = [{ path: "a@1.0.0@@@1", archive: { url: "https://x/a.tgz", mirrors: [], stripTop: true }, hash: "sha512-a" }];
    const content = {
      version: LOCK_VERSION,
      bunVersion: Bun.version,
      inputsHash: "",
      packages: [],
      artifacts,
    };
    const lock: Record<string, unknown> = { ...content, contentHash: contentHash(content as never) };
    edit(lock);
    write(LOCK_FILE, JSON.stringify(lock, null, 2));
  }

  const file = () => join(dir, LOCK_FILE);

  test("reads a lockfile", () => {
    lockfile();
    expect(readLock(file())?.artifacts.length).toBe(1);
  });
  test("returns nothing without a lockfile", () => expect(readLock(file())).toBeUndefined());
  test("names a merge conflict", () => {
    write(LOCK_FILE, '{\n<<<<<<< ours\n"a": 1\n=======\n"a": 2\n>>>>>>> theirs\n}\n');
    expect(() => readLock(file())).toThrow(/merge conflict markers.*bun-purifier lock --force/);
  });
  test("names malformed JSON", () => {
    write(LOCK_FILE, '{ "version": ');
    expect(() => readLock(file())).toThrow(/not valid JSON.*bun-purifier lock --force/);
  });
  test("names another format version", () => {
    lockfile((lock) => (lock.version = 0));
    expect(() => readLock(file())).toThrow(/lock format version 0/);
  });
  test("names a hand-edited hash", () => {
    lockfile((lock) => ((lock.artifacts as { hash: string }[])[0].hash = "sha512-tampered"));
    expect(() => readLock(file())).toThrow(LockError);
    expect(() => readLock(file())).toThrow(/edited after the lock.*bun-purifier lock --force/);
  });
  test("reads a lockfile outside the project by its own name", () => {
    lockfile();
    write("elsewhere/app.lock.json", JSON.stringify(readLock(file())));
    expect(readLock(join(dir, "elsewhere/app.lock.json"))?.artifacts.length).toBe(1);
  });
});
