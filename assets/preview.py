"""Rasterise the terminal screenshots to PNG with Pillow.

The SVGs written by make_terminal.py only use rects, a path for the title
bar, circles, lines and monospace <text> rows, so a tiny purpose-built
renderer is enough to preview them (and to publish PNG copies) without an
SVG library.

Run:  python assets/preview.py
Out:  assets/terminal.png, assets/terminal-progress.png (2x scale)
"""
import re
from pathlib import Path
from xml.dom import minidom

from PIL import Image, ImageDraw, ImageFont

here = Path(__file__).resolve().parent
SCALE = 2

FONT_CANDIDATES = [r"C:\Windows\Fonts\CascadiaMono.ttf", r"C:\Windows\Fonts\consola.ttf", r"C:\Windows\Fonts\cour.ttf"]
BOLD_CANDIDATES = [r"C:\Windows\Fonts\CascadiaMonoPL-Bold.ttf", r"C:\Windows\Fonts\consolab.ttf", r"C:\Windows\Fonts\courbd.ttf"]


def load_font(cands, size):
    for c in cands:
        if Path(c).exists():
            return ImageFont.truetype(c, size)
    return ImageFont.load_default()


def render(svg_path: Path, png_path: Path):
    doc = minidom.parse(str(svg_path)).documentElement
    W = int(float(doc.getAttribute("width"))); H = int(float(doc.getAttribute("height")))
    im = Image.new("RGBA", (W * SCALE, H * SCALE), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    font = load_font(FONT_CANDIDATES, 13 * SCALE)
    bold = load_font(BOLD_CANDIDATES, 13 * SCALE)
    small = load_font(FONT_CANDIDATES, 12 * SCALE)
    body_fill = next((n.getAttribute("fill") for n in doc.getElementsByTagName("rect")), "#000000")

    for node in doc.childNodes:
        if node.nodeType != node.ELEMENT_NODE:
            continue
        tag = node.tagName
        if tag == "rect":
            x, y = float(node.getAttribute("x") or 0), float(node.getAttribute("y") or 0)
            w, h = float(node.getAttribute("width")), float(node.getAttribute("height"))
            r = float(node.getAttribute("rx") or 0)
            fill = node.getAttribute("fill"); stroke = node.getAttribute("stroke") or None
            d.rounded_rectangle([x * SCALE, y * SCALE, (x + w) * SCALE, (y + h) * SCALE], radius=r * SCALE,
                                fill=fill, outline=stroke, width=SCALE if stroke else 0)
        elif tag == "path":
            # title bar: rounded top, flat bottom
            m = re.search(r"v([\d.]+)H", node.getAttribute("d"))
            top_h = float(m.group(1)) + 10 if m else 44
            fill = node.getAttribute("fill")
            d.rounded_rectangle([0, 0, W * SCALE - 1, (top_h + 12) * SCALE], radius=10 * SCALE, fill=fill)
            # restore the body background below the bar (the rounded rect overshoots by 12 px)
            d.rectangle([0, top_h * SCALE, W * SCALE - 1, (top_h + 12) * SCALE], fill=body_fill)
        elif tag == "line":
            x1, y1, x2, y2 = (float(node.getAttribute(k)) for k in ("x1", "y1", "x2", "y2"))
            d.line([x1 * SCALE, y1 * SCALE, x2 * SCALE, y2 * SCALE], fill=node.getAttribute("stroke"), width=SCALE)
        elif tag == "circle":
            cx, cy, r = (float(node.getAttribute(k)) for k in ("cx", "cy", "r"))
            d.ellipse([(cx - r) * SCALE, (cy - r) * SCALE, (cx + r) * SCALE, (cy + r) * SCALE], fill=node.getAttribute("fill"))
        elif tag == "text":
            x, y = float(node.getAttribute("x")), float(node.getAttribute("y"))
            anchor = node.getAttribute("text-anchor")
            f = small if node.getAttribute("font-size") == "12" else font
            spans = []
            for ch in node.childNodes:
                if ch.nodeType == ch.ELEMENT_NODE and ch.tagName == "tspan":
                    txt = "".join(t.data for t in ch.childNodes if t.nodeType == t.TEXT_NODE)
                    spans.append((txt, ch.getAttribute("fill"), ch.getAttribute("font-weight") == "600"))
                elif ch.nodeType == ch.TEXT_NODE and ch.data.strip():
                    spans.append((ch.data, node.getAttribute("fill"), False))
            total = sum(d.textlength(t, font=f) for t, _, _ in spans)
            px = x * SCALE - (total / 2 if anchor == "middle" else 0)
            for txt, fill, is_bold in spans:
                ff = bold if is_bold else f
                d.text((px, y * SCALE), txt, font=ff, fill=fill, anchor="ls")
                px += d.textlength(txt, font=ff)
    im.save(png_path)
    print(f"{png_path.name}: {im.size[0]}x{im.size[1]}")


for name in ("terminal", "terminal-progress", "terminal-light", "terminal-progress-light"):
    p = here / f"{name}.svg"
    if p.exists():
        render(p, here / f"{name}.png")
