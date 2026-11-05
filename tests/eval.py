"""Accuracy test over real panel photos.

Put photos in tests/panels/ (e.g. microwave.jpg). Optionally add a label file
next to each one, microwave.json, listing the buttons that are really there:

    {"buttons": [{"label": "Start", "icon": false}, {"label": "Defrost", "icon": true}]}

Run (from the repo root):  .venv/bin/python tests/eval.py

For every photo it saves tests/out/<name>.png with the boxes drawn (so you can
check the positions by eye) and prints, per panel and overall:
  - recall: share of labelled buttons the Reader found (by name)
  - icon recall: the same, only for icon-only buttons
  - extras: buttons the Reader reported that aren't in the label file
  - latency and cost per panel
Results are also written to tests/out/results.json for the README.
"""

import difflib
import glob
import json
import os
import sys
import time

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "backend"))
os.chdir(os.path.join(ROOT, "backend"))

from dotenv import load_dotenv  # noqa: E402

load_dotenv()

import agents  # noqa: E402
from app import _prepare  # noqa: E402
from cost import meter  # noqa: E402

SYNONYMS = {"start": ["start", "begin", "go", "play"], "stop": ["stop", "cancel", "clear", "pause"]}


def same(a, b):
    a, b = a.lower().strip(), b.lower().strip()
    if a == b or a in b or b in a:
        return True
    for words in SYNONYMS.values():
        if any(w in a for w in words) and any(w in b for w in words):
            return True
    return difflib.SequenceMatcher(None, a, b).ratio() > 0.8


def main():
    out_dir = os.path.join(ROOT, "tests", "out")
    os.makedirs(out_dir, exist_ok=True)
    photos = sorted(glob.glob(os.path.join(ROOT, "tests", "panels", "*.jp*g")))
    if not photos:
        print("No photos in tests/panels/")
        return
    totals = {"labelled": 0, "found": 0, "icons": 0, "icons_found": 0, "extras": 0}
    rows = []
    for path in photos:
        name = os.path.splitext(os.path.basename(path))[0]
        jpeg, w, h = _prepare(open(path, "rb").read())
        spend_before = meter.total
        t = time.time()
        try:
            panel = agents.read_panel(jpeg, w, h)
        except Exception as e:
            print(json.dumps({"panel": name, "error": str(e)[:200]}))
            continue
        secs = time.time() - t
        cost = meter.total - spend_before

        img = Image.open(path).convert("RGB")
        img.thumbnail((1024, 1024))
        draw = ImageDraw.Draw(img)
        for b in panel["buttons"]:
            x1, y1, x2, y2 = [v / 1000 * s for v, s in zip(b["box"], (w, h, w, h))]
            draw.rectangle([x1, y1, x2, y2], outline="lime" if b["box_source"] == "sam-3.1" else "orange", width=3)
            draw.text((x1 + 3, y1 + 3), b["label"][:18], fill="yellow")
        img.save(os.path.join(out_dir, name + ".png"))

        row = {"panel": name, "device": panel["device"], "buttons_found": len(panel["buttons"]),
               "seconds": round(secs, 1), "cost_usd": round(cost, 4),
               "sam_boxes": sum(b["box_source"] == "sam-3.1" for b in panel["buttons"])}
        label_path = os.path.splitext(path)[0] + ".json"
        if os.path.exists(label_path):
            truth = json.load(open(label_path))["buttons"]
            predicted = [b["label"] for b in panel["buttons"]]
            def hit(t, p):
                return any(same(n, p) for n in [t["label"]] + t.get("aliases", []))
            found = [t for t in truth if any(hit(t, p) for p in predicted)]
            icons = [t for t in truth if t.get("icon")]
            icons_found = [t for t in icons if t in found]
            extras = [p for p in predicted if not any(hit(t, p) for t in truth)]
            row.update({"labelled": len(truth), "found": len(found), "icons": len(icons),
                        "icons_found": len(icons_found), "extras": extras,
                        "missed": [t["label"] for t in truth if t not in found]})
            for k in ("labelled", "found", "icons", "icons_found"):
                totals[k] += row[k]
            totals["extras"] += len(extras)
        rows.append(row)
        print(json.dumps(row))

    summary = {"panels": len(rows), **totals,
               "recall": round(totals["found"] / totals["labelled"], 3) if totals["labelled"] else None,
               "icon_recall": round(totals["icons_found"] / totals["icons"], 3) if totals["icons"] else None,
               "avg_seconds": round(sum(r["seconds"] for r in rows) / len(rows), 1),
               "avg_cost_usd": round(sum(r["cost_usd"] for r in rows) / len(rows), 4)}
    print("\nSUMMARY", json.dumps(summary, indent=2))
    json.dump({"summary": summary, "panels": rows}, open(os.path.join(out_dir, "results.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
