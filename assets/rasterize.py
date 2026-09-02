"""Rasterise the mark with numpy (no SVG renderer needed).

Reuses the geometry from make_logo.py, paints it with anti-aliased signed
distance coverage into an RGBA array, and writes logo.png (512 px) plus a
multi-size icon.ico through Pillow.

Run:  python assets/rasterize.py
"""
import importlib.util
from pathlib import Path

import numpy as np
from PIL import Image

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("make_logo", here / "make_logo.py")
logo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logo)          # regenerates the SVGs as a side effect

S = 512
yy, xx = np.mgrid[0:S, 0:S].astype(float) + 0.5
img = np.zeros((S, S, 4), float)


def hex_rgb(h):
    return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], float)


def blend(cov, rgb):
    a = cov[..., None]
    img[..., :3] = img[..., :3] * (1 - a) + rgb * a
    img[..., 3:] = img[..., 3:] * (1 - a) + a


def stroke_cov(dist, width):
    """coverage of a stroke of the given width from a signed distance field"""
    return np.clip(width / 2 + 0.5 - dist, 0.0, 1.0)


def seg_dist(P, Q):
    px, py = Q[0] - P[0], Q[1] - P[1]
    L2 = px * px + py * py
    t = np.clip(((xx - P[0]) * px + (yy - P[1]) * py) / L2, 0.0, 1.0)
    return np.hypot(xx - (P[0] + t * px), yy - (P[1] + t * py))


def polyline_dist(pts):
    d = np.full((S, S), np.inf)
    for a, b in zip(pts[:-1], pts[1:]):
        d = np.minimum(d, seg_dist(a, b))
    return d


# rounded card
r = 112.0
inner_x = (xx >= r) & (xx <= S - r)
inner_y = (yy >= r) & (yy <= S - r)
card = (inner_x | inner_y).astype(float)
for cx_, cy_ in ((r, r), (S - r, r), (r, S - r), (S - r, S - r)):
    card = np.maximum(card, np.clip(r + 0.5 - np.hypot(xx - cx_, yy - cy_), 0, 1))
blend(card, hex_rgb(logo.DARK))

# ring as an arc: distance to the circle, masked to the open angular range
ang = np.arctan2(yy - logo.cy, xx - logo.cx)
ring_d = np.abs(np.hypot(xx - logo.cx, yy - logo.cy) - logo.R)
in_arc = ((ang - logo.start) % (2 * np.pi)) <= (logo.end - logo.start)
arc_d = np.where(in_arc, ring_d, np.inf)
# round caps at both ends
for a in (logo.start, logo.end):
    cap = np.hypot(xx - (logo.cx + logo.R * np.cos(a)), yy - (logo.cy + logo.R * np.sin(a)))
    arc_d = np.minimum(arc_d, cap)
blend(stroke_cov(arc_d, logo.W), hex_rgb(logo.ACCENT))

# chevron and stem
ink = hex_rgb(logo.INK_ON_DARK)
blend(stroke_cov(polyline_dist(logo.chevron), logo.W), ink)
blend(stroke_cov(polyline_dist(logo.stem), logo.W), ink)

out = np.zeros((S, S, 4), np.uint8)
out[..., :3] = np.clip(img[..., :3], 0, 255).astype(np.uint8)
out[..., 3] = (np.clip(img[..., 3], 0, 1) * 255).astype(np.uint8)
im = Image.fromarray(out, "RGBA")
im.save(here / "logo.png")
im.resize((256, 256), Image.LANCZOS).save(here / "icon.ico", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
print("wrote logo.png and icon.ico")
