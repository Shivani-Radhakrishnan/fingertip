"""Live, hands-free goal capture with Muse Voice Transcribe.

The phone streams raw audio to /listen on this backend; we relay it to Meta's
realtime endpoint in ENDPOINTING mode, which detects when the user starts and
stops talking. Recognition is biased toward this panel's button names.
The API key never leaves the backend.
"""

import asyncio
import json
import os
import time

import websockets

from cost import meter
from meta import ASR, meta_key

REALTIME_URL = os.environ.get("ASR_REALTIME_URL", "wss://api.meta.ai/v1/asr/realtime")


def _text_of(event):
    for k in ("transcript", "text"):
        v = event.get(k)
        if isinstance(v, str):
            return v
        if isinstance(v, dict) and isinstance(v.get("text"), str):
            return v["text"]
    return ""


async def relay(phone_ws, keywords):
    """Relay audio phone -> Meta and events Meta -> phone until speech is complete.
    Returns the final transcript."""
    meter.check()
    started = time.time()
    async with websockets.connect(REALTIME_URL, max_size=None) as meta_ws:
        await meta_ws.send(json.dumps({
            "authorization": {"accessToken": meta_key()},
            "model": ASR,
            "mode": "ENDPOINTING",
            "audioEncoding": "PCM_24KHZ",
            "keywords": list(keywords)[:50],
        }))
        final = {"text": ""}

        async def phone_to_meta():
            while True:
                msg = await phone_ws.receive()
                if msg.get("bytes"):
                    await meta_ws.send(msg["bytes"])
                elif msg.get("text") == "end" or msg.get("type") == "websocket.disconnect":
                    await meta_ws.send(json.dumps({"type": "endStream"}))
                    return

        async def meta_to_phone():
            async for raw in meta_ws:
                if isinstance(raw, bytes):
                    continue
                event = json.loads(raw)
                kind = event.get("type") or event.get("event") or ""
                text = _text_of(event)
                if text:
                    final["text"] = text
                await phone_ws.send_json({"type": kind, "text": text})
                if kind in ("speechComplete", "final", "endStream"):
                    return

        sender = asyncio.create_task(phone_to_meta())
        try:
            await asyncio.wait_for(meta_to_phone(), timeout=30)
        finally:
            sender.cancel()
    meter.add_audio("transcribe-live", ASR, time.time() - started, int((time.time() - started) * 1000))
    return final["text"]
