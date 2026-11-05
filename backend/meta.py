"""Thin client for the Meta Model API (https://api.meta.ai/v1).

Every call goes through `_post`, which records tokens and cost in the
CostMeter and refuses to run once the hard spending limit is reached.
"""

import base64
import json
import os
import re
import time

import httpx

from cost import meter

BASE = os.environ.get("META_API_BASE", "https://api.meta.ai/v1")
SPARK = os.environ.get("SPARK_MODEL", "muse-spark-1.3")
SAM = os.environ.get("SAM_MODEL", "sam-3.1")
ASR = os.environ.get("ASR_MODEL", "muse-voice-transcribe-1.0")


# Muse Spark Open (open weights) served by Baseten, an inference partner.
OPEN_BASE = os.environ.get("BASETEN_BASE", "https://inference.baseten.co/v1")
OPEN_MODEL = os.environ.get("OPEN_MODEL", "meta-models/muse-spark-open")


def meta_key():
    key = os.environ.get("META_API_KEY")
    if not key:
        raise RuntimeError("META_API_KEY is not set (put it in backend/.env)")
    return key


def open_available():
    return bool(os.environ.get("BASETEN_API_KEY"))


def data_url(jpeg_bytes):
    return "data:image/jpeg;base64," + base64.b64encode(jpeg_bytes).decode()


def _post(path, purpose, base=None, key=None, **kwargs):
    meter.check()
    t = time.time()
    headers = {"Authorization": f"Bearer {key or meta_key()}"}
    for attempt in range(3):  # retry dropped connections and timeouts, not API errors
        try:
            r = httpx.post((base or BASE) + path, headers=headers,
                           timeout=httpx.Timeout(45, connect=10), **kwargs)
            break
        except httpx.TransportError:
            if attempt == 2:
                raise
            time.sleep(1 + attempt)
    ms = int((time.time() - t) * 1000)
    if r.status_code >= 400:
        raise RuntimeError(f"{path} {r.status_code}: {r.text[:400]}")
    return r, ms


def _chat_json(purpose, system, user_text, images, schema, model, base, key, extra):
    """One chat call that must return JSON matching `schema`. The fixed system
    prompt goes first and images last, so prompt caching can reuse the prefix."""
    content = [{"type": "text", "text": user_text}]
    content += [{"type": "image_url", "image_url": {"url": data_url(b)}} for b in images]
    body = {
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}],
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": purpose, "schema": schema, "strict": True}},
        **extra,
    }
    r, ms = _post("/chat/completions", purpose, base=base, key=key, json=body)
    data = r.json()
    usage = data.get("usage", {})
    meter.add_tokens(purpose, model, usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0),
                     (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0), ms)
    text = data["choices"][0]["message"]["content"]
    return json.loads(text[text.find("{"):text.rfind("}") + 1])


def spark_json(purpose, system, user_text, images, schema, effort="low"):
    """Muse Spark 1.3 through the Meta Model API."""
    return _chat_json(purpose, system, user_text, images, schema, SPARK, BASE, None,
                      {"reasoning_effort": effort})


def open_json(purpose, system, user_text, images, schema):
    """Muse Spark Open (open weights) through Baseten. Falls back to Muse Spark
    1.3 when no Baseten key is configured, so the app keeps working."""
    if not open_available():
        return spark_json(purpose, system, user_text, images, schema)
    return _chat_json(purpose, system, user_text, images, schema, OPEN_MODEL, OPEN_BASE,
                      os.environ["BASETEN_API_KEY"], {"reasoning_effort": "low"})


def sam_boxes_from_points(jpeg_bytes, width, height, points):
    """Ask SAM 3.1 for the exact outline of each button, prompted with the
    pixel point Muse Spark gave. Returns {index: [x1, y1, x2, y2]} in pixels.
    Prompt grammar: <0f> (frame 0), the object id, then a point token.
    SAM takes at most 16 prompted objects per request, so we batch."""
    out = {}
    for start in range(0, len(points), 16):
        batch = points[start:start + 16]
        prompt = "".join(f"<0f>{i}<|point;x={x};y={y};w={width};h={height}|>" for i, (x, y) in enumerate(batch))
        body = {"model": SAM,
                "input": [{"role": "user", "content": [
                    {"type": "input_text", "text": prompt},
                    {"type": "input_image", "image_url": data_url(jpeg_bytes)}]}]}
        r, ms = _post("/responses", "segment", json=body)
        meter.add_images("segment", SAM, 1, ms)
        for obj_id, box in _parse_boxes(_response_text(r)).items():
            out[start + obj_id] = box
    return out


def _response_text(r):
    """SAM answers as text (one line per frame). Collect it whether the API
    returned a plain Responses object or a server-sent event stream."""
    try:
        data = r.json()
        parts = []
        for item in data.get("output", []):
            for c in item.get("content", []):
                parts.append(c.get("text", ""))
        return "\n".join(parts) or data.get("output_text", "")
    except json.JSONDecodeError:
        text = []
        for line in r.text.splitlines():
            if line.startswith("data:") and "delta" in line:
                try:
                    text.append(json.loads(line[5:]).get("delta", ""))
                except json.JSONDecodeError:
                    pass
        return "".join(text)


def _parse_boxes(text):
    """SAM answers one token run per object, e.g.
    <0f>0<|box;x1=775;y1=390;x2=857;y2=442;w=1024;h=766|><|mask;...|>
    Returns {object_id: [x1, y1, x2, y2]} in source pixels."""
    boxes = {}
    for m in re.finditer(r"(\d+)<\|box;x1=([\d.]+);y1=([\d.]+);x2=([\d.]+);y2=([\d.]+)", text):
        boxes.setdefault(int(m.group(1)), [round(float(v)) for v in m.groups()[1:]])
    return boxes


def transcribe(wav_bytes, keywords=()):
    """Spoken goal -> text with Muse Voice Transcribe (file mode). The panel's
    own button names are passed as keywords so "Defrost" isn't heard as "the frost"."""
    files = {"file": ("goal.wav", wav_bytes, "audio/wav")}
    data = {"model": ASR}
    if keywords:
        data["keywords"] = json.dumps(list(keywords)[:50])
    r, ms = _post("/asr/transcribe", "transcribe", files=files, data=data)
    j = r.json()
    seconds = len(wav_bytes) / (24000 * 2)
    meter.add_audio("transcribe", ASR, seconds, ms)
    return j.get("text") or j.get("transcript") or " ".join(s.get("text", "") for s in j.get("segments", []))
