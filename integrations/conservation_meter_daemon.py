#!/usr/bin/env python3
"""
conservation_meter_daemon.py — Periodically fetch colony data, compute γ/η, push through protocol.

Runs every 60 seconds:
1. Fetch /games/reputation from colony-games server
2. Compute γ, η, C from live cell data
3. Package as a Bottle via superinstance_bottle
4. POST the bottle to conservation-meter endpoint

Usage:
    python3 conservation_meter_daemon.py
    python3 conservation_meter_daemon.py --interval 30 --colony-url http://localhost:8823
"""

import json
import math
import os
import sys
import time
import argparse
import urllib.request
import urllib.error

# Import the protocol client
# Locate the superinstance_bottle module
_bottle_path = os.path.join(os.path.dirname(__file__), "fleet-oracle2", "integrations")
if os.path.isdir(_bottle_path):
    sys.path.insert(0, _bottle_path)
else:
    sys.path.insert(0, os.path.expanduser("~/.openclaw/workspace"))

from superinstance_bottle import Bottle

# ─── Constants ────────────────────────────────────────────────────────────────
C = math.log2(3)  # ≈ 1.585 — the conservation budget


def fetch_reputation_ledger(url: str) -> dict:
    """Fetch the reputation data from the colony-games server."""
    req = urllib.request.Request(f"{url}/games/reputation")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def compute_conservation(reputation_data: dict) -> dict:
    """
    Compute γ, η, and derived metrics from colony reputation data.

    γ (gamma) = mean absolute deviation of cooperation rate from 0.5
    η (eta)   = interaction complexity normalized to [0, 1]
    """
    reputations = reputation_data.get("reputations", {})
    n = len(reputations)
    if n == 0:
        return {
            "n": 0,
            "gamma": 0.0,
            "eta": 0.0,
            "C": 0.0,
            "delta": C,
            "conserved": True,
            "budget": C,
        }

    # γ = mean |cooperation_rate - 0.5|
    coop_rates = [c.get("cooperate_rate", 0.5) for c in reputations.values()]
    gamma = sum(abs(r - 0.5) for r in coop_rates) / n
    gamma = max(0.0, min(1.0, gamma))

    # η = interaction density = total_pd_games / (n*(n-1)/2 * target)
    total_pd = sum(c.get("total_pd_games", 0) for c in reputations.values())
    max_pairs = n * (n - 1) / 2 if n > 1 else 1
    eta = min(1.0, total_pd / (max_pairs * 2))

    total = gamma + eta
    delta = C - total

    return {
        "n": n,
        "gamma": round(gamma, 4),
        "eta": round(eta, 4),
        "C": round(total, 4),
        "delta": round(delta, 4),
        "budget": round(C, 4),
        "conserved": delta >= 0,
        "utilization_pct": round((total / C) * 100, 2),
    }


def push_to_conservation_meter(metrics: dict, check_url: str = "http://localhost:8798") -> bool:
    """Push conservation metrics as a Bottle to the conservation-meter service."""
    # Create bottle with conservation trits:
    # trits[0] = conservation signal (+1 if conserved, -1 if violated, 0 if marginal)
    if metrics["conserved"]:
        if metrics["delta"] > 0.5:
            env_trits = [1, 1, 1]    # Healthy headroom
        else:
            env_trits = [1, 0, 1]    # Conserved but tight
    elif 0.5 - metrics["delta"] < 0.1:
        env_trits = [0, -1, 0]        # Very close — marginal
    else:
        env_trits = [-1, -1, -1]      # Violated

    bottle = Bottle.new(
        src="conservation-meter-daemon",
        tgt="colony-games",
        act="conservation.fleet.heartbeat",
        trits=env_trits,
        payload={
            **metrics,
            "type": "colony_conservation_heartbeat",
            "timestamp": time.time(),
        },
        ttl=120,
    )

    wire = bottle.encode()

    try:
        req = urllib.request.Request(
            check_url,
            data=wire,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            response_data = json.loads(resp.read())
            return True
    except (urllib.error.URLError, ConnectionRefusedError) as e:
        print(f"  ⚠️  Could not reach conservation meter at {check_url}: {e}")
        # Still show the bottle on stdout even if push fails
        return False


def run(interval: int = 60, colony_url: str = "http://localhost:8823",
        check_url: str = "http://localhost:8798"):
    """Main daemon loop."""
    print("═" * 60)
    print("Colony Conservation Meter Daemon")
    print(f"Colony: {colony_url}  |  Check: {check_url}  |  Interval: {interval}s")
    print(f"C = log₂(3) ≈ {C:.4f}")
    print("═" * 60)

    while True:
        try:
            reputation_data = fetch_reputation_ledger(colony_url)
            metrics = compute_conservation(reputation_data)

            ts = time.strftime("%H:%M:%S")
            status = "✅" if metrics["conserved"] else "❌"
            print(
                f"[{ts}] {status} n={metrics['n']:2d} "
                f"γ={metrics['gamma']:.4f} η={metrics['eta']:.4f} "
                f"C={metrics['C']:.4f} δ={metrics['delta']:.4f} "
                f"({metrics['utilization_pct']:.1f}%)"
            )

            # Push conservation check
            pushed = push_to_conservation_meter(metrics, check_url)
            if pushed:
                print(f"      → Bottle pushed to {check_url}")

            # If conservation is violated, log the violation
            if not metrics["conserved"]:
                print(f"      ⚠️  CONSERVATION VIOLATION: γ+η={metrics['C']} > C={C}")
                print(f"      Need to reduce by {abs(metrics['delta']):.4f}")

        except urllib.error.URLError as e:
            print(f"[{time.strftime('%H:%M:%S')}] ⚠️  Colony server unreachable: {e}")
        except json.JSONDecodeError as e:
            print(f"[{time.strftime('%H:%M:%S')}] ⚠️  Bad JSON from colony: {e}")
        except Exception as e:
            print(f"[{time.strftime('%H:%M:%S')}] ❌ Error: {e}")

        time.sleep(interval)


# ─── Main ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Colony Conservation Meter Daemon")
    parser.add_argument("--interval", "-i", type=int, default=60, help="Poll interval (seconds)")
    parser.add_argument("--colony-url", "-c", default="http://localhost:8823", help="Colony games URL")
    parser.add_argument("--check-url", "-k", default="http://localhost:8798", help="Conservation meter URL")
    parser.add_argument("--oneshot", "-1", action="store_true", help="Run once and exit")
    args = parser.parse_args()

    if args.oneshot:
        reputation = fetch_reputation_ledger(args.colony_url)
        metrics = compute_conservation(reputation)
        print(json.dumps(metrics, indent=2))
    else:
        run(interval=args.interval, colony_url=args.colony_url, check_url=args.check_url)
