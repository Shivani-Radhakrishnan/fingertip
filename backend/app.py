"""Fingertip backend. The phone sends photos and audio; this server calls the
Meta models, keeps the API key off the phone and enforces the spending limit.

Run:  .venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000   (from backend/)
"""

import io
import json

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, File, Form, HTTPException, UploadFile, WebSocket  # noqa: E402
from PIL import Image  # noqa: E402

import agents  # noqa: E402
import memory  # noqa: E402
import meta  # noqa: E402
import voice  # noqa: E402
from cost import OverBudget, meter  # noqa: E402

app = FastAPI(title="Fingertip")
MAX_SIDE = 1024  # smaller images are cheaper and faster; buttons stay readable


def _prepare(upload_bytes):
    img = Image.open(io.BytesIO(upload_bytes)).convert("RGB")
    img.thumbnail((MAX_SIDE, MAX_SIDE))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    return buf.getvalue(), img.width, img.height


def _guard(fn, *args):
    try:
        return fn(*args)
    except OverBudget as e:
        raise HTTPException(402, str(e))
    except Exception as e:
        raise HTTPException(502, str(e)[:500])


@app.post("/read")
async def read(photo: UploadFile = File(...)):
    jpeg, w, h = _prepare(await photo.read())
    known = memory.recall(jpeg)
    if known:
        return {**known, "remembered": True}
    panel = _guard(agents.read_panel, jpeg, w, h)
    if panel["framing"]["ok"] and panel["buttons"]:
        memory.remember(jpeg, panel)
    return {**panel, "remembered": False}


@app.websocket("/listen")
async def listen(ws: WebSocket):
    """Hands-free goal: the phone streams 24 kHz PCM; first message is JSON with
    the panel's button labels. Replies with live events, then {"type":"final"}."""
    await ws.accept()
    try:
        first = json.loads(await ws.receive_text())
        text = await voice.relay(ws, first.get("keywords", []))
        await ws.send_json({"type": "final", "text": text})
    except Exception as e:
        await ws.send_json({"type": "error", "text": str(e)[:300]})
    finally:
        await ws.close()


@app.post("/plan")
async def plan(panel: str = Form(...), goal: str = Form(""), audio: UploadFile = File(None)):
    p = json.loads(panel)
    if audio is not None:
        labels = [b["label"] for b in p["buttons"]]
        goal = _guard(meta.transcribe, await audio.read(), labels)
    result = _guard(agents.plan, p, goal)
    result["heard"] = goal
    return result


@app.post("/check")
async def check(before: UploadFile = File(...), after: UploadFile = File(...), step: str = Form(...)):
    b, _, _ = _prepare(await before.read())
    a, _, _ = _prepare(await after.read())
    return _guard(agents.check, b, a, json.loads(step))


@app.get("/cost")
def cost():
    return meter.summary()
