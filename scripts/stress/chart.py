#!/usr/bin/env python3
"""Draws memory and CPU time over the whole stress scenario as an SVG, one run per app (the run with the median wall
time), from the res-*.samples.jsonl that sample.py wrote.
Usage: chart.py <out.svg> <label>=<glob of res-*.json> ...   (the first app gets the first color)"""
import glob, json, os, statistics, sys

out = sys.argv[1]
apps = []
for arg in sys.argv[2:]:
    label, pattern = arg.split("=", 1)
    runs = []
    for f in sorted(glob.glob(pattern)):
        samples = f[:-len(".json")] + ".samples.jsonl"
        if not os.path.exists(samples): continue
        steps = json.load(open(f))["steps"]
        start = next(s["start"] for s in steps if s["step"] == "launch")
        end = next(s["at"] for s in steps if s["step"] == "memory_end")
        pts = [json.loads(l) for l in open(samples)]
        pts = [p for p in pts if start <= p["t"] <= end]
        cpu0 = pts[0]["cpu"] if pts else 0
        runs.append((end - start, [(p["t"] - start, p["mb"], p["cpu"] - cpu0) for p in pts]))
    runs.sort(key=lambda r: r[0])
    apps.append((label, runs[len(runs) // 2][1]))

COLORS = ["#eb6834", "#2a78d6"]  # light mode; the style sheet has the dark steps
W, PANEL, TOP, LEFT, RIGHT, GAP = 860, 220, 64, 64, 200, 70
H = TOP + 2 * PANEL + GAP + 40
tmax = max(p[0] for _, pts in apps for p in pts)
def nice(v):
    for e in range(0, 6):
        for step in [1, 2, 2.5, 5]:
            s = step * 10 ** e
            if v / s <= 5: return s
    return v / 5
def x(t): return LEFT + t / tmax * (W - LEFT - RIGHT)

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="-apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif" font-size="12">',
       """<style>
  @media (prefers-color-scheme: dark) {
    .surface { fill: #1a1a19 } .ink { fill: #f0efec } .muted { fill: #c3c2b7 } .grid { stroke: #2e2d2b } .axis { stroke: #55544f }
    .s0 { stroke: #d95926 } .f0 { fill: #d95926 } .s1 { stroke: #3987e5 } .f1 { fill: #3987e5 }
  }
</style>""",
       f'<rect class="surface" fill="#fcfcfb" width="{W}" height="{H}" rx="8"/>',
       f'<text class="ink" fill="#0b0b0b" x="{LEFT}" y="26" font-size="15" font-weight="600">The whole stress scenario: memory and CPU time</text>']
lx = LEFT
for i, (label, _) in enumerate(apps):
    svg.append(f'<rect class="f{i}" fill="{COLORS[i]}" x="{lx}" y="38" width="14" height="4" rx="2"/>')
    svg.append(f'<text class="muted" fill="#52514e" x="{lx + 20}" y="44">{label}</text>')
    lx += 30 + 7.2 * len(label) + 20

def panel(y0, title, idx, unit, fmt):
    vmax = max(p[idx] for _, pts in apps for p in pts) * 1.05
    step = nice(vmax)
    top, bottom = y0 + 24, y0 + PANEL
    def y(v): return bottom - v / vmax * (bottom - top)
    svg.append(f'<text class="ink" fill="#0b0b0b" x="{LEFT}" y="{y0 + 10}" font-weight="600">{title}</text>')
    v = 0
    while v <= vmax:
        svg.append(f'<line class="grid" stroke="#e4e3df" x1="{LEFT}" x2="{W - RIGHT}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>')
        svg.append(f'<text class="muted" fill="#52514e" x="{LEFT - 8}" y="{y(v) + 4:.1f}" text-anchor="end">{fmt(v)}</text>')
        v += step
    svg.append(f'<line class="axis" stroke="#b8b7b1" x1="{LEFT}" x2="{W - RIGHT}" y1="{bottom}" y2="{bottom}"/>')
    labels = []
    for i, (label, pts) in enumerate(apps):
        columns = {}
        for t, *vals in pts:
            c = round(x(t))
            columns[c] = max(columns.get(c, 0), vals[idx - 1])
        d = " ".join(f"{'M' if k == 0 else 'L'}{c},{y(v):.1f}" for k, (c, v) in enumerate(sorted(columns.items())))
        svg.append(f'<path class="s{i}" stroke="{COLORS[i]}" d="{d}" fill="none" stroke-width="2" stroke-linejoin="round"/>')
        t, *vals = pts[-1]
        labels.append([y(vals[idx - 1]), f"{label}: {fmt(vals[idx - 1])} {unit}"])
    labels.sort()
    for k in range(1, len(labels)):
        labels[k][0] = max(labels[k][0], labels[k - 1][0] + 16)
    for ly, text in labels:
        svg.append(f'<text class="ink" fill="#0b0b0b" x="{W - RIGHT + 8}" y="{ly + 4:.1f}">{text}</text>')
    return bottom

b = panel(TOP, "Memory (all processes, physical footprint)", 1, "MB", lambda v: f"{v:,.0f}".replace(",", " "))
b = panel(b + GAP - 24, "CPU time used so far (all cores)", 2, "s", lambda v: f"{v:,.0f}".replace(",", " "))
v = 0
step = nice(tmax / 60) * 60
while v <= tmax:
    svg.append(f'<text class="muted" fill="#52514e" x="{x(v):.1f}" y="{b + 18}" text-anchor="middle">{v / 60:.0f} min</text>')
    v += step
svg.append("</svg>")
open(out, "w").write("\n".join(svg))
