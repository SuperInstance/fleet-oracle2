#!/usr/bin/env python3
"""
gamma-predictor.py — Predictive gamma scheduling for Oracle2.

Fetches the gamma trend (30 samples) from the conservation meter,
fits a 3-point moving average, computes the rate of change (derivative),
and emits predictions:

  - SPIKE if γ > 850 AND dγ/dt > +15/sample
  - DIP   if γ < 740 AND dγ/dt < -10/sample

Outputs JSON to stdout and appends to the prediction log.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ─── Configuration ──────────────────────────────────────────────────────────

CONSERVATION_URL = "http://localhost:8798/api/status"
LOG_PATH = Path(
    os.environ.get(
        "GAMMA_PREDICTOR_LOG",
        "/home/ubuntu/.openclaw/workspace/construct/logs/gamma-predictions.log",
    )
)
# Moving average window
MA_WINDOW = 3
# Spike threshold
GAMMA_SPIKE_THRESHOLD = 850
DGAMMA_SPIKE_THRESHOLD = 15  # per sample
# Dip threshold
GAMMA_DIP_THRESHOLD = 740
DGAMMA_DIP_THRESHOLD = -10  # per sample


# ─── Helpers ─────────────────────────────────────────────────────────────────


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def moving_average(data: list[float], window: int) -> list[float]:
    """Simple N-point moving average (padded with None at the front)."""
    if len(data) < window:
        return data  # not enough data
    result: list[float] = []
    for i in range(len(data)):
        if i < window - 1:
            result.append(float(data[i]))
        else:
            result.append(sum(data[i - window + 1 : i + 1]) / window)
    return result


def rate_of_change(smoothed: list[float]) -> float:
    """Compute the latest dγ/dt from the smoothed series.
    Uses the difference between the two most recent smoothed values.
    Returns 0.0 if insufficient data.
    """
    if len(smoothed) < 2:
        return 0.0
    return smoothed[-1] - smoothed[-2]


def raw_delta(trend: list[float]) -> float:
    """Raw single-step delta (fastest reaction)."""
    if len(trend) < 2:
        return 0.0
    return trend[-1] - trend[-2]


def avg_recent_delta(trend: list[float], n: int = 3) -> float:
    """Average of the last N raw deltas."""
    if len(trend) < 2:
        return 0.0
    deltas = [trend[i] - trend[i - 1] for i in range(max(1, len(trend) - n), len(trend))]
    return sum(deltas) / len(deltas) if deltas else 0.0


# ─── Main ────────────────────────────────────────────────────────────────────


def fetch_gamma_trend() -> list[float] | None:
    """Fetch the gamma_trend from the conservation meter API."""
    import urllib.request

    try:
        req = urllib.request.Request(
            CONSERVATION_URL,
            headers={"Accept": "application/json"},
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        trend = data.get("gamma_trend")
        if not isinstance(trend, list) or len(trend) == 0:
            print(
                json.dumps(
                    {
                        "error": f"Invalid gamma_trend from API: {type(trend).__name__}",
                        "raw_sample": str(trend)[:200] if trend else "null",
                    }
                ),
                file=sys.stderr,
            )
            return None
        return [float(v) for v in trend]
    except Exception as e:
        print(
            json.dumps({"error": f"Failed to fetch gamma trend: {e}"}),
            file=sys.stderr,
        )
        return None


def predict(trend: list[float]) -> dict:
    """Run the prediction algorithm on the gamma trend.

    The trend is stored NEWEST-FIRST (index 0 = current).
    We convert to chronological order for prediction logic.
    """
    raw_len = len(trend)
    # Convert to chronological (oldest first) for prediction
    chrono = list(reversed(trend))
    smoothed = moving_average(chrono, MA_WINDOW)
    dgdt = rate_of_change(smoothed)
    raw_dgdt = raw_delta(chrono)
    current_gamma = chrono[-1] if chrono else 0.0

    prediction = "NONE"
    alert_priority = 0

    # Decision logic: use smoothed+raw combo for detection
    # SPIKE: γ > 850 AND (smoothed rising > 15/sample OR raw jump > 40/sample)
    if current_gamma > GAMMA_SPIKE_THRESHOLD and (
        dgdt > DGAMMA_SPIKE_THRESHOLD or raw_dgdt > 40
    ):
        prediction = "SPIKE"
        alert_priority = 1
    # DIP: γ < 740 AND (smoothed falling < -10/sample OR raw drop < -30/sample)
    elif current_gamma < GAMMA_DIP_THRESHOLD and (
        dgdt < DGAMMA_DIP_THRESHOLD or raw_dgdt < -30
    ):
        prediction = "DIP"
        alert_priority = 1
    elif current_gamma > 900:
        # Sustained high gamma — near-spike advisory
        prediction = "HIGH_PLATEAU"
        alert_priority = 2

    # Calculate expected gamma (extrapolate 3 steps ahead)
    expected_gamma = current_gamma
    if len(chrono) >= 2:
        avg_delta = avg_recent_delta(chrono, 3)
        expected_gamma = round(current_gamma + avg_delta * 3, 1)

    result = {
        "timestamp": now_iso(),
        "prediction": prediction,
        "alert_priority": alert_priority,
        "current_gamma": int(round(current_gamma)),
        "expected_gamma": int(round(expected_gamma)),
        "dgdt": round(dgdt, 2),
        "raw_dgdt": int(round(raw_dgdt)),
        "trend_length": raw_len,
        "smoothed_last_3": (
            [round(v, 1) for v in smoothed[-3:]]
            if len(smoothed) >= 3
            else [round(v, 1) for v in smoothed]
        ),
        "raw_last_5": [int(round(v)) for v in chrono[-5:]],
    }
    return result


def log_prediction(result: dict) -> None:
    """Append the prediction to the log file."""
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(result) + "\n")
    except Exception as e:
        print(
            json.dumps({"error": f"Failed to write log: {e}"}),
            file=sys.stderr,
        )


def main() -> None:
    trend = fetch_gamma_trend()
    if trend is None:
        # Error already printed to stderr
        error_result = {
            "timestamp": now_iso(),
            "prediction": "ERROR",
            "alert_priority": 0,
            "current_gamma": 0,
            "expected_gamma": 0,
            "dgdt": 0.0,
            "error": "Failed to fetch gamma trend",
        }
        print(json.dumps(error_result))
        log_prediction(error_result)
        sys.exit(1)

    result = predict(trend)
    log_prediction(result)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
