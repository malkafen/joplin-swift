#!/usr/bin/env python3
"""Loads a JSON-lines dataset (from gen.py or demo.py) into a running Joplin Desktop through its local Data API.
Usage: load.py data.jsonl [token]. Notebooks are written as paths: "Work/Projects" goes inside "Work"."""
import json, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
API = "http://127.0.0.1:41184"
TOKEN = sys.argv[2] if len(sys.argv) > 2 else "stresstoken"
def post(path, obj):
    req = urllib.request.Request(f"{API}/{path}?token={TOKEN}", json.dumps(obj).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=600))
folders, notes = {}, []
for line in open(sys.argv[1]):
    d = json.loads(line)
    if "note" in d:
        notes.append(d)
        continue
    parent, _, title = d["folder"].rpartition("/")
    folders[d["folder"]] = post("folders", {"title": title, "parent_id": folders.get(parent, "")})["id"]
def add(d):
    post("notes", {"parent_id": folders[d["folder"]], "title": d["title"], "body": d["body"], "is_todo": int(d.get("todo", False))})
t = time.time()
small = [d for d in notes if len(d["body"]) < 1_000_000]
with ThreadPoolExecutor(4) as ex:
    for i, _ in enumerate(ex.map(add, small)):
        if i % 1000 == 999: print(i + 1, round(time.time() - t), "s", flush=True)
for d in notes:
    if len(d["body"]) < 1_000_000: continue
    s = time.time(); add(d); print(d["title"], round(time.time() - s, 1), "s", flush=True)
print("done", len(notes), "notes in", round(time.time() - t), "s")
