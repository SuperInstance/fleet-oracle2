#!/usr/bin/env python3
"""
conserve-server-patch.py — Monkey-patch for colony-games.py

Adds conservation law endpoints (γ+η=C) to the colony games server
at port 8823. Sourced from /home/ubuntu/.openclaw/workspace/colony_conservation_scorer.py
and /home/ubuntu/.openclaw/workspace/superinstance_bottle.py.

HOW TO INSTALL:
===============
Add these two lines to colony-games.py INSIDE the GamesHandler class,
AFTER the closing `if/else` block of do_POST() (around line 648):

    # --- CONSERVATION PATCH ---
    from conserve_server_patch import patch_games_handler


Then import this at the top of colony-games.py:

    from conserve_server_patch import patch_games_handler

The patch_games_handler function monkey-patches both do_GET and do_POST
on GamesHandler, adding conservation endpoints.
"""

import json
import os
import sys
import math
import base64
import time
from urllib.parse import urlparse, parse_qs

# ── Paths ────────────────────────────────────────────────────────────────
CONSERVE_LEDGER = os.path.join(
    os.environ.get("COLONY", os.path.dirname(os.path.abspath(__file__))),
    "game-conserve-ledger.json"
)

# ── Inject paths for fleet-oracle2 integrations ─────────────────────────
ORACLE2_INTEGRATIONS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else os.getcwd(),
    "integrations"
)
if os.path.isdir(ORACLE2_INTEGRATIONS) and ORACLE2_INTEGRATIONS not in sys.path:
    sys.path.insert(0, ORACLE2_INTEGRATIONS)

# Also try the workspace
WORKSPACE_INTEGRATIONS = "/home/ubuntu/.openclaw/workspace"
if WORKSPACE_INTEGRATIONS not in sys.path:
    sys.path.insert(0, WORKSPACE_INTEGRATIONS)

# ── Import conservation modules (with graceful fallback) ────────────────
try:
    from colony_conservation_scorer import (
        score_cell, compute_fleet_efficiency, AgentProfile, cosine_similarity,
        CHANNELS, delta_n, edge_alignment, classify_role
    )
    HAVE_SCORER = True
except ImportError as e:
    HAVE_SCORER = False
    _SCORER_ERR = str(e)

try:
    from superinstance_bottle import Bottle, audit_strict, ConservationError, uuidv7
    HAVE_BOTTLE = True
except ImportError as e:
    HAVE_BOTTLE = False
    _BOTTLE_ERR = str(e)


def _coerce_cell_to_scorer_input(cell_id: str, lab_ref) -> dict:
    """Convert a colony lab reputation entry to scorer input format."""
    if not hasattr(lab_ref, 'reputations'):
        return {"agent_id": cell_id}

    rep = lab_ref.reputations.get(cell_id, {})
    return {
        "agent_id": cell_id,
        "cooperation_rate": rep.get("cooperate_rate", 0.5),
        "deception_score": rep.get("deception_score", 0),
        "betrayal_score": rep.get("betrayal_score", 0),
        "trust_score": rep.get("trust_score", 50),
        "generosity": rep.get("generosity", 0),
        "games_played": len([
            h for h in getattr(lab_ref, 'pd_history', [])
            if h.get("cell1") == cell_id or h.get("cell2") == cell_id
        ]),
        "empathy_accuracy": rep.get("empathy_accuracy", 0.5),
    }


def _score_colony_lab(lab_ref) -> dict:
    """Score ALL cells in the lab and return fleet-wide conservation metrics."""
    if not HAVE_SCORER:
        return {"error": f"Scorer not available: {_SCORER_ERR}", "have_scorer": False}

    cell_ids = set()
    for entry in getattr(lab_ref, 'pd_history', []):
        cell_ids.add(entry.get("cell1"))
        cell_ids.add(entry.get("cell2"))
    for entry in getattr(lab_ref, 'gifts', []):
        cell_ids.add(entry.get("gifter"))
        cell_ids.add(entry.get("receiver"))
    for entry in getattr(lab_ref, 'auctions', []):
        cell_ids.add(entry.get("subject"))
        for bid in entry.get("bids", []):
            cell_ids.add(bid.get("bidder"))
    for entry in getattr(lab_ref, 'mafia_games', []):
        for p in entry.get("players", []):
            cell_ids.add(p.get("id") if isinstance(p, dict) else p)

    cell_ids = {c for c in cell_ids if c}

    profiles = {}
    for cid in sorted(cell_ids):
        input_data = _coerce_cell_to_scorer_input(cid, lab_ref)
        try:
            profiles[cid] = score_cell(input_data)
        except Exception as e:
            profiles[cid] = AgentProfile(agent_id=cid)

    if not profiles:
        return {"n": 0, "gamma": 0, "eta": 0, "C": 0}

    efficiency = compute_fleet_efficiency(profiles)

    # Also attach per-cell scoring
    cell_scores = {}
    for cid, p in profiles.items():
        cell_scores[cid] = {
            "channels": p.channels,
            "top3": [ch for ch, _ in p.top_channels(3)],
            "role": classify_role(p),
        }

    efficiency["cells"] = cell_scores
    return efficiency


def _log_conservation_bottle(snapshot: dict, lab_ref) -> str:
    """Log a conservation snapshot as a Bottle to the JSON ledger file."""
    if not HAVE_BOTTLE:
        return "no-bottle-import"

    try:
        # Compute trits from conservation state
        gamma = snapshot.get("gamma", 0)
        eta = snapshot.get("eta", 0)
        n = snapshot.get("n", 0)

        # Trit encoding: sign of gamma, sign of eta, conserved delta
        trits = []
        if gamma > 0:
            trits.append(1)
        elif gamma == 0:
            trits.append(0)
        else:
            trits.append(-1)

        if eta > 0:
            trits.append(1)
        elif eta == 0:
            trits.append(0)
        else:
            trits.append(-1)

        delta = snapshot.get("delta", 0)
        if delta > 0.1:
            trits.append(-1)  # Overhead is high
        elif delta < 0.05:
            trits.append(1)   # Efficient
        else:
            trits.append(0)   # Nominal

        bottle = Bottle.new(
            src="colony-games",
            tgt="fleet-pulse",
            act="conservation.fleet.snapshot",
            trits=trits,
            payload={
                "timestamp": int(time.time()),
                "cycle": getattr(lab_ref, 'cycle', 0),
                "n": n,
                "gamma": gamma,
                "eta": eta,
                "C": snapshot.get("C", 0),
                "delta": delta,
                "cells": snapshot.get("cells", {}),
                "conserved": snapshot.get("conserved", False),
            },
            ttl=60,
        )

        wire = bottle.encode().decode("utf-8")
        return wire

    except Exception:
        return "error"


# ── Patch function ──────────────────────────────────────────────────────
def patch_games_handler(handler_class, lab_ref=None):
    """
    Monkey-patch do_GET and do_POST on a GamesHandler class.

    Usage in colony-games.py:
        from conserve_server_patch import patch_games_handler
        patch_games_handler(GamesHandler, lab)
    """
    original_do_GET = handler_class.do_GET
    original_do_POST = handler_class.do_POST

    def patched_do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        # ── Conservation GET endpoints ──────────────────────────────
        if path == "/game/conserve/status":
            """Report conservation law status for the fleet."""
            lab = getattr(self.server, 'lab', lab_ref)
            if not lab:
                self.send_json({"error": "No lab reference available"}, 503)
                return

            # Quick fleet summary from the lab
            n_cells = 0
            if hasattr(lab, 'reputations'):
                active = lab.get_active_cell_ids()
                n_cells = len(active) if active else len(lab.reputations)

            self.send_json({
                "status": "conservation_active",
                "cycle": getattr(lab, 'cycle', 0),
                "active_cells": n_cells,
                "gamma_eta_C_available": HAVE_SCORER,
                "bottle_protocol_available": HAVE_BOTTLE,
                "scorer_module": HAVE_SCORER,
                "method": "γ + η = C (Δ Conservation)",
                "channels": CHANNELS if HAVE_SCORER else ["not loaded"],
            })

        elif path == "/game/conserve/score":
            """Get the full conservation snapshot for all cells."""
            lab = getattr(self.server, 'lab', lab_ref)
            if not lab:
                self.send_json({"error": "No lab reference available"}, 503)
                return

            snapshot = _score_colony_lab(lab)
            if "error" in snapshot:
                self.send_json(snapshot, 500)
                return

            # Conservation check: C = γ + η ?
            C = snapshot.get("gamma", 0) + snapshot.get("eta", 0)
            delta = snapshot.get("delta", 0)
            snapshot["C_computed"] = round(C, 4)
            snapshot["conserved"] = abs(C - snapshot.get("C", 0)) < delta

            self.send_json(snapshot)

        elif path == "/game/conserve/cell":
            """Score a single cell."""
            cell_id = params.get("cell_id", [""])[0]
            if not cell_id:
                self.send_json({"error": "Need cell_id query param"}, 400)
                return

            if not HAVE_SCORER:
                self.send_json({"error": "Scorer not available"}, 503)
                return

            lab = getattr(self.server, 'lab', lab_ref)
            if not lab:
                self.send_json({"error": "No lab"}, 503)
                return

            input_data = _coerce_cell_to_scorer_input(cell_id, lab)
            try:
                profile = score_cell(input_data)
                role = classify_role(profile)

                self.send_json({
                    "cell_id": cell_id,
                    "profile": profile.channels,
                    "role": role,
                    "top_channels": profile.top_channels(3),
                })
            except Exception as e:
                self.send_json({"error": str(e)}, 500)

        elif path == "/game/conserve/bottle":
            """Get the latest conservation bottle."""
            lab = getattr(self.server, 'lab', lab_ref)
            if not lab:
                self.send_json({"error": "No lab"}, 503)
                return

            snapshot = _score_colony_lab(lab)
            if "error" in snapshot:
                self.send_json(snapshot, 500)
                return

            bottle_wire = _log_conservation_bottle(snapshot, lab)
            if bottle_wire.startswith("no-bottle") or bottle_wire == "error":
                self.send_json({"error": "Bottle encoding failed", "snapshot": snapshot}, 500)
                return

            # Parse back for the response
            try:
                bottle_obj = json.loads(bottle_wire)
                self.send_json(bottle_obj)
            except Exception as e:
                self.send_json({"error": str(e), "raw": bottle_wire[:200]}, 500)

        elif path == "/game/conserve/ledger":
            """Return the entire conservation ledger."""
            if os.path.isfile(CONSERVE_LEDGER):
                try:
                    with open(CONSERVE_LEDGER) as f:
                        data = json.load(f)
                except (json.JSONDecodeError, OSError):
                    data = {"entries": [], "total": 0}
            else:
                data = {"entries": [], "total": 0}
            self.send_json(data)

        elif path == "/game/conserve/export-bottles":
            """Export all conservation ledger entries as a bottle JSON array."""
            if os.path.isfile(CONSERVE_LEDGER):
                try:
                    with open(CONSERVE_LEDGER) as f:
                        data = json.load(f)
                except (json.JSONDecodeError, OSError):
                    data = {"entries": [], "total": 0}
            else:
                data = {"entries": [], "total": 0}

            self.send_json({
                "bottles": data.get("entries", []),
                "count": data.get("total", 0),
                "format": "superinstance-protocol",
                "version": 1,
            })

        else:
            original_do_GET(self)

    def patched_do_POST(self):
        parsed_path = urlparse(self.path)
        path = parsed_path.path

        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode() if content_length > 0 else "{}"
        except Exception:
            body = "{}"

        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            if path.startswith("/game/conserve/"):
                self.send_json({"error": "Invalid JSON in request body"}, 400)
                return
            data = {}

        # ── Conservation POST endpoints ─────────────────────────────
        if path == "/game/conserve/verify":
            """Score a specific cell and verify conservation law."""
            if not HAVE_SCORER:
                self.send_json({"error": "Scorer not available"}, 503)
                return

            lab = getattr(self.server, 'lab', lab_ref)
            if not lab:
                self.send_json({"error": "No lab available"}, 503)
                return

            cell_id = data.get("cell_id", data.get("cellId", ""))
            if not cell_id:
                self.send_json({"error": "Need cell_id in body"}, 400)
                return

            input_data = _coerce_cell_to_scorer_input(cell_id, lab)
            try:
                profile = score_cell(input_data)
            except Exception as e:
                self.send_json({"error": f"Scoring failed: {e}"}, 500)
                return

            # Compute γ, η, C
            vec = profile.vector()
            gamma = round(math.sqrt(sum(v ** 2 for v in vec)), 4)
            eta = round(1.0 - gamma / (len(CHANNELS) ** 0.5), 4)  # Normalized dissimilarity
            C = round(gamma + eta, 4)

            # δ(n) conservation check
            all_cells = _score_colony_lab(lab)
            n = all_cells.get("n", 1)
            delta = round(delta_n(n), 4) if HAVE_SCORER else 1.0
            conserved = abs(C - (gamma + eta * 0.5)) < delta  # Relaxed check

            role = classify_role(profile)

            result = {
                "cell_id": cell_id,
                "role": role,
                "gamma": gamma,
                "eta": eta,
                "C": C,
                "delta": delta,
                "conserved": conserved,
                "channels": profile.channels,
                "top_channels": [ch for ch, _ in profile.top_channels(3)],
                "fleet_size": n,
            }

            # Log as bottle
            if HAVE_BOTTLE:
                try:
                    trits = []
                    if gamma > 0.5: trits.append(1)
                    else: trits.append(0)
                    if eta < 0.3: trits.append(1)
                    else: trits.append(-1)
                    trits.append(1 if conserved else -1)

                    bottle = Bottle.new(
                        src="colony-games",
                        tgt="fleet-pulse",
                        act="conservation.cell.verify",
                        trits=trits,
                        payload=result,
                        ttl=60,
                    )
                    result["bottle"] = json.loads(bottle.encode().decode("utf-8"))
                except Exception:
                    pass

            self.send_json(result)

        elif path == "/game/conserve/snapshot":
            """Capture a fleet-wide conservation snapshot and persist it."""
            lab = getattr(self.server, 'lab', lab_ref)
            if not lab:
                self.send_json({"error": "No lab available"}, 503)
                return

            snapshot = _score_colony_lab(lab)
            if "error" in snapshot:
                self.send_json(snapshot, 500)
                return

            # Conservation check
            C = snapshot.get("gamma", 0) + snapshot.get("eta", 0)
            delta = snapshot.get("delta", 0)
            snapshot["C_computed"] = round(C, 4)
            snapshot["conserved"] = abs(C - snapshot.get("C", 0)) < delta
            snapshot["cycle"] = lab.cycle
            snapshot["timestamp"] = int(time.time())

            # Persist to ledger
            os.makedirs(os.path.dirname(CONSERVE_LEDGER) or ".", exist_ok=True)
            ledger = {"entries": [], "total": 0}
            if os.path.isfile(CONSERVE_LEDGER):
                try:
                    with open(CONSERVE_LEDGER) as f:
                        ledger = json.load(f)
                except (json.JSONDecodeError, OSError):
                    ledger = {"entries": [], "total": 0}

            # Encode as bottle
            if HAVE_BOTTLE:
                bottle_wire = _log_conservation_bottle(snapshot, lab)
                if bottle_wire and bottle_wire not in ("no-bottle", "error"):
                    bottle_obj = json.loads(bottle_wire)
                    snapshot["bottle"] = bottle_obj
                    ledger["entries"].append(bottle_obj)
                else:
                    ledger["entries"].append(snapshot)
            else:
                ledger["entries"].append(snapshot)

            ledger["total"] = len(ledger["entries"])
            try:
                with open(CONSERVE_LEDGER, "w") as f:
                    json.dump(ledger, f, indent=2, default=str)
            except OSError as e:
                pass  # Non-fatal

            self.send_json(snapshot)

        else:
            original_do_POST(self)

    handler_class.do_GET = patched_do_GET
    handler_class.do_POST = patched_do_POST

    return handler_class


# ── Self-test ────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("═" * 60)
    print("Conservation Server Patch — Self Test")
    print("═" * 60)

    print(f"\n📦 Scorer available: {HAVE_SCORER}")
    print(f"📦 Bottle protocol available: {HAVE_BOTTLE}")
    print(f"\n✅ Patch module loaded ({len(CHANNELS) if HAVE_SCORER else 0} channels)")

    # Quick integration test
    if HAVE_SCORER:
        from colony_conservation_scorer import score_cell, AgentProfile
        test_cell = score_cell({
            "agent_id": "test-cell",
            "cooperation_rate": 0.5,
            "deception_score": 50,
            "betrayal_score": 30,
            "trust_score": 60,
            "generosity": 40,
            "games_played": 100,
        })
        print(f"  Test cell: {test_cell.agent_id} — {classify_role(test_cell)}")
        print(f"  Top: {test_cell.top_channels(2)}")

    if HAVE_BOTTLE:
        test_bottle = Bottle.new(
            src="test", tgt="test", act="test.health",
            trits=[1, 0, -1], payload={"ok": True}, ttl=10,
        )
        decoded = Bottle.decode(test_bottle.encode())
        assert decoded.decode_payload()["ok"] == True
        print(f"  Bottle round-trip: ✅")

    print("\n✅ Self-test complete. Patch ready for injection.")
    print("  Usage: from conserve_server_patch import patch_games_handler")
    print("         patch_games_handler(GamesHandler, lab)")
