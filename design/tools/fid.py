"""Shared pixel helpers for render.py and check.py. All coordinates are device pixels at 2x."""
import io
from functools import lru_cache
from collections import Counter
from pathlib import Path

from PIL import Image, ImageCms

DESIGN = Path(__file__).resolve().parent.parent
SCALE = 2
EDGE_DE = 3.0


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rgb_hex(c):
    return "#%02x%02x%02x" % tuple(c[:3])


@lru_cache(maxsize=None)
def lab(c):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in c[:3])
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def delta_e(a, b):
    """CIE76 ΔE: stricter than ΔE2000 on the near-black greys these screens are made of."""
    la, lb = lab(tuple(a[:3])), lab(tuple(b[:3]))
    return sum((p - q) ** 2 for p, q in zip(la, lb)) ** 0.5


def load_srgb(path):
    """Load a capture as sRGB RGB; returns (image, source profile name or None)."""
    im = Image.open(path)
    icc = im.info.get("icc_profile")
    name = None
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
        im = Image.alpha_composite(bg, im)
    im = im.convert("RGB")
    if icc:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        name = ImageCms.getProfileDescription(src).strip()
        im = ImageCms.profileToProfile(im, src, ImageCms.createProfile("sRGB"), outputMode="RGB")
    return im, name


def in_bounds(im, x, y):
    return 0 <= x < im.width and 0 <= y < im.height


def sample(im, x, y):
    return im.getpixel((x, y)) if in_bounds(im, x, y) else None


def ink(im, rect):
    """Text colour: the pixel in the box furthest from the box's most common (background) colour."""
    x0, y0, x1, y1 = rect
    px = [im.getpixel((x, y)) for y in range(max(y0, 0), min(y1, im.height)) for x in range(max(x0, 0), min(x1, im.width))]
    if not px:
        return None, None
    bg = Counter(px).most_common(1)[0][0]
    return max(px, key=lambda c: delta_e(c, bg)), bg


STEP = {"down": (0, 1), "up": (0, -1), "right": (1, 0), "left": (-1, 0)}


def scan(im, x, y, direction, limit=4000):
    """First coordinate along the scan whose colour differs from the start by more than EDGE_DE."""
    c0 = sample(im, x, y)
    if c0 is None:
        return None
    dx, dy = STEP[direction]
    for _ in range(limit):
        x, y = x + dx, y + dy
        c = sample(im, x, y)
        if c is None:
            return None
        if delta_e(c, c0) > EDGE_DE:
            return y if dy else x
    return None
