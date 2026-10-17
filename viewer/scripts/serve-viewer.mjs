#!/usr/bin/env node
/**
 * Serves viewer/dist in a normal browser, standing in for the Quick Look host.
 *
 * The extension injects `window.__GLB_MODEL_URL` as a document-start user script;
 * this does the same thing by rewriting index.html on the way out, so the same
 * bundle can be exercised — camera framing, Draco decoding, animations — without
 * a Finder round-trip.
 *
 *   node scripts/serve-viewer.mjs <model.glb> [port]
 */
import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIST = path.join(ROOT, "dist");

const modelPath = process.argv[2];
const port = Number(process.argv[3] ?? 5183);

if (!modelPath || !existsSync(modelPath)) {
  console.error("usage: node scripts/serve-viewer.mjs <model.glb> [port]");
  process.exit(2);
}

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".wasm": "application/wasm",
  ".glb": "model/gltf-binary",
  ".css": "text/css",
};

const server = createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");

  if (url.pathname === "/" || url.pathname === "/index.html") {
    // Serve index.html verbatim — matching the extension, which passes the model
    // in the query string rather than injecting a script (the page's CSP has no
    // 'unsafe-inline', deliberately).
    const html = readFileSync(path.join(DIST, "index.html"), "utf8");
    response.writeHead(200, { "Content-Type": "text/html" });
    return response.end(html);
  }

  const filePath =
    url.pathname === "/model.glb" ? modelPath : path.join(DIST, url.pathname.slice(1));

  // Keep the server from walking outside dist/.
  if (url.pathname !== "/model.glb" && !path.resolve(filePath).startsWith(DIST)) {
    response.writeHead(403);
    return response.end();
  }

  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    response.writeHead(404);
    return response.end(`not found: ${url.pathname}`);
  }

  response.writeHead(200, {
    "Content-Type": MIME[path.extname(filePath)] ?? "application/octet-stream",
    "Content-Length": statSync(filePath).size,
  });
  createReadStream(filePath).pipe(response);
});

server.listen(port, () => {
  console.log(`open:          http://localhost:${port}/?model=/model.glb`);
  console.log(`model:         ${modelPath}`);
  console.log(`framing probe: window.__glbFrame`);
});
