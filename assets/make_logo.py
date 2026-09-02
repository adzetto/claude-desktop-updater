"""Generate the project mark as SVG with numpy.

A single accent ring drawn as a 300 degree arc (the "update in progress"
gesture) and a chevron pointing up, on a dark rounded card. All geometry is
computed with numpy and emitted as plain SVG paths, so the repository carries
no binary image source.

Run:  python assets/make_logo.py
Out:  assets/logo.svg (dark card), assets/logo-light.svg (white card),
      assets/icon.svg (transparent, mark only)
"""
import numpy as np
from pathlib import Path

out_dir = Path(__file__).resolve().parent

S = 512.0
cx = cy = S / 2.0

ACCENT = "#D97757"      # terracotta
DARK = "#0D1117"
LIGHT = "#FFFFFF"
INK_ON_DARK = "#F0F6FC"
INK_ON_LIGHT = "#0D1117"

# ------------------------------------------------------------------ ring
R = 168.0                     # ring radius
W = 30.0                      # stroke width
gap_deg = 60.0                # opening at the top right
start = np.deg2rad(-90.0 + gap_deg / 2.0)
end = np.deg2rad(270.0 - gap_deg / 2.0)
t = np.linspace(start, end, 181)
arc = np.column_stack([cx + R * np.cos(t), cy + R * np.sin(t)])

# ------------------------------------------------------------------ chevron
# an up-pointing chevron whose arms are equal in length to a quarter of the
# ring diameter, centred slightly below the ring centre
L = 78.0
apex = np.array([cx, cy - 34.0])
left = apex + L * np.array([-np.cos(np.deg2rad(45)), np.sin(np.deg2rad(45))])
right = apex + L * np.array([np.cos(np.deg2rad(45)), np.sin(np.deg2rad(45))])
chevron = np.vstack([left, apex, right])

# a short stem under the apex reads as an arrow at small sizes
stem = np.vstack([apex + [0, 26.0], apex + [0, 118.0]])


def path(P):
    return "M " + " L ".join(f"{x:.2f} {y:.2f}" for x, y in P)


def svg(background: str | None, ink: str) -> str:
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S:.0f} {S:.0f}" width="{S:.0f}" height="{S:.0f}" '
        f'role="img" aria-label="claude-desktop-updater">'
    ]
    if background:
        parts.append(f'<rect width="{S:.0f}" height="{S:.0f}" rx="112" fill="{background}"/>')
    parts.append(f'<path d="{path(arc)}" fill="none" stroke="{ACCENT}" stroke-width="{W}" stroke-linecap="round"/>')
    parts.append(f'<path d="{path(chevron)}" fill="none" stroke="{ink}" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"/>')
    parts.append(f'<path d="{path(stem)}" fill="none" stroke="{ink}" stroke-width="{W}" stroke-linecap="round"/>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


(out_dir / "logo.svg").write_text(svg(DARK, INK_ON_DARK), encoding="utf-8")
(out_dir / "logo-light.svg").write_text(svg(LIGHT, INK_ON_LIGHT), encoding="utf-8")
(out_dir / "icon.svg").write_text(svg(None, INK_ON_DARK), encoding="utf-8")
print(f"wrote logo.svg, logo-light.svg, icon.svg ({len(arc)} arc points) in {out_dir}")
