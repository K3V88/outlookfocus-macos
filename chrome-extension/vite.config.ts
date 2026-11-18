import { defineConfig } from "vite";
export default defineConfig({
  base: "./",
  build: { target: "chrome120", rollupOptions: { input: "popup.html" } },
});
