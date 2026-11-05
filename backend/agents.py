"""The three Muse Spark agents: Reader, Planner and Critic.

Each one returns strict JSON so the next stage (and the phone) can act on it
without parsing prose. Coordinates use Muse Spark's 0-1000 grid, origin top-left.
"""

import meta

READER_SYSTEM = """You read appliance and kiosk control panels for blind users.
List EVERY pressable control you can see: physical buttons, touch keys, icons, dials.
`label` is the control's short name, 1-3 words, as a user would say it (e.g. "Start", "Defrost", "3h delay").
`meaning` is what it does; for icon-only controls, explain the icon (e.g. "snowflake icon: defrost").
Give each control's center point and bounding box on a 0-1000 grid (x right, y down, origin top-left).
Never invent controls you cannot see. If the panel is cut off, blurry, too far or too close,
set framing.ok=false and give ONE short fix the user can do without seeing (e.g. "move the phone left").
Read any text on the display exactly."""

READER_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["device", "display_text", "framing", "buttons"],
    "properties": {
        "device": {"type": "string"},
        "display_text": {"type": "string"},
        "framing": {"type": "object", "additionalProperties": False, "required": ["ok", "hint"],
                    "properties": {"ok": {"type": "boolean"}, "hint": {"type": "string"}}},
        "buttons": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["id", "label", "meaning", "kind", "x", "y", "box", "confidence"],
            "properties": {
                "id": {"type": "string"},
                "label": {"type": "string"},
                "meaning": {"type": "string"},
                "kind": {"type": "string", "enum": ["text", "icon", "number", "dial"]},
                "x": {"type": "number"}, "y": {"type": "number"},
                "box": {"type": "array", "items": {"type": "number"}},
                "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
            }}},
    },
}

PLANNER_SYSTEM = """You plan which controls a blind user should press to reach their goal on THIS panel.
Use only controls from the given list, by id, in order. Repeat a step if it must be pressed several times.
Prefer the fewest presses. If the goal is impossible with these controls, set feasible=false and explain briefly.
SAFETY: a blind person will press exactly what you say. Never guess what an unreadable or unlabelled control does.
If a control you would need has an unknown label or low confidence, set feasible=false and tell the user how to
get a clearer view instead (e.g. "I can't read the buttons. Move the phone closer.").
`say` is what the phone speaks: short and plain, e.g. "2 presses: 2 minutes, then Start."
`expect_display` is what the display should show after that step (empty if unknown)."""

PLANNER_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["feasible", "say", "steps"],
    "properties": {
        "feasible": {"type": "boolean"},
        "say": {"type": "string"},
        "steps": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["button_id", "label", "expect_display"],
            "properties": {"button_id": {"type": "string"}, "label": {"type": "string"},
                           "expect_display": {"type": "string"}}}},
    },
}

CRITIC_SYSTEM = """You check whether a blind user's button press worked.
You get the panel BEFORE and AFTER the press, the button they were meant to press, and what the display should show.
Compare the two images, especially the display. Decide:
- "ok": the expected change happened (or the press clearly registered if no display change is expected).
- "retry": nothing changed; the press probably missed.
- "wrong": a different change happened (wrong button). Say how to undo it if you can.
- "unsure": you cannot tell (glare, hand in the way, display hidden).
`say` is one short sentence for the user, e.g. "Display shows 2:00." or "That didn't register. Press again."""

CRITIC_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["verdict", "display_text", "say"],
    "properties": {
        "verdict": {"type": "string", "enum": ["ok", "retry", "wrong", "unsure"]},
        "display_text": {"type": "string"},
        "say": {"type": "string"},
    },
}


def read_panel(jpeg, width, height):
    panel = meta.spark_json("reader", READER_SYSTEM, "Read this control panel.", [jpeg], READER_SCHEMA, effort="minimal")
    # Refine each button's box with SAM 3.1, prompted by the point Muse Spark gave.
    pts = [(round(b["x"] / 1000 * width), round(b["y"] / 1000 * height)) for b in panel["buttons"]]
    try:
        sam = meta.sam_boxes_from_points(jpeg, width, height, pts) if pts else {}
    except Exception as e:  # keep working with Spark's boxes if SAM is unavailable
        sam, panel["sam_error"] = {}, str(e)[:200]
    for i, b in enumerate(panel["buttons"]):
        if i in sam:
            x1, y1, x2, y2 = sam[i]
            b["box"] = [x1 / width * 1000, y1 / height * 1000, x2 / width * 1000, y2 / height * 1000]
            b["box_source"] = "sam-3.1"
        else:
            b["box_source"] = "muse-spark"
    return panel


def plan(panel, goal):
    controls = "\n".join(f'{b["id"]}: {b["label"]} ({b["kind"]}, confidence {b["confidence"]})' for b in panel["buttons"])
    text = f'Device: {panel["device"]}\nDisplay now: "{panel["display_text"]}"\nControls:\n{controls}\n\nGoal: {goal}'
    return meta.spark_json("planner", PLANNER_SYSTEM, text, [], PLANNER_SCHEMA, effort="low")


def check(before, after, step):
    text = f'Button meant to be pressed: {step["label"]}\nExpected display after: "{step.get("expect_display", "")}"'
    # The Critic runs on Muse Spark Open (open weights, via Baseten) when configured.
    return meta.open_json("critic", CRITIC_SYSTEM, text + "\nImage 1 = BEFORE, image 2 = AFTER.",
                          [before, after], CRITIC_SCHEMA)
