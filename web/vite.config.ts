import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { type Plugin } from "vite";
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

const REPO = resolve(__dirname, "..");

// sha256 over every file git tracks under web/: its path, then its bytes with CRLF read as LF (so a
// Windows checkout hashes the same), for text and binary files alike. The build writes it to
// dist/source-hash.txt; tests/test_build_web.py recomputes it the same way, so a source change
// without a rebuild fails the tests.
export function sourceHash(): string {
  const files = execFileSync("git", ["ls-files", "web"], { cwd: REPO, encoding: "utf8" })
    .split("\n").filter(Boolean).sort();
  // An empty list means web/ is not committed yet: a stamp over nothing would compare nothing.
  if (!files.length) throw new Error("git tracks no files under web/: commit (or git add) the source, then build");
  const h = createHash("sha256");
  for (const f of files) {
    h.update(f + "\n");
    // latin1 maps each byte to one char and back, so this replaces CRLF bytes without decoding.
    h.update(Buffer.from(readFileSync(resolve(REPO, f)).toString("latin1").replace(/\r\n/g, "\n"), "latin1"));
    h.update("\n");
  }
  return h.digest("hex");
}

function sourceHashFile(): Plugin {
  return {
    name: "source-hash",
    apply: "build",
    generateBundle() {
      this.emitFile({ type: "asset", fileName: "source-hash.txt", source: sourceHash() + "\n" });
    },
  };
}

// The build is committed to app/web/dist so users need no Node; FastAPI serves it.
export default defineConfig({
  plugins: [react(), sourceHashFile()],
  base: "/",
  build: { outDir: "../app/web/dist", emptyOutDir: true, sourcemap: false, chunkSizeWarningLimit: 2000 },
  server: { proxy: { "/api": "http://127.0.0.1:8000" } },
  test: { environment: "jsdom", globals: true, setupFiles: ["./src/test/setup.ts"] },
});
