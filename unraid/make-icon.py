#!/usr/bin/env python3
"""Generates unraid/icon.png - the container icon shown in Unraid's Docker tab.

Drawn at 4x and downsampled, because PIL has no antialiasing of its own. Run it
from anywhere: python3 unraid/make-icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 256
SCALE = 4
S = SIZE * SCALE

TOP = (0x14, 0x2A, 0x4C)  # deep navy
BOTTOM = (0x0E, 0x7C, 0x86)  # teal


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius, fill=255)
    return mask


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        draw.line(
            [(0, y), (size, y)],
            fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)),
        )
    return img


def glyph_mask(size):
    """The Cast symbol, with level meters inside so it reads as audio, not video.

    A screen outline with signal arcs in its lower-left corner.
    """
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    stroke = round(size * 0.052)

    # Screen
    draw.rounded_rectangle(
        [size * 0.20, size * 0.22, size * 0.82, size * 0.66],
        radius=size * 0.05,
        outline=255,
        width=stroke,
    )

    # Level meters, in the right half where the arcs will not reach
    bar_w = size * 0.045
    baseline = size * 0.575
    for i, height in enumerate((0.10, 0.19, 0.13, 0.23)):
        x = size * 0.46 + i * size * 0.085
        draw.rounded_rectangle(
            [x, baseline - size * height, x + bar_w, baseline],
            radius=bar_w / 2,
            fill=255,
        )

    # Clear the lower-left corner of the screen so the arcs sit in a gap
    draw.rectangle([size * 0.14, size * 0.52, size * 0.44, size * 0.72], fill=0)

    # Arcs radiate from the corner point, quarter circles opening up and right
    cx, cy = size * 0.22, size * 0.74
    for r in (size * 0.10, size * 0.19, size * 0.28):
        draw.arc([cx - r, cy - r, cx + r, cy + r], 270, 360, fill=255, width=stroke)

    dot = size * 0.035
    draw.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=255)
    return mask


img = gradient(S, TOP, BOTTOM).convert("RGBA")
img.paste(Image.new("RGB", (S, S), (255, 255, 255)), mask=glyph_mask(S))
img.putalpha(rounded_mask(S, round(S * 0.22)))

out = Path(__file__).resolve().parent / "icon.png"
img.resize((SIZE, SIZE), Image.LANCZOS).save(out)
print(f"wrote {out}")
