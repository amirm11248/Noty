import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
  plugins: [react()],
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
