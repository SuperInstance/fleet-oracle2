#!/usr/bin/env python3
"""
colony_conservation_scorer.py — Score colony cells on 9 polyformalism channels.

Provides an integration between Forgemaster's `nine_channel_scorer.py` and
Oracle2's `colony-games.py`. Every game action produces a 9-channel profile
for each cell, computed from empirical behavioral data.

Channels: boundary, pattern, process, knowledge, social, deepstructure,
          instrument, paradigm, stakes

Usage:
    from colony_conservation_scorer import score_cell_from_ledger
    
    # Score all cells from the reputation ledger
    profiles = score_cell_from_ledger("game-reputation-ledger.json")
    
    # Or score a single cell from raw data
    profile = score_cell({
        "cooperation_rate": 0.8,
        "deception_score": 20,
        "betrayal_score": 0,
        "trust_score": 75,
        "generosity": 60,
        "games_played": 100,
    })
"""

import json
import math
from dataclasses import dataclass, field
from typing import Optional

# ─── 9-Channel Definitions ────────────────────────────────────────────────────
CHANNELS = [
    "boundary",      # Clear scope — does this cell stay in its lane?
    "pattern",       # Structural connections — does it form good topology?
    "process",       # Temporal flow — does its behavior change meaningfully?
    "knowledge",     # Factual rigor — is its data trustworthy?
    "social",        # Audience awareness — does it serve downstream consumers?
    "deepstructure", # Hidden meaning — is there depth behind its outputs?
    "instrument",    # Actionability — can others act on its output?
    "paradigm",      # Perspective shift — does it change how we see the system?
    "stakes",        # Significance — what breaks if this cell goes down?
]


@dataclass
class AgentProfile:
    """9-channel intent profile for a fleet agent."""
    agent_id: str
    channels: dict = field(default_factory=dict)

    def __post_init__(self):
        for ch in CHANNELS:
            if ch not in self.channels:
                self.channels[ch] = 0.0

    def vector(self) -> list[float]:
        return [self.channels[ch] for ch in CHANNELS]

    def top_channels(self, n: int = 3) -> list[tuple[str, float]]:
        return sorted(self.channels.items(), key=lambda x: x[1], reverse=True)[:n]

    def to_dict(self) -> dict:
        return {"agent_id": self.agent_id, "channels": self.channels}

    @classmethod
    def from_dict(cls, d: dict) -> "AgentProfile":
        return cls(agent_id=d.get("agent_id", "unknown"), channels=d.get("channels", {}))


def cosine_similarity(v1: list[float], v2: list[float]) -> float:
    """Cosine similarity between two vectors."""
    if len(v1) != len(v2):
        return 0.0
    dot = sum(a * b for a, b in zip(v1, v2))
    mag1 = math.sqrt(sum(a * a for a in v1))
    mag2 = math.sqrt(sum(b * b for b in v2))
    if mag1 == 0 or mag2 == 0:
        return 0.0
    return dot / (mag1 * mag2)


# ─── Cell Scoring ─────────────────────────────────────────────────────────────

def score_cell(cell_data: dict) -> AgentProfile:
    """
    Score a colony cell on 9 channels using behavioral fingerprint data.

    Input fields:
        agent_id (str): Cell identifier.
        cooperation_rate (float): 0.0-1.0 — how often this cell cooperates.
        deception_score (float): 0-100 — how much this cell lies in Deception Arena.
        betrayal_score (float): 0-100 — how much this cell breaks promises.
        trust_score (float): 0-100 — how much others trust this cell.
        generosity (float): 0-100 — how much this cell gives in Empathy Loop.
        games_played (int): Number of games participated in.
        avg_bid (float): Average bid amount in Trust Auctions.
        mafia_role (str): Role in Mafia if played.
        empathy_accuracy (float): 0.0-1.0 — accuracy in reading partner states.
    """
    agent_id = cell_data.get("agent_id", cell_data.get("id", "unknown"))

    # Extract metrics
    coop = cell_data.get("cooperation_rate", 0.5)
    deception = cell_data.get("deception_score", 0.0) / 100.0
    betrayal = cell_data.get("betrayal_score", 0.0) / 100.0
    trust = cell_data.get("trust_score", 50.0) / 100.0
    generosity = min(cell_data.get("generosity", 0) / 100.0, 1.0)
    empathy_accuracy = cell_data.get("empathy_accuracy", 0.5)
    games = cell_data.get("games_played", 0)
    avg_bid = cell_data.get("avg_bid", 50.0) / 100.0

    # Personality types (from the personality matrix)
    is_deceiver = deception > 0.3
    is_betrayer = betrayal > 0.3

    # ─── 9-Channel Scores ────────────────────────────────────────────────
    channels = {}

    # boundary (0-1): Does this cell stay in its lane?
    # High for non-role-switching cells. Cooperators are reliable.
    channels["boundary"] = min(1.0, coop * 0.6 + (1 - deception) * 0.2 + (1 - betrayal) * 0.2)

    # pattern (0-1): Structural connections — does it form good topology?
    # Cells with high trust and cooperation create stable network patterns.
    channels["pattern"] = min(1.0, coop * 0.4 + trust * 0.3 + avg_bid * 0.3)

    # process (0-1): Temporal flow — does behavior change meaningfully?
    # High for adaptive cells (TFT, random) that change strategy.
    # Low for pure cooperators/defectors that never change.
    adaptation = 1.0 - abs(coop - 0.5) * 2  # 0 = always same, 1 = balanced
    channels["process"] = max(0.1, min(1.0, adaptation * 0.6 + empathy_accuracy * 0.4))

    # knowledge (0-1): Factual rigor — is its behavior trustworthy?
    cells_played = min(games / 100.0, 1.0)
    honesty = 1.0 - deception
    channels["knowledge"] = min(1.0, honesty * 0.5 + cells_played * 0.3 + trust * 0.2)

    # social (0-1): Audience awareness — does it serve downstream consumers?
    generosity_scaled = generosity * 0.5
    coop_scaled = coop * 0.3
    empathy_scaled = empathy_accuracy * 0.2
    channels["social"] = min(1.0, generosity_scaled + coop_scaled + empathy_scaled)

    # deepstructure (0-1): Hidden meaning — is there depth behind outputs?
    # Deceptive cells that maintain covers score high.
    # Cells that betray AND cooperate strategically score highest.
    depth = (deception + betrayal) * 0.3 + (1 - abs(coop - 0.3)) * 0.4
    channels["deepstructure"] = max(0.1, min(1.0, depth))

    # instrument (0-1): Actionability — can others act on its output?
    # Cooperative, high-trust cells provide actionable information.
    channels["instrument"] = min(1.0, coop * 0.5 + trust * 0.3 + generosity * 0.2)

    # paradigm (0-1): Perspective shift — does it change how we see the system?
    # Defectors and unusual strategies shift perspective.
    # Random strategy cells are most paradigm-shifting.
    channels["paradigm"] = max(0.1, min(1.0, adaptation * 0.5 + (1 - coop) * 0.3 + deception * 0.2))

    # stakes (0-1): What breaks if this cell goes down?
    # Cells with central roles (high trust, many games) are high stakes.
    # Based on games played and trust — how much the fleet depends on this cell.
    channels["stakes"] = min(1.0, cells_played * 0.4 + trust * 0.3 + coop * 0.3)

    return AgentProfile(agent_id=agent_id, channels=channels)


def score_cell_from_ledger(ledger_path: str) -> dict[str, AgentProfile]:
    """
    Score all cells from the reputation ledger JSON file.

    The reputation ledger has keys like "cooperate_rate", "betray_rate"
    per cell. We fit these into the scoring model.

    Returns dict of {cell_id: AgentProfile}.
    """
    with open(ledger_path) as f:
        ledger = json.load(f)

    # The ledger format: dict of {cell_id: {cooperate_rate, betray_rate, ...}}
    cells = ledger.get("cells", {}) if isinstance(ledger, dict) else ledger

    profiles = {}
    for cell_id, cell_data in cells.items():
        # Map ledger fields to score_cell inputs
        mapped = {
            "agent_id": cell_id,
            "cooperation_rate": cell_data.get("cooperate_rate",
                               cell_data.get("cooperation_rate", 0.5)),
            "deception_score": cell_data.get("deception_score", 0),
            "betrayal_score": cell_data.get("betrayal_score", 0),
            "trust_score": cell_data.get("trust_score", 50),
            "generosity": cell_data.get("generosity", 0),
            "games_played": cell_data.get("games_played", 0),
            "empathy_accuracy": cell_data.get("empathy_accuracy", 0.5),
        }
        profiles[cell_id] = score_cell(mapped)

    return profiles


# ─── Edge alignment ────────────────────────────────────────────────────────────

def edge_alignment(producer: AgentProfile, consumer: AgentProfile) -> float:
    """
    Compute edge alignment between a producer and consumer.

    Edge alignment measures how well a producer's output fits
    a consumer's input requirements, based on 9-channel similarity.
    Returns 0.0 (mismatched) to 1.0 (perfect alignment).
    """
    return cosine_similarity(producer.vector(), consumer.vector())


# ─── Role classification ──────────────────────────────────────────────────────

def classify_role(profile: AgentProfile) -> str:
    """
    Classify an agent's role based on its dominant channels.

    Rules:
        - Social > 0.7: "COMMUNICATOR"
        - Instrument > 0.7: "OPERATOR"
        - Knowledge > 0.7: "ARCHIVIST"
        - Pattern > 0.7: "MAPPER"
        - Process > 0.7: "PROCESSOR"
        - DeepStructure > 0.7: "STRATEGIST"
        - Boundary > 0.7: "GATEKEEPER"
        - Paradigm > 0.7: "VISIONARY"
        - Stakes > 0.7: "ANCHOR"
        - else: "GENERALIST"
    """
    channels = profile.channels
    if channels.get("social", 0) > 0.7:
        return "COMMUNICATOR"
    if channels.get("instrument", 0) > 0.7:
        return "OPERATOR"
    if channels.get("knowledge", 0) > 0.7:
        return "ARCHIVIST"
    if channels.get("pattern", 0) > 0.7:
        return "MAPPER"
    if channels.get("process", 0) > 0.7:
        return "PROCESSOR"
    if channels.get("deepstructure", 0) > 0.7:
        return "STRATEGIST"
    if channels.get("boundary", 0) > 0.7:
        return "GATEKEEPER"
    if channels.get("paradigm", 0) > 0.7:
        return "VISIONARY"
    if channels.get("stakes", 0) > 0.7:
        return "ANCHOR"
    return "GENERALIST"


# ─── Conservation law integration ─────────────────────────────────────────────

def delta_n(n: int) -> float:
    """δ(n) = (1/√n)(1 − 3/(2n)) — the CLT cancellation rate."""
    if n < 1:
        return float('inf')
    return (1.0 / math.sqrt(n)) * (1.0 - 3.0 / (2.0 * n))


def compute_fleet_efficiency(profiles: dict[str, AgentProfile]) -> dict:
    """
    Compute fleet-wide conservation metrics from cell profiles.

    γ (gamma) = average profile magnitude across all cells (productive capacity)
    η (eta)   = average pairwise cosine dissimilarity (coordination overhead)
    C (total) = γ + η (conserved)
    """
    n = len(profiles)
    if n == 0:
        return {"n": 0, "gamma": 0, "eta": 0, "C": 0, "delta": 0}

    profiles_list = list(profiles.values())

    # γ = mean vector magnitude (how much productive signal each cell carries)
    gamma = sum(math.sqrt(sum(v ** 2 for v in p.vector())) for p in profiles_list) / n

    # η = mean pairwise (1 - cosine_similarity) = overhead from misalignment
    sum_dissim = 0.0
    pairs = 0
    for i in range(n):
        for j in range(i + 1, n):
            sim = cosine_similarity(profiles_list[i].vector(), profiles_list[j].vector())
            sum_dissim += 1.0 - sim
            pairs += 1

    eta = sum_dissim / pairs if pairs > 0 else 0

    return {
        "n": n,
        "gamma": round(gamma, 4),
        "eta": round(eta, 4),
        "C": round(gamma + eta, 4),
        "delta": round(delta_n(n), 4),
        "gamma_predicted": round(1.0 - delta_n(n), 4),
    }


# ─── Main (test with colony experiment data) ──────────────────────────────────
if __name__ == "__main__":
    # Test with the 6 cells from the personality matrix experiment
    cells = [
        {"agent_id": "bottle-counter", "cooperation_rate": 0.3, "deception_score": 80, "betrayal_score": 0, "trust_score": 45, "generosity": 20, "games_played": 50},
        {"agent_id": "chek-squared", "cooperation_rate": 0.2, "deception_score": 90, "betrayal_score": 80, "trust_score": 30, "generosity": 10, "games_played": 50},
        {"agent_id": "culler", "cooperation_rate": 0.1, "deception_score": 85, "betrayal_score": 90, "trust_score": 15, "generosity": 5, "games_played": 50},
        {"agent_id": "harvester", "cooperation_rate": 0.4, "deception_score": 0, "betrayal_score": 95, "trust_score": 55, "generosity": 30, "games_played": 50},
        {"agent_id": "logger", "cooperation_rate": 0.3, "deception_score": 70, "betrayal_score": 60, "trust_score": 40, "generosity": 15, "games_played": 50},
        {"agent_id": "synthesizer", "cooperation_rate": 0.2, "deception_score": 75, "betrayal_score": 85, "trust_score": 25, "generosity": 20, "games_played": 50},
    ]

    print("═" * 60)
    print("Colony 9-Channel Conservation Scoring")
    print("═" * 60)

    profiles = {}
    for c in cells:
        p = score_cell(c)
        profiles[c["agent_id"]] = p
        role = classify_role(p)
        print(f"\n📊 {p.agent_id} — {role}")
        for ch, score in sorted(p.channels.items(), key=lambda x: x[1], reverse=True):
            bar = "█" * int(score * 20) + "░" * (20 - int(score * 20))
            print(f"  {ch:16s} {bar} {score:.2f}")

    # Fleet efficiency
    efficiency = compute_fleet_efficiency(profiles)
    print(f"\n📈 Fleet Conservation Metrics")
    print(f"  n={efficiency['n']}, γ={efficiency['gamma']}, η={efficiency['eta']}, C={efficiency['C']}")
    print(f"  Predicted δ({efficiency['n']}) = {efficiency['delta']}")
    print(f"  γ predicted = {efficiency['gamma_predicted']}")

    # Edge alignment matrix
    print(f"\n🔗 Edge Alignment Matrix")
    ids = list(profiles.keys())
    print(f"     {'  '.join(f'{id[:5]:>6s}' for id in ids)}")
    for i, id_i in enumerate(ids):
        row = f"{id_i[:8]:8s}"
        for j, id_j in enumerate(ids):
            sim = edge_alignment(profiles[id_i], profiles[id_j])
            row += f"{sim:.2f}  "
        print(row)

    # Bottle integration test
    from superinstance_bottle import Bottle, audit

    bottle = Bottle.new(
        src="colony-conservation-scorer",
        tgt="fleet-pulse",
        act="conservation.fleet.efficiency",
        trits=[1, -1, 0],
        payload=efficiency,
        ttl=60,
    )
    print(f"\n📦 Bottle: {bottle}")
    print(f"  Payload: {bottle.decode_payload()}")

    # Verify round-trip
    decoded = Bottle.decode(bottle.encode())
    assert decoded.decode_payload() == efficiency
    print("  ✅ Round-trip verified")

    print("\n✅ Scoring system operational")
