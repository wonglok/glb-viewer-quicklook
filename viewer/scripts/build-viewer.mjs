#!/usr/bin/env node
/**
 * Bundles viewer/src into viewer/dist, which is what the Quick Look extension
 * actually ships.
 *
 * Output is a single IIFE classic script. That matters: the page is served over
 * the glbview:// scheme, and a classic script avoids any question of ES-module
 * resolution at runtime — the bundle is self-contained.
 *
 *   node scripts/build-viewer.mjs
 */
import { build } from "esbuild";
import { cpSync, mkdirSync, readdirSync, rmSync } from "node:fs";

import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const SRC = path.join(ROOT, "viewer", "src");
const DIST = path.join(ROOT, "viewer", "dist");
const VENDOR_THREE = path.join(ROOT, "viewer", "vendor", "build", "three.module.js");

mkdirSync(DIST, { recursive: true });

const result = await build({
  entryPoints: [path.join(SRC, "main.js")],
  outfile: path.join(DIST, "viewer.js"),
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["safari17"],
  minify: true,
  sourcemap: false,
  legalComments: "none",
  // The vendored addons all `import ... from 'three'`; point that at our copy so
  // the bundle can never pick up a second, mismatched three at runtime.
  alias: { three: VENDOR_THREE },
  // DRACOLoader and KTX2Loader evaluate `new URL('../libs/…', import.meta.url)`
  // at module scope. An IIFE has no import.meta, so that would be `new URL(x,
  // undefined)` — which throws and takes the whole bundle down before it runs.
  // Substituting a real absolute URL keeps those (unused — we always call
  // setDecoderPath/setTranscoderPath) defaults well-formed.
  define: { "import.meta.url": '"glbview://app/viewer.js"' },
  // Expected and harmless: DRACOLoader/KTX2Loader compute their *default* decoder
  // paths from import.meta.url, which an IIFE bundle has no equivalent for.
  // main.js always calls setDecoderPath/setTranscoderPath, so those defaults are
  // dead code — if these warnings ever change, nothing is broken.
  logLevel: "info",
});

if (result.errors.length > 0) process.exit(1);

// Static payload copied verbatim: the page, and the error reporter that has to
// load before the bundle so it can catch failures during bundle evaluation.
cpSync(path.join(SRC, "index.html"), path.join(DIST, "index.html"));
cpSync(path.join(SRC, "boot.js"), path.join(DIST, "boot.js"));

// The studio environment. Copied into dist rather than fetched from elsewhere so
// the page, the bundle and the HDR share one origin in both hosts — the appex
// over glbview:// and the dev server over http://localhost.
cpSync(path.join(ROOT, "viewer", "assets", "office.hdr"), path.join(DIST, "office.hdr"));

// Decoder payloads were fetched into vendor/decoders by scripts/vendor-three.mjs.
// Copy them verbatim — the directory structure is what the loaders' paths expect.
const decodersFrom = path.join(ROOT, "viewer", "vendor", "decoders");
const decodersTo = path.join(DIST, "decoders");
rmSync(decodersTo, { recursive: true, force: true });
cpSync(decodersFrom, decodersTo, { recursive: true });

console.log(`viewer/dist ready: ${readdirSync(DIST).sort().join(", ")}`);
