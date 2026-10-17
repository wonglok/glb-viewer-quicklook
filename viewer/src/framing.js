import * as THREE from "../vendor/build/three.module.js";

/** Extra breathing room on top of an exact sphere fit. */
export const FIT_MARGIN = 1.15;

/** Anything at or below this is treated as "no geometry" rather than a real size. */
const MIN_RADIUS = 1e-4;

/**
 * World-space bounding sphere of a loaded model: the union of every mesh's own
 * bounding sphere, pushed through its world matrix.
 *
 * Deliberately not `Box3.setFromObject`: a box's half-diagonal massively
 * over-estimates for anything long and thin (a sword, a chair), which would make
 * "fit to bounding box" zoom far further out than the model needs.
 *
 * @param {THREE.Object3D} root
 * @returns {THREE.Sphere}
 */
export function worldBoundingSphere(root) {
  // Required, and easy to miss: GLTFLoader does not promise current world
  // matrices when loadAsync resolves, and reading a stale matrixWorld collapses
  // deep nodes back to local coordinates — framing the model far too close.
  root.updateMatrixWorld(true);

  const bounds = new THREE.Sphere().makeEmpty();
  const position = new THREE.Vector3();
  const quaternion = new THREE.Quaternion();
  const scale = new THREE.Vector3();

  root.traverse((object) => {
    let local = null;

    if (object.isSkinnedMesh) {
      // The mesh-level method is pose-aware: it pushes each vertex through the
      // bone transforms, unlike geometry.boundingSphere which stays in bind
      // pose and so misses limbs that an animation swings out wide.
      object.computeBoundingSphere();
      local = object.boundingSphere;
    } else if (object.isMesh && object.geometry) {
      if (!object.geometry.boundingSphere) object.geometry.computeBoundingSphere();
      local = object.geometry.boundingSphere;
    }

    if (!local || !Number.isFinite(local.radius) || local.radius <= 0) return;
    bounds.union(toWorld(local, object.matrixWorld, position, quaternion, scale));
  });

  if (bounds.isEmpty() || !Number.isFinite(bounds.radius) || bounds.radius <= 0) {
    // Nothing measurable — an empty or unusual scene. A Box3 is corner-based and
    // therefore shear-safe, so it makes a decent last resort.
    const box = new THREE.Box3().setFromObject(root);
    if (!box.isEmpty()) box.getBoundingSphere(bounds);
  }

  if (!Number.isFinite(bounds.radius) || bounds.radius <= MIN_RADIUS) {
    // Give the camera a sane stage rather than letting it collapse onto a point.
    bounds.set(new THREE.Vector3(), 1);
  }
  return bounds;
}

/**
 * Moves a local-space sphere into world space.
 *
 * A radius is a scalar, so it cannot be pushed through the matrix directly — it
 * has to be scaled by the largest singular value of the 3x3 linear part. For the
 * usual rotation-times-scale node that is exactly max(|sx|, |sy|, |sz|). But a
 * *parent's* non-uniform scale composed with a *child's* rotation produces shear,
 * where that value under-estimates the real stretch and the model gets clipped.
 * Shear is cheap to detect (the matrix columns stop being orthogonal); when it
 * is present, fall back to the Frobenius norm, which is a guaranteed upper bound
 * (over-estimating by at most sqrt(3)).
 */
function toWorld(local, matrix, position, quaternion, scale) {
  matrix.decompose(position, quaternion, scale);
  const maxScale = Math.max(Math.abs(scale.x), Math.abs(scale.y), Math.abs(scale.z));

  const elements = new THREE.Matrix3().setFromMatrix4(matrix).elements;
  const [c0, c1, c2] = [
    new THREE.Vector3(elements[0], elements[1], elements[2]),
    new THREE.Vector3(elements[3], elements[4], elements[5]),
    new THREE.Vector3(elements[6], elements[7], elements[8]),
  ];
  const perpendicular = (a, b) => Math.abs(a.dot(b)) <= 1e-6 * a.length() * b.length();
  const sheared =
    !perpendicular(c0, c1) || !perpendicular(c0, c2) || !perpendicular(c1, c2);

  const radiusScale = sheared ? Math.hypot(...elements) : maxScale;
  return new THREE.Sphere(local.center.clone().applyMatrix4(matrix), local.radius * radiusScale);
}

/**
 * Centres the view on `sphere` and pulls the camera back until the sphere just
 * fits the tighter of the two field-of-view axes.
 *
 * The distance form is `radius / sin(theta/2)`, not the more familiar
 * `radius / tan(theta/2)`. A sphere of radius R seen from distance d subtends a
 * half-angle of asin(R/d), so filling a half-angle of theta/2 needs exactly
 * d = R/sin(theta/2). The tan form answers a different question — how far away to
 * put a flat quad — and because tan > sin it always lands too close, clipping the
 * silhouette.
 *
 * @returns {{center: THREE.Vector3, radius: number, distance: number}}
 */
export function fitCameraToSphere(camera, controls, sphere, margin = FIT_MARGIN) {
  const { center, radius } = sphere;

  const verticalFov = THREE.MathUtils.degToRad(camera.fov);
  const horizontalFov = 2 * Math.atan(Math.tan(verticalFov / 2) * camera.aspect);
  const theta = Math.min(verticalFov, horizontalFov);

  const distance = (radius / Math.sin(theta / 2)) * margin;
  const direction = new THREE.Vector3(1, 0.6, 1).normalize();

  camera.position.copy(center).addScaledVector(direction, distance);
  // Kept independent of `distance` on purpose: tying the near plane to the
  // initial fit clips the model as soon as the viewer orbits in close.
  camera.near = Math.max(radius * 0.01, 1e-5);
  camera.far = (distance + radius * 2) * 10;
  camera.updateProjectionMatrix();

  controls.target.copy(center);
  controls.minDistance = radius * 0.1;
  controls.maxDistance = (distance + radius) * 5;
  controls.update();

  return { center, radius, distance };
}
