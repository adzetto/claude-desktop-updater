r"""Render a terminal screenshot of a real updater run as SVG.

Reads %ProgramData%\claude-desktop-updater\updater.log (or a path given as
argv[1]), keeps the console-relevant lines, and lays them out as a styled
terminal window so the README shows genuine output without a PNG.

Run:  python assets/make_terminal.py [updater.log]
Out:  assets/terminal.svg
"""
import os
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

here = Path(__file__).resolve().parent
src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "claude-desktop-updater" / "updater.log"

C = {"bg": "#0B0F19", "chrome": "#141A26", "fg": "#E6EDF3", "grey": "#8B949E", "violet": "#9B7BFF",
     "cyan": "#3CC8EB", "green": "#50DC78", "yellow": "#FFC846", "red": "#FF5F5F", "amber": "#F5A623"}
LEVEL = {"OK": ("\u2714", C["green"]), "WARN": ("\u25B2", C["yellow"]), "ERROR": ("\u2716", C["red"]),
         "INFO": ("\u276F", C["grey"]), "DETAIL": (" ", C["grey"])}

pat = re.compile(r"^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)\.\d+  \[(\w+)\s*\] (.*)$")
rows = []          # (time, level, text)
step = 0
for line in src.read_text(encoding="utf-8", errors="replace").splitlines():
    m = pat.match(line)
    if not m:
        continue
    _, t, lvl, text = m.groups()
    if text.startswith("===") or text.startswith("---") or lvl not in LEVEL and lvl != "STEP":
        continue
    if lvl == "STEP":
        step += 1
    rows.append((t, lvl, text))

# collapse the very long signature subject and URLs for readability
clean = []
for t, lvl, text in rows:
    text = re.sub(r"CN=([^,]+),.*", r"CN=\1", text)
    text = re.sub(r"https://downloads\.claude\.ai/\S+", "https://downloads.claude.ai/releases/win32/x64/.../Claude-....msix", text)
    clean.append((t, lvl, text[:110]))
rows = clean[-34:]

banner = ["  \u256D" + "\u2500" * 58 + "\u256E",
          "  \u2502   CLAUDE DESKTOP UPDATER" + " " * 33 + "\u2502",
          "  \u2502   MSIX repair and update tool for Windows" + " " * 16 + "\u2502",
          "  \u2502   v3.0.0   github.com/adzetto/claude-desktop-updater" + " " * 5 + "\u2502",
          "  \u2570" + "\u2500" * 58 + "\u256F"]

LH, PADX, PADY, TOP = 19, 22, 18, 40
W = 900
H = TOP + PADY * 2 + LH * (len(banner) + len(rows) + 3)
out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="Cascadia Code, JetBrains Mono, Consolas, monospace" font-size="13">',
       f'<rect width="{W}" height="{H}" rx="12" fill="{C["bg"]}"/>',
       f'<path d="M0 12a12 12 0 0 1 12-12h{W-24}a12 12 0 0 1 12 12v{TOP-12}H0z" fill="{C["chrome"]}"/>',
       f'<circle cx="22" cy="20" r="6" fill="#FF5F57"/><circle cx="42" cy="20" r="6" fill="#FEBC2E"/><circle cx="62" cy="20" r="6" fill="#28C840"/>',
       f'<text x="{W/2}" y="25" text-anchor="middle" fill="{C["grey"]}" font-size="12">claude-desktop-updater</text>']

y = TOP + PADY + LH
out.append(f'<text x="{PADX}" y="{y}" fill="{C["grey"]}">PS C:\\Users\\you&gt; <tspan fill="{C["fg"]}">claude-desktop-updater</tspan></text>')
y += LH
for i, b in enumerate(banner):
    col = C["violet"]
    if i == 1:
        out.append(f'<text x="{PADX}" y="{y}" fill="{col}" xml:space="preserve">{escape(b[:5])}<tspan fill="{C["amber"]}" font-weight="bold">{escape(b[5:28])}</tspan>{escape(b[28:])}</text>')
    else:
        inner = C["fg"] if i in (2,) else C["grey"] if i == 3 else col
        out.append(f'<text x="{PADX}" y="{y}" fill="{col}" xml:space="preserve">{escape(b[:3])}<tspan fill="{inner}">{escape(b[3:-1])}</tspan>{escape(b[-1])}</text>')
    y += LH
y += 4
n = 0
total = step
for t, lvl, text in rows:
    if lvl == "STEP":
        n += 1
        y += 6
        out.append(f'<text x="{PADX}" y="{y}" xml:space="preserve"><tspan fill="{C["grey"]}">  {t} </tspan><tspan fill="{C["violet"]}">[{n}/{total}]</tspan> <tspan fill="{C["fg"]}" font-weight="bold">{escape(text)}</tspan></text>')
    else:
        glyph, col = LEVEL[lvl]
        body_col = col if lvl in ("WARN", "ERROR") else C["fg"] if lvl == "OK" else C["grey"]
        out.append(f'<text x="{PADX}" y="{y}" xml:space="preserve"><tspan fill="{C["grey"]}">  {t}   </tspan><tspan fill="{col}">{glyph}</tspan>  <tspan fill="{body_col}">{escape(text)}</tspan></text>')
    y += LH
out.append("</svg>")
(here / "terminal.svg").write_text("\n".join(out), encoding="utf-8")
print(f"terminal.svg: {len(rows)} lines from {src}")
