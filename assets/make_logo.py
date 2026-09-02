"""Generate the project logo as SVG using numpy.

The mark is a stylised repair spiral: a golden-angle sunflower lattice of
dots whose radius follows a Gaussian ring, wrapped by a segmented progress
arc. Everything is computed with numpy and written as hand-assembled SVG
so the repository carries no binary assets.

Run:  python assets/make_logo.py
Out:  assets/logo.svg, assets/logo-dark.svg, assets/icon.svg
"""
import numpy as np
from pathlib import Path

rng = np.random.default_rng(1406091)
out_dir = Path(__file__).resolve().parent

W = H = 512.0
cx = cy = W / 2.0

# ---------------------------------------------------------------- lattice
n = 420
k = np.arange(1, n + 1, dtype=float)
phi = (1.0 + 5.0 ** 0.5) / 2.0
theta = 2.0 * np.pi * k / phi ** 2          # golden angle spiral
r = 168.0 * np.sqrt(k / n)                   # equal-area (Vogel) radius
x = cx + r * np.cos(theta)
y = cy + r * np.sin(theta)

# dot radius: Gaussian ring peaked at r0, plus a gentle spiral modulation
r0, sigma = 118.0, 46.0
ring = np.exp(-0.5 * ((r - r0) / sigma) ** 2)
swirl = 0.5 + 0.5 * np.cos(3.0 * theta - 0.035 * r)
dot = 1.4 + 6.4 * ring * (0.55 + 0.45 * swirl)

# colour: hue drifts along the spiral from indigo to amber, alpha with radius
t = (k - 1) / (n - 1)
stops = np.array([[0x6C, 0x5C, 0xE7], [0x00, 0xB8, 0xD9], [0xF5, 0xA6, 0x23]], float)
seg = np.clip(t * 2.0, 0.0, 2.0)
i0 = np.floor(seg).astype(int).clip(0, 1)
f = seg - i0
rgb = stops[i0] * (1.0 - f)[:, None] + stops[i0 + 1] * f[:, None]
alpha = 0.35 + 0.65 * ring

# ---------------------------------------------------------------- arc
# segmented progress ring: 36 ticks, 27 "done" (75 %), gap at 12 o'clock
ticks = 36
ang = -np.pi / 2.0 + 2.0 * np.pi * np.arange(ticks) / ticks
done = np.arange(ticks) < 27
R_in, R_out = 206.0, 226.0
ax0 = cx + R_in * np.cos(ang); ay0 = cy + R_in * np.sin(ang)
ax1 = cx + R_out * np.cos(ang); ay1 = cy + R_out * np.sin(ang)

# ---------------------------------------------------------------- centre glyph
# a wrench-like chevron built from two rotated rounded bars
bar = np.array([[-64, -11], [64, -11], [64, 11], [-64, 11]], float)
rot = lambda a: np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
chev_a = bar @ rot(np.deg2rad(45)).T + [cx - 20, cy + 20]
chev_b = bar @ rot(np.deg2rad(-45)).T + [cx + 20, cy + 20]


def svg(dark: bool, icon: bool = False) -> str:
    bg = "#0B0F19" if dark else "#FFFFFF"
    fg = "#E6EDF3" if dark else "#0B0F19"
    dim = "#30363D" if dark else "#D0D7DE"
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" '
        f'width="{W:.0f}" height="{H:.0f}" role="img" aria-label="Claude Desktop Updater">',
        "<defs>",
        '<radialGradient id="glow" cx="50%" cy="50%" r="50%">'
        '<stop offset="0%" stop-color="#6C5CE7" stop-opacity="0.35"/>'
        '<stop offset="100%" stop-color="#6C5CE7" stop-opacity="0"/></radialGradient>',
        '<linearGradient id="arc" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0%" stop-color="#6C5CE7"/><stop offset="55%" stop-color="#00B8D9"/>'
        '<stop offset="100%" stop-color="#F5A623"/></linearGradient>',
        "</defs>",
    ]
    if not icon:
        parts.append(f'<rect width="{W:.0f}" height="{H:.0f}" rx="96" fill="{bg}"/>')
    parts.append(f'<circle cx="{cx}" cy="{cy}" r="230" fill="url(#glow)"/>')

    # lattice dots, back to front by radius so the ring reads as a torus
    order = np.argsort(-r)
    for i in order:
        c = "#%02X%02X%02X" % tuple(int(v) for v in rgb[i])
        parts.append(
            f'<circle cx="{x[i]:.2f}" cy="{y[i]:.2f}" r="{dot[i]:.2f}" '
            f'fill="{c}" fill-opacity="{alpha[i]:.3f}"/>'
        )

    # progress ticks
    for j in range(ticks):
        col = "url(#arc)" if done[j] else dim
        w = 7.5 if done[j] else 5.0
        parts.append(
            f'<line x1="{ax0[j]:.2f}" y1="{ay0[j]:.2f}" x2="{ax1[j]:.2f}" y2="{ay1[j]:.2f}" '
            f'stroke="{col}" stroke-width="{w}" stroke-linecap="round"/>'
        )

    # centre chevron (the "fix" mark)
    pts = lambda P: " ".join(f"{px:.2f},{py:.2f}" for px, py in P)
    parts.append(f'<polygon points="{pts(chev_a)}" fill="{fg}" stroke="{fg}" '
                 f'stroke-width="22" stroke-linejoin="round"/>')
    parts.append(f'<polygon points="{pts(chev_b)}" fill="{fg}" stroke="{fg}" '
                 f'stroke-width="22" stroke-linejoin="round"/>')
    parts.append(f'<circle cx="{cx}" cy="{cy - 52}" r="26" fill="{bg}" stroke="{fg}" stroke-width="14"/>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


(out_dir / "logo.svg").write_text(svg(dark=False), encoding="utf-8")
(out_dir / "logo-dark.svg").write_text(svg(dark=True), encoding="utf-8")
(out_dir / "icon.svg").write_text(svg(dark=True, icon=True), encoding="utf-8")
print(f"wrote {n} lattice dots, {ticks} arc ticks -> logo.svg, logo-dark.svg, icon.svg in {out_dir}")
