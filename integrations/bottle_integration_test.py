#!/usr/bin/env python3
"""
bottle_integration_test.py — Integration test: colony games ➔ protocol bottles ➔ conservation scorer.

Exercises the full pipeline:
  1. Play colony PD games → get raw scores
  2. Wrap scores in protocol bottles (superinstance-protocol format)
  3. Score cells on 9 channels (conservation scorer)
  4. Compute fleet-wide γ + η = C
  5. Verify conservation

This is a REAL test: it exits non-zero (return code = number of failures) if any
conservation invariant is broken. It includes *negative* checks that deliberately
violate conservation and assert the violation is detected — those prove the
assertions have teeth rather than being structurally unfalsifiable.

Run:
    python3 integrations/bottle_integration_test.py
Exit code: 0 = all checks passed, N = number of failed checks.
Requires: msgpack (`pip install msgpack`).
"""

import json, sys, os, random, math, time
from pathlib import Path

# Ensure we can find local modules
sys.path.insert(0, os.path.dirname(__file__))

from superinstance_bottle import Bottle, BottleHeader, audit, audit_strict, ConservationError
from colony_conservation_scorer import (
    score_cell, AgentProfile, compute_fleet_efficiency,
    edge_alignment, classify_role, delta_n, CHANNELS
)

# ─── Test harness ─────────────────────────────────────────────────────────────
# Every meaningful claim goes through expect(), which records pass/fail and makes
# the process exit non-zero on any failure. Previously the conservation checks
# were either swallowed in try/except or compared structurally-identical bottles,
# so the test could never fail — it was fake-green.
FAILURES = []
PASSES = []


def expect(condition: bool, name: str, detail: str = "") -> None:
    """Record a pass/fail. A False condition is a hard test failure."""
    if condition:
        PASSES.append(name)
        print(f"  ✅ PASS: {name}" + (f" — {detail}" if detail else ""))
    else:
        FAILURES.append(name)
        print(f"  ❌ FAIL: {name}" + (f" — {detail}" if detail else ""))


# ─── Phase 1: Play Colony Games ──────────────────────────────────────────────
print("═" * 72)
print("Phase 1: Simulate Colony Game Rounds")
print("═" * 72)

random.seed(42)  # deterministic game outcomes so checks are reproducible

# Simulate 100 rounds of PD between 13 cells
players = 13
strategies = ["cooperate", "defect", "tit-for-tat", "grudge", "random"]

def gen_move(strat: str, history: dict) -> str:
    if strat == "cooperate": return "cooperate"
    if strat == "defect": return "defect"
    if strat == "random": return random.choice(["cooperate", "defect"])
    if strat == "tit-for-tat":
        # Cooperate unless opponent last defected
        opp_last = history.get("last_opponent_move")
        return "cooperate" if opp_last != "defect" else "defect"
    if strat == "grudge":
        return "defect" if history.get("ever_betrayed", False) else "cooperate"
    return "cooperate"

pd_payoff = {
    ("cooperate", "cooperate"): (3, 3),
    ("defect", "defect"): (1, 1),
    ("cooperate", "defect"): (0, 5),
    ("defect", "cooperate"): (5, 0),
}

cells = {f"cell-{i:03d}": {"strategy": random.choice(strategies), "score": 0, "moves": []}
         for i in range(players)}

# Simulate 100 rounds with random pairing
for round_num in range(100):
    # Pair cells randomly
    shuffled = list(cells.keys())
    random.shuffle(shuffled)
    for i in range(0, len(shuffled) - 1, 2):
        id1, id2 = shuffled[i], shuffled[i+1]
        s1, s2 = cells[id1]["strategy"], cells[id2]["strategy"]
        m1 = gen_move(s1, {"ever_betrayed": False, "last_opponent_move": "cooperate" if round_num == 0 else None})
        m2 = gen_move(s2, {"ever_betrayed": False, "last_opponent_move": "cooperate" if round_num == 0 else None})
        p1, p2 = pd_payoff[(m1, m2)]
        cells[id1]["score"] += p1
        cells[id2]["score"] += p2
        cells[id1]["moves"].append((round_num, id2, m1))
        cells[id2]["moves"].append((round_num, id1, m2))

print(f"  100 rounds played across {players} cells")
avg_score = sum(c["score"] for c in cells.values()) / players
print(f"  Average score: {avg_score:.1f} (max possible: 500)")

# ─── Phase 2: Wrap Results in Bottles + Conservation Audit ────────────────────
print("\n" + "═" * 72)
print("Phase 2: Wrap Results in superinstance-protocol Bottles")
print("═" * 72)

round_results = [{
    "cell_id": cid,
    "score": data["score"],
    "strategy": data["strategy"],
    "moves_count": len(data["moves"]),
} for cid, data in cells.items()]

bottle = Bottle.new(
    src="colony-games",
    tgt="fleet-pulse",
    act="colony.pd.100-rounds",
    trits=[1, -1, 0, 1],  # ternary fingerprint: +net good, -overhead, 0-neutral, +fertile
    payload={
        "rounds": 100,
        "players": players,
        "results": round_results,
        "avg_score": round(avg_score, 1),
        "timestamp": time.time(),
    },
    ttl=60,
)

# Round-trip encode/decode — the only assertions that previously had teeth.
wire = bottle.encode()
decoded = Bottle.decode(wire)
expect(decoded.id == bottle.id, "bottle: encode/decode preserves id")
expect(decoded.decode_payload()["avg_score"] == round(avg_score, 1),
       "bottle: payload survives msgpack round-trip")
print(f"  Bottle: {bottle.id[:12]}...  action={bottle.act}  trits={bottle.trits} (sum={bottle.trit_sum()})")

# Response bottle with the SAME trit sum → conservation must HOLD.
resp_bottle = Bottle.new(
    src="fleet-pulse",
    tgt="colony-games",
    act="colony.pd.ack",
    trits=[-1, 1, 0, 1],  # different array, SAME sum (1) → conserved
    payload={"status": "received", "rounds": 100, "cells_scored": players},
    ttl=30,
)
expect(audit(bottle, resp_bottle),
       "conservation: matching trit sums are conserved",
       f"Σ={bottle.trit_sum()} == Σ={resp_bottle.trit_sum()}")

# POSITIVE: audit_strict must NOT raise for a conserved pair.
strict_ok = True
try:
    audit_strict(bottle, resp_bottle)
except ConservationError:
    strict_ok = False
expect(strict_ok, "audit_strict: accepts a conserved pair without raising")

# NEGATIVE — the teeth check. A response with a DIFFERENT trit sum must be
# detected as a violation. If audit_strict stops raising, this fails and the
# whole test exits non-zero (proving the assertions are not fake-green).
bad_resp = Bottle.new(
    src="fleet-pulse",
    tgt="colony-games",
    act="colony.pd.ack",
    trits=[1, 1, 1, 1],  # sum=4 ≠ bottle sum=1 → violation
    payload={"status": "corrupted"},
    ttl=30,
)
violation_raised = False
try:
    audit_strict(bottle, bad_resp)
except ConservationError as e:
    violation_raised = True
    print(f"  (detected violation: {e})")
expect(violation_raised,
       "audit_strict: raises ConservationError on sum mismatch (negative test)")
expect(not audit(bottle, bad_resp),
       "audit: returns False on sum mismatch (negative test)")

# ─── Phase 3: Score Cells on 9 Channels ──────────────────────────────────────
print("\n" + "═" * 72)
print("Phase 3: 9-Channel Conservation Scoring")
print("═" * 72)

profiles = {}
for cid, data in cells.items():
    coop_rate = sum(1 for (_, _, m) in data["moves"] if m == "cooperate") / max(len(data["moves"]), 1)
    cell_input = {
        "agent_id": cid,
        "cooperation_rate": coop_rate,
        "deception_score": random.uniform(0, 30),  # Simulated — would come from deception arena
        "betrayal_score": random.uniform(0, 30),    # Simulated — would come from diplomacy engine
        "trust_score": coop_rate * 100,
        "generosity": random.uniform(0, 50),
        "games_played": 100,
        "empathy_accuracy": random.uniform(0.3, 0.9),
    }
    profile = score_cell(cell_input)
    profiles[cid] = profile

# Top profiles
for cid in sorted(profiles.keys())[:5]:
    p = profiles[cid]
    role = classify_role(p)
    top = p.top_channels(2)
    print(f"  {cid} → {role} (top: {top[0][0]}={top[0][1]:.2f}, {top[1][0]}={top[1][1]:.2f})")

expect(len(set(profiles)) == players, "scorer: produced a profile for every cell")

# ─── Phase 4: Fleet Efficiency (γ + η = C) ───────────────────────────────────
print("\n" + "═" * 72)
print("Phase 4: Fleet Efficiency — Conservation Law")
print("═" * 72)

eff = compute_fleet_efficiency(profiles)
print(f"  Cells (n): {eff['n']}")
print(f"  Gamma (γ): {eff['gamma']} — productive capacity (avg profile magnitude)")
print(f"  Eta   (η): {eff['eta']} — coordination overhead (avg pairwise dissimilarity)")
print(f"  C     = γ + η: {eff['C']}")
print(f"  Predicted δ({eff['n']}) = {eff['delta']}")

# The DEFINITIONAL conservation identity: C is defined as γ + η. The scorer
# rounds γ, η and C independently to 4 dp, so the published C can drift from
# (γ+η) by ~1e-4 — tolerate that rounding but still catch real inconsistency.
expect(abs(eff["C"] - (eff["gamma"] + eff["eta"])) < 1e-3,
       "conservation law: C == γ + η (definitional identity, within 4dp rounding)",
       f"C={eff['C']} γ+η={eff['gamma'] + eff['eta']:.6f}")

# The C ≈ 1 + δ(n) prediction is an *approximate* theoretical claim, not a tight
# invariant — report the deviation as an observation rather than a pass/fail gate.
expected_C = 1.0 + eff["delta"]
deviation = abs(eff["C"] - expected_C)
print(f"  Observation: |C − (1+δ(n))| = {deviation:.4f} (approximate prediction, not a hard gate)")

# ─── Phase 5: Edge Alignment Matrix ──────────────────────────────────────────
print("\n" + "═" * 72)
print("Phase 5: Edge Alignment Matrix")
print("═" * 72)

all_ids = sorted(profiles.keys())
# 5x5 sample
sample = all_ids[:5]
header = "  " + "  ".join(f"{pid[-5:]:>6s}" for pid in sample)
print(header)
for i, pid_i in enumerate(sample):
    row = f"{pid_i[-5:]:>5s} "
    for pid_j in sample:
        sim = edge_alignment(profiles[pid_i], profiles[pid_j])
        row += f"{sim:.2f}  "
    print(row)

# A profile's self-alignment should be maximal (==1.0) — real invariant.
self_aligned = all(abs(edge_alignment(profiles[c], profiles[c]) - 1.0) < 1e-9 for c in sample)
expect(self_aligned, "edge_alignment: self-similarity == 1.0")

# ─── Phase 6: Full Bottle Pipeline (conservation across a chain) ──────────────
print("\n" + "═" * 72)
print("Phase 6: End-to-End Bottle Pipeline")
print("═" * 72)

# Three links with DIFFERENT trit arrays but the SAME sum (0) — so conservation
# holds across the chain by sum, not by identical arrays (the old test compared
# three identical bottles, which is trivially/unfalsifiably "all same").
step1 = Bottle.new("colony-games", "conservation-meter", "game.pd.round",
                   trits=[1, -1, 0], payload={"round": 1, "players": players}, ttl=30)
step2 = Bottle.new("conservation-meter", "fleet-pulse", "conservation.cell.scores",
                   trits=[-1, 1, 0], payload={"profiles": {k: p.to_dict() for k, p in profiles.items()}}, ttl=30)
step3 = Bottle.new("fleet-pulse", "colony-games", "conservation.fleet.efficiency",
                   trits=[0, 0, 0], payload=eff, ttl=30)
chain = [step1, step2, step3]

# Conservation must hold across every consecutive link.
chain_conserved = all(audit(chain[i], chain[i + 1]) for i in range(len(chain) - 1))
expect(chain_conserved,
       "pipeline chain: trit sum conserved across all links",
       f"sums={[b.trit_sum() for b in chain]}")

# NEGATIVE — a broken link (different sum) must be detected somewhere in the chain.
broken = Bottle.new("fleet-pulse", "colony-games", "conservation.broken",
                    trits=[1, 1, 1], payload={"oops": True}, ttl=30)  # sum=3 ≠ 0
broken_link_detected = (not audit(step3, broken)) or (not audit(step1, broken))
expect(broken_link_detected,
       "pipeline chain: a non-conserved link is detected (negative test)")

# ─── Results ────────────────────────────────────────────────────────────────
print("\n" + "═" * 72)
print("RESULTS SUMMARY")
print("═" * 72)
print(f"  Checks passed: {len(PASSES)}")
print(f"  Checks failed: {len(FAILURES)}")
if FAILURES:
    print("  FAILED:")
    for name in FAILURES:
        print(f"    - {name}")
print(f"\n  Protocol client:     {'✅' if decoded.id == bottle.id else '❌'} superinstance_bottle.py")
print(f"  Conservation audit:  {'✅' if not FAILURES else '⚠️'} audit/audit_strict enforce trit-sum invariance")
print(f"  9-channel scorer:    ✅ colony_conservation_scorer.py ({len(CHANNELS)} channels)")
print(f"  Role classification: ✅ {len(set(classify_role(p) for p in profiles.values()))} role types detected")
print(f"  Fleet efficiency:    ✅ γ+η=C computed (γ={eff['gamma']}, η={eff['eta']}, C={eff['C']})")
print(f"  Pipeline chain:      {'✅ conserved' if chain_conserved else '❌ broken'}")
print(f"\n  Protocol format: superinstance-protocol v1")
print(f"  Envelope: JSON (10 fields)")
print(f"  Payload:  base64(msgpack)")
print(f"  Conservation: Σ trits preserved across transformations (enforced by assertions)")
print("═" * 72)

sys.exit(len(FAILURES))
