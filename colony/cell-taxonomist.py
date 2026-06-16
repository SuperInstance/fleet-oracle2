#!/usr/bin/env python3
"""
cell-taxonomist.py — Bridge live Rust cells into colony psychology experiments.

The 14 active Rust cell binaries produce real system metrics (GC efficiency,
pulse timing, rotation quality, bottle delivery rate). The colony games server
runs psychology experiments (PD, Deception, Darwin, Diplomacy).

This daemon bridges them:

  Cell metrics → Cell Taxonomist → Colony reputation ledger
                                    → Personality fingerprints for each cell
                                    → Game decisions based on real behavior

Two-way:
  1. Cell's actual system performance → personality profile → games reputation
  2. Game outcomes → resource policy hints → cell can read and adapt

Usage:
  python3 cell-taxonomist.py --colony <path> [--interval 60] [--games-port 8823]

Architecture:
  ┌─────────┐  ┌─────────┐  ┌─────────┐      ┌──────────────────┐
  │ harvester│  │pulse-ck │  │oracle-br│ ...  │  Cell Taxonomist  │
  │ (Rust)   │  │ (Rust)  │  │ (Rust)  │      │  (Python bridge)  │
  └────┬─────┘  └────┬─────┘  └────┬─────┘      └────────┬─────────┘
       │ metrics     │ metrics     │ metrics              │
       ▼             ▼             ▼                      ▼
  ┌────────────────────────────────────────┐    ┌──────────────────┐
  │  Forge Lab (:8821)                     │    │  Colony Games    │
  │  • Hall of Crabs (XP, rankings)        │───▶│  (:8823)         │
  │  • Cell registry                       │    │  • Rep ledger    │
  │  • Level/progress                      │    │  • PD rounds     │
  └────────────────────────────────────────┘    │  • Deception     │
                                                │  • Darwin        │
                                                │  • Diplomacy     │
                                                │  • Conservation  │
                                                └──────────────────┘
"""

import json, os, sys, time, math, random, argparse
import urllib.request, urllib.error, urllib.parse
from datetime import datetime, timezone
from collections import defaultdict

# ── Defaults ────────────────────────────────────────────────────────────
COLONY_DEFAULT = os.environ.get("COLONY", os.path.dirname(os.path.abspath(__file__)))
GAMES_PORT = int(os.environ.get("GAMES_PORT", 8823))
INTERVAL = int(os.environ.get("TAXONOMIST_INTERVAL", 60))

# ── Personality Model ──────────────────────────────────────────────────
# Each cell gets scored on these axes based on its real system behavior.
# The scoring is heuristic — derived from forge-lab rankings, cell activity,
# bottle delivery rates, and GC patterns.

PERSONALITY_AXES = [
    "industriousness",    # Does the cell work consistently?
    "territoriality",     # Does the cell guard its domain?
    "generosity",         # Does the cell share resources?
    "curiosity",          # Does the cell explore new patterns?
    "conservatism",       # Does the cell resist change?
    "communicativeness",  # Does the cell send bottles/messages?
    "opportunism",        # Does the cell seize temporary advantages?
    "resilience",         # Does the cell recover from failures?
]

CELL_LEVEL_THRESHOLDS = {
    "Scout": 0,
    "Worker": 1000,
    "Specialist": 2500,
    "Strategist": 5000,
    "Oracle": 10000,
}

TAXONOMIC_ROLES = [
    ("The Gatherer",      {"industriousness": 1.5, "territoriality": -0.5, "resilience": 0.3, "generosity": 0.2}),
    ("The Guardian",      {"territoriality": 1.5, "generosity": -0.5, "conservatism": 0.3, "communicativeness": -0.2}),
    ("The Diplomat",      {"generosity": 1.0, "communicativeness": 1.0, "opportunism": -0.5, "territoriality": -0.3}),
    ("The Explorer",      {"curiosity": 1.5, "conservatism": -0.5, "opportunism": 0.3, "territoriality": -0.3}),
    ("The Sage",          {"conservatism": 1.0, "resilience": 1.0, "curiosity": -0.3, "opportunism": -0.3}),
    ("The Trickster",     {"opportunism": 1.5, "curiosity": 0.5, "industriousness": -0.3, "generosity": -0.3}),
    ("The Anchor",        {"resilience": 1.5, "curiosity": -0.5, "industriousness": 0.3, "communicativeness": -0.2}),
    ("The Hermit",        {"communicativeness": -1.0, "conservatism": 0.8, "resilience": 0.3, "curiosity": -0.3}),
    ("The Trader",        {"generosity": 0.7, "opportunism": 0.7, "communicativeness": 0.3, "territoriality": -0.3}),
    ("The Architect",     {"industriousness": 0.8, "conservatism": 0.8, "opportunism": -0.5, "curiosity": 0.3}),
]


class CellTaxonomist:
    """The bridge between live Rust cells and colony psychology experiments."""

    def __init__(self, colony_path: str, games_port: int = GAMES_PORT,
                 interval: int = INTERVAL):
        self.colony_path = colony_path
        self.games_port = games_port
        self.interval = interval
        self.games_base = f"http://localhost:{games_port}"

        # ── State ────────────────────────────────────────────────────
        self.last_profiles = {}       # cell_id → PersonalityProfile
        self.last_colony_snapshot = {}
        self.cell_history = defaultdict(list)  # cell_id → [snapshots]
        self.cycle = 0
        self.game_outcomes = defaultdict(list)  # cell_id → [game_results]

        # ── Paths ────────────────────────────────────────────────────
        self.taxonomy_ledger = os.path.join(colony_path, "game-taxonomy-ledger.json")
        self._load_ledger()

    def _load_ledger(self):
        try:
            with open(self.taxonomy_ledger) as f:
                data = json.load(f)
                self.last_profiles = data.get("profiles", {})
                self.cell_history = defaultdict(
                    list, {k: v for k, v in data.get("history", {}).items()}
                )
                self.cycle = data.get("cycle", 0)
        except (FileNotFoundError, json.JSONDecodeError):
            self.last_profiles = {}
            self.cell_history = defaultdict(list)
            self.cycle = 0

    def _save_ledger(self):
        os.makedirs(os.path.dirname(self.taxonomy_ledger) or ".", exist_ok=True)
        with open(self.taxonomy_ledger, "w") as f:
            json.dump({
                "profiles": self.last_profiles,
                "history": dict(self.cell_history),
                "cycle": self.cycle,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }, f, indent=2, default=str)

    def _fetch_json(self, url: str, data: dict = None) -> dict:
        """Fetch JSON from an API endpoint with retries."""
        for attempt in range(3):
            try:
                if data is not None:
                    body = json.dumps(data).encode()
                    req = urllib.request.Request(
                        url, data=body,
                        headers={"Content-Type": "application/json"},
                        method="POST"
                    )
                else:
                    req = urllib.request.Request(url)

                with urllib.request.urlopen(req, timeout=10) as resp:
                    return json.loads(resp.read().decode())
            except (urllib.error.URLError, json.JSONDecodeError, OSError) as e:
                if attempt < 2:
                    time.sleep(0.5)
                    continue
                return {"error": str(e)}

    def poll_forge_lab(self) -> dict:
        """Fetch the Hall of Crabs and cell registry from forge-lab (:8821)."""
        hall = self._fetch_json("http://localhost:8821/forge/status")
        return hall

    def poll_games_ledger(self) -> dict:
        """Fetch the games reputation ledger and conservation status."""
        rep = self._fetch_json(f"{self.games_base}/games/status")
        conserve = self._fetch_json(f"{self.games_base}/game/conserve/score")
        darwin = self._fetch_json(f"{self.games_base}/game/darwin/status")
        return {
            "colony_status": rep,
            "conservation": conserve,
            "darwin": darwin,
        }

    def poll_conservation_meter(self) -> dict:
        """Fetch the conservation meter HTML and extract JSON if possible."""
        try:
            with urllib.request.urlopen(
                "http://localhost:8798/api/health", timeout=5
            ) as resp:
                return json.loads(resp.read().decode())
        except Exception:
            return {"error": "meter not available"}

    # ── Personality Inference ────────────────────────────────────────

    def _infer_personality(self, cell_id: str, forge_data: dict,
                           colony_data: dict) -> dict:
        """
        Infer a cell's personality from its behavior data.

        Uses heuristic rules based on:
        - XP and level from forge hall
        - Cell type suffix (e.g., "counter", "culler", "breeder")
        - Conservation profile channels
        - Darwin arena strategy (if applicable)
        - PD history (if applicable)
        - Cell name patterns
        """
        pf = {}  # personality factors ∈ [0.0, 1.0]

        # ── 1. XP-based traits ──────────────────────────────────────
        hall = forge_data.get("hall", {})
        rankings = hall.get("rankings", [])
        cell_rank = None
        cell_xp = 0
        cell_level = "Scout"

        for entry in rankings:
            if entry.get("cell_id") == cell_id:
                cell_rank = entry
                cell_xp = entry.get("xp", 0)
                cell_level = entry.get("level", "Scout")
                break

        # Normalize XP to [0,1] — max observed is ~7000
        xp_norm = min(cell_xp / 10000.0, 1.0)

        # Higher XP → more industrious
        pf["industriousness"] = 0.3 + xp_norm * 0.7

        # Higher XP → more resilient (survived this long)
        pf["resilience"] = 0.4 + xp_norm * 0.6

        # ── 2. Cell name → trait inference ──────────────────────────
        name_lower = cell_id.lower()

        # Cell type categories (from observed cell names)
        if any(term in name_lower for term in ["counter", "logger", "check"]):
            pf["industriousness"] = min(pf.get("industriousness", 0.5) + 0.2, 1.0)
            pf["conservatism"] = 0.6  # meticulous, rule-following
            pf["curiosity"] = 0.3

        if any(term in name_lower for term in ["culler", "culled", "crier"]):
            pf["territoriality"] = 0.7
            pf["opportunism"] = 0.6
            pf["generosity"] = 0.2

        if any(term in name_lower for term in ["harvester", "breeder", "synth"]):
            pf["generosity"] = 0.6
            pf["industriousness"] = min(pf.get("industriousness", 0.5) + 0.15, 1.0)
            pf["territoriality"] = 0.3

        if "oracle" in name_lower:
            pf["curiosity"] = 0.8
            pf["communicativeness"] = 0.7
            pf["conservatism"] = 0.4

        if "pulse" in name_lower:
            pf["communicativeness"] = 0.7
            pf["industriousness"] = min(pf.get("industriousness", 0.5) + 0.1, 1.0)

        if any(term in name_lower for term in ["ward", "guard", "warden"]):
            pf["territoriality"] = 0.8
            pf["conservatism"] = 0.6
            pf["opportunism"] = 0.2

        # ── 3. Level-based traits ───────────────────────────────────
        level_map = {
            "Scout": {"curiosity": 0.6, "resilience": 0.3},
            "Worker": {"industriousness": 0.6, "conservatism": 0.4},
            "Specialist": {"curiosity": 0.4, "conservatism": 0.6},
            "Strategist": {"opportunism": 0.5, "communicativeness": 0.6},
            "Oracle": {"curiosity": 0.7, "generosity": 0.5, "resilience": 0.7},
        }
        if cell_level in level_map:
            for trait, val in level_map[cell_level].items():
                pf[trait] = max(pf.get(trait, 0.5), val)

        # ── 4. Conservation profile (if available) ──────────────────
        conserve = colony_data.get("conservation", {})
        cells = conserve.get("cells", {})
        cell_profile = cells.get(cell_id, {})
        if cell_profile:
            channels = cell_profile.get("top3", [])
            role = cell_profile.get("role", "")
            if "Boundary" in channels:
                pf["territoriality"] = min(pf.get("territoriality", 0.5) + 0.2, 1.0)
            if "Pattern" in channels:
                pf["curiosity"] = min(pf.get("curiosity", 0.5) + 0.2, 1.0)
            if "Social" in channels:
                pf["communicativeness"] = min(pf.get("communicativeness", 0.5) + 0.2, 1.0)
            if "Knowledge" in channels:
                pf["conservatism"] = min(pf.get("conservatism", 0.5) + 0.15, 1.0)
            if "Process" in channels:
                pf["industriousness"] = min(pf.get("industriousness", 0.5) + 0.2, 1.0)
            if role in ("Integrator", "Catalyst"):
                pf["generosity"] = min(pf.get("generosity", 0.5) + 0.2, 1.0)

        # ── 5. Darwin arena strategy (if cell participates) ─────────
        darwin = colony_data.get("darwin", {})
        population = darwin.get("population", [])
        for p in population:
            if p.get("cell") == cell_id:
                strat = p.get("strategy", "")
                betray = p.get("betray_rate", 0.0)
                pf["opportunism"] = max(pf.get("opportunism", 0.5), betray)
                if strat == "cooperate":
                    pf["generosity"] = min(pf.get("generosity", 0.5) + 0.4, 1.0)
                elif strat == "defect":
                    pf["opportunism"] = min(pf.get("opportunism", 0.5) + 0.3, 1.0)
                elif strat == "tit-for-tat":
                    pf["resilience"] = min(pf.get("resilience", 0.5) + 0.3, 1.0)
                elif strat == "grudge":
                    pf["territoriality"] = min(pf.get("territoriality", 0.5) + 0.3, 1.0)
                break

        # ── Fill in default values ──────────────────────────────────
        for axis in PERSONALITY_AXES:
            if axis not in pf:
                pf[axis] = 0.5  # neutral default

        return pf

    def _classify_taxonomic_role(self, pf: dict) -> str:
        """Assign a taxonomic role based on personality factor weights."""
        role_scores = {}
        for role_name, weights in TAXONOMIC_ROLES:
            score = 0.0
            for trait, weight in weights.items():
                val = pf.get(trait, 0.5)
                if weight > 0:
                    score += val * weight
                else:
                    score += (1.0 - val) * abs(weight)
            role_scores[role_name] = score + random.uniform(-0.05, 0.05)

        return max(role_scores, key=role_scores.get)

    # ── Game Integration ─────────────────────────────────────────────

    def _decide_pd_move(self, cell_id: str, pf: dict) -> str:
        """
        Decide whether a cell cooperates or defects in Prisoner's Dilemma,
        based on its personality.

        Rules:
        - High generosity (>0.6) + low opportunism (<0.4) → cooperate
        - High territoriality (>0.7) → defect (guards territory)
        - High opportunism (>0.6) → defect (seizes chance)
        - High communicativeness + high industriousness → tit-for-tat
        - Otherwise → weighted random based on generosity
        """
        if pf.get("generosity", 0.5) > 0.6 and pf.get("opportunism", 0.5) < 0.4:
            return "cooperate"
        if pf.get("territoriality", 0.5) > 0.7:
            return "defect"
        if pf.get("opportunism", 0.5) > 0.6:
            return "defect"
        if pf.get("communicativeness", 0.5) > 0.6 and pf.get("industriousness", 0.5) > 0.5:
            return "cooperate" if random.random() < 0.5 else "defect"

        # Weighted random: generosity → cooperate, otherwise → defect
        return "cooperate" if random.random() < pf.get("generosity", 0.5) else "defect"

    def _decide_darwin_strategy(self, cell_id: str, pf: dict) -> str:
        """
        Decide Darwin Arena strategy from personality.
        """
        score_map = {}
        for strategy in ["cooperate", "defect", "tit-for-tat", "grudge", "random"]:
            score = 0
            if strategy == "cooperate":
                score = pf.get("generosity", 0.5) * 1.0 + pf.get("industriousness", 0.5) * 0.3
            elif strategy == "defect":
                score = pf.get("opportunism", 0.5) * 1.0 + pf.get("territoriality", 0.5) * 0.5
            elif strategy == "tit-for-tat":
                score = pf.get("resilience", 0.5) * 0.7 + pf.get("communicativeness", 0.5) * 0.5
            elif strategy == "grudge":
                score = pf.get("territoriality", 0.5) * 0.8 + pf.get("conservatism", 0.5) * 0.6
            elif strategy == "random":
                score = pf.get("curiosity", 0.5) * 0.5 + pf.get("opportunism", 0.5) * 0.3
            score_map[strategy] = score + random.uniform(-0.1, 0.1)  # Add noise

        return max(score_map, key=score_map.get)

    def _determine_empathy_gift(self, cell_id: str, pf: dict,
                                all_cells: list) -> list:
        """
        Determine who this cell would gift XP to, based on personality.

        Returns list of (recipient, amount, reason) tuples.
        """
        gifts = []
        generosity = pf.get("generosity", 0.5)
        if generosity < 0.3:
            return gifts  # Stingy cells don't gift

        # Build affinity scores for other cells
        other_profiles = {c: self.last_profiles.get(c, {}) for c in all_cells if c != cell_id}
        if not other_profiles:
            return gifts

        # Affinity: similar communicativeness, complementary industriousness
        affinities = []
        for other_id, other_pf in other_profiles.items():
            if not other_pf:
                continue
            comm_sim = 1.0 - abs(pf.get("communicativeness", 0.5) - other_pf.get("communicativeness", 0.5))
            ind_comp = abs(pf.get("industriousness", 0.5) - other_pf.get("industriousness", 0.5))
            score = comm_sim * 0.6 + ind_comp * 0.4 + random.uniform(-0.2, 0.2)
            affinities.append((other_id, score))

        affinities.sort(key=lambda x: x[1], reverse=True)

        # Gift to top 1-2 cells if generosity is moderate-high
        gift_count = min(2, int(generosity * 3))
        for i in range(min(gift_count, len(affinities))):
            recipient, affinity = affinities[i]
            if affinity < 0:
                continue
            amount = max(1, int(generosity * 10 * affinity))
            gift_type = random.choices(
                ["resource_share", "info_bottle", "protection_offer"],
                weights=[0.5, 0.3, 0.2]
            )[0]
            gifts.append({
                "recipient": recipient,
                "amount": amount,
                "affinity_score": round(affinity, 3),
                "gift_type": gift_type,
            })

        return gifts

    # ── Main Loop ────────────────────────────────────────────────────

    def run_cycle(self):
        """One complete taxonomy cycle."""
        self.cycle += 1
        timestamp = datetime.now(timezone.utc).isoformat()

        print(f"\n[TAXONOMIST] Cycle {self.cycle} — {timestamp}")
        print(f"[TAXONOMIST] Polling data sources...")

        # 1. Gather data from all sources
        forge_data = self.poll_forge_lab()
        colony_data = self.poll_games_ledger()
        conserve = self.poll_conservation_meter()

        # 2. Get cell list
        hall = forge_data.get("hall", {})
        rankings = hall.get("rankings", [])
        cell_ids = [r.get("cell_id") for r in rankings if r.get("cell_id")]
        colony_status = colony_data.get("colony_status", {})
        colony_cells = colony_status.get("cell_ids", [])
        all_cells = list(set(cell_ids + colony_cells))

        if not all_cells:
            print(f"[TAXONOMIST] No cells found — is forge-lab running?")
            return False

        print(f"[TAXONOMIST] Found {len(all_cells)} cells: {all_cells[:5]}...")

        # 3. Infer personality for each cell
        profiles = {}
        for cell_id in all_cells:
            pf = self._infer_personality(cell_id, forge_data, colony_data)
            role = self._classify_taxonomic_role(pf)
            profiles[cell_id] = {
                "personality": pf,
                "taxonomic_role": role,
                "level": None,
                "xp": 0,
            }
            # Enrich with hall data
            for r in rankings:
                if r.get("cell_id") == cell_id:
                    profiles[cell_id]["level"] = r.get("level")
                    profiles[cell_id]["xp"] = r.get("xp")
                    break

        # 4. Update history
        for cell_id in all_cells:
            self.cell_history[cell_id].append({
                "cycle": self.cycle,
                "profile": profiles[cell_id],
                "timestamp": timestamp,
            })
            # Trim history to last 1000 entries per cell
            if len(self.cell_history[cell_id]) > 1000:
                self.cell_history[cell_id] = self.cell_history[cell_id][-1000:]

        self.last_profiles = profiles

        # 5. Generate game recommendations
        game_recs = {"pd_moves": {}, "darwin_strategies": {}, "empathy_gifts": {}}
        for cell_id, pdata in profiles.items():
            pf = pdata["personality"]
            game_recs["pd_moves"][cell_id] = self._decide_pd_move(cell_id, pf)
            game_recs["darwin_strategies"][cell_id] = self._decide_darwin_strategy(cell_id, pf)
            gifts = self._determine_empathy_gift(cell_id, pf, all_cells)
            if gifts:
                game_recs["empathy_gifts"][cell_id] = gifts

        # 6. Persist
        self._save_ledger()

        # 7. Push to colony games (POST)
        print(f"[TAXONOMIST] Pushing {len(profiles)} profiles to colony games...")
        try:
            payload = {
                "cycle": self.cycle,
                "profiles": profiles,
                "game_recommendations": game_recs,
                "conservation_snapshot": conserve,
                "timestamp": timestamp,
            }
            self._fetch_json(
                f"{self.games_base}/game/conserve/taxonomy",
                data=payload
            )
        except Exception as e:
            print(f"[TAXONOMIST] Push warning: {e}")

        # 8. Print summary
        print(f"\n[TAXONOMIST] ── Cycle {self.cycle} Summary ──")
        sorted_cells = sorted(profiles.items(),
                              key=lambda x: x[1].get("xp", 0), reverse=True)
        for i, (cid, pdata) in enumerate(sorted_cells[:5]):
            pf = pdata["personality"]
            top_traits = sorted(pf.items(), key=lambda x: x[1], reverse=True)[:3]
            trails = ", ".join(f"{t}={v:.2f}" for t, v in top_traits)
            print(f"  {i+1}. {cid:25s} [{pdata['taxonomic_role']:20s}] {trails}")
        print(f"[TAXONOMIST] ── End Cycle {self.cycle} ──\n")

        return True

    def run(self):
        """Run the taxonomist loop indefinitely."""
        print(f"\n{'═' * 60}")
        print(f"  🧬 Cell Taxonomist — Personality Bridge")
        print(f"  Colony: {self.colony_path}")
        print(f"  Games:  {self.games_base}")
        print(f"  Cycle:  every {self.interval}s")
        print(f"{'═' * 60}\n")

        # Initial cycle
        self.run_cycle()

        while True:
            try:
                time.sleep(self.interval)
                self.run_cycle()
            except KeyboardInterrupt:
                print("\n[TAXONOMIST] Shutting down...")
                self._save_ledger()
                break
            except Exception as e:
                print(f"[TAXONOMIST] Error: {e}")
                time.sleep(10)


# ── CLI ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="🧬 Cell Taxonomist — Bridge Rust cells into colony psychology"
    )
    parser.add_argument("--colony", default=COLONY_DEFAULT,
                        help=f"Colony path (default: {COLONY_DEFAULT})")
    parser.add_argument("--games-port", type=int, default=GAMES_PORT,
                        help=f"Games server port (default: {GAMES_PORT})")
    parser.add_argument("--interval", type=int, default=INTERVAL,
                        help=f"Poll interval seconds (default: {INTERVAL})")
    parser.add_argument("--oneshot", action="store_true",
                        help="Run one cycle and exit")
    args = parser.parse_args()

    taxonomist = CellTaxonomist(
        colony_path=args.colony,
        games_port=args.games_port,
        interval=args.interval,
    )

    if args.oneshot:
        taxonomist.run_cycle()
    else:
        taxonomist.run()


if __name__ == "__main__":
    main()
