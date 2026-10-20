#!/usr/bin/env python3
"""Turns res-*.json from the stress runs into a Markdown table (medians over runs).
Usage: report.py <label>=<glob> ...   e.g. report.py "Joplin=res-joplin-*.json" "Native=res-native-[0-9].json" """
import glob, json, statistics, sys
apps = []
for arg in sys.argv[1:]:
    label, pattern = arg.split("=", 1)
    runs = [json.load(open(f)) for f in sorted(glob.glob(pattern))]
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
