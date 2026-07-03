import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "path";

const host = process.env.TAURI_DEV_HOST;

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  // Prevent vite from obscuring Rust errors
  clearScreen: false,
  server: {
    port: 5173,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 5174,
        }
      : undefined,
    watch: {
      // Tell vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
    proxy: {
      // Dev/testing only: same-origin route to a local stand-in for the
      // vellum-web custom protocol, so the webpage reader can be exercised
      // in a plain browser (see __VELLUM_DEV_PROXY__ in WebViewer).
      "/__vellum-dev-proxy": {
        target: "http://127.0.0.1:8632",
        changeOrigin: true,
        rewrite: (p) => p.replace(/^\/__vellum-dev-proxy/, ""),
      },
    },
  },
});
