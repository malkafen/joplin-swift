#!/usr/bin/env python3
"""Turns res-*.json from the stress runs into Markdown tables (medians over runs): times, then CPU and memory from the
res-*.samples.jsonl that sample.py wrote next to them.
Usage: report.py <label>=<glob> ...   e.g. report.py "Joplin=res-joplin-*.json" "Native=res-native-[0-9].json" """
import bisect, glob, json, os, statistics, sys
apps = []
for arg in sys.argv[1:]:
    label, pattern = arg.split("=", 1)
    runs = []
    for f in sorted(glob.glob(pattern)):
        r = json.load(open(f))
        samples = f[:-len(".json")] + ".samples.jsonl"
        r["samples"] = [json.loads(l) for l in open(samples)] if os.path.exists(samples) else []
        runs.append(r)
    apps.append((label, runs))
def value(runs, step, note, key):
    vals = []
    for r in runs:
        for s in r["steps"]:
            if s["step"] == step and s.get("note") == note and s.get(key) is not None: vals.append(s[key])
    return statistics.median(vals) if vals else None
ROWS = [
    ("Launch to the note list (10 000 notes)", "launch", None, "ready", "ms"),
    ("Memory after launch", "memory_idle", None, "mb", "MB"),
    ("Open an ordinary note (median of 20)", "switch_notes", None, "median", "ms"),
    ("— longest freeze", "switch_notes", None, "freeze_max", "ms"),
]
for n in ["Huge 1 MB", "Huge 5 MB", "Huge 20 MB"]:
    ROWS += [
        (f"**{n[5:]} note** — open in the editor", "open_editor", n, "ready", "ms"),
        ("— longest freeze", "open_editor", n, "freeze", "ms"),
        ("Open straight in split, preview shown", "open_split", n, "ready", "ms"),
        ("— longest freeze", "open_split", n, "freeze", "ms"),
        ("Editor → split, preview shown", "to_split", n, "ready", "ms"),
        ("— longest freeze", "to_split", n, "freeze", "ms"),
        ("Jump to the end (⌘↓) in split", "jump_end", n, "ready", "ms"),
        ("— longest freeze", "jump_end", n, "freeze", "ms"),
        ("Keystroke in split (median of 5)", "typing_split", n, "key_median", "ms"),
        ("— slowest keystroke", "typing_split", n, "key_max", "ms"),
        ("Preview catches up after typing", "typing_split", n, "preview_updated", "ms"),
        ("— longest freeze while it does", "typing_split", n, "freeze", "ms"),
        ("Split → preview only", "to_preview", n, "ready", "ms"),
        ("— longest freeze", "to_preview", n, "freeze", "ms"),
    ]
ROWS += [
    ("**Search** «значение» typed letter by letter, 5 MB note open in split: longest freeze", "search_typing", None, "freeze", "ms"),
    ("— results after the last key", "search_typing", None, "results_after_last_key", "ms"),
    ("Memory at the end", "memory_end", None, "mb", "MB"),
]
def fmt(v, unit):
    if v is None: return "—"
    if unit == "MB": return f"{v:,.0f} MB".replace(",", " ")
    if v < 5: return "< 5 ms"  # the drivers poll every 5–10 ms
    return f"{v / 1000:.1f} s" if v >= 1000 else f"{v:.0f} ms"
print("| | " + " | ".join(l for l, _ in apps) + " |")
print("|:--|" + "--:|" * len(apps))
for title, step, note, key, unit in ROWS:
    print(f"| {title} | " + " | ".join(fmt(value(runs, step, note, key), unit) for _, runs in apps) + " |")

def at(run, step, note=None):
    if step == "start": return next((s.get("start") for s in run["steps"] if s["step"] == "launch"), None)
    return next((s.get("at") for s in run["steps"] if s["step"] == step and s.get("note") == note), None)
def before(run, step, note=None):
    steps = run["steps"]
    i = next((i for i, s in enumerate(steps) if s["step"] == step and s.get("note") == note), None)
    return None if i is None else (steps[i - 1].get("at") if i > 0 else at(run, "start"))
def cpu_at(samples, t):
    i = bisect.bisect_right([x["t"] for x in samples], t) - 1
    return samples[max(0, i)]["cpu"]
def window(run, a, b):
    """CPU seconds, peak and average MB of the samples between Unix times a and b."""
    sm = run["samples"]
    if not sm or a is None or b is None: return None
    inside = [x for x in sm if a <= x["t"] <= b] or [min(sm, key=lambda x: abs(x["t"] - b))]
    return cpu_at(sm, b) - cpu_at(sm, a), max(x["mb"] for x in inside), statistics.mean(x["mb"] for x in inside), b - a
PHASES = [
    ("Launch and 10 s idle", lambda r: (at(r, "start"), at(r, "memory_idle"))),
    ("Idle 10 s after launch", lambda r: (at(r, "launch"), at(r, "memory_idle"))),
    ("Open 20 ordinary notes", lambda r: (before(r, "switch_notes"), at(r, "switch_notes"))),
]
for n in ["Huge 1 MB", "Huge 5 MB", "Huge 20 MB"]:
    PHASES.append((f"{n[5:]} note, all steps (open, split, ⌘↓, type, preview, editor)",
                   lambda r, n=n: (before(r, "open_editor", n), at(r, "to_editor", n))))
    PHASES.append((f"— typing 5 letters in split until the preview has them",
                   lambda r, n=n: (before(r, "typing_split", n), at(r, "typing_split", n))))
PHASES += [
    ("Open huge notes straight in split (3)", lambda r: (before(r, "open_split", "Huge 1 MB"), at(r, "open_split", "Huge 20 MB"))),
    ("Search typed letter by letter", lambda r: (before(r, "search_typing"), at(r, "search_typing"))),
    ("**Whole scenario**", lambda r: (at(r, "start"), at(r, "memory_end"))),
]
def phase(runs, f, i):
    vals = [w[i] for w in (window(r, *f(r)) for r in runs) if w]
    return statistics.median(vals) if vals else None
def cpu(v): return "—" if v is None else f"{v:.1f} s" if v >= 0.95 else f"{v * 1000:.0f} ms"
def mb(v): return "—" if v is None else f"{v:,.0f} MB".replace(",", " ")
if any(r["samples"] for _, runs in apps for r in runs):
    print()
    print("| CPU time (all cores) / peak memory | " + " | ".join(l for l, _ in apps) + " |")
    print("|:--|" + "--:|" * len(apps))
    for title, f in PHASES:
        cells = []
        for _, runs in apps:
            c, m = phase(runs, f, 0), phase(runs, f, 1)
            if title.startswith("Idle"):
                d = phase(runs, f, 3)
                cells.append("—" if c is None or not d else f"{c / d * 100:.1f} % of a core")
            else:
                cells.append(f"{cpu(c)} / {mb(m)}")
        print(f"| {title} | " + " | ".join(cells) + " |")
    print(f"| — wall time | " + " | ".join(f"{phase(runs, PHASES[-1][1], 3) or 0:.0f} s" for _, runs in apps) + " |")
    print(f"| — average memory | " + " | ".join(mb(phase(runs, PHASES[-1][1], 2)) for _, runs in apps) + " |")
