r"""Render terminal screenshots of a real updater run as SVG.

Reads %ProgramData%\claude-desktop-updater\updater.log (or argv[1]) and
reproduces the console layout of the tool: a step list with durations, the
indented details, the live progress line and the outcome block. Two frames
are produced, each in a dark and a light variant:

  terminal.svg / terminal-light.svg            the finished run
  terminal-progress.svg / -light.svg           a frame during the download

Run:  python assets/make_terminal.py [updater.log]
"""
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from xml.sax.saxutils import escape

here = Path(__file__).resolve().parent
src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "claude-desktop-updater" / "updater.log"

THEMES = {
    "dark":  {"bg": "#0D1117", "chrome": "#161B22", "border": "#30363D", "fg": "#E6EDF3", "dim": "#8B949E",
              "accent": "#D97757", "ok": "#3FB950", "warn": "#D29922", "err": "#F85149", "bar_empty": "#30363D"},
    "light": {"bg": "#FFFFFF", "chrome": "#F6F8FA", "border": "#D0D7DE", "fg": "#1F2328", "dim": "#6E7781",
              "accent": "#C9643F", "ok": "#1A7F37", "warn": "#9A6700", "err": "#CF222E", "bar_empty": "#D0D7DE"},
}

pat = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)  \[(\w+)\s*\] (.*)$")


def parse(text):
    """-> list of steps: {title, start, end, state, elevated, details:[(level,text)]}, summary rows"""
    steps, summary, last_ts = [], {}, None
    elevated, anchor, cur, closing = False, None, None, False
    # anchor: the user step that spawned the elevated phase; cur: the step that
    # receives detail lines; closing: the elevated block just ended, so the next
    # user-phase timestamp closes both the last elevated step and the anchor.
    for line in text.splitlines():
        if line.startswith("--- elevated phase"):
            elevated, anchor = True, len(steps) - 1
            continue
        if line.startswith("--- end elevated phase"):
            elevated, closing, cur = False, True, anchor
            continue
        m = pat.match(line)
        if not m:
            continue
        ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
        lvl, msg = m.group(2), m.group(3)
        last_ts = ts
        if closing:
            for s in steps[anchor:]:
                if s["end"] is None:
                    s["end"] = ts
            closing = False
        if msg.startswith("==="):
            # a restarted elevated phase supersedes what an earlier one logged
            if elevated and anchor is not None:
                del steps[anchor + 1:]
            continue
        if lvl == "STEP":
            if steps and not elevated and steps[-1]["end"] is None:
                steps[-1]["end"] = ts
            if elevated and steps and steps[-1]["elevated"] and steps[-1]["end"] is None:
                steps[-1]["end"] = ts
            steps.append({"title": msg, "start": ts, "end": None, "state": "ok", "elevated": elevated, "details": []})
            cur = len(steps) - 1
        elif msg.startswith("SUMMARY:"):
            a, b = msg[len("SUMMARY:"):].strip().split("->")
            summary = {"previous": a.strip(), "installed": b.strip()}
        elif lvl in ("OK", "DETAIL", "INFO", "WARN", "ERROR") and steps and cur is not None:
            if lvl == "WARN" and steps[cur]["state"] == "ok":
                steps[cur]["state"] = "warn"
            if lvl == "ERROR":
                steps[cur]["state"] = "fail"
            if SKIP.search(msg):
                continue
            # lines the user phase logs after the elevated block belong below it
            after = (cur == anchor) and anchor is not None and any(s["elevated"] for s in steps[anchor + 1:])
            steps[cur].setdefault("after", []) if after else None
            (steps[cur]["after"] if after else steps[cur]["details"]).append((lvl, msg))
    for s in steps:
        if s["end"] is None:
            s["end"] = last_ts
    return steps, summary


# log lines that belong in the file but only add noise to a screenshot
SKIP = re.compile(r"^(elevated phase finished|https?://|stopped \S+ \(PID|approve the UAC prompt|AppModelUnlock keys set|elevated phase completed)")


def elapsed(s):
    if s < 1:
        return f"{s * 1000:.0f}ms"
    if s < 60:
        return f"{s:.1f}s"
    m, sec = divmod(int(round(s)), 60)
    return f"{m}m {sec:02d}s"


def tidy(msg):
    # logs written before v3.1.1 cut the quoted CN at its comma
    msg = re.sub(r'signer "Anthropic$', "signer Anthropic, PBC", msg)
    msg = re.sub(r'CN="?([^",]+)"?,.*', r"\1", msg)
    msg = msg.replace("[SC] ", "").replace(":  ", ": ").rstrip()
    return msg[:96]


def frame(steps, summary, theme, live=None, outcome=True, cmd="claude-desktop-updater"):
    """Render one frame. `live` = (step_index, percent, detail) draws a progress line
    under that step and hides everything after it."""
    T = THEMES[theme]
    LH, X, TOP = 20, 28, 44
    W = 860
    glyph = {"ok": ("\u2713", T["ok"]), "warn": ("!", T["warn"]), "fail": ("\u2717", T["err"]), "active": ("\u25CF", T["accent"])}
    rows = []                                    # (svg text, height)

    def text(x, y, parts, **kw):
        attrs = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in kw.items())
        spans = "".join(f'<tspan fill="{c}"{" font-weight=\"600\"" if b else ""}>{escape(s)}</tspan>' for s, c, b in parts)
        return f'<text x="{x}" y="{y}" xml:space="preserve" {attrs}>{spans}</text>'

    body = []
    y = TOP + 30
    body.append(text(X, y, [("$ ", T["dim"], False), (cmd, T["fg"], False)]))
    y += LH * 1.6
    body.append(text(X, y, [("claude-desktop-updater", T["fg"], True), ("  v3.1.0", T["dim"], False)]))
    y += LH * 1.6

    cols = 92
    shown = steps if live is None else steps[: live[0] + 1]
    was_elevated, post = False, []

    def detail_line(dind, lvl, msg):
        msg = tidy(msg)
        if lvl == "WARN":
            return text(X, y, [(dind + "! ", T["warn"], False), (msg, T["warn"], False)])
        if lvl == "ERROR":
            return text(X, y, [(dind + "✗ ", T["err"], False), (msg, T["err"], False)])
        return text(X, y, [(dind + msg, T["fg"] if lvl == "OK" else T["dim"], False)])

    for i, st in enumerate(shown):
        active = live is not None and i == live[0]
        ind = "      " if st["elevated"] else "  "          # elevated steps nest under their parent
        if was_elevated and not st["elevated"]:
            for lvl, msg in post:                           # the parent's closing lines
                body.append(detail_line("      ", lvl, msg)); y += LH
            post = []
        if st["elevated"] and not was_elevated:
            body.append(text(X, y, [("      elevated phase, reported in its own window", T["dim"], False)]))
            y += LH
        was_elevated = st["elevated"]
        if st.get("after"):
            post = st["after"]
        g, c = glyph["active"] if active else glyph[st["state"]]
        dur = "" if active else elapsed((st["end"] - st["start"]).total_seconds())
        title = st["title"]
        pad = " " * max(1, cols - len(ind) - 2 - len(title) - len(dur))
        body.append(text(X, y, [(ind, T["fg"], False), (g, c, False), (" " + title, T["fg"], False), (pad + dur, T["dim"], False)]))
        y += LH
        details = st["details"] if not active else []
        dind = ind + "    "
        for lvl, msg in details:
            body.append(detail_line(dind, lvl, msg)); y += LH
        if active:
            pct, detail = live[1], live[2]
            width = 34
            filled = int(width * pct / 100)
            bar = "\u2501" * filled + ("\u2578" if 0 < filled < width else "") + "\u2500" * (width - filled - (1 if 0 < filled < width else 0))
            body.append(text(X, y, [("      \u280B ", T["accent"], False),
                                    (bar[:filled + 1], T["accent"], False), (bar[filled + 1:], T["bar_empty"], False),
                                    (f" {pct:5.1f}%  ", T["fg"], False), (detail, T["dim"], False)]))
            y += LH
    if post:
        for lvl, msg in post:
            body.append(detail_line("      ", lvl, msg)); y += LH

    if outcome and live is None:
        total = (steps[-1]["end"] - steps[0]["start"]).total_seconds()
        ok = all(s["state"] != "fail" for s in steps)
        y += LH * 0.6
        title = "Update complete" if ok else "Update did not complete"
        g, c = glyph["ok"] if ok else glyph["fail"]
        dur = elapsed(total)
        pad = " " * max(1, cols - 4 - len(title) - len(dur))
        body.append(text(X, y, [("  ", T["fg"], False), (g, c, False), (" " + title, T["fg"], True), (pad + dur, T["dim"], False)]))
        y += LH * 1.4
        rows_kv = [("previous", summary.get("previous", "")), ("installed", summary.get("installed", "")),
                   ("user data", "preserved"), ("log", r"C:\ProgramData\claude-desktop-updater\updater.log")]
        for k, v in rows_kv:
            body.append(text(X, y, [("      " + k.ljust(10), T["dim"], False), (v, T["fg"], False)]))
            y += LH
    H = int(y + 26)

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
           f'font-family="ui-monospace, \'Cascadia Mono\', \'JetBrains Mono\', Menlo, Consolas, monospace" font-size="13">',
           f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="10" fill="{T["bg"]}" stroke="{T["border"]}"/>',
           f'<path d="M0.5 10.5a10 10 0 0 1 10-10h{W - 21}a10 10 0 0 1 10 10v{TOP - 10}H0.5z" fill="{T["chrome"]}"/>',
           f'<line x1="0.5" y1="{TOP + 0.5}" x2="{W - 0.5}" y2="{TOP + 0.5}" stroke="{T["border"]}"/>',
           f'<circle cx="24" cy="22" r="6" fill="#FF5F57"/><circle cx="44" cy="22" r="6" fill="#FEBC2E"/><circle cx="64" cy="22" r="6" fill="#28C840"/>',
           f'<text x="{W / 2}" y="26" text-anchor="middle" fill="{T["dim"]}" font-size="12">Windows PowerShell</text>']
    out += body
    out.append("</svg>")
    return "\n".join(out) + "\n"


steps, summary = parse(src.read_text(encoding="utf-8", errors="replace"))
if not steps:
    sys.exit(f"no steps found in {src}")

# derive a plausible mid-download frame from the real download step
dl = next((i for i, s in enumerate(steps) if s["title"].startswith("Downloading")), None)
live = None
if dl is not None:
    m = re.search(r"([\d.]+) MB in (\d\d):(\d\d)", " ".join(t for _, t in steps[dl]["details"]))
    if m:
        total_mb = float(m.group(1)); secs = int(m.group(2)) * 60 + int(m.group(3))
        speed = total_mb / max(secs, 1)
        pct = 63.0
        done_mb = total_mb * pct / 100
        eta = (total_mb - done_mb) / speed
        live = (dl, pct, f"{done_mb:.1f} MB / {total_mb:.1f} MB \u00b7 {speed:.1f} MB/s \u00b7 {int(eta) // 60:02d}:{int(eta) % 60:02d} left")

for theme in THEMES:
    suffix = "" if theme == "dark" else "-light"
    (here / f"terminal{suffix}.svg").write_text(frame(steps, summary, theme), encoding="utf-8")
    if live:
        (here / f"terminal-progress{suffix}.svg").write_text(frame(steps, summary, theme, live=live, cmd="claude-desktop-updater -Force"), encoding="utf-8")
print(f"rendered {len(steps)} steps from {src}")
