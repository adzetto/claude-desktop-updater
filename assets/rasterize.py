"""Rasterise the procedural logo with numpy (no SVG renderer needed).

Reuses the exact geometry from make_logo.py and paints it into an RGBA
array with anti-aliased circle coverage, then writes logo.png (512 px),
a README preview and icon.ico (256/128/64/48/32/16) via Pillow.

Run:  python assets/rasterize.py
"""
import numpy as np
from pathlib import Path
from PIL import Image
import importlib.util

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("make_logo", here / "make_logo.py")
logo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logo)          # regenerates the SVGs as a side effect

S = 512
yy, xx = np.mgrid[0:S, 0:S].astype(float) + 0.5
img = np.zeros((S, S, 4), float)


def blend(cov, rgb, a):
    """Alpha-composite a coverage mask with colour rgb (0..255) and alpha a."""
    a_src = (cov * a)[..., None]
    img[..., :3] = img[..., :3] * (1 - a_src) + np.asarray(rgb, float) * a_src
    img[..., 3:] = img[..., 3:] * (1 - a_src) + a_src


def disc(cx, cy, r):
    d = np.hypot(xx - cx, yy - cy)
    return np.clip(r + 0.5 - d, 0.0, 1.0)          # 1 px anti-aliased edge


def segment(x0, y0, x1, y1, w):
    px, py = x1 - x0, y1 - y0
    L2 = px * px + py * py
    t = np.clip(((xx - x0) * px + (yy - y0) * py) / L2, 0.0, 1.0)
    d = np.hypot(xx - (x0 + t * px), yy - (y0 + t * py))
    return np.clip(w / 2 + 0.5 - d, 0.0, 1.0)


def polygon(P):
    inside = np.zeros((S, S), bool)
    n = len(P)
    for i in range(n):
        (x0, y0), (x1, y1) = P[i], P[(i + 1) % n]
        cond = ((y0 > yy) != (y1 > yy)) & (xx < (x1 - x0) * (yy - y0) / (y1 - y0 + 1e-12) + x0)
        inside ^= cond
    return inside.astype(float)


# background: dark rounded card
rr = 96.0
corner = np.minimum.reduce([disc(rr, rr, rr), disc(S - rr, rr, rr), disc(rr, S - rr, rr), disc(S - rr, S - rr, rr)])
card = ((xx >= rr) & (xx <= S - rr)) | ((yy >= rr) & (yy <= S - rr))
card = np.maximum(card.astype(float), np.maximum.reduce([disc(rr, rr, rr), disc(S - rr, rr, rr), disc(rr, S - rr, rr), disc(S - rr, S - rr, rr)]))
blend(card, (0x0B, 0x0F, 0x19), 1.0)

# glow
d = np.hypot(xx - logo.cx, yy - logo.cy) / 230.0
blend(np.clip(1 - d, 0, 1) ** 2, (0x6C, 0x5C, 0xE7), 0.35)

# lattice, back to front
for i in np.argsort(-logo.r):
    blend(disc(logo.x[i], logo.y[i], logo.dot[i]), logo.rgb[i], logo.alpha[i])

# arc ticks with gradient along the arc
stops = np.array([[0x6C, 0x5C, 0xE7], [0x00, 0xB8, 0xD9], [0xF5, 0xA6, 0x23]], float)
for j in range(logo.ticks):
    t = j / (logo.ticks - 1)
    seg = min(int(t * 2), 1); f = t * 2 - seg
    col = stops[seg] * (1 - f) + stops[seg + 1] * f if logo.done[j] else np.array([0x30, 0x36, 0x3D], float)
    blend(segment(logo.ax0[j], logo.ay0[j], logo.ax1[j], logo.ay1[j], 7.5 if logo.done[j] else 5.0), col, 1.0)

# chevron bars (rounded by dilating with the stroke width) and the pivot ring
fg = (0xE6, 0xED, 0xF3)
for P in (logo.chev_a, logo.chev_b):
    core = polygon(P)
    # approximate round join: union of the polygon and discs along its edges
    m = core.copy()
    for k in range(len(P)):
        (x0, y0), (x1, y1) = P[k], P[(k + 1) % len(P)]
        m = np.maximum(m, segment(x0, y0, x1, y1, 22.0))
    blend(m, fg, 1.0)
ring = disc(logo.cx, logo.cy - 52, 26 + 7) - disc(logo.cx, logo.cy - 52, 26 - 7)
blend(disc(logo.cx, logo.cy - 52, 26 - 7), (0x0B, 0x0F, 0x19), 1.0)
blend(np.clip(ring, 0, 1), fg, 1.0)

out = np.clip(img, 0, 255).astype(np.uint8)
out[..., 3] = (np.clip(img[..., 3], 0, 1) * 255).astype(np.uint8)
im = Image.fromarray(out, "RGBA")
im.save(here / "logo.png")
im.resize((256, 256), Image.LANCZOS).save(here / "icon.ico", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
print("wrote logo.png and icon.ico")
