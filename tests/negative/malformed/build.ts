// Bundles main.ts with esbuild, whose native binary comes from a
// platform-specific optional dependency.
import { build } from "esbuild";

await build({
  entryPoints: ["main.ts"],
  bundle: true,
  platform: "node",
  format: "esm",
  banner: { js: "#!/usr/bin/env node" },
  outfile: "dist/main.js",
});
