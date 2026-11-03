// SPDX-License-Identifier: MIT
import { withNpmInputs } from "./npm-inputs";
const [root, catalog, repository, ...command] = process.argv.slice(2);
let code = 1;
withNpmInputs(root, [{ repository, catalog }], () => {
  const rebound = Bun.spawnSync([process.execPath, "install", "--lockfile-only", "--offline", "--ignore-scripts", "--no-progress"], {
    cwd: root, stdin: "inherit", stdout: "inherit", stderr: "inherit",
  });
  if (rebound.exitCode !== 0) { code = rebound.exitCode ?? 1; return; }
  const result = Bun.spawnSync(command, { cwd: root, stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  code = result.exitCode ?? 1;
});
process.exit(code);
