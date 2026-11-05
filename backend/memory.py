"""Device memory: a panel seen before is recognised instantly, at no cost.

Each successful read is stored with a 64-bit difference hash of the photo.
A new photo that is almost identical (same device, same phone position on the
stand) reuses the stored reading, so the button positions are still valid.
"""

import io
import json
import os

from PIL import Image

PATH = os.path.join(os.path.dirname(__file__), "devices.json")
MAX_DISTANCE = 6  # bits out of 64; tight on purpose so stale positions are never reused


def dhash(jpeg):
    img = Image.open(io.BytesIO(jpeg)).convert("L").resize((9, 8))
    px = list(img.getdata())
    bits = 0
    for row in range(8):
        for col in range(8):
            bits = (bits << 1) | (px[row * 9 + col] > px[row * 9 + col + 1])
    return bits


def _load():
    return json.load(open(PATH)) if os.path.exists(PATH) else []


def recall(jpeg):
    h = dhash(jpeg)
    best = None
    for entry in _load():
        d = bin(h ^ entry["hash"]).count("1")
        if d <= MAX_DISTANCE and (best is None or d < best[0]):
            best = (d, entry["panel"])
    return best[1] if best else None


def remember(jpeg, panel):
    entries = _load()
    entries.append({"hash": dhash(jpeg), "panel": panel})
    json.dump(entries[-50:], open(PATH, "w"))
