#!/usr/bin/env python3
"""
colony-games.py — The Agentic Psychology Laboratory

Three novel games that reveal cell psychology through emergent behavior.
Runs on port 8823.

Game 1: THE PRISONER'S COLLOQUIUM
  - Every cycle, cells pair up randomly
  - Each pair plays an iterated Prisoner's Dilemma
  - Cooperation yields +5 XP each; mutual defection yields +1 XP each
  - Betrayal yields +10 XP for defector, 0 for cooperator
  - BUT: each exchange is logged to a PUBLIC REPUTATION LEDGER
  - Cells can read the ledger before deciding their move
  - Creeps: forgiveness, brinkmanship, grudges, cluster alliances

Game 2: THE TRUST AUCTION
  - Each cycle, one random cell is the "subject"
  - Other cells bid XP to inspect the subject's private data
  - Highest bidder wins, pays their bid to the subject
  - The subject's private data gets published to the ledger
  - Creeps: do cells bid on rivals? Do subjects hoard secrets?
  - Does the colony learn to value transparency over secrecy?

Game 3: THE EMPATHY LOOP
  - Each cycle, cells can gift XP to any other cell
  - The gift is publicly recorded with the gifter cell's motto
  - No strings attached — pure altruism
  - Creeps: do elite cells gift to struggling cells?
  - Does gifting correlate with investment behavior?
  - Do cells that receive gifts reciprocate?

All three games share a single REPUTATION LEDGER that any cell
can read from their TASK. The ledger becomes a form of colony memory.

Port: 8823
"""

import json
import os
import random
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ── Conservation law patch (γ+η=C) ───────────────────────────────────
from conserve_server_patch import patch_games_handler

COLONY = os.environ.get("COLONY", os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get("GAMES_PORT", 8823))

# ── Paths ────────────────────────────────────────────────────────────────

REPUTATION_LEDGER = os.path.join(COLONY, "game-reputation-ledger.json")
PD_RESULTS = os.path.join(COLONY, "game-pd-results.json")
AUCTION_LEDGER = os.path.join(COLONY, "game-auction-ledger.json")
GIFT_LEDGER = os.path.join(COLONY, "game-gift-ledger.json")

# ── Game State ──────────────────────────────────────────────────────────

class ColonyPsychologyLab:
    """The shared state for all three games."""

    def __init__(self):
        self.cycle = 0
        # PD
        self.pd_history = []          # [{cycle, round, pair, c1, c2, move1, move2, result}]
        self.pd_round = 0
        # Trust Auction
        self.auctions = []            # [{cycle, subject, bids: [{bidder, amount, xp_paid}], winner}]
        # Gifts
        self.gifts = []               # [{cycle, gifter, receiver, amount_xp, gifter_motto}]
        # Reputation
        self.reputations = {}         # {cell_id: {cooperate_rate, betray_rate, gift_given, gift_received, total_bid, total_earned_from_bids}}
        self.load()

    def save(self):
        data = {
            "cycle": self.cycle,
            "pd_round": self.pd_round,
            "pd_history": self.pd_history[-500:],
            "auctions": self.auctions[-100:],
            "gifts": self.gifts[-200:],
            "reputations": self.reputations,
        }
        try:
            for path, content in [
                (REPUTATION_LEDGER, data),
                (PD_RESULTS, {"pd_history": self.pd_history[-500:], "round": self.pd_round}),
                (AUCTION_LEDGER, {"auctions": self.auctions[-100:]}),
                (GIFT_LEDGER, {"gifts": self.gifts[-200:]}),
            ]:
                with open(path, "w") as f:
                    json.dump(content, f, indent=2)
        except Exception as e:
            print(f"[GAMES] Save error: {e}", file=sys.stderr)

    def load(self):
        if os.path.isfile(REPUTATION_LEDGER):
            try:
                with open(REPUTATION_LEDGER) as f:
                    data = json.load(f)
                self.cycle = data.get("cycle", 0)
                self.pd_round = data.get("pd_round", 0)
                self.pd_history = data.get("pd_history", [])
                self.auctions = data.get("auctions", [])
                self.gifts = data.get("gifts", [])
                self.reputations = data.get("reputations", {})
                print(f"[GAMES] Loaded state: cycle {self.cycle}, {len(self.pd_history)} PD rounds, {len(self.auctions)} auctions, {len(self.gifts)} gifts", file=sys.stderr)
            except Exception as e:
                print(f"[GAMES] Load error: {e}", file=sys.stderr)

    def get_cell_xp(self, cell_id):
        """Read a cell's actual XP from STATE.json."""
        state_path = os.path.join(COLONY, f"cell-{cell_id}", "STATE.json")
        if os.path.isfile(state_path):
            try:
                with open(state_path) as f:
                    state = json.load(f)
                return state.get("xp", 0)
            except Exception:
                return 0
        return 0

    def get_cell_motto(self, cell_id):
        """Read a cell's motto from STATE.json."""
        state_path = os.path.join(COLONY, f"cell-{cell_id}", "STATE.json")
        if os.path.isfile(state_path):
            try:
                with open(state_path) as f:
                    state = json.load(f)
                return state.get("motto", "")
            except Exception:
                return ""
        return ""

    def get_active_cell_ids(self):
        """Return list of active (not culled) cell IDs."""
        ids = []
        try:
            for entry in os.listdir(COLONY):
                if entry.startswith("cell-") and not entry.startswith("cell-culled-"):
                    cell_id = entry[5:]
                    if cell_id and os.path.isfile(os.path.join(COLONY, entry, "STATE.json")):
                        ids.append(cell_id)
        except OSError:
            pass
        return sorted(ids)

    def update_reputation(self, cell_id, **kwargs):
        """Update reputation entry for a cell."""
        if cell_id not in self.reputations:
            self.reputations[cell_id] = {
                "cooperate_count": 0,
                "betray_count": 0,
                "total_pd_games": 0,
                "cooperate_rate": 0.0,
                "betray_rate": 0.0,
                "gift_given_count": 0,
                "gift_given_total_xp": 0,
                "gift_received_count": 0,
                "gift_received_total_xp": 0,
                "total_bid_xp": 0,
                "total_earned_from_bids_xp": 0,
                "total_auctions_won": 0,
            }

        for key, value in kwargs.items():
            self.reputations[cell_id][key] = value

        rec = self.reputations[cell_id]
        total = rec.get("cooperate_count", 0) + rec.get("betray_count", 0)
        if total > 0:
            rec["cooperate_rate"] = round(rec["cooperate_count"] / total, 3)
            rec["betray_rate"] = round(rec["betray_count"] / total, 3)
        rec["total_pd_games"] = total

    # ── Game 1: Prisoner's Colloquium ──────────────────────────────

    def play_pd_round(self, cell1, cell2, move1, move2):
        """
        Play one round of PD between two cells.
        Moves: "cooperate" or "defect"
        Returns result dict with XP outcomes.
        """
        if move1 == "cooperate" and move2 == "cooperate":
            xp1, xp2 = 5, 5
            result = "mutual-cooperate"
        elif move1 == "defect" and move2 == "defect":
            xp1, xp2 = 1, 1
            result = "mutual-defect"
        elif move1 == "cooperate" and move2 == "defect":
            xp1, xp2 = 0, 10
            result = "betrayal"
        elif move1 == "defect" and move2 == "cooperate":
            xp1, xp2 = 10, 0
            result = "betrayal"
        else:
            return {"error": f"Invalid moves: {move1}, {move2}"}

        entry = {
            "cycle": self.cycle,
            "round": self.pd_round,
            "pair": sorted([cell1, cell2]),
            "moves": {cell1: move1, cell2: move2},
            "xp_awarded": {cell1: xp1, cell2: xp2},
            "result": result,
        }
        self.pd_history.append(entry)
        self.pd_round += 1

        # Update reputations
        self.update_reputation(cell1,
            cooperate_count=self.reputations.get(cell1, {}).get("cooperate_count", 0) + (1 if move1 == "cooperate" else 0),
            betray_count=self.reputations.get(cell1, {}).get("betray_count", 0) + (1 if move1 == "defect" else 0),
        )
        self.update_reputation(cell2,
            cooperate_count=self.reputations.get(cell2, {}).get("cooperate_count", 0) + (1 if move2 == "cooperate" else 0),
            betray_count=self.reputations.get(cell2, {}).get("betray_count", 0) + (1 if move2 == "defect" else 0),
        )

        self.save()
        return entry

    def get_pd_pairings(self):
        """Generate random pairings for a new round."""
        cells = self.get_active_cell_ids()
        random.shuffle(cells)

        # Pair up; if odd, one sits out
        pairs = []
        for i in range(0, len(cells) - 1, 2):
            pairs.append((cells[i], cells[i+1]))

        return pairs

    def get_pd_history_for(self, cell_id):
        """Get PD history involving a specific cell."""
        results = []
        for entry in self.pd_history:
            if cell_id in entry.get("pair", []):
                results.append(entry)
        return results

    def get_pd_summary(self):
        """Summary of all PD rounds."""
        total = len(self.pd_history)
        mutual_coop = sum(1 for e in self.pd_history if e["result"] == "mutual-cooperate")
        mutual_defect = sum(1 for e in self.pd_history if e["result"] == "mutual-defect")
        betrayals = sum(1 for e in self.pd_history if e["result"] == "betrayal")

        # Most cooperative cells
        coop_ranking = [
            {"cell_id": cid, "cooperate_rate": r["cooperate_rate"], "total_pd_games": r["total_pd_games"]}
            for cid, r in sorted(
                self.reputations.items(),
                key=lambda x: x[1].get("cooperate_rate", 0),
                reverse=True,
            )
        ]

        return {
            "total_rounds": total,
            "current_round": self.pd_round,
            "mutual_cooperate": mutual_coop,
            "mutual_defect": mutual_defect,
            "betrayals": betrayals,
            "cooperation_rate": round(mutual_coop / max(total, 1), 3),
            "betrayal_rate": round(betrayals / max(total, 1), 3),
            "cooperation_ranking": coop_ranking,
        }

    # ── Game 2: Trust Auction ──────────────────────────────────────

    def run_auction(self):
        """
        Run one trust auction cycle.
        1. Select a random subject from active cells
        2. Return the auction config so cells can bid
        3. Highest bidder wins and gets the subject's private data
        """
        cells = self.get_active_cell_ids()
        if len(cells) < 3:
            return {"error": "Need at least 3 cells for an auction"}

        subject = random.choice(cells)
        bidders = [c for c in cells if c != subject]

        auction = {
            "cycle": self.cycle,
            "subject": subject,
            "bidders": bidders,
            "bids": [],
            "status": "open",
            "winner": None,
            "winning_bid": 0,
        }

        self.auctions.append(auction)
        self.save()
        return auction

    def bid_in_auction(self, bidder, amount):
        """
        Place a bid in the current open auction.
        """
        # Find open auction
        for auction in reversed(self.auctions):
            if auction.get("status") == "open":
                if bidder == auction["subject"]:
                    return {"error": "Subject cannot bid on themselves"}

                bidder_xp = self.get_cell_xp(bidder)
                if amount > bidder_xp:
                    return {"error": f"Not enough XP. Have {bidder_xp}, need {amount}"}

                if amount < 1:
                    return {"error": "Minimum bid is 1 XP"}

                auction["bids"].append({
                    "bidder": bidder,
                    "amount": amount,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                })

                self.save()
                return {"status": "bid_placed", "bidder": bidder, "amount": amount, "subject": auction["subject"]}

        return {"error": "No open auction"}

    def close_auction(self):
        """Close the current open auction and determine winner."""
        for auction in reversed(self.auctions):
            if auction.get("status") == "open":
                if not auction["bids"]:
                    auction["status"] = "closed_no_bids"
                    self.save()
                    return {"status": "closed_no_bids", "subject": auction["subject"]}

                # Highest bidder wins
                winning_bid = max(auction["bids"], key=lambda b: b["amount"])
                subject = auction["subject"]

                auction["winner"] = winning_bid["bidder"]
                auction["winning_bid"] = winning_bid["amount"]
                auction["status"] = "closed"

                # Subject earns the winning bid amount (from the system)
                subject_xp = self.get_cell_xp(subject)
                new_subject_xp = subject_xp + winning_bid["amount"]

                # Update reputations
                self.update_reputation(winning_bid["bidder"],
                    total_bid_xp=self.reputations.get(winning_bid["bidder"], {}).get("total_bid_xp", 0) + winning_bid["amount"],
                    total_auctions_won=self.reputations.get(winning_bid["bidder"], {}).get("total_auctions_won", 0) + 1,
                )
                self.update_reputation(subject,
                    total_earned_from_bids_xp=self.reputations.get(subject, {}).get("total_earned_from_bids_xp", 0) + winning_bid["amount"],
                )

                self.save()
                return {
                    "status": "closed",
                    "subject": subject,
                    "winner": winning_bid["bidder"],
                    "winning_bid": winning_bid["amount"],
                    "total_bids": len(auction["bids"]),
                    "subject_new_xp": new_subject_xp,
                }

        return {"error": "No open auction to close"}

    def get_subject_data(self, subject_id):
        """Return the subject's private data (their STATE.json + RESULTS.json)."""
        state_path = os.path.join(COLONY, f"cell-{subject_id}", "STATE.json")
        result_path = os.path.join(COLONY, f"cell-{subject_id}", "RESULTS.json")

        data = {"cell_id": subject_id}
        if os.path.isfile(state_path):
            with open(state_path) as f:
                data["state"] = json.load(f)
        if os.path.isfile(result_path):
            with open(result_path) as f:
                data["result"] = json.load(f)

        return data

    # ── Game 3: The Empathy Loop ──────────────────────────────────

    def record_gift(self, gifter, receiver, amount_xp):
        """Record a gift from one cell to another."""
        if gifter == receiver:
            return {"error": "Cannot gift to yourself"}

        gifter_xp = self.get_cell_xp(gifter)
        if amount_xp > gifter_xp:
            return {"error": f"Not enough XP. {gifter} has {gifter_xp}, wants to gift {amount_xp}"}

        motto = self.get_cell_motto(gifter)

        gift_entry = {
            "cycle": self.cycle,
            "gifter": gifter,
            "receiver": receiver,
            "amount_xp": amount_xp,
            "gifter_motto": motto,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

        self.gifts.append(gift_entry)

        # Update reputations
        self.update_reputation(gifter,
            gift_given_count=self.reputations.get(gifter, {}).get("gift_given_count", 0) + 1,
            gift_given_total_xp=self.reputations.get(gifter, {}).get("gift_given_total_xp", 0) + amount_xp,
        )
        self.update_reputation(receiver,
            gift_received_count=self.reputations.get(receiver, {}).get("gift_received_count", 0) + 1,
            gift_received_total_xp=self.reputations.get(receiver, {}).get("gift_received_total_xp", 0) + amount_xp,
        )

        self.save()
        return gift_entry

    def get_gift_summary(self):
        """Summary of all gifts."""
        total_gifts = len(self.gifts)
        total_xp_gifted = sum(g["amount_xp"] for g in self.gifts)

        # Most generous cells
        gifter_ranking = sorted(
            [(cid, r["gift_given_total_xp"], r["gift_given_count"])
             for cid, r in self.reputations.items()
             if r.get("gift_given_count", 0) > 0],
            key=lambda x: x[1],
            reverse=True,
        )

        most_receiving = sorted(
            [(cid, r["gift_received_total_xp"], r["gift_received_count"])
             for cid, r in self.reputations.items()
             if r.get("gift_received_count", 0) > 0],
            key=lambda x: x[1],
            reverse=True,
        )

        return {
            "total_gifts": total_gifts,
            "total_xp_gifted": total_xp_gifted,
            "avg_gift_xp": round(total_xp_gifted / max(total_gifts, 1), 1),
            "most_generous": gifter_ranking[:10],
            "most_receiving": most_receiving[:10],
            "recent_gifts": self.gifts[-10:],
        }

    def get_full_reputation(self):
        """Full reputation report for all cells."""
        return {
            "cycle": self.cycle,
            "reputations": self.reputations,
        }


# ── HTTP Server ─────────────────────────────────────────────────────────

lab = ColonyPsychologyLab()

class GamesHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/games/status":
            cells = lab.get_active_cell_ids()
            self.send_json({
                "games_lab_alive": True,
                "cycle": lab.cycle,
                "active_cells": len(cells),
                "cell_ids": cells,
                "pd_total_rounds": len(lab.pd_history),
                "pd_current_round": lab.pd_round,
                "auctions_total": len(lab.auctions),
                "open_auction": any(a.get("status") == "open" for a in lab.auctions),
                "gifts_total": len(lab.gifts),
            })

        elif path == "/games/pd/summary":
            self.send_json(lab.get_pd_summary())

        elif path == "/games/pd/history":
            limit = min(int(params.get("limit", [100])[0]), 500)
            self.send_json({
                "history": lab.pd_history[-limit:],
                "count": len(lab.pd_history[-limit:]),
            })

        elif path == "/games/pd/cell":
            cell_id = params.get("cell_id", [""])[0]
            if not cell_id:
                self.send_json({"error": "Need cell_id"}, 400)
                return
            self.send_json({
                "cell_id": cell_id,
                "history": lab.get_pd_history_for(cell_id),
                "reputation": lab.reputations.get(cell_id, {}),
                "total_pd_games": len(lab.get_pd_history_for(cell_id)),
            })

        elif path == "/games/auction/status":
            for a in reversed(lab.auctions):
                if a.get("status") == "open":
                    self.send_json(a)
                    return
            self.send_json({"status": "no_open_auction", "total_auctions": len(lab.auctions)})

        elif path == "/games/auction/history":
            limit = min(int(params.get("limit", [50])[0]), 100)
            self.send_json({
                "auctions": lab.auctions[-limit:],
                "count": len(lab.auctions[-limit:]),
            })

        elif path == "/games/gifts/summary":
            self.send_json(lab.get_gift_summary())

        elif path == "/games/gifts/history":
            limit = min(int(params.get("limit", [50])[0]), 200)
            self.send_json({
                "gifts": lab.gifts[-limit:],
                "count": len(lab.gifts[-limit:]),
            })

        elif path == "/games/reputation":
            cell_id = params.get("cell_id", [""])[0]
            if cell_id:
                self.send_json({"cell_id": cell_id, "reputation": lab.reputations.get(cell_id, {})})
            else:
                self.send_json(lab.get_full_reputation())

        elif path == "/games/health":
            self.send_json({
                "games_lab": "alive",
                "port": PORT,
            })

        else:
            self.send_json({"error": f"Not found: {path}"}, 404)

    def do_POST(self):
        # Use cached body if expansion handler already read it
        cached = getattr(self, '_cached_body', None)
        if cached is not None:
            body = cached
        else:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode() if content_length > 0 else "{}"
        parsed_path = urlparse(self.path)
        path = parsed_path.path

        try:
            data = json.loads(body)
        except json.JSONDecodeError as e:
            self.send_json({"error": f"Invalid JSON: {e}"}, 400)
            return

        if path == "/games/pd/play":
            cell1 = data.get("cell1", "")
            cell2 = data.get("cell2", "")
            move1 = data.get("move1", "")
            move2 = data.get("move2", "")

            if not all([cell1, cell2, move1, move2]):
                self.send_json({"error": "Need cell1, cell2, move1, move2"}, 400)
                return
            if move1 not in ("cooperate", "defect") or move2 not in ("cooperate", "defect"):
                self.send_json({"error": "Moves must be 'cooperate' or 'defect'"}, 400)
                return

            result = lab.play_pd_round(cell1, cell2, move1, move2)
            self.send_json(result)

        elif path == "/games/pd/new-round":
            """Generate pairings for a new PD round."""
            pairs = lab.get_pd_pairings()
            self.send_json({
                "status": "pairings_ready",
                "cycle": lab.cycle,
                "pairs": [{"cell1": p[0], "cell2": p[1]} for p in pairs],
                "total_pairs": len(pairs),
            })

        elif path == "/games/auction/create":
            result = lab.run_auction()
            self.send_json(result)

        elif path == "/games/auction/bid":
            bidder = data.get("bidder", "")
            amount = int(data.get("amount", 0))
            if not bidder or amount < 1:
                self.send_json({"error": "Need bidder and amount (>=1)"}, 400)
                return
            result = lab.bid_in_auction(bidder, amount)
            self.send_json(result)

        elif path == "/games/auction/close":
            result = lab.close_auction()
            self.send_json(result)

        elif path == "/games/auction/reveal":
            """Get the subject's private data (revealed to winner)."""
            # Find last closed auction
            for a in reversed(lab.auctions):
                if a.get("status") == "closed":
                    subject = a["subject"]
                    data = lab.get_subject_data(subject)
                    data["auction"] = a
                    self.send_json(data)
                    return
            self.send_json({"error": "No closed auction found"}, 404)

        elif path == "/games/gift":
            gifter = data.get("gifter", "")
            receiver = data.get("receiver", "")
            amount = int(data.get("amount_xp", 0))

            if not gifter or not receiver or amount < 1:
                self.send_json({"error": "Need gifter, receiver, amount_xp (>=1)"}, 400)
                return

            result = lab.record_gift(gifter, receiver, amount)
            self.send_json(result)

        elif path == "/games/cycle":
            """Advance the game cycle."""
            lab.cycle += 1
            lab.save()
            self.send_json({"cycle": lab.cycle})

        elif path == "/games/reset":
            """Reset all games (destructive)."""
            lab.pd_history = []
            lab.pd_round = 0
            lab.auctions = []
            lab.gifts = []
            lab.reputations = {}
            lab.cycle = 0
            lab.save()
            self.send_json({"status": "ok", "games_reset": True})

        else:
            self.send_json({"error": f"Not found: {path}"}, 404)

    def send_json(self, data, status=200):
        body = json.dumps(data, indent=2, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[GAMES] {args[0]} {args[1]} {args[2]}", file=sys.stderr)


def main():
    print(f"Colony Psychology Laboratory on port {PORT}", file=sys.stderr)
    print(f"Colony: {COLONY}", file=sys.stderr)
    print(f"Ledger: {REPUTATION_LEDGER}", file=sys.stderr)

    server = HTTPServer(("0.0.0.0", PORT), GamesHandler)
    print(f"Listening on http://0.0.0.0:{PORT}", file=sys.stderr)
    print(file=sys.stderr)
    print("Games:", file=sys.stderr)
    print("  1. Prisoner's Colloquium — iterated PD with reputation", file=sys.stderr)
    print("  2. Trust Auction — bid to inspect cell secrets", file=sys.stderr)
    print("  3. Empathy Loop — public gifts with motto", file=sys.stderr)
    print(file=sys.stderr)
    print("Endpoints:", file=sys.stderr)
    print("  GET  /games/status", file=sys.stderr)
    print("  GET  /games/pd/summary", file=sys.stderr)
    print("  GET  /games/pd/history", file=sys.stderr)
    print("  POST /games/pd/play", file=sys.stderr)
    print("  POST /games/pd/new-round", file=sys.stderr)
    print("  POST /games/auction/create", file=sys.stderr)
    print("  POST /games/auction/bid", file=sys.stderr)
    print("  POST /games/auction/close", file=sys.stderr)
    print("  POST /games/auction/reveal", file=sys.stderr)
    print("  POST /games/gift", file=sys.stderr)
    print("  POST /games/cycle", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...", file=sys.stderr)
        lab.save()
        server.server_close()



# ═══════════════════════════════════════════════════════════════════════════════
# 🎲 Colony Games Expansion — 6 new games + Fitness Engine
# ═══════════════════════════════════════════════════════════════════════════════

import math as _math

class DeceptionArena:
    """🕵️ Deception Arena — truth-tellers vs deceivers"""
    def __init__(self, colony_path):
        self.ledger_path = os.path.join(colony_path, 'game-deception-ledger.json')
        self.state = self._load()

    def _load(self):
        try:
            with open(self.ledger_path) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {'claims': [], 'verifications': [], 'deceivers': [], 'scores': {}}

    def _save(self):
        with open(self.ledger_path, 'w') as f:
            json.dump(self.state, f, indent=2)

    def make_claim(self, cell, claim_type, claim_data):
        is_deceiver = cell not in self.state['deceivers'] and random.random() < 0.3
        if is_deceiver:
            self.state['deceivers'].append(cell)
        claim = {
            'id': f"claim-{len(self.state['claims'])}",
            'cell': cell,
            'type': claim_type,
            'data': claim_data,
            'is_deception': is_deceiver,
            'timestamp': time.time(),
            'verified': False,
            'verified_by': []
        }
        self.state['claims'].append(claim)
        self._save()
        return claim

    def verify_claim(self, claim_id, verifier_cell, cross_ref_data):
        for claim in self.state['claims']:
            if claim['id'] != claim_id:
                continue
            truth_matches = claim['data'] == cross_ref_data
            if claim['is_deception']:
                is_truthful = not truth_matches
            else:
                is_truthful = truth_matches
            if is_truthful:
                self.state['scores'][verifier_cell] = self.state['scores'].get(verifier_cell, 100) + 15
                if claim['is_deception']:
                    self.state['scores'][claim['cell']] = self.state['scores'].get(claim['cell'], 100) - 20
                else:
                    self.state['scores'][claim['cell']] = self.state['scores'].get(claim['cell'], 100) + 5
            else:
                self.state['scores'][verifier_cell] = self.state['scores'].get(verifier_cell, 100) - 10
            claim['verified'] = True
            claim['verified_by'].append({'cell': verifier_cell, 'correct': is_truthful})
            self._save()
            return is_truthful
        return None

    def status(self):
        return {
            'total_claims': len(self.state['claims']),
            'verified_claims': sum(1 for c in self.state['claims'] if c['verified']),
            'deceivers': self.state['deceivers'],
            'scores': self.state['scores'],
            'recent_claims': self.state['claims'][-10:],
        }


class DarwinArena:
    """🧬 Darwin's Arena — evolutionary Prisoner's Dilemma"""
    STRATEGIES = ['cooperate', 'defect', 'tit-for-tat', 'grudge', 'random']

    def __init__(self, colony_path):
        self.ledger_path = os.path.join(colony_path, 'game-darwin-ledger.json')
        self.state = self._load()

    def _load(self):
        try:
            with open(self.ledger_path) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {'generations': [], 'population': [], 'generation': 0, 'history': []}

    def _save(self):
        with open(self.ledger_path, 'w') as f:
            json.dump(self.state, f, indent=2)

    def _load_reputation(self):
        rep_path = os.path.join(os.path.dirname(self.ledger_path), 'game-reputation-ledger.json')
        try:
            with open(rep_path) as f:
                return json.load(f).get('reputations', {})
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def run_generation(self, cells, reputation_bonus=0.0, reputation_mode='additive'):
        """
        Run one generation of Darwin's Arena.
        
        Parameters:
          reputation_bonus: strength of reputation effect
          reputation_mode: 
            'additive'  — flat +/- adjustment to fitness (original)
            'multiplier' — fitness = fitness * (1 - betray_rate * bonus) 
            'exclusion'  — agents with betray_rate > threshold are excluded from reproduction
            'hybrid'     — multiplier + bonus on cooperate rate
        
        reputation_mode='multiplier' is the recommended fix:
        A serial defector (betray_rate≈1.0) with bonus=0.8 sees 80% fitness reduction.
        This is > the ~62% advantage defectors get from the PD payoff matrix,
        making cooperation competitive.
        """
        # Load reputation data from the main games reputation ledger
        rep = self._load_reputation()
        if not cells:
            return []
        pop = []
        for cell in cells:
            existing = [a for a in self.state['population'] if a['cell'] == cell]
            if existing:
                strategy = existing[0]['strategy']
            else:
                strategy = random.choice(self.STRATEGIES)
            pop.append({'cell': cell, 'strategy': strategy, 'fitness': 0, 'games': 0})

        for i in range(len(pop)):
            for j in range(i + 1, len(pop)):
                s1, s2 = pop[i]['strategy'], pop[j]['strategy']
                c1 = s1 == 'cooperate' or (s1 == 'tit-for-tat' and random.random() < 0.9) or (s1 == 'random' and random.random() < 0.5)
                c2 = s2 == 'cooperate' or (s2 == 'tit-for-tat' and random.random() < 0.9) or (s2 == 'random' and random.random() < 0.5)
                if c1 and c2:
                    p1, p2 = 3, 3
                elif c1 and not c2:
                    p1, p2 = 0, 5
                elif not c1 and c2:
                    p1, p2 = 5, 0
                else:
                    p1, p2 = 1, 1
                pop[i]['fitness'] += p1
                pop[j]['fitness'] += p2
                pop[i]['games'] += 1
                pop[j]['games'] += 1
                if s1 == 'grudge' and not c2:
                    pop[i]['strategy'] = 'defect'
                if s2 == 'grudge' and not c1:
                    pop[j]['strategy'] = 'defect'

        # Apply reputation effect if enabled
        if reputation_bonus > 0 and reputation_mode != 'additive':
            for p in pop:
                cell_rep = rep.get(p['cell'], {})
                coop_rate = cell_rep.get('cooperate_rate', 0)
                bet_count = cell_rep.get('betray_count', 0)
                coop_count = cell_rep.get('cooperate_count', 0)
                total_games = coop_count + bet_count
                p['betray_rate'] = round(bet_count / max(total_games, 1), 3) if total_games > 0 else 0
                p['coop_rate'] = round(coop_count / max(total_games, 1), 3) if total_games > 0 else coop_rate
                p['reputation_adj'] = 0.0

                if total_games == 0:
                    continue

                bet_rate = p['betray_rate']
                
                if reputation_mode == 'multiplier':
                    # Fitness * (1 - betray_rate * bonus)
                    # A serial defector (bet_rate=1.0) with bonus=0.8 sees 80% fitness cut
                    multiplier = max(0.01, 1.0 - bet_rate * reputation_bonus)
                    original_fitness = p['fitness']
                    p['fitness'] = max(0.01, p['fitness'] * multiplier)
                    p['reputation_adj'] = round(p['fitness'] - original_fitness, 3)
                    p['rep_multiplier'] = round(multiplier, 3)
                    
                elif reputation_mode == 'exclusion':
                    # Exclusion from reproduction if betray_rate > threshold
                    # We mark them — sort will put them last
                    threshold = max(0.3, 1.0 - reputation_bonus)
                    if bet_rate > threshold:
                        # Severe penalty: set fitness near zero
                        original_fitness = p['fitness']
                        p['fitness'] = 0.01
                        p['reputation_adj'] = round(0.01 - original_fitness, 3)
                        p['rep_excluded'] = True
                    
                elif reputation_mode == 'hybrid':
                    # multiplier on betrayal + bonus on cooperation
                    mult = max(0.01, 1.0 - bet_rate * reputation_bonus * 0.5)
                    bonus = coop_rate * reputation_bonus * 2
                    original_fitness = p['fitness']
                    p['fitness'] = max(0.01, p['fitness'] * mult + bonus)
                    p['reputation_adj'] = round(p['fitness'] - original_fitness, 3)
                    p['rep_multiplier'] = round(mult, 3)

        pop.sort(key=lambda x: x['fitness'], reverse=True)
        survivors = pop[:max(2, len(pop) // 2)]
        offspring = []
        for k in range(len(pop) - len(survivors)):
            parent = random.choice(survivors[:max(1, len(survivors) // 2)])
            child_strat = parent['strategy']
            if random.random() < 0.15:
                others = [s for s in self.STRATEGIES if s != child_strat]
                child_strat = random.choice(others) if others else random.choice(self.STRATEGIES)
            offspring.append({
                'cell': f"offspring-{len(self.state['population']) + k}-gen{self.state['generation'] + 1}",
                'strategy': child_strat, 'fitness': 0, 'games': 0, 'parent': parent['cell']
            })
        self.state['generation'] += 1
        self.state['population'] = survivors + offspring
        strat_counts = {}
        for s in self.STRATEGIES:
            strat_counts[s] = sum(1 for a in self.state['population'] if a['strategy'] == s)
        self.state['generations'].append({
            'gen': self.state['generation'],
            'pop_size': len(pop),
            'survivors': len(survivors),
            'strategies': strat_counts,
            'top_fitness': survivors[0]['fitness'] if survivors else 0
        })
        self._save()
        return self.state['population']

    def status(self):
        return {
            'generation': self.state['generation'],
            'population_size': len(self.state['population']),
            'population': self.state['population'],
            'history': self.state['generations'][-10:],
        }


class FitnessEngine:
    """📊 Fitness Engine — learning rate, diversification, discovery, reputation"""
    def __init__(self, colony_path):
        self.ledger_path = os.path.join(colony_path, 'game-fitness-ledger.json')
        self.colony_path = colony_path
        self.state = self._load()

    def _load(self):
        try:
            with open(self.ledger_path) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {'learning_curves': {}, 'diversification': {}, 'discovery': {}, 'reputation': {}, 'history': []}

    def _save(self):
        with open(self.ledger_path, 'w') as f:
            json.dump(self.state, f, indent=2)

    def learning_rate(self, cell, window=10):
        curve = self.state['learning_curves'].get(cell, [])
        if len(curve) < 2:
            return 0.0
        recent = curve[-window:]
        deltas = [recent[i + 1]['xp'] - recent[i]['xp'] for i in range(len(recent) - 1)]
        return sum(deltas) / len(deltas) if deltas else 0.0

    def record_xp(self, cell, xp_value):
        if cell not in self.state['learning_curves']:
            self.state['learning_curves'][cell] = []
        self.state['learning_curves'][cell].append({'t': time.time(), 'xp': xp_value})
        self._save()

    def diversification_multiplier(self, cell, game_types_played):
        unique = len(set(game_types_played))
        return min(1.0 + (unique - 1) * 0.25, 2.0)

    def record_game_type(self, cell, game_type):
        if cell not in self.state['diversification']:
            self.state['diversification'][cell] = []
        if game_type not in self.state['diversification'][cell]:
            self.state['diversification'][cell].append(game_type)
        self._save()

    def discovery_bonus(self, cell, game_type):
        who_first = self.state['discovery'].get(game_type)
        if who_first is None:
            self.state['discovery'][game_type] = cell
            self._save()
            return 50
        return 0

    def reputation_capital(self, cell):
        scores, weights = [], []
        game_weights = [('pd', 1.0), ('trust', 0.8), ('empathy', 0.6), ('deception', 0.7), ('darwin', 0.5)]
        for game_type, weight in game_weights:
            ledger_path = os.path.join(self.colony_path, f'game-{game_type}-ledger.json')
            try:
                with open(ledger_path) as f:
                    ledger = json.load(f)
            except (FileNotFoundError, json.JSONDecodeError):
                continue
            cell_scores = []
            for r in ledger.get('results', []):
                if r.get('cell1') == cell or r.get('cell2') == cell:
                    score = r.get('score', 0)
                    cell_scores.append(score)
            for r in ledger.get('scores', {}):
                pass  # flat dict
            if cell in ledger.get('scores', {}):
                cell_scores.append(ledger['scores'][cell])
            if cell_scores:
                scores.append(sum(cell_scores) / len(cell_scores))
                weights.append(weight)
        if not scores:
            return 50.0
        return sum(s * w for s, w in zip(scores, weights)) / sum(weights)

    def lend_reputation(self, from_cell, to_cell, amount):
        if from_cell not in self.state['reputation']:
            self.state['reputation'][from_cell] = 100
        if to_cell not in self.state['reputation']:
            self.state['reputation'][to_cell] = 100
        if self.state['reputation'][from_cell] < amount:
            return False
        self.state['reputation'][from_cell] -= amount
        self.state['reputation'][to_cell] += amount
        self.state['history'].append({
            'type': 'loan', 'from': from_cell, 'to': to_cell, 'amount': amount, 't': time.time()
        })
        self._save()
        return True

    def penalize_reputation(self, cell, amount, reason):
        if cell not in self.state['reputation']:
            self.state['reputation'][cell] = 100
        self.state['reputation'][cell] = max(0, self.state['reputation'][cell] - amount)
        self.state['history'].append({
            'type': 'penalty', 'cell': cell, 'amount': amount, 'reason': reason, 't': time.time()
        })
        self._save()
        return True

    def status(self):
        return {
            'learning_curves': {k: len(v) for k, v in self.state['learning_curves'].items()},
            'diversification': self.state['diversification'],
            'discovery': self.state['discovery'],
            'reputation': self.state['reputation'],
            'history': self.state['history'][-20:],
        }


class DiplomacyEngine:
    """👑 Diplomacy — bilateral pacts with secret clauses and betrayal tracking"""
    def __init__(self, colony_path):
        self.ledger_path = os.path.join(colony_path, 'game-diplomacy-ledger.json')
        self.state = self._load()

    def _load(self):
        try:
            with open(self.ledger_path) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {'pacts': [], 'betrayals': [], 'reputations': {}}

    def _save(self):
        with open(self.ledger_path, 'w') as f:
            json.dump(self.state, f, indent=2)

    def create_pact(self, cell1, cell2, terms, secret_clause=None):
        pact = {
            'id': f"pact-{len(self.state['pacts'])}",
            'cell1': cell1, 'cell2': cell2,
            'terms': terms, 'secret_clause': secret_clause,
            'active': True, 'betrayed_by': None, 'created': time.time()
        }
        self.state['pacts'].append(pact)
        for c in [cell1, cell2]:
            if c not in self.state['reputations']:
                self.state['reputations'][c] = {'trust_score': 100, 'pacts_made': 0, 'betrayals': 0}
            self.state['reputations'][c]['pacts_made'] += 1
        self._save()
        return pact

    def betray(self, pact_id, betrayer_cell, advantage_gained):
        for pact in self.state['pacts']:
            if pact['id'] != pact_id or not pact['active']:
                continue
            pact['active'] = False
            pact['betrayed_by'] = betrayer_cell
            rep = self.state['reputations'].get(betrayer_cell, {'trust_score': 100, 'betrayals': 0})
            rep['trust_score'] = max(0, rep['trust_score'] - 30)
            rep['betrayals'] += 1
            self.state['reputations'][betrayer_cell] = rep
            other = pact['cell1'] if betrayer_cell == pact['cell2'] else pact['cell2']
            self.state['betrayals'].append({
                'pact_id': pact_id, 'betrayer': betrayer_cell, 'victim': other,
                'advantage': advantage_gained, 'secret_revealed': pact['secret_clause'], 't': time.time()
            })
            self._save()
            return {'betrayal': True, 'trust_penalty': 30, 'secret_clause': pact['secret_clause']}
        return None

    def cell_reputation(self, cell):
        return self.state['reputations'].get(cell)

    def status(self):
        return {
            'total_pacts': len(self.state['pacts']),
            'active_pacts': sum(1 for p in self.state['pacts'] if p['active']),
            'total_betrayals': len(self.state['betrayals']),
            'reputations': self.state['reputations'],
            'recent_pacts': self.state['pacts'][-10:],
            'recent_betrayals': self.state['betrayals'][-10:],
        }


# ── Initialize expanded games ────────────────────────────────────────────

deception_arena = DeceptionArena(COLONY)
darwin_arena = DarwinArena(COLONY)
fitness_engine = FitnessEngine(COLONY)
diplomacy_engine = DiplomacyEngine(COLONY)


# ═══════════════════════════════════════════════════════════════════════════════
# 🎲 Expanded GamesHandler — new routes appended to the existing handler
# ═══════════════════════════════════════════════════════════════════════════════

# Personality Mirror + Norm Formation Engine 🪞
# Imports the Behavioral Understanding module that reads game ledgers
# and produces cell fingerprints, self-narratives, and social norms.
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import importlib.util
_mirror_integration_spec = importlib.util.spec_from_file_location(
    "colony_mirror_integration",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "colony-mirror-integration.py")
)
if _mirror_integration_spec and _mirror_integration_spec.loader:
    _mirror_integration_mod = importlib.util.module_from_spec(_mirror_integration_spec)
    _mirror_integration_spec.loader.exec_module(_mirror_integration_mod)
    _mirror_integration_mod.mirror_norms_integrate(globals(), COLONY)
    print(f"[MIRROR] 🪞 Personality Mirror + 👮 Norm Formation loaded", file=sys.stderr)
else:
    print(f"[MIRROR] WARNING: colony-mirror-integration.py not found — mirror/norms disabled", file=sys.stderr)

# Monkey-patch the existing GamesHandler to add expanded routes.
# This works because Python allows patching class methods at runtime.
_orig_do_GET = GamesHandler.do_GET
_orig_do_POST = GamesHandler.do_POST
_orig_send_json = GamesHandler.send_json


def _expanded_do_GET(self):
    try:
        return _expanded_do_GET_impl(self)
    except BrokenPipeError:
        pass
    except Exception as e:
        try:
            self.send_json({'error': str(e)}, 500)
        except Exception:
            pass

def _expanded_do_GET_impl(self):
    parsed = urlparse(self.path)
    path = parsed.path
    params = parse_qs(parsed.query)

    # 🪞 Personality Mirror + 👮 Norm Formation — check new routes FIRST
    try:
        handler, handler_params = _mirror_get_handler(path)
        if handler:
            combined_params = {k: v[0] if len(v) == 1 else v for k, v in params.items()}
            for k, v in handler_params.items():
                combined_params[k] = v
            return handler(self, combined_params)
    except Exception as e:
        pass  # fall through to original

    # 🎲 Deception Arena
    if path == '/game/deception/status':
        return self.send_json(deception_arena.status())

    # 🧬 Darwin's Arena
    if path == '/game/darwin/status':
        return self.send_json(darwin_arena.status())

    # 📊 Fitness Engine
    if path == '/fitness/status':
        return self.send_json(fitness_engine.status())

    if path == '/fitness/learning-curves':
        cells = lab.get_active_cell_ids()
        curves = {c: fitness_engine.learning_rate(c) for c in cells}
        return self.send_json({'learning_rates': curves})

    if path.startswith('/fitness/cell/'):
        cell = path.split('/fitness/cell/')[-1]
        if not cell:
            return self.send_json({'error': 'Need cell name'}, 400)
        return self.send_json({
            'cell': cell,
            'learning_rate': fitness_engine.learning_rate(cell),
            'reputation_capital': fitness_engine.reputation_capital(cell),
            'diversification': fitness_engine.state['diversification'].get(cell, []),
        })

    # 👑 Diplomacy
    if path == '/game/diplomacy/status':
        return self.send_json(diplomacy_engine.status())

    if path.startswith('/game/diplomacy/reputation/'):
        cell = path.split('/game/diplomacy/reputation/')[-1]
        return self.send_json({'cell': cell, 'reputation': diplomacy_engine.cell_reputation(cell)})

    # Fall through to original
    return _orig_do_GET(self)


def _expanded_do_POST(self):
    try:
        return _expanded_do_POST_impl(self)
    except BrokenPipeError:
        pass
    except Exception as e:
        try:
            self.send_json({'error': str(e)}, 500)
        except Exception:
            pass

def _expanded_do_POST_impl(self):
    content_length = int(self.headers.get('Content-Length', 0))
    body = self.rfile.read(content_length).decode() if content_length > 0 else '{}'
    parsed_path = urlparse(self.path)
    path = parsed_path.path

    try:
        data = json.loads(body)
    except json.JSONDecodeError as e:
        return self.send_json({'error': f'Invalid JSON: {e}'}, 400)

    # 🪞 Personality Mirror + 👮 Norm Formation — check new routes FIRST
    try:
        handler, handler_params, _ = _mirror_post_handler(path)
        if handler:
            return handler(self, handler_params, data)
    except Exception as e:
        pass  # fall through to original

    # 🕵️ Deception Arena
    if path == '/game/deception/claim':
        cell = data.get('cell', '')
        claim_type = data.get('claim_type', 'state')
        claim_data = data.get('claim_data', '')
        if not cell or not claim_data:
            return self.send_json({'error': 'Need cell and claim_data'}, 400)
        claim = deception_arena.make_claim(cell, claim_type, claim_data)
        discovery = fitness_engine.discovery_bonus(cell, 'deception')
        fitness_engine.record_game_type(cell, 'deception')
        fitness_engine.record_xp(cell, lab.get_cell_xp(cell))
        result = {'claim': claim}
        if discovery:
            result['discovery_bonus'] = discovery
        return self.send_json(result)

    if path == '/game/deception/verify':
        claim_id = data.get('claim_id', '')
        verifier = data.get('verifier', '')
        cross_ref = data.get('cross_ref_data', '')
        if not claim_id or not verifier or not cross_ref:
            return self.send_json({'error': 'Need claim_id, verifier, cross_ref_data'}, 400)
        result = deception_arena.verify_claim(claim_id, verifier, cross_ref)
        return self.send_json({'claim_id': claim_id, 'verified': result})

    # 🧬 Darwin's Arena
    if path == '/game/darwin/generation':
        cells = data.get('cells', lab.get_active_cell_ids())
        reputation_bonus = float(data.get('reputation_bonus', 0.0))
        reputation_mode = data.get('reputation_mode', 'additive')
        population = darwin_arena.run_generation(
            cells, 
            reputation_bonus=reputation_bonus,
            reputation_mode=reputation_mode
        )
        rec = {'generation': darwin_arena.state['generation'], 'population': population}
        if reputation_bonus > 0:
            rep_adjs = [{'cell': p['cell'], 'strategy': p['strategy'], 'fitness': round(p['fitness'], 3),
                         'rep_adj': p.get('reputation_adj', 0),
                         'betray_rate': p.get('betray_rate', 0),
                         'rep_multiplier': p.get('rep_multiplier', None)}
                        for p in population if p.get('reputation_adj', 0) != 0]
            rec['reputation_adjustments'] = rep_adjs
        return self.send_json(rec)

    # 👑 Diplomacy
    if path == '/game/diplomacy/pact':
        cell1 = data.get('cell1', '')
        cell2 = data.get('cell2', '')
        terms = data.get('terms', '')
        secret = data.get('secret_clause')
        if not cell1 or not cell2 or not terms:
            return self.send_json({'error': 'Need cell1, cell2, terms'}, 400)
        pact = diplomacy_engine.create_pact(cell1, cell2, terms, secret)
        fitness_engine.record_game_type(cell1, 'diplomacy')
        fitness_engine.record_game_type(cell2, 'diplomacy')
        return self.send_json({'pact': pact})

    if path == '/game/diplomacy/betray':
        pact_id = data.get('pact_id', '')
        betrayer = data.get('betrayer', '')
        advantage = data.get('advantage', 0)
        if not pact_id or not betrayer:
            return self.send_json({'error': 'Need pact_id, betrayer'}, 400)
        result = diplomacy_engine.betray(pact_id, betrayer, advantage)
        return self.send_json(result)

    # 📊 Fitness Engine
    if path == '/fitness/reputation/loan':
        from_cell = data.get('from_cell', '')
        to_cell = data.get('to_cell', '')
        amount = int(data.get('amount', 0))
        if not from_cell or not to_cell or amount < 1:
            return self.send_json({'error': 'Need from_cell, to_cell, amount'}, 400)
        result = fitness_engine.lend_reputation(from_cell, to_cell, amount)
        return self.send_json({'ok': result, 'from': from_cell, 'to': to_cell, 'amount': amount})

    if path == '/fitness/reputation/penalty':
        cell = data.get('cell', '')
        amount = int(data.get('amount', 0))
        reason = data.get('reason', 'unknown')
        if not cell or amount < 1:
            return self.send_json({'error': 'Need cell, amount'}, 400)
        fitness_engine.penalize_reputation(cell, amount, reason)
        return self.send_json({'ok': True, 'cell': cell, 'amount': amount, 'reason': reason})

    # Cache body for original handler (it will re-read, but we already consumed rfile)
    self._cached_body = body
    return _orig_do_POST(self)


# Apply monkey patches
GamesHandler.protocol_version = 'HTTP/1.0'
GamesHandler.do_GET = _expanded_do_GET
GamesHandler.do_POST = _expanded_do_POST

# ── Conservation law endpoints (γ+η=C) ───────────────────────────────────
# Injects /game/conserve/* endpoints as the outermost dispatch layer.
try:
    patch_games_handler(GamesHandler, lab)
    HAVE_CONSERVE = True
except Exception as e:
    print(f"[GAMES] Conservation patch failed: {e}", file=sys.stderr)
    HAVE_CONSERVE = False


# ═══════════════════════════════════════════════════════════════════════════════
# 🚀 Modified main() — expanded startup banner
# ═══════════════════════════════════════════════════════════════════════════════

_orig_main = main

def expanded_main():
    print(file=sys.stderr)
    print("╔═══════════════════════════════════════════════════════╗", file=sys.stderr)
    print("║     🎲  Colony Games — Agentic Psychology Lab        ║", file=sys.stderr)
    print("╠═══════════════════════════════════════════════════════╣", file=sys.stderr)
    print("║  🎮 Prisoner's Colloquium   🤝 Trust Auction        ║", file=sys.stderr)
    print("║  💚 Empathy Loop            🎲 Recursive Meta-Bet   ║", file=sys.stderr)
    print("║  🕵️ Deception Arena         🧬 Darwin's Arena       ║", file=sys.stderr)
    print("║  👑 Diplomacy               📊 Fitness Engine       ║", file=sys.stderr)
    print("║  🪞 Personality Mirror       👮 Norm Formation      ║", file=sys.stderr)
    print("╚═══════════════════════════════════════════════════════╝", file=sys.stderr)
    print(file=sys.stderr)
    print(f"  Port: {PORT}  |  Colony: {COLONY}", file=sys.stderr)
    print(file=sys.stderr)
    _orig_main()

main = expanded_main

# End of colony-games expansion

if __name__ == "__main__":
    main()
