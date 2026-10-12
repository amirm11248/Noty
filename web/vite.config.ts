import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
  plugins: [react(), {
    name: "local-development-policy",
    apply: "serve",
    transformIndexHtml(html) {
      // Allow only the local development server's scripts and live reload.
      return html.replace("script-src 'self';", "script-src 'self' 'unsafe-inline';")
        .replace("connect-src blob:;", "connect-src 'self' blob: ws://localhost:* ws://127.0.0.1:*;");
    },
  }],
  build: {
    rollupOptions: {
      treeshake: false,
      output: {
        manualChunks(id) {
          if (id.includes("/node_modules/pdfjs-dist/")) return "pdf";
          if (id.includes("/node_modules/mammoth/")) return "word-import";
          if (
            id.includes("/node_modules/@tiptap/") ||
            id.includes("/node_modules/prosemirror-")
          )
            return "writing";
        },
      },
    },
  },
});
