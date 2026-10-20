#!/usr/bin/env python3
"""Generates the stress dataset as JSON lines: 50 notebooks of 10 000 ordinary notes, and notes of 1, 5 and 20 MB that
end with a marker, so a driver can tell when a preview has rendered all of it. Seeded: every run writes the same data."""
import json, random, sys
random.seed(42)
RU = ("значение система данные процесс работа проект время задача решение функция модель сервер клиент запрос ответ "
      "память поиск заметка файл строка таблица список ключ индекс версия обновление ошибка результат пример настройка").split()
EN = ("value system data process work project time task solution function model server client request response "
      "memory search note file line table list key index version update error result example setting").split()
def words(n, hit=0.0):
    out = []
    for _ in range(n):
        w = random.choice(RU if random.random() < .6 else EN)
        if w == "значение" and random.random() > hit: w = "смысл"
        out.append(w)
    return out
def para(n=40, hit=0.0):
    w = words(n, hit); w[0] = w[0].capitalize()
    if random.random() < .3: i = random.randrange(len(w)); w[i] = f"**{w[i]}**"
    if random.random() < .2: i = random.randrange(len(w)); w[i] = f"[{w[i]}](https://example.com/{w[i]})"
    return " ".join(w) + "."
def block(hit):
    r = random.random()
    if r < .55: return para(random.randint(20, 80), hit)
    if r < .7: return "\n".join(f"- {para(random.randint(4, 12), hit)}" for _ in range(random.randint(2, 6)))
    if r < .8: return f"## {' '.join(words(3)).capitalize()}"
    if r < .9:
        rows = ["| " + " | ".join(words(4)) + " |", "|---|---|---|---|"]
        rows += ["| " + " | ".join(words(4, hit)) + " |" for _ in range(random.randint(3, 12))]
        return "\n".join(rows)
    return "```swift\n" + "\n".join(f"let {random.choice(EN)}{i} = {random.randint(0, 999)} // {' '.join(words(4))}" for i in range(random.randint(3, 15))) + "\n```"
def body(size, hit):
    parts, n = [], 0
    while n < size:
        b = block(hit); parts.append(b); n += len(b) + 2
    return "\n\n".join(parts)
out = sys.stdout
folders = [f"Notebook {i:02d}" for i in range(50)] + ["Huge"]
for f in folders: out.write(json.dumps({"folder": f}) + "\n")
for i in range(10000):
    out.write(json.dumps({"note": True, "folder": folders[i % 50], "title": f"{' '.join(words(4)).capitalize()} {i}",
                          "body": body(random.randint(500, 6000), .03)}, ensure_ascii=False) + "\n")
for name, size in [("Huge 1 MB", 1_000_000), ("Huge 5 MB", 5_000_000), ("Huge 20 MB", 20_000_000)]:
    marker = "STRESSEND " + name.replace(" ", "")
    out.write(json.dumps({"note": True, "folder": "Huge", "title": name, "body": body(size, .02) + f"\n\n{marker}\n"}, ensure_ascii=False) + "\n")
