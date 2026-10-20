#!/usr/bin/env python3
"""Drives the official Joplin client through CDP like a user: real mouse clicks and key events.
Each step reports `ready` (ms until the expected result is on screen) and `freeze` (longest gap between painted frames
in the main window or the note viewer, i.e. the longest time the UI could not respond)."""
import time
from cdp import CDP
HARNESS = r"""
(() => {
 if (window.__p) return 'ok';
 const p = window.__p = {frames: []};
 const loop = () => { p.frames.push(performance.now()); if (p.frames.length > 50000) p.frames.splice(0, 25000); requestAnimationFrame(loop); };
 requestAnimationFrame(loop);
 p.rect = e => { if (!e) return null; e.scrollIntoView({block: 'nearest'}); const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; };
 // Longest gap between frames since `since` (ms ago); a gap still running counts up to now.
 p.freeze = since => { const t0 = performance.now() - since, fr = p.frames.filter(f => f >= t0); let gap = 0, prev = t0;
   for (const f of fr) { gap = Math.max(gap, f - prev); prev = f; } return gap; };
 // End of the last gap over 100 ms since `since` ms ago, relative to that moment.
 p.settled = since => { const t0 = performance.now() - since, fr = p.frames.filter(f => f >= t0); let end = 0, prev = t0;
   for (const f of fr) { if (f - prev > 100) end = f - t0; prev = f; } return end; };
 return 'installed';
})()
"""
KEYS = {"ArrowDown": 40, "ArrowLeft": 37, "ArrowUp": 38, "Escape": 27, "Backspace": 8, "Enter": 13}
class Joplin:
    def __init__(self):
        for _ in range(120):
            try:
                self.main = CDP(); break
            except Exception: time.sleep(1)
        self.main.eval(HARNESS)
        self._viewer = None
    @property
    def viewer(self):
        if self._viewer is None:
            self._viewer = CDP(match=lambda p: "note-viewer" in p.get("url", ""))
            self._viewer.eval(HARNESS)
        return self._viewer
    def js(self, s, timeout=600): return self.main.eval(s, timeout)
    def vjs(self, s, timeout=600):
        """Evaluates in the note viewer; Joplin recreates its frame, so a broken connection is opened again."""
        try:
            return self.viewer.eval(s, timeout)
        except (OSError, EOFError, StopIteration, ValueError):
            self._viewer = None
            return self.viewer.eval(s, timeout)
    def click(self, el_js):
        xy = self.js(f"window.__p.rect({el_js})")
        if not xy: raise RuntimeError("no element " + el_js)
        for t in ("mousePressed", "mouseReleased"):
            self.main.call("Input.dispatchMouseEvent", type=t, x=xy[0], y=xy[1], button="left", clickCount=1)
    def key(self, key, mods=0):
        vk = KEYS[key]
        self.main.call("Input.dispatchKeyEvent", type="rawKeyDown", key=key, code=key, windowsVirtualKeyCode=vk, modifiers=mods)
        self.main.call("Input.dispatchKeyEvent", type="keyUp", key=key, code=key, windowsVirtualKeyCode=vk, modifiers=mods)
    def type(self, text): self.main.call("Input.insertText", text=text)
    def until(self, cond, where="main", timeout=180):
        """Polls `cond` (JS) until true; returns ms since `self.t0` or None on timeout."""
        f = self.js if where == "main" else self.vjs
        while True:
            try:
                if f(f"(() => {{ try {{ return !!({cond}); }} catch (e) {{ return false; }} }})()", 30): return (time.time() - self.t0) * 1000
            except Exception:
                if where != "main": self._viewer = None
            if time.time() - self.t0 > timeout: return None
            time.sleep(0.01)
    def start(self): self.t0 = time.time()
    def freeze(self, settle=0.5):
        """Longest frame gap since the mark; also stores `self.settled`, when the last gap over 100 ms ended."""
        time.sleep(settle)
        since = (time.time() - self.t0) * 1000 + 50
        m = self.js(f"[window.__p.freeze({since}), window.__p.settled({since})]")
        # A hidden viewer paints no frames, so it only counts while it is visible.
        visible = self.js("!!document.querySelector('.noteTextViewer')?.offsetParent")
        try: v = self.vjs(f"[window.__p.freeze({since}), window.__p.settled({since})]") if visible else [0, 0]
        except Exception: v = [0, 0]
        self.settled = round(max(m[1], v[1]) - 50) if max(m[1], v[1]) else 0
        return round(max(m[0], v[0]))
