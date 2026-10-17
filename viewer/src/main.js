import * as THREE from "../vendor/build/three.module.js";
import { OrbitControls } from "../vendor/examples/jsm/controls/OrbitControls.js";
import { GLTFLoader } from "../vendor/examples/jsm/loaders/GLTFLoader.js";
import { DRACOLoader } from "../vendor/examples/jsm/loaders/DRACOLoader.js";
import { KTX2Loader } from "../vendor/examples/jsm/loaders/KTX2Loader.js";
import { MeshoptDecoder } from "../vendor/examples/jsm/libs/meshopt_decoder.module.js";
import { RoomEnvironment } from "../vendor/examples/jsm/environments/RoomEnvironment.js";
import { HDRLoader } from "../vendor/examples/jsm/loaders/HDRLoader.js";
import { worldBoundingSphere, fitCameraToSphere } from "./framing.js";

/**
 * The extension injects an absolute glbview:// decoder root; the browser dev
 * server leaves it unset and relative paths resolve to http://localhost:PORT.
 */
const DECODER_ROOT = globalThis.__GLB_DECODER_ROOT ?? "./decoders/";

/**
 * The studio IBL, shipped beside the page. Relative so the same path works in
 * the appex (glbview://app/) and the dev server; scripts/build-viewer.mjs copies
 * it into dist.
 */
const ENVIRONMENT_URL = "./office.hdr";

/** Injected by the extension; the dev server passes it as ?model= instead. */
const MODEL_URL = globalThis.__GLB_MODEL_URL ?? new URLSearchParams(location.search).get("model");

/**
 * How many frames after load to keep looking for a bigger bounding sphere.
 * Animation can carry geometry outside its bind pose, so the sphere is allowed
 * to grow shortly after the first frame; once it settles we stop paying for it.
 */
const REFIT_FRAMES = 30;

const host = document.getElementById("viewer");
const status = document.getElementById("status");
const loading = document.getElementById("loading");
const loadingLabel = document.getElementById("loading-label");
const loadingTrack = document.getElementById("loading-track");
const loadingBar = document.getElementById("loading-bar");
const precompile = document.getElementById("precompile");
const precompileLabel = document.getElementById("precompile-label");
const precompileTrack = document.getElementById("precompile-track");
const precompileBar = document.getElementById("precompile-bar");

// ---------------------------------------------------------------- renderer

const renderer = new THREE.WebGLRenderer({
  antialias: true,
  alpha: true, // let the Quick Look panel's own background show through
  powerPreference: "high-performance",
});
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
host.appendChild(renderer.domElement);

const scene = new THREE.Scene();

const camera = new THREE.PerspectiveCamera(45, 1, 0.01, 100);
camera.position.set(2, 2, 2);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.1;
controls.enablePan = false;

// Metallic/PBR glTF materials render black without an environment. The bundled
// office HDR is the studio IBL; RoomEnvironment is the fallback if the file
// cannot be read, so a missing asset dims the lighting rather than the preview.
const pmrem = new THREE.PMREMGenerator(renderer);
let environmentTarget = null;

function setEnvironment(hdr) {
  const previous = environmentTarget;
  environmentTarget = hdr
    ? pmrem.fromEquirectangular(hdr)
    : pmrem.fromScene(new RoomEnvironment(), 0.04);
  scene.environment = environmentTarget.texture;
  previous?.dispose();
}

/**
 * Started alongside the model download and awaited before the first frame, so
 * the model never flashes under one lighting and settles under another. The
 * programs compiled below also depend on whether an environment map is present.
 */
async function loadEnvironment() {
  try {
    const hdr = await new HDRLoader().loadAsync(ENVIRONMENT_URL);
    hdr.mapping = THREE.EquirectangularReflectionMapping;
    setEnvironment(hdr);
    hdr.dispose();
    report("environment", "Environment: office.hdr");
  } catch (error) {
    console.warn("viewer: office.hdr unavailable; using RoomEnvironment", error);
    setEnvironment(null);
    report("environment", "Environment: RoomEnvironment fallback");
  }
}

// Fallback contribution for flat/unlit-ish materials that ignore the environment.
const keyLight = new THREE.DirectionalLight(0xffffff, 2.0);
keyLight.position.set(3, 6, 4);
scene.add(keyLight, new THREE.HemisphereLight(0xffffff, 0x555566, 1.2));

// ------------------------------------------------------------------- state

let modelRoot = null;
let mixer = null;
let frame = { center: new THREE.Vector3(), radius: 1, distance: 1 };
let userInteracted = false;
let needsRender = true;
let framesSinceLoad = 0;
let pendingFit = false;
let reportedFirstFrame = false;
/** True while shaders are being precompiled; suppresses the first draw. */
let precompiling = false;
/** True once the loading screen has been taken down; see report(). */
let loadingDone = false;

controls.addEventListener("change", () => {
  needsRender = true;
});
controls.addEventListener("start", () => {
  // Once the viewer takes control, stop re-framing underneath them.
  userInteracted = true;
});

// ---------------------------------------------------------------- viewport

/** @returns {boolean} false while the container has no size (Quick Look starts at 0x0). */
function resize() {
  const width = host.clientWidth;
  const height = host.clientHeight;
  if (width === 0 || height === 0) return false;

  camera.aspect = width / height;
  camera.updateProjectionMatrix();
  renderer.setSize(width, height);
  return true;
}

function fit() {
  if (!modelRoot) return;
  frame = fitCameraToSphere(camera, controls, worldBoundingSphere(modelRoot));
  needsRender = true;
  // Exposed so framing can be asserted numerically instead of by eye.
  window.__glbFrame = {
    radius: frame.radius,
    distance: frame.distance,
    center: frame.center.toArray(),
    fov: camera.fov,
    aspect: camera.aspect,
  };
}

// -------------------------------------------------------------- model load

const draco = new DRACOLoader().setDecoderPath(`${DECODER_ROOT}draco/`);
const ktx2 = new KTX2Loader().setTranscoderPath(`${DECODER_ROOT}basis/`).detectSupport(renderer);
const loader = new GLTFLoader()
  .setDRACOLoader(draco)
  .setKTX2Loader(ktx2)
  .setMeshoptDecoder(MeshoptDecoder);

function report(type, message) {
  // boot.js installs this before the bundle is evaluated; fall back to posting
  // directly in case the bundle is ever loaded on its own.
  window.__glbReport?.(type, message);

  if (type !== "error") return;
  // While the loading screen is up it owns the message; the status line is only
  // for failures that arrive afterwards, when there is nowhere else to put them.
  if (loadingDone) status.textContent = message;
  else failLoading(message);
}

function formatBytes(bytes) {
  if (!(bytes > 0)) return "";
  const mb = bytes / (1024 * 1024);
  return mb >= 1 ? `${mb.toFixed(1)} MB` : `${Math.round(bytes / 1024)} KB`;
}

/**
 * GLTFLoader reports bytes as the GLB streams in. The scheme handler sets
 * Content-Length, so `total` is normally there and this is a real percentage;
 * if it is ever absent the label falls back to a byte count rather than
 * pretending to know how far along it is.
 */
function setProgress(loaded, total) {
  if (loadingDone) return;
  if (total > 0) {
    loadingTrack.classList.add("is-active");
    const percent = Math.min(100, (loaded / total) * 100);
    loadingBar.style.width = `${percent.toFixed(1)}%`;
    loadingLabel.textContent = `Loading… ${Math.round(percent)}%`;
  } else {
    const size = formatBytes(loaded);
    loadingLabel.textContent = size ? `Loading… ${size}` : "Loading…";
  }
}

function failLoading(message) {
  loadingDone = true;
  loading.classList.add("is-error");
  loadingLabel.textContent = message;
}

// -------------------------------------------------------- shader precompile

/**
 * The second loading phase. Bytes can arrive in a blink and the first frame can
 * still stall while the GPU driver builds every program the model needs, so it
 * gets its own row beneath the download progress rather than leaving the load
 * bar sitting at 100%.
 */
function setPrecompileProgress(done, total) {
  if (loadingDone) return;
  const percent = total > 0 ? Math.min(100, (done / total) * 100) : 100;
  precompileBar.style.width = `${percent.toFixed(1)}%`;
  precompileLabel.textContent = `Precompiling shaders… ${Math.round(percent)}%`;
}

/**
 * Compile every material the model needs before it is first drawn. `compile()`
 * returns the set of materials it prepared; their programs build in parallel
 * (KHR_parallel_shader_compile), so poll `isReady()` to count real completions
 * instead of animating a bar that knows nothing. This mirrors what three's own
 * compileAsync does, with a count exposed for the UI.
 */
async function precompileModel(root) {
  if (!root || loadingDone) return;

  // Hold the render loop: drawing now would compile lazily and hide the loading
  // screen before the second progress row had been seen. The frame it is
  // released for is the one that removes the loading screen.
  precompiling = true;
  precompile.classList.add("is-active");
  precompileTrack.classList.add("is-active");
  setPrecompileProgress(0, 1);
  report("precompiling", "Precompiling shaders");

  try {
    let materials;
    try {
      // World matrices affect the program variants (skinning, morph targets), so
      // settle them before asking the renderer what it needs.
      root.updateWorldMatrix(true, true);
      materials = renderer.compile(root, camera, scene);
    } catch (error) {
      // Not fatal: the first render compiles lazily and surfaces any real error.
      console.warn("viewer: shader precompile failed", error);
      setPrecompileProgress(1, 1);
      return;
    }

    const total = materials.size;
    if (total === 0) {
      setPrecompileProgress(1, 1);
      return;
    }

    // compileAsync-equivalent polling. The deadline keeps a driver that never
    // reports readiness from holding the loading screen up forever.
    const deadline = performance.now() + 10000;
    let done = 0;
    do {
      done = 0;
      for (const material of materials) {
        const program = renderer.properties.get(material)?.currentProgram;
        if (program === undefined || program.isReady()) done++;
      }
      setPrecompileProgress(done, total);
      if (done === total) break;
      if (performance.now() > deadline) {
        console.warn(`viewer: precompile timed out with ${total - done} material(s) pending`);
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    } while (!loadingDone);

    report("precompiled", JSON.stringify({ materials: total, pending: total - done }));
  } finally {
    precompiling = false;
    // The model is ready to be drawn now; this is the frame that takes the
    // loading screen down (see renderFrame/hideLoading).
    needsRender = true;
  }
}

/**
 * Called once a frame containing the model has actually been drawn. Hiding on
 * load rather than on first paint would flash an empty canvas for a frame, and
 * in Quick Look the two are not adjacent — the panel may not even be on screen.
 */
function hideLoading() {
  if (loadingDone) return;
  loadingDone = true;
  loading.classList.add("is-done");
}

async function loadModel(url, environmentReady) {
  if (!url) {
    report("error", "No model URL was supplied by the host");
    return;
  }
  try {
    report("loading", "Loading…");
    const gltf = await loader.loadAsync(url, (event) => setProgress(event.loaded, event.total));

    modelRoot = gltf.scene;
    scene.add(modelRoot);

    if (gltf.animations.length > 0) {
      mixer = new THREE.AnimationMixer(modelRoot);
      mixer.clipAction(gltf.animations[0]).play();
      // Pose it now, synchronously. An earlier version waited a frame via
      // requestAnimationFrame here, which never resolves when the host is not
      // compositing the page — the load then hung with no error reported.
      mixer.update(0);
    }

    if (resize()) fit();
    else pendingFit = true;

    scene.updateMatrixWorld(true);

    // The environment is one of the program's defines, so it has to be in place
    // before anything is compiled. Awaiting it here also starts it as early as
    // the model download, not after it.
    await environmentReady;

    // Build every shader the model needs before the first frame is drawn.
    await precompileModel(modelRoot);

    let triangles = 0;
    modelRoot.traverse((object) => {
      if (object.isMesh && object.geometry?.index) triangles += object.geometry.index.count / 3;
      else if (object.isMesh && object.geometry?.attributes.position) {
        triangles += object.geometry.attributes.position.count / 3;
      }
    });

    report(
      "loaded",
      JSON.stringify({
        animations: gltf.animations.length,
        triangles: Math.round(triangles),
        radius: Number(frame.radius.toFixed(4)),
        distance: Number(frame.distance.toFixed(4)),
      }),
    );
  } catch (error) {
    report("error", String(error?.message ?? error));
  }
}

/**
 * While the model animates, its real extent can grow past the bind-pose sphere.
 * The sphere only ever grows, so re-measure a few times and stop once it settles.
 */
function refitIfGrown() {
  if (!modelRoot || userInteracted) return;
  const sphere = worldBoundingSphere(modelRoot);
  if (sphere.radius > frame.radius * 1.001) {
    frame = fitCameraToSphere(camera, controls, sphere);
    needsRender = true;
  }
}

// --------------------------------------------------------------- main loop

let lastFrameTime = performance.now();

function renderFrame() {
  const now = performance.now();
  const delta = (now - lastFrameTime) / 1000;
  lastFrameTime = now;

  controls.update(); // damping needs a per-frame update, but only paints on change

  if (mixer) {
    mixer.update(delta);
    needsRender = true;
  }

  if (modelRoot && framesSinceLoad <= REFIT_FRAMES) {
    if (framesSinceLoad % 5 === 0) refitIfGrown();
    framesSinceLoad++;
  }

  // While precompiling, the loading screen is still up and the first draw is
  // deliberately deferred — see precompileModel.
  if (needsRender && !precompiling) {
    needsRender = false;
    renderer.render(scene, camera);
    if (!reportedFirstFrame && modelRoot) {
      reportedFirstFrame = true;
      hideLoading();
      // Confirms a frame was actually drawn, not merely that the model parsed —
      // the two can differ when a host never composites the page.
      report("rendered", JSON.stringify({ via: rafAlive ? "requestAnimationFrame" : "timer" }));
    }
  }
}

// requestAnimationFrame is suspended whenever the host is not compositing the
// page — Quick Look does exactly that when the panel is off-screen, and it never
// recovers on its own. So drive the loop on a timer if rAF has not fired.
let rafAlive = false;

function rafLoop() {
  rafAlive = true;
  renderFrame();
  requestAnimationFrame(rafLoop);
}

requestAnimationFrame(rafLoop);

setTimeout(() => {
  if (rafAlive) return;
  console.warn("viewer: requestAnimationFrame is suspended — falling back to a timer loop");
  setInterval(renderFrame, 66);
}, 1000);

// --------------------------------------------------------------- bootstrap

new ResizeObserver(() => {
  if (!resize()) return;
  needsRender = true;
  if (pendingFit || (modelRoot && !userInteracted)) fit();
}).observe(host);

resize();
report("ready", "Viewer initialised");
// Environment and model download in parallel; the model waits for the
// environment only at the point where it would start compiling shaders.
loadModel(MODEL_URL, loadEnvironment());

// Handle for inspecting framing from the dev-server console (see
// viewer/scripts/serve-viewer.mjs). Costs nothing: these are live references.
window.__glbDebug = { THREE, scene, camera, controls, get modelRoot() { return modelRoot; } };
