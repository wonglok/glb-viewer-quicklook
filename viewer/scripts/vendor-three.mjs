#!/usr/bin/env node
/**
 * Vendors three.js into viewer/vendor/ so `scripts/build-viewer.sh` needs no network.
 *
 * Rather than hand-listing the files (which rots the moment a three.js release
 * moves a module), this walks the real import graph starting from our entries and
 * copies exactly what is reachable.
 *
 *   node scripts/vendor-three.mjs [version]
 */
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const VERSION = process.argv[2] ?? "0.186.1";
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const VENDOR = path.join(ROOT, "viewer", "vendor");
const DECODERS = path.join(VENDOR, "decoders");

/** Entry points the viewer actually imports. Everything else is pulled in transitively. */
const ENTRIES = [
  "build/three.module.js", // pulls in build/three.core.js — three 0.186 splits the build in two
  "examples/jsm/loaders/GLTFLoader.js",
  "examples/jsm/loaders/DRACOLoader.js",
  "examples/jsm/loaders/KTX2Loader.js",
  "examples/jsm/loaders/HDRLoader.js",
  "examples/jsm/controls/OrbitControls.js",
  "examples/jsm/environments/RoomEnvironment.js",
  "examples/jsm/libs/meshopt_decoder.module.js",
];

/**
 * Runtime-fetched decoder payloads. These are not `import`ed (the loaders fetch
 * them as text/bytes from the glbview:// scheme), so the graph walk can't find
 * them and they must be listed. Encoder and non-gltf variants are deliberately
 * excluded — the viewer only decodes.
 */
const DECODER_DIRS = [
  {
    from: "examples/jsm/libs/draco/gltf",
    to: "draco",
    files: ["draco_decoder.js", "draco_decoder.wasm", "draco_wasm_wrapper.js"],
  },
  {
    from: "examples/jsm/libs/basis",
    to: "basis",
    files: ["basis_transcoder.js", "basis_transcoder.wasm"],
  },
];

const work = mkdtempSync(path.join(tmpdir(), "vendor-three-"));
try {
  console.log(`Fetching three@${VERSION}…`);
  const tgz = path.join(work, `three-${VERSION}.tgz`);
  execFileSync("npm", ["pack", `three@${VERSION}`, "--pack-destination", work], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  execFileSync("tar", ["xzf", path.join(work, `three-${VERSION}.tgz`), "-C", work]);
  const pkg = path.join(work, "package");

  const version = JSON.parse(readFileSync(path.join(pkg, "package.json"), "utf8")).version;
  if (version !== VERSION) throw new Error(`expected three@${VERSION}, tarball says ${version}`);

  // ---- walk the import graph -------------------------------------------------
  const seen = new Set();
  const queue = [...ENTRIES];
  while (queue.length) {
    const rel = queue.shift();
    if (seen.has(rel)) continue;
    if (!existsSync(path.join(pkg, rel))) throw new Error(`missing in tarball: ${rel}`);
    seen.add(rel);

    const src = readFileSync(path.join(pkg, rel), "utf8");
    const specs = [
      ...src.matchAll(/\bfrom\s*["']([^"']+)["']/g),
      ...src.matchAll(/\bimport\s*\(\s*["']([^"']+)["']/g),
      ...src.matchAll(/^\s*import\s*["']([^"']+)["']/gm),
    ].map((m) => m[1]);

    for (const spec of specs) {
      if (!spec.startsWith(".")) continue; // 'three' is aliased at bundle time
      queue.push(path.normalize(path.join(path.dirname(rel), spec)));
    }
  }

  // ---- copy -----------------------------------------------------------------
  rmSync(VENDOR, { recursive: true, force: true });

  for (const rel of [...seen].sort()) {
    const dest = path.join(VENDOR, rel);
    mkdirSync(path.dirname(dest), { recursive: true });
    cpSync(path.join(pkg, rel), dest);
  }

  for (const { from, to, files } of DECODER_DIRS) {
    const src = path.join(pkg, from);
    if (!existsSync(src)) throw new Error(`missing decoder dir: ${from}`);
    mkdirSync(path.join(DECODERS, to), { recursive: true });
    for (const f of files) {
      cpSync(path.join(src, f), path.join(DECODERS, to, f));
    }
  }

  writeFileSync(
    path.join(VENDOR, "VERSION"),
    `three@${version}\nvendored by scripts/vendor-three.mjs\nfiles:\n${[...seen].sort().map((f) => "  " + f).join("\n")}\n`,
  );

  console.log(`Vendored ${seen.size} modules + decoders into viewer/vendor/`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
