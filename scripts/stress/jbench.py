#!/usr/bin/env python3
"""Stress scenario for Joplin Desktop, the same steps as Sources/JoplinNative/StressProbe.swift.
Usage: jbench.py <profile dir> <out.json>. Joplin must not be running."""
import json, re, sqlite3, statistics, subprocess, sys, time
from jdrive import Joplin
prof, out = sys.argv[1], sys.argv[2]
QUERY = "значение"
db = sqlite3.connect(f"{prof}/database.sqlite")
huge = {t: (i, b[:40].split("\n")[0]) for i, t, b in db.execute("select id, title, substr(body, 1, 200) from notes where title like 'Huge %'")}
word = re.compile(rf"(?<!\w){QUERY}(?!\w)", re.I)
expected = [i for i, t, b in db.execute("select id, title, body from notes") if word.search(t) or word.search(b)]
db.close()
R = {"app": "Joplin 3.7.21", "steps": []}
def memory():
    """Physical footprint of all Joplin processes, MB (what Activity Monitor shows as Memory)."""
    pids = subprocess.run(["pgrep", "-f", "/Applications/Joplin.app/"], capture_output=True, text=True).stdout.split()
    total = 0.0
    for p in pids:
        o = subprocess.run(["footprint", "-p", p], capture_output=True, text=True).stdout
        m = re.search(r"phys_footprint:\s+([\d.]+)\s+(KB|MB|GB)", o)
        if m: total += float(m[1]) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m[2]]
    return round(total), len(pids)
def log(name, **kw):
    kw["step"] = name; kw["at"] = round(time.time(), 3); R["steps"].append(kw); print(json.dumps(kw, ensure_ascii=False), flush=True)

t0 = time.time()
subprocess.run(["open", "-n", "-a", "Joplin", "--args", "--profile", prof, "--remote-debugging-port=9222"])
j = Joplin(); j.t0 = t0
ready = j.until("document.querySelectorAll('.note-list-item').length > 0 && document.querySelector('.cm-content')", timeout=300)
log("launch", ready=round(ready), start=round(t0, 3))
time.sleep(10)
mb, n = memory(); log("memory_idle", mb=mb, processes=n)

title = "document.querySelector('.title-input').value"
def folder(name):
    find = f"[...document.querySelectorAll('.list-item-container')].find(e => e.innerText.split('\\n')[0] === {json.dumps(name)})"
    j.js("(() => { let e = document.querySelector('.list-item-container'); while (e && e.scrollHeight <= e.clientHeight + 1) e = e.parentElement; if (e) e.scrollTop = 0; })()")
    time.sleep(0.5)
    j.click(find)
    time.sleep(1.5)
def note_item(t): return f"[...document.querySelectorAll('.note-list-item')].find(e => e.querySelector('.title').innerText.trim() === {json.dumps(t)})"
def panes(): return j.js("[!!document.querySelector('.cm-editor')?.offsetParent, !!document.querySelector('.noteTextViewer')?.offsetParent]")
def layout(target):
    """Clicks “Toggle editor layout” (it cycles through the layouts) until the panes are `target` ([editor, viewer])."""
    state = lambda: "[!!document.querySelector('.cm-editor')?.offsetParent, !!document.querySelector('.noteTextViewer')?.offsetParent]"
    for _ in range(4):
        before = panes()
        if before == target: return
        j.start(); j.click("document.querySelector('button[title=\"Toggle editor layout\"]')")
        j.until(f"JSON.stringify({state()}) !== {json.dumps(json.dumps(before).replace(' ', ''))}")
def viewer_has(text, timeout=300):
    return j.until(f"(() => {{ const m = document.getElementById('rendered-md'); let e = m && m.lastElementChild; for (let i = 0; e && i < 4; i++, e = e.previousElementSibling) if (e.textContent.includes({json.dumps(text)})) return true; return false; }})()", "viewer", timeout)

layout([True, False])
folder("Notebook 00")
titles = j.js("[...document.querySelectorAll('.note-list-item .title')].map(e => e.innerText.trim()).slice(1, 21)")
times, freezes = [], []
for t in titles:
    j.start(); j.click(note_item(t))
    r = j.until(f"{title} === {json.dumps(t)} && document.querySelector('.cm-content').textContent.length > 0")
    if r is not None: times.append(r)
    freezes.append(j.freeze(0.3))
log("switch_notes", n=len(times), timeouts=len(titles) - len(times), median=round(statistics.median(times)), max=round(max(times)), freeze_max=max(freezes))

folder("Huge")
for name in ["Huge 1 MB", "Huge 5 MB", "Huge 20 MB"]:
    nid, head = huge[name]; mark = "STRESSEND " + name.replace(" ", "")
    layout([True, False])
    j.start(); j.click(note_item(name))
    r = j.until(f"{title} === {json.dumps(name)} && document.querySelector('.cm-content').textContent.includes({json.dumps(head[:20])})", timeout=300)
    log("open_editor", note=name, ready=r and round(r), freeze=j.freeze(), settled=j.settled)
    m = layout([True, True]); r2 = viewer_has(mark)
    log("to_split", note=name, ready=r2 and round(r2), freeze=j.freeze(), settled=j.settled)
    j.click("[...document.querySelectorAll('.cm-line')].find(e => { const r = e.getBoundingClientRect(); return r.top > 0 && r.bottom < innerHeight; })"); time.sleep(0.5)
    j.start(); j.key("ArrowDown", 4)
    r = j.until("[...document.querySelectorAll('.cm-line')].some(e => e.textContent.startsWith('STRESSEND'))")
    log("jump_end", note=name, ready=r and round(r), freeze=j.freeze(1.5), settled=j.settled)
    j.key("ArrowLeft"); time.sleep(1)
    lat = []; j.start()
    for ch in "abcde":
        s = time.time(); last_key = (s - j.t0) * 1000; j.type(ch); j.js("new Promise(r => requestAnimationFrame(() => r(0)))", 120); lat.append((time.time() - s) * 1000)
        time.sleep(0.25)
    r3 = viewer_has(name.replace(" ", "") + "abcde")  # from the last key, as StressProbe does
    log("typing_split", note=name, key_median=round(statistics.median(lat)), key_max=round(max(lat)),
        preview_updated=r3 and round(r3 - last_key), freeze=j.freeze(), settled=j.settled)
    layout([False, True]); r4 = viewer_has(name.replace(" ", "") + "abcde")
    log("to_preview", note=name, ready=r4 and round(r4), freeze=j.freeze(), settled=j.settled)
    layout([True, False])
    log("to_editor", note=name, ready=round((time.time() - j.t0) * 1000), freeze=j.freeze(), settled=j.settled)

layout([True, True])
for prev, name in [("Huge 20 MB", "Huge 1 MB"), ("Huge 1 MB", "Huge 5 MB"), ("Huge 5 MB", "Huge 20 MB")]:
    j.click(note_item(prev)); viewer_has("STRESSEND " + prev.replace(" ", "")); time.sleep(3)
    j.start(); j.click(note_item(name))
    r = viewer_has("STRESSEND " + name.replace(" ", ""))
    log("open_split", note=name, ready=r and round(r), freeze=j.freeze(2), settled=j.settled)

layout([True, True])
j.start(); j.click(note_item("Huge 5 MB")); viewer_has("STRESSEND Huge5MB"); time.sleep(3)
j.click("document.querySelector('input[placeholder^=\"Search\"]')"); time.sleep(0.5)
j.start()
for ch in QUERY:
    j.type(ch); time.sleep(0.2)
typed_end = (time.time() - j.t0) * 1000
exp = json.dumps(expected)
r = j.until(f"(() => {{ const s = new Set({exp}); const ids = [...document.querySelectorAll('.note-list-item')].map(e => e.dataset.id); return ids.length > 0 && ids.every(i => s.has(i)); }})()")
log("search_typing", query=QUERY, expected=len(expected), results_after_last_key=r and round(r - typed_end), freeze=j.freeze(1), settled=j.settled)
mb, n = memory(); log("memory_end", mb=mb, processes=n)
json.dump(R, open(out, "w"), ensure_ascii=False, indent=1)
