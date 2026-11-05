"""End-to-end check against the real Meta API, without the phone.

    ../.venv/bin/python smoke.py ../tests/panels/microwave.jpg "heat for 2 minutes"

Prints what the Reader saw, the plan, and what everything cost.
"""

import json
import sys
import time

from dotenv import load_dotenv

load_dotenv()

import agents  # noqa: E402
from app import _prepare  # noqa: E402
from cost import meter  # noqa: E402


def main(path, goal):
    jpeg, w, h = _prepare(open(path, "rb").read())
    t = time.time()
    panel = agents.read_panel(jpeg, w, h)
    print(f"READ ({time.time() - t:.1f}s): {panel['device']} | display: {panel['display_text']!r} | "
          f"framing ok={panel['framing']['ok']} {panel['framing']['hint']!r}")
    for b in panel["buttons"]:
        print(f"  {b['id']:>4}  {b['label']:<22} {b['kind']:<6} {b['confidence']:<6} "
              f"box={[round(v) for v in b['box']]} ({b['box_source']})")
    if "sam_error" in panel:
        print("  SAM error:", panel["sam_error"])
    t = time.time()
    plan = agents.plan(panel, goal)
    print(f"\nPLAN ({time.time() - t:.1f}s): {plan['say']}")
    for s in plan["steps"]:
        print("  ->", s["button_id"], s["label"], "| expect:", s["expect_display"])
    t = time.time()
    v = agents.check(jpeg, jpeg, plan["steps"][0]) if plan["steps"] else None
    if v:
        print(f"\nCHECK same photo twice ({time.time() - t:.1f}s), should be retry/unsure: {json.dumps(v)}")
    print("\nCOST so far:", meter.summary())


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "heat for 2 minutes")
