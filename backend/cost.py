"""Cost meter with a hard stop.

Meta's billing page can only email a warning, so the backend enforces its own
limit: once estimated spend reaches HARD_LIMIT_USD every model call is refused.
Every call is also logged (tokens, cost, latency) for the README numbers.
"""

import json
import os
import threading
import time

# Published prices (USD), from dev.meta.ai/models.
PRICES = {
    "muse-spark-1.3": {"in": 1.25 / 1e6, "cached": 0.15 / 1e6, "out": 4.25 / 1e6},
    # Baseten's listed price for Muse Spark Open; billed to Baseten credits, not Meta.
    "meta-models/muse-spark-open": {"in": 1.25 / 1e6, "cached": 0.15 / 1e6, "out": 4.25 / 1e6},
    "sam-3.1": {"image": 2.50 / 1000},
    "muse-voice-transcribe-1.0": {"hour": 0.18},
}
HARD_LIMIT_USD = float(os.environ.get("HARD_LIMIT_USD", "120"))
LOG = os.path.join(os.path.dirname(__file__), "calls.jsonl")


class OverBudget(RuntimeError):
    pass


class CostMeter:
    def __init__(self):
        self.lock = threading.Lock()
        self.total = 0.0
        if os.path.exists(LOG):
            for line in open(LOG):
                self.total += json.loads(line).get("cost_usd", 0)

    def check(self):
        if self.total >= HARD_LIMIT_USD:
            raise OverBudget(f"spend ${self.total:.2f} reached the ${HARD_LIMIT_USD:.0f} limit")

    def _log(self, row):
        with self.lock:
            self.total += row["cost_usd"]
            with open(LOG, "a") as f:
                f.write(json.dumps(row) + "\n")

    def add_tokens(self, purpose, model, tin, tout, cached, ms):
        p = PRICES.get(model, PRICES["muse-spark-1.3"])
        cost = (tin - cached) * p["in"] + cached * p["cached"] + tout * p["out"]
        self._log({"t": time.time(), "purpose": purpose, "model": model, "in": tin, "out": tout,
                   "cached": cached, "ms": ms, "cost_usd": round(cost, 6)})

    def add_images(self, purpose, model, n, ms):
        self._log({"t": time.time(), "purpose": purpose, "model": model, "images": n, "ms": ms,
                   "cost_usd": round(n * PRICES[model]["image"], 6)})

    def add_audio(self, purpose, model, seconds, ms):
        self._log({"t": time.time(), "purpose": purpose, "model": model, "seconds": round(seconds, 1),
                   "ms": ms, "cost_usd": round(seconds / 3600 * PRICES[model]["hour"], 6)})

    def summary(self):
        return {"total_usd": round(self.total, 4), "limit_usd": HARD_LIMIT_USD}


meter = CostMeter()
