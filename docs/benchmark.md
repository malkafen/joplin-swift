# Stress test: Joplin Native vs Joplin Desktop

Both apps get the same library and go through the same steps, driven by scripts rather than by hand. The scripts are in
[`scripts/stress`](../scripts/stress), and the raw results are in [`benchmark/`](benchmark).

<img src="huge-note.png" alt="Joplin Native with the 20 MB note open in split: 270 596 lines, 20 million characters" width="860">

## Setup

- macOS 27.0.1 in a VM on an Apple M4 Pro host, 8 cores, 8 GB of memory.
- Joplin Desktop 3.7.21 (the official Electron app, as shipped, with its default plugins) and Joplin Native 3.7.21-15 and
  3.7.21-16. 3.7.21-16 has the fixes this test led to (see below).
- One library, imported into both apps: 50 notebooks with **10 000 notes** of 0.5–6 KB (Markdown in Russian and English
  with lists, tables and code), plus notes of **1 MB, 5 MB and 20 MB** (13 000, 68 000 and 270 000 lines).
  [`gen.py`](../scripts/stress/gen.py) is seeded, so every run gets the same text.
- Joplin Desktop gets a profile of its own. It is driven through the Chrome DevTools Protocol like a user would drive
  it, with real mouse clicks and key events ([`jbench.py`](../scripts/stress/jbench.py)). Joplin Native runs the
  same steps from inside the app ([`StressProbe.swift`](../Sources/JoplinNative/StressProbe.swift)).
- The apps ran one after the other, never at the same time. Joplin Desktop ran twice, Joplin Native 3.7.21-16 three
  times. The table shows the medians.

## What is measured

- **Time**: from the action until its result is on screen, for example until the preview shows the last line of the
  note.
- **Longest freeze**: the longest time the app could not respond, in the same window. For Joplin Desktop this is the
  longest gap between painted frames in the main window or the note viewer. For Joplin Native it is the longest
  main-thread run loop pass. Above about 1 s, macOS shows the spinning cursor.

A long time with a short freeze is fine: the app renders in the background and stays responsive. A long freeze is not.

## Results

| | Joplin Desktop 3.7.21 | Native 3.7.21-15 | Native 3.7.21-16 |
|:--|--:|--:|--:|
| Launch to the note list (10 000 notes) | 2.3 s | 2.7 s | 1.1 s |
| Memory after launch | 640 MB | 138 MB | 131 MB |
| Open an ordinary note (median of 20) | 52 ms | 47 ms | 46 ms |
| — longest freeze | 34 ms | 53 ms | 59 ms |
| **1 MB note** — open in the editor | 9 ms | < 5 ms | < 5 ms |
| — longest freeze | 24 ms | < 5 ms | < 5 ms |
| Open straight in split, preview shown | 16.0 s | 8.8 s | 705 ms |
| — longest freeze | 6.7 s | 8.7 s | 536 ms |
| Editor → split, preview shown | 664 ms | 293 ms | 304 ms |
| — longest freeze | 536 ms | 76 ms | 71 ms |
| Jump to the end (⌘↓) in split | 123 ms | 483 ms | 68 ms |
| — longest freeze | 78 ms | 488 ms | 73 ms |
| Keystroke in split (median of 5) | 72 ms | 14 ms | 10 ms |
| — slowest keystroke | 78 ms | 18 ms | 14 ms |
| Preview catches up after typing | 698 ms | 344 ms | 396 ms |
| — longest freeze while it does | 253 ms | 63 ms | 60 ms |
| Split → preview only | 30 ms | < 5 ms | < 5 ms |
| — longest freeze | 271 ms | 38 ms | 75 ms |
| **5 MB note** — open in the editor | 239 ms | 107 ms | 88 ms |
| — longest freeze | 180 ms | 87 ms | 70 ms |
| Open straight in split, preview shown | 4.1 s | 1.3 s | 1.3 s |
| — longest freeze | 1.7 s | 68 ms | 69 ms |
| Editor → split, preview shown | 2.1 s | 1.3 s | 1.3 s |
| — longest freeze | 1.2 s | 91 ms | 82 ms |
| Jump to the end (⌘↓) in split | 7.2 s | 2.4 s | 55 ms |
| — longest freeze | 7.3 s | 2.4 s | 60 ms |
| Keystroke in split (median of 5) | 206 ms | 25 ms | 27 ms |
| — slowest keystroke | 210 ms | 29 ms | 28 ms |
| Preview catches up after typing | 2.6 s | 3.8 s | 3.0 s |
| — longest freeze while it does | 1.4 s | 236 ms | 242 ms |
| Split → preview only | 124 ms | < 5 ms | < 5 ms |
| — longest freeze | 542 ms | 35 ms | 59 ms |
| **20 MB note** — open in the editor | 261 ms | 214 ms | 195 ms |
| — longest freeze | 327 ms | 148 ms | 129 ms |
| Open straight in split, preview shown | 14.3 s | 5.0 s | 5.0 s |
| — longest freeze | 6.2 s | 108 ms | 121 ms |
| Editor → split, preview shown | 12.0 s | 5.1 s | 5.1 s |
| — longest freeze | 6.9 s | 179 ms | 174 ms |
| Jump to the end (⌘↓) in split | 33.5 s | 10.7 s | 79 ms |
| — longest freeze | 33.5 s | 10.7 s | 82 ms |
| Keystroke in split (median of 5) | 953 ms | 101 ms | 103 ms |
| — slowest keystroke | 2.8 s | 193 ms | 188 ms |
| Preview catches up after typing | 24.3 s | 15.1 s | 15.1 s |
| — longest freeze while it does | 17.3 s | 973 ms | 983 ms |
| Split → preview only | 5.6 s | < 5 ms | < 5 ms |
| — longest freeze | 3.7 s | 71 ms | 76 ms |
| **Search** «значение» typed letter by letter, 5 MB note open in split: longest freeze | 700 ms | 49.1 s | 439 ms |
| — results after the last key | 25 ms | < 5 ms | < 5 ms |
| Memory at the end | 7 786 MB | 201 MB | 444 MB |

“Keystroke” is the time until the frame with the typed character is painted. “Preview catches up” counts from the last
key until the preview shows the new text.

Memory is the physical footprint of all the app's processes, which is what Activity Monitor shows: 7 processes for Joplin
Desktop, 1 for Joplin Native. At the end, the 5 MB note is open in split. How much of a huge note's layout TextKit keeps
in memory varies: running only the 20 MB steps ends at 1.2 GB with 3.7.21-15 and at 0.7 GB with 3.7.21-16.

## What we learned

**Where Joplin Native is far ahead.** With huge notes, Joplin Desktop freezes for seconds at a time:
- 34 s on ⌘↓ in the 20 MB note;
- 17 s while the preview re-renders after typing;
- 6–7 s on opening the note in split.

Its memory grows to 7.7 GB. Joplin Native keeps the UI responsive in all of these: the longest freeze is under 1 s, and
under 0.2 s for most steps. In split, a keystroke takes 0.1 s on 20 MB, against 1–3 s.

**Where the test caught Joplin Native.** Three bugs, all fixed in 3.7.21-16:
- **Search typed letter by letter froze for 49 s.** The cause was not the open huge note. The search snippets were
  computed with a correlated `snippet()` query, which expanded the prefix again for every row. After the first letter,
  «з*» matches all 10 000 notes, so that alone took 53 s in SQLite. Now one query computes snippets only for the first
  200 results, a one- or two-letter prefix keeps the start of the note, and snippets are cleaned only for the rows on
  screen. The freeze is down to 0.4 s, and launch with 10 000 notes went from 2.7 s to 1.1 s.
- **⌘↓ in a huge note in split froze for 2.4 s on 5 MB and 10.7 s on 20 MB.** The preview followed the editor by first
  laying out its text from the top. Previews over 300 000 characters now lay out only the block they scroll to: it shows
  where TextKit's estimate puts it.
- **Opening a 1 MB note right after the 20 MB one froze for 8.7 s**, for the same reason. It is now 0.5 s.

**Where Joplin Native is still slower.** These are small, and none freezes the UI:
- On 5 MB, the preview catches up after typing in 3.0 s against 2.6 s.
- On 20 MB, the first preview takes 5 s. It renders in the background without freezing the UI. Joplin Desktop takes 12–14 s
  and freezes for 6–7 s.
- Opening an ordinary note freezes for up to 59 ms against 34 ms. Both are below what anyone notices.

## Run it yourself

On a Mac with `/Applications/Joplin.app` installed:

```bash
scripts/build-app.sh
scripts/stress/run.sh          # RUNS=3 by default; data and results go to /tmp/stress
```

It takes about 30 minutes per Joplin Desktop run. Your own Joplin profile is not touched.
