import { defineConfig } from "vitest/config";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  plugins: [vue()],

  server: {
    host: "0.0.0.0",
    port: 5173,

    // Backend dijalankan terpisah saat development. Komponen memanggil
    // "/api/data" relatif, jadi proxy inilah yang mengarahkannya ke Echo.
    proxy: {
      "/api": {
        target: "http://localhost:8888",
        changeOrigin: true,
      },
    },
  },

  test: {
    environment: "jsdom",
    globals: true,
    include: ["src/**/*.spec.js"],
  },
});
