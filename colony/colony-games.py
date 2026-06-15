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


if __name__ == "__main__":
    main()
