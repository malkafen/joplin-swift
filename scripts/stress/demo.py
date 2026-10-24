#!/usr/bin/env python3
import json, sys
F = ["Work", "Work/Projects", "Personal", "Personal/Travel", "Recipes", "Reading"]
N = [
("Work/Projects", "Release checklist", """Steps for every native revision. The tag mirrors the upstream Joplin version.

## Before tagging

- [x] Merge the pull request after CI is green
- [x] Run the stress test against Joplin Desktop
- [ ] Update the screenshots
- [ ] Write the release notes

## Timeline

```mermaid
graph LR
  A[Branch] --> B[Pull request]
  B --> C{CI green?}
  C -- yes --> D[Merge]
  C -- no --> A
  D --> E[Tag vX.Y.Z-N]
```

| Step | Owner | Status |
|:--|:--|:--:|
| Build | CI | ✅ |
| Notarize | Release | ⏳ |
| Announce | Team | — |
"""),
("Work/Projects", "Search architecture", """The note list uses **SQLite FTS5** with the `unicode61` tokenizer, so it works for any language.

> [!NOTE]
> Matches are drawn by the layout manager, only for the visible part of the note, so typing a query never edits the text.

```swift
let results = store.notes(filter: .search("value"), sort: .updated)
for note in results.prefix(3) {
    print(note.title, note.snippet)
}
```

Snippets are computed for the first results only: with a one-letter prefix nearly every note matches.

Complexity of the old snippet query: $O(n \\cdot m)$, where $n$ is the number of results and $m$ the size of the prefix list.
"""),
("Work", "Meeting notes — Q4 planning", """**Attendees:** design, sync, release

## Decisions

1. Keep the UI strictly native: no custom themes
2. Sync only with Joplin Server for now
3. Measure every performance change on the same dataset

## Action items

- [ ] Profile opening a 20 MB note in split
- [x] Make the note list titles-only by default
- [ ] Look at search in huge notes

==Next meeting: Thursday, 10:00==
"""),
("Work", "Interview questions", """- How would you find the slowest frame in a SwiftUI app?
- What does `allowsNonContiguousLayout` change in TextKit 1?
- When is a background render worth the complexity?
"""),
("Personal/Travel", "Kazan in November", """## Plan

| Day | Morning | Evening |
|:--|:--|:--|
| Fri | Arrive, Kremlin | Bauman street |
| Sat | Old Tatar quarter | Theatre |
| Sun | Sviyazhsk island | Train home |

## Packing

- [x] Passport
- [x] Tickets
- [ ] Warm gloves
- [ ] Charger

> Book the Sviyazhsk boat a day ahead.
"""),
("Personal/Travel", "Weekend in the mountains", """Trail notes and a gear list.

- [ ] Check the weather on Friday
- [ ] Pack the stove
"""),
("Personal", "Books to read", """1. *The Pragmatic Programmer*
2. *Designing Data-Intensive Applications*
3. *Crafting Interpreters*
"""),
("Personal", "Dentist", """Call on Monday to book a check-up.""", True),
("Recipes", "Borscht", """Serves 6. About 2 hours.

## Ingredients

| Ingredient | Amount |
|:--|--:|
| Beef on the bone | 600 g |
| Beetroot | 2 |
| Cabbage | ¼ head |
| Potatoes | 3 |
| Carrot, onion | 1 each |
| Tomato paste | 2 tbsp |

## Steps

1. Simmer the beef for an hour, skimming the foam.
2. Fry onion, carrot and beetroot with the tomato paste.
3. Add potatoes, then cabbage, then the fried vegetables.
4. Rest for 20 minutes. Serve with sour cream.
"""),
("Recipes", "Syrniki", """Cottage cheese pancakes.

- 500 g cottage cheese
- 1 egg
- 3 tbsp flour
- 1 tbsp sugar
"""),
("Reading", "Notes on TextKit", """TextKit 1 lays out text lazily when `allowsNonContiguousLayout` is on. Asking for the position of a far character lays out only the text around it; the rest is estimated.

Asking for the layout from the top makes positions exact, but on a 20 MB note it takes seconds.
"""),
]
out = sys.stdout
for f in F: out.write(json.dumps({"folder": f}) + "\n")
for n in N:
    out.write(json.dumps({"note": True, "folder": n[0], "title": n[1], "body": n[2], "todo": len(n) > 3}, ensure_ascii=False) + "\n")
