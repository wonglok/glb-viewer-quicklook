# GLB 3D model viewer

Press **Space** on a `.glb` in Finder to preview it in 3D, or open one in the
**GLB 3D model viewer** app. Either way the camera centres on the model and pulls back
to fit its **bounding sphere**.

Rendering is three.js inside a `WKWebView`, so PBR materials, textures and
animations look exactly as they do on the web. Draco, Meshopt and KTX2 compressed
models all work: the decoders are vendored into the bundle and the viewer never
touches the network.

The app and the extension compile the *same* `ViewerWebView` / `GLBSchemeHandler`
sources against the *same* `viewer/dist`, so the two render identically by
construction rather than by being kept in sync.

## Layout

```
glb-viewer-quicklook/     the app
  MyApp / AppDelegate      SwiftUI scene; Finder opens arrive at the delegate
  ViewerModel              what is on screen (a singleton: a double-click can
                           arrive before any window exists)
  ContentView              viewer + empty state, Open / Reveal / Use for .glb
  GLBViewerView            wraps ViewerWebView for SwiftUI
  Assets.xcassets          the app icon — generated, see scripts/make-icon.py
AppSupport/Info.plist     the app's plist — CFBundleDocumentTypes is what makes
                          Finder able to hand us a file (kept outside the
                          synchronized group, which would copy it as a resource)
GLBQuickLook/             the Quick Look preview extension
  PreviewViewController   QLPreviewingController entry point
  ViewerWebView           hosts the web view, injects the model/decoder URLs
  GLBSchemeHandler        serves the page, scripts, decoders and model bytes
  GLBPreviewLog           the os_log subsystem, shared with the app
viewer/                   the web viewer
  src/framing.js            bounding-sphere fit  ← the camera behaviour lives here
  src/main.js               scene, lighting, load, render loop
  src/boot.js               error reporting (installed before the bundle)
  vendor/                   three.js 0.186.1, vendored — see scripts/vendor-three.mjs
  dist/                     build output; ships inside *both* bundles
  scripts/                  vendor-three.mjs, build-viewer.mjs, serve-viewer.mjs
```

## Opening a model

| Route | What to do |
| --- | --- |
| Quick Look | Space on a `.glb` in Finder |
| This app | drag the file onto the Dock icon, or onto the app window, or ⌘O |
| Double-click | click **Use for .glb** in the app's toolbar first — see below |

**The app does not seize the default handler on its own.** `org.khronos.glb` is a
real system UTI and this machine already had a handler for it, so becoming the
default is a one-click, reversible decision rather than something that happens
on first launch. Until you click it, the app is registered as an *Alternate*
handler, which is enough for drag-to-Dock, "Open With", the app window's own
drop target, and ⌘O. The button disappears once the app is the default.

## Building

```bash
cd viewer && npm install          # once; only esbuild
npm run build                     # viewer/src → viewer/dist
cd ..
xcodebuild -project glb-viewer-quicklook.xcodeproj \
           -target glb-viewer-quicklook -configuration Debug build

osascript -e 'quit app "GLB 3D model viewer"'          # a running copy keeps the old binary
rm -rf "/Applications/GLB 3D model viewer.app"         # ditto alone leaves removed files behind
ditto build/Debug/glb-viewer-quicklook.app "/Applications/GLB 3D model viewer.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "/Applications/GLB 3D model viewer.app"
qlmanage -r && qlmanage -r cache
```

`viewer/dist` is committed so the Xcode build needs neither Node nor a network
connection. Re-run `npm run build` after touching anything in `viewer/src`.

### Regenerating the app icon

```bash
scripts/make-icon.py path/to/square-artwork.png
```

It writes all ten slots of `Assets.xcassets/AppIcon.appiconset` from one square
source. The output is **full bleed** — square, opaque, edge to edge, no margin —
because that is what the modern icon system wants: it lays down the plate and
applies the corner mask itself. A margin or rounded corners baked into the
artwork therefore get applied *twice*, and the symptom is distinctive rather
than subtle: the system's plate shows through around a picture sitting inset
inside it, like a photo in a frame.

The source can have anything painted on its edges; it is scaled to fill the
square and nothing about its own corners survives. `--masked` produces the old
treatment instead (824 of 1024, squircle corners, transparent margin) for a
macOS that does not mask icons itself. Nothing here ships to such a system; the
flag exists so the choice is reversible rather than lost.

`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is what pulls the set into the
build. Note the icon has to be *checked* through the system rather than by
opening the PNGs — the artwork looking right says nothing about how it will be
plated:

```bash
# what Finder will actually draw, at 1024
swift - <<'EOF'
import AppKit
let i = NSWorkspace.shared.icon(forFile: "/Applications/GLB 3D model viewer.app")
i.size = NSSize(width: 512, height: 512)
try! NSBitmapImageRep(data: i.tiffRepresentation!)!
    .representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "/tmp/icon.png"))
EOF
```

### Iterating on the viewer

The same bundle runs in a normal browser, which is far faster than a Finder
round-trip and lets you inspect `window.__glbFrame` / `window.__glbDebug`:

```bash
cd viewer && npm run dev /path/to/model.glb    # then open the printed URL
```

### Testing the actual preview

```bash
qlmanage -p /path/to/model.glb                            # the extension
open -a "/Applications/GLB 3D model viewer.app" /path/to/model.glb   # the app

log show --last 30s --info --predicate 'subsystem BEGINSWITH "com.loklok"'
```

The extension is out of process with no console, so it logs everything through
`os_log`; that subsystem is the only way to see what it is doing. It reports the
page handshake, every asset it serves, the loaded model's triangle count and
computed framing, and any page-side error. If a preview is blank, read that log
first. The subsystem is `Bundle.main.bundleIdentifier` — the app and the
extension therefore share one prefix but have separate subsystems, and the
category (`App`, `Viewer`, `SchemeHandler`) says which part is talking.

The framing line is worth reading on a model that sits wrong:

```
Model loaded — message={"triangles":98336,"radius":1.3939,"distance":4.1889}
```

`distance` is `radius / sin(θ/2) × 1.15` with `θ` the smaller field of view, so
on a 45° vertical fov in a window wider than it is tall the ratio is always
`1.15 / sin(22.5°) = 3.005`. A ratio that does not match means the aspect ratio
at fit time was not what you think it was.

### Signing and notarizing for distribution

```bash
NOTARY_PROFILE=AC_PASSWORD scripts/package.sh   # build → sign → notarize → staple → zip
scripts/package.sh --skip-notarize              # stop after the zip

scripts/make-dmg.sh                             # signed timestamped DMG
NOTARY_PROFILE=AC_PASSWORD scripts/make-dmg.sh --notarize   # + notarize/staple the DMG
```

`make-dmg.sh` takes the app `package.sh` left in `build/dist`, adds the
Applications drop link, and writes `GLB-3D-Model-Viewer-<version>-<YYYYMMDD-HHMM>.dmg`.
It uses `hdiutil` rather than `create-dmg` because the latter drives Finder over
AppleScript, which fails opaquely without a GUI session. The image is signed with
the same Developer ID identity as the app; `--notarize` is a separate round-trip
that makes Gatekeeper recognize the image before it is opened.

The notary profile name comes from `$NOTARY_PROFILE` and has no default, so no
credential name is baked into the repo. `$SIGN_IDENTITY` and `$TEAM_ID` can be
overridden the same way, and `--skip-notarize` needs no profile at all.

The everyday `xcodebuild` above keeps automatic signing with an Apple Development
identity. `scripts/package.sh` is the only thing that signs for distribution, and
it leaves `build/dist/GLB-3D-Model-Viewer-<version>-<YYYYMMDD-HHMM>.zip` behind. The
version is read back out of the signed bundle rather than the project file, and
the stamp comes from the build, so neither can drift from what shipped. Earlier
archives are kept — only the `.app` is cleared between runs, and the timestamp
is what tells two builds apart.

Three things it has to get right, each of which produces a *signed-looking* app
that fails later:

- **`CODE_SIGN_IDENTITY="Developer ID Application"`** — the Developer ID
  certificate in the keychain. A Development identity signs just as cleanly and
  Gatekeeper rejects it on every other machine.
- **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`** — Xcode otherwise injects
  `com.apple.security.get-task-allow` into the entitlements. Nothing local
  complains; the *notary service* refuses the whole submission for it. Verify
  with `codesign -d --entitlements - "GLB 3D model viewer.app"`.
- **Hardened runtime**, from `ENABLE_HARDENED_RUNTIME = YES` in the project (both
  targets). Check for `flags=0x10000(runtime)` in `codesign -dvvv`; notarization
  requires it, and its absence is invisible until submission.

Renaming the `.app` to its display name before zipping is safe — the seal covers
the bundle's contents, not the bundle's name — but `package.sh` re-verifies the
signature after the rename rather than trusting that.

Notarization needs a `notarytool` keychain profile, created once:

```bash
xcrun notarytool store-credentials AC_PASSWORD \
      --apple-id you@example.com --team-id CY8MDF5N35
```

Until the team has an in-effect Apple Developer Program License Agreement the
service answers *every* submission with `403 ... A required agreement is missing
or has expired`; the credentials and the build are both fine in that case, and
only the Account Holder can clear it, under App Store Connect → Business. In the
meantime `spctl` reports the app as `source=Unnotarized Developer ID`: correctly
signed, not yet distributable.

Both zips are made with `ditto --noextattr --norsrc`. Plain `ditto` turns every
`com.apple.provenance` attribute into a visible `._Foo` entry — dozens per
archive — and `xattr -cr` cannot prevent it, because that attribute is not
removable by `xattr`. This is safe to do here: the notarization ticket is not an
extended attribute but a real file, `Contents/CodeResources`, which is why
`package.sh` asserts the ticket is present in the final zip.

## Three environment requirements that are easy to miss

Each of these fails *silently* — no error, no callback, just a blank panel — and
each was found only by bisecting the running extension against its log.

1. **Both targets need `com.apple.security.network.client`.** Without that
   entitlement WebKit cannot start its WebContent process from a sandboxed
   process, and *every* `WKWebView` load becomes a no-op: `webView.url` stays
   `nil`, `isLoading` stays `false`, and neither `didFinish` nor `didFail` ever
   fires. The viewer never uses the network; the entitlement is purely what
   WebKit requires — in the app it comes from
   `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`, in the appex from its
   entitlements file. Removing the sandbox instead is not an option — Quick Look
   declines to register an unsandboxed preview extension at all.

2. **The page must not be on a `file://` origin.** `DRACOLoader` and
   `KTX2Loader` both build their Web Workers from `blob:` URLs. From a `file://`
   origin WebKit constructs those workers but never runs them, so Draco decoding
   hangs forever with nothing reported. The page is therefore loaded with
   `loadHTMLString(_:baseURL:)` against a `glbview://` base URL, which gives it a
   real origin; WebKit will not navigate a main frame to a custom scheme, so the
   base URL is what provides it (see `ViewerWebView.load`).

3. **`requestAnimationFrame` can be suspended.** Quick Look does not always
   composite the preview, and a suspended rAF never resumes. Anything that
   *waits* on a frame — an earlier version awaited one before measuring the
   model — hangs the load. `main.js` poses the model synchronously instead, and
   drives the render loop from a timer if rAF has not fired within a second.

## Camera framing

`viewer/src/framing.js` is the whole of the requested behaviour:

- The bounding sphere is the union of every mesh's geometry bounding sphere
  pushed through its world matrix — not `Box3.setFromObject`, whose half-diagonal
  over-estimates badly for anything long and thin. `root.updateMatrixWorld(true)`
  first, because `GLTFLoader` does not promise current world matrices when
  `loadAsync` resolves.
- Radii are scaled by the largest singular value of the 3×3 linear part. For the
  usual rotation×scale node that is exactly `max(|sx|,|sy|,|sz|)`, but a parent's
  non-uniform scale around a child's rotation shears the matrix, where that
  under-estimates and clips the model — so shear is detected (columns no longer
  orthogonal) and the Frobenius norm used instead.
- `SkinnedMesh.computeBoundingSphere()` is pose-aware, so rigged models are
  measured posed rather than in bind pose.
- Distance is `radius / sin(θ/2) × 1.15`, with `θ` the **smaller** of the
  vertical and horizontal fields of view. `sin` is the correct form for a sphere
  (a sphere of radius R at distance d subtends `asin(R/d)`); the familiar `tan`
  form answers the flat-quad question and always lands too close.

`FIT_MARGIN` at the top of that file is the one knob for how much breathing room
the model gets.

## The loading screen

`#loading` in `viewer/src/index.html` covers the panel from the moment the page
loads; `main.js` drives it. Three decisions in there are not obvious:

- **It is transparent, not painted.** The Quick Look panel draws its own
  material underneath, and a page background would cover it up. Only the spinner
  and the label are drawn, so the same overlay looks native in the panel and in
  the app window.
- **The spinner is a CSS animation**, so it keeps turning while
  `requestAnimationFrame` is suspended — which Quick Look does — without
  depending on any of the viewer's own JavaScript.
- **It is dismissed on the first frame drawn, not on load.** Hiding it as soon
  as the model parses would flash an empty canvas; in Quick Look the two are not
  even adjacent, because the panel may not be composited yet.

Progress comes from `GLTFLoader`'s byte callback, and the percentage is only
shown when the response carried a `Content-Length` — `GLBSchemeHandler` always
sets one, so in both hosts it does. Without one the label falls back to a byte
count rather than showing a bar that cannot be trusted.

Beneath it is a second, quieter row for **shader precompilation**. After the
bytes are parsed, `precompileModel()` calls `renderer.compile()` and polls each
material's `currentProgram.isReady()` — the same approach as three's
`compileAsync` — until every program is built. The first draw is withheld for
the duration, so the frame that dismisses the loading screen is not the one that
stalls on a shader compile. A ten-second deadline keeps a driver that never
reports readiness from holding the screen up forever; on timeout the viewer
draws anyway and lets the renderer compile lazily.

## Environment lighting

Metallic and PBR glTF materials render black without an image-based environment.
The viewer uses the bundled `viewer/assets/office.hdr`, which
`scripts/build-viewer.mjs` copies to `viewer/dist/office.hdr` so both hosts
serve it from the same origin as the page. `loadEnvironment()` reads it with
three's `HDRLoader` and converts it to a PMREM.

The download starts alongside the model and is awaited before shader
compilation, because whether an environment map is present changes the compiled
program. If the HDR is missing or unreadable the viewer falls back to three's
`RoomEnvironment`: lighting gets flatter, but the preview still works.
