#!/usr/bin/env python3
"""Build the macOS app icon set from one square source image.

    scripts/make-icon.py <source.png> [Assets.xcassets/AppIcon.appiconset]
    scripts/make-icon.py --masked <source.png>            # for old macOS

The source should be a square illustration. What comes out is full bleed:
square, opaque, edge to edge, with no margin and no rounded corners, because
that is what the modern icon system asks for. It draws the plate and applies
the corner mask itself, so anything baked into the artwork here gets applied
on top of that — and a transparent margin in particular is visible, as the
system's plate showing through around a picture that has been inset inside it.

`--masked` bakes in the old treatment instead (824 of 1024, squircle corners,
transparent margin), which is what an app needs on a macOS old enough not to
mask icons for you. Nothing in this project ships to such a system; the flag is
here so the decision is reversible rather than lost.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

CANVAS = 1024                 # the icon the largest slot asks for
BODY = 824                    # Apple's icon body: 824/1024 of the canvas
CORNER_EXPONENT = 5.0         # superellipse exponent ~ a continuous corner
SUPERSAMPLE = 4
STEPS = 1024                  # polygon resolution per quarter of the shape

# size, scale -> pixel dimension. The 1x/2x pairs are what Xcode's asset
# catalogue expects; 32 and 256 are deliberately listed twice, as different
# slots that happen to resolve to the same pixels.
SLOTS = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]


def squircle_mask(pixels: int) -> Image.Image:
    """An antialiased superellipse, full bleed, in an `L` image of `pixels`."""
    big = pixels * SUPERSAMPLE
    half = big / 2.0

    # |x/a|^n + |y/b|^n = 1, parametrised from the top of the shape round to the
    # side. Solving it as an outline keeps this to a few thousand evaluations
    # rather than the few million a per-pixel test would need.
    quarter = []
    for i in range(STEPS + 1):
        t = i / STEPS                       # 0 at top-centre, 1 at right-middle
        quarter.append((
            half * t,
            -half * (1.0 - t ** CORNER_EXPONENT) ** (1.0 / CORNER_EXPONENT),
        ))

    # Offsets from the centre, reflected into a closed clockwise loop: down the
    # right side, back along the bottom, up the left. Four arcs in, and the point
    # where each meets the next is shared, so the fill has no seam.
    outline = (
        [(half + x, half + y) for x, y in quarter]              # top-centre -> right-middle
        + [(half + x, half - y) for x, y in reversed(quarter)]  # right-middle -> bottom-centre
        + [(half - x, half - y) for x, y in quarter]            # bottom-centre -> left-middle
        + [(half - x, half + y) for x, y in reversed(quarter)]  # left-middle -> top-centre
    )

    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(outline, fill=255)
    return mask.resize((pixels, pixels), Image.LANCZOS)


def build_master(source: Image.Image, masked: bool = False) -> Image.Image:
    if not masked:
        # Full bleed, square, opaque, edge to edge. This is what the modern icon
        # system wants: it applies the plate and the corner mask itself, so
        # anything baked in here gets applied twice — a margin written into the
        # artwork shows up as an inset picture sitting on the system's plate.
        return source.convert("RGBA").resize((CANVAS, CANVAS), Image.LANCZOS)

    body = source.convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
    body.putalpha(squircle_mask(BODY))

    master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    master.paste(body, (offset, offset))
    return master


def write_set(master: Image.Image, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)

    images = []
    for size, scale in SLOTS:
        pixels = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        # Downsampled from the master rather than resampled from the source per
        # size, so every slot is filtered from the same pixels.
        master.resize((pixels, pixels), Image.LANCZOS).save(out / name)
        images.append({
            "filename": name,
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{size}x{size}",
        })

    (out / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                   indent=2) + "\n"
    )


def main(argv: list[str]) -> int:
    """`--masked` bakes Apple's squircle in; see build_master for why that
    is not the default."""
    argv = [a for a in argv if a != "--masked"]
    masked = "--masked" in sys.argv
    if not 2 <= len(argv) <= 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print(f"usage: {argv[0]} <source.png> [output.appiconset]", file=sys.stderr)
        return 2

    source_path = Path(argv[1])
    out = Path(argv[2]) if len(argv) == 3 else (
        Path(__file__).resolve().parent.parent
        / "glb-viewer-quicklook/Assets.xcassets/AppIcon.appiconset"
    )

    source = Image.open(source_path)
    if source.width != source.height:
        print(f"error: {source_path} is {source.width}x{source.height}, need a square",
              file=sys.stderr)
        return 1

    master = build_master(source, masked=masked)
    write_set(master, out)
    print(f"{source.width}x{source.height} -> {len(SLOTS)} icons in {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
