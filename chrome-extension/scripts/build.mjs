import { build } from "vite";
import { readFile, copyFile, access } from "node:fs/promises";
await build();
await build({
  configFile: false,
  publicDir: false,
  build: {
    target: "chrome120",
    emptyOutDir: false,
    lib: {
      entry: "src/background/index.ts",
      formats: ["es"],
      fileName: () => "background.js",
    },
  },
});
await copyFile("manifest.json", "dist/manifest.json");
const m = JSON.parse(await readFile("dist/manifest.json", "utf8"));
for (const path of [
  m.background.service_worker,
  m.action.default_popup,
  ...Object.values(m.icons),
])
  await access("dist/" + path);
console.log("Verified MV3 package and all extension entry points.");
