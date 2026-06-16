#!/usr/bin/env python3
"""Darwin Reputation Extension — Inherited reputation with decay for colony-games.py.

This module adds the `DarwinReputationArena` engine to the existing colony-games server.
It implements the key finding from the next-phase strategy: reputation alone can't break
defection because offspring inherit the parent's *strategy* but not the parent's *reputation*.

Patch this into colony-games.py by adding the routes in the monkey-patch section below.
"""

import json, os, random, math, time
from collections import defaultdict

# === Constants ===
COLONY = os.environ.get("COLONY_DATA", ".")
DARWIN_REP_LEDGER = os.path.join(COLONY, "darwin-rep-ledger.json")

REPUTATION_DECAY = 0.20         # How much reputation decays per generation
INITIAL_REPUTATION = 0.5        # Neutral starting point
TOTAL_GENERATIONS = 200          # Default run length
POPULATION_SIZE = 13            # Match original experiment

# === Strategy definitions (mirrored from colony-games.py) ===
STRATEGIES = ["cooperate", "defect", "tit-for-tat", "grudge", "random"]

def default_strategy_weights():
    return {s: 1.0 for s in STRATEGIES}

def make_default_population(n=POPULATION_SIZE, with_reputation=True):
    """Create a population for Darwin Reputation Arena."""
    population = []
    for i in range(n):
        strat = random.choice(STRATEGIES)
        agent = {
            "id": f"rep-cell-{i:03d}",
            "strategy": strat,
            "fitness": 0.0,
            "generation": 0,
            "ancestors": [],
        }
        if with_reputation:
            agent["reputation"] = INITIAL_REPUTATION
            agent["reputation_history"] = [INITIAL_REPUTATION]
        population.append(agent)
    return population

def make_fixed_population(strategies, with_reputation=True):
    """Create a population with specific strategies (for reproducible experiments)."""
    population = []
    for i, strat in enumerate(strategies):
        agent = {
            "id": f"rep-cell-{i:03d}",
            "strategy": strat,
            "fitness": 0.0,
            "generation": 0,
            "ancestors": [],
        }
        if with_reputation:
            agent["reputation"] = INITIAL_REPUTATION
            agent["reputation_history"] = [INITIAL_REPUTATION]
        population.append(agent)
    return population


class DarwinReputationArena:
    """Darwin's Arena with inherited reputation.

    Key innovation over the baseline:
    - Each agent has a `reputation` value [0.0, 1.0]
    - Offspring inherit parent's reputation with REPUTATION_DECAY decay
    - Reputation affects fitness calculation: f = f_raw * (reputation ** multiplier)
    - Four modes: none, multiplier, exclusion, hybrid
    """

    def __init__(self, population=None, mode="multiplier", rep_weight=0.3,
                 inherit_reputation=True, rep_decay=REPUTATION_DECAY):
        self.population = population or make_default_population()
        self.generation = 0
        self.history = []
        self.mode = mode          # none | multiplier | exclusion | hybrid
        self.rep_weight = rep_weight   # How much reputation affects fitness
        self.inherit_reputation = inherit_reputation
        self.rep_decay = rep_decay

    def round_robin(self):
        """Play one round-robin PD tournament among all agents."""
        scores = {a["id"]: 0.0 for a in self.population}
        interactions = []
        for i in range(len(self.population)):
            for j in range(i + 1, len(self.population)):
                a1, a2 = self.population[i], self.population[j]
                m1 = self._get_move(a1, a2)
                m2 = self._get_move(a2, a1)
                s1, s2 = self._pd_payoff(m1, m2)
                scores[a1["id"]] += s1
                scores[a2["id"]] += s2
                interactions.append({
                    "a1_id": a1["id"], "a2_id": a2["id"],
                    "m1": m1, "m2": m2,
                    "s1": s1, "s2": s2,
                })
        self.current_interactions = interactions
        return scores

    def _get_move(self, agent, opponent):
        s = agent["strategy"]
        if s == "cooperate":
            return "cooperate"
        elif s == "defect":
            return "defect"
        elif s == "random":
            return random.choice(["cooperate", "defect"])
        elif s == "tit-for-tat":
            # TFT: cooperate unless opponent defected last time
            opp_last = self._last_move(opponent["id"], agent["id"])
            return "cooperate" if opp_last != "defect" else "defect"
        elif s == "grudge":
            # Grudge: cooperate until first betrayal, then always defect
            opp_betrayed = self._ever_betrayed(opponent["id"], agent["id"])
            return "defect" if opp_betrayed else "cooperate"
        return "cooperate"

    def _iter_interactions(self):
        """Yield all interaction entries across all generations."""
        for gen_record in self.history:
            for interaction in gen_record.get("interactions", []):
                yield interaction

    def _last_move(self, opp_id, self_id):
        """Get opponent's last move against this agent."""
        last = None
        for entry in self._iter_interactions():
            if entry["a1_id"] == opp_id and entry["a2_id"] == self_id:
                last = entry["m2"]
            elif entry["a1_id"] == self_id and entry["a2_id"] == opp_id:
                last = entry["m1"]
        return last

    def _ever_betrayed(self, opp_id, self_id):
        """Check if opponent ever defected against this agent."""
        for entry in self._iter_interactions():
            if entry["a1_id"] == opp_id and entry["a2_id"] == self_id and entry["m1"] == "defect":
                return True
            elif entry["a1_id"] == self_id and entry["a2_id"] == opp_id and entry["m2"] == "defect":
                return True
        return False

    def _pd_payoff(self, m1, m2):
        """Classic PD payoff matrix."""
        if m1 == "cooperate" and m2 == "cooperate":
            return (3, 3)
        elif m1 == "defect" and m2 == "defect":
            return (1, 1)
        elif m1 == "cooperate" and m2 == "defect":
            return (0, 5)
        elif m1 == "defect" and m2 == "cooperate":
            return (5, 0)
        return (0, 0)

    def _apply_reputation_to_fitness(self, agent, raw_fitness):
        """Apply reputation modifier to fitness based on mode."""
        rep = agent.get("reputation", INITIAL_REPUTATION)

        if self.mode == "none":
            return raw_fitness

        elif self.mode == "multiplier":
            # f = f_raw * rep^weight — defectors with low rep get heavily penalized
            return raw_fitness * (rep ** self.rep_weight)

        elif self.mode == "exclusion":
            # f = f_raw if rep > threshold else 0
            threshold = 0.3
            return raw_fitness if rep >= threshold else 0.0

        elif self.mode == "hybrid":
            # mult + bonus: first apply multiplier, then add cooperation bonus
            base = raw_fitness * (rep ** (self.rep_weight * 0.7))
            coop_bonus = 2.0 * rep  # Bonus for good reputation
            return base + coop_bonus

        return raw_fitness

    def _update_reputation(self, agent, all_scores, total_rounds):
        """Update an agent's reputation based on this generation's performance."""
        if not self.inherit_reputation:
            agent["reputation"] = INITIAL_REPUTATION
            return

        if not self.current_interactions:
            return

        coop_count = 0
        total_encounters = 0

        for entry in self.current_interactions:
            if entry["a1_id"] == agent["id"]:
                total_encounters += 1
                if entry["m1"] == "cooperate":
                    coop_count += 1
            elif entry["a2_id"] == agent["id"]:
                total_encounters += 1
                if entry["m2"] == "cooperate":
                    coop_count += 1

        if total_encounters > 0:
            coop_rate = coop_count / total_encounters
            new_rep = 0.5 * (1 - self.rep_decay) + 0.5 * coop_rate
            agent["reputation"] = max(0.0, min(1.0, new_rep))

        agent.setdefault("reputation_history", [])
        agent["reputation_history"].append(agent["reputation"])

    def step(self):
        """Run one generation."""
        self.generation += 1

        # Round-robin tournament
        scores = self.round_robin()

        # Apply reputation to fitness
        for agent in self.population:
            raw_fitness = scores.get(agent["id"], 0.0)
            agent["fitness"] = self._apply_reputation_to_fitness(agent, raw_fitness)

        # Record generation
        gen_record = {
            "generation": self.generation,
            "population": [{
                "id": a["id"], "strategy": a["strategy"],
                "fitness": a["fitness"], "reputation": a.get("reputation", 0.5)
            } for a in self.population],
            "mode": self.mode,
            "inherit_reputation": self.inherit_reputation,
            "interactions": self.current_interactions,
        }
        self.history.append(gen_record)

        # Update reputations based on this generation's interactions
        total_encounters = (len(self.population) * (len(self.population) - 1)) // 2
        for agent in self.population:
            self._update_reputation(agent, scores, total_encounters)

        # Clear current interactions after processing
        # They're already recorded in the gen_record history

        # Selection + reproduction (fitness-proportional)
        self._reproduce()

        return gen_record

    def _reproduce(self):
        """Fitness-proportional selection with crossover + mutation."""
        fitnesses = [a["fitness"] for a in self.population]
        min_f = min(fitnesses)
        max_f = max(fitnesses)

        # Shift so all fitnesses are non-negative
        if min_f < 0:
            fitnesses = [f - min_f + 0.01 for f in fitnesses]
        elif max_f == 0:
            fitnesses = [1.0 for _ in fitnesses]

        total_f = sum(fitnesses)
        if total_f <= 0:
            fitnesses = [1.0 for _ in fitnesses]
            total_f = sum(fitnesses)

        probs = [f / total_f for f in fitnesses]

        new_pop = []
        for _ in range(len(self.population)):
            # Select parent (fitness-proportional)
            parent = random.choices(self.population, weights=probs, k=1)[0]

            # Clone with mutation
            child_strat = parent["strategy"]
            if random.random() < 0.15:  # 15% mutation rate
                child_strat = random.choice(STRATEGIES)

            child_rep = INITIAL_REPUTATION
            if self.inherit_reputation:
                # Offspring inherit parent's reputation with decay
                child_rep = max(0.0, parent.get("reputation", INITIAL_REPUTATION) * (1.0 - self.rep_decay))

            child = {
                "id": f"rep-cell-{len(new_pop):03d}",
                "strategy": child_strat,
                "fitness": 0.0,
                "generation": self.generation,
                "ancestors": parent.get("ancestors", []) + [parent["id"]],
                "reputation": child_rep,
                "reputation_history": [child_rep],
            }
            new_pop.append(child)

        self.population = new_pop

    def run(self, generations=TOTAL_GENERATIONS):
        """Run N generations and return summary."""
        for g in range(generations):
            self.step()

        return self.summarize()

    def summarize(self):
        """Return final state summary."""
        strat_counts = defaultdict(int)
        rep_avg = 0.0
        rep_by_strat = defaultdict(list)

        for a in self.population:
            strat_counts[a["strategy"]] += 1
            rep_avg += a.get("reputation", 0.5)
            rep_by_strat[a["strategy"]].append(a.get("reputation", 0.5))

        rep_avg /= max(len(self.population), 1)

        # Track per-generation strategy dominance
        gen_trace = []
        for g in self.history:
            c = defaultdict(int)
            for a in g["population"]:
                c[a["strategy"]] += 1
            gen_trace.append({
                "generation": g["generation"],
                "counts": dict(c),
                "reputations": {a["id"]: a["reputation"] for a in g["population"]}
            })

        return {
            "mode": self.mode,
            "inherit_reputation": self.inherit_reputation,
            "generations_run": self.generation,
            "final_strategies": dict(strat_counts),
            "dominant_strategy": max(strat_counts, key=strat_counts.get),
            "dominant_count": max(strat_counts.values()),
            "avg_reputation": round(rep_avg, 3),
            "reputation_by_strategy": {
                s: round(sum(v) / len(v), 3) for s, v in rep_by_strat.items()
            },
            "gen_trace": gen_trace,
        }


# === Monkey-patch: integrate into colony-games.py HTTP server ===
# To use, add these imports and routes to the PDGameLab class:

DARWIN_REP_EXPANSION_CODE = """
import random
from colony-games-darwin-reputation import DarwinReputationArena, make_default_population

# In PDGameLab.__init__:
self.darwin_rep_arenas = {}  # {run_id: DarwinReputationArena}

# Routes to add:

# POST /game/darwin-rep/init — Initialize a new reputation Darwin run
elif path == "/game/darwin-rep/init":
    body = self._read_body()
    data = json.loads(body) if body else {}
    mode = data.get("mode", "multiplier")       # none | multiplier | exclusion | hybrid
    inherit = data.get("inherit_reputation", True)
    generations = data.get("generations", 200)
    pop_size = data.get("population_size", 13)

    arena = DarwinReputationArena(
        population=make_default_population(pop_size),
        mode=mode,
        inherit_reputation=inherit,
    )
    run_id = f"darwin-rep-{int(time.time())}"
    self.darwin_rep_arenas[run_id] = (arena, generations)
    self.send_json({"run_id": run_id, "status": "initialized", "mode": mode, "inherit": inherit})

# POST /game/darwin-rep/step — Run one generation
elif path == "/game/darwin-rep/step":
    body = self._read_body()
    data = json.loads(body) if body else {}
    run_id = data.get("run_id")
    if run_id not in self.darwin_rep_arenas:
        self.send_json({"error": f"Run {run_id} not found"}, 400)
        return
    arena, _ = self.darwin_rep_arenas[run_id]
    gen_record = arena.step()
    self.send_json(gen_record)

# POST /game/darwin-rep/run — Run all generations
elif path == "/game/darwin-rep/run":
    body = self._read_body()
    data = json.loads(body) if body else {}
    run_id = data.get("run_id")
    if run_id not in self.darwin_rep_arenas:
        self.send_json({"error": f"Run {run_id} not found"}, 400)
        return
    arena, n_gen = self.darwin_rep_arenas[run_id]
    summary = arena.run(n_gen)
    self.send_json(summary)

# GET /game/darwin-rep/status — Get run status
elif path == "/game/darwin-rep/status":
    run_id = self._get_param("run_id")
    if run_id and run_id in self.darwin_rep_arenas:
        arena, n_gen = self.darwin_rep_arenas[run_id]
        self.send_json({
            "run_id": run_id,
            "generation": arena.generation,
            "mode": arena.mode,
            "inherit": arena.inherit_reputation,
            "total_generations": n_gen,
            "population_size": len(arena.population),
        })
    else:
        # List all runs
        self.send_json({
            "runs": list(self.darwin_rep_arenas.keys()),
            "count": len(self.darwin_rep_arenas),
        })

# GET /game/darwin-rep/results — Final results for a run
elif path == "/game/darwin-rep/results":
    run_id = self._get_param("run_id")
    if not run_id or run_id not in self.darwin_rep_arenas:
        self.send_json({"error": f"Run {run_id} not found"}, 400)
        return
    arena, _ = self.darwin_rep_arenas[run_id]
    self.send_json(arena.summarize())
"""


# === Standalone experiment runner ===
def run_experiment(mode="multiplier", inherit=True, generations=TOTAL_GENERATIONS,
                   pop_size=POPULATION_SIZE, trials=1):
    """Run the experiment and return summarized results."""
    results = []
    for t in range(trials):
        arena = DarwinReputationArena(
            population=make_default_population(pop_size),
            mode=mode, inherit_reputation=inherit,
        )
        for g in range(generations):
            arena.step()
        summary = arena.summarize()
        summary["trial"] = t
        results.append(summary)

    # Aggregate
    if trials > 1:
        dom_strats = defaultdict(int)
        for r in results:
            dom_strats[r["dominant_strategy"]] += 1
        avg_rep = sum(r["avg_reputation"] for r in results) / len(results)

        return {
            "mode": mode,
            "inherit_reputation": inherit,
            "generations": generations,
            "trials": trials,
            "dominant_strategy_distribution": dict(dom_strats),
            "avg_reputation_across_trials": round(avg_rep, 3),
            "trials_detail": results,
        }
    return results[0]


# === Main ===
if __name__ == "__main__":
    import sys

    print("═" * 60)
    print("Darwin Reputation Arena — Experiment Suite")
    print("═" * 60)

    # Experiment 1: No reputation (baseline comparison)
    print("\n📊 Experiment 1: No reputation (baseline)")
    print("-" * 40)
    r1 = run_experiment(mode="none", inherit=False, generations=TOTAL_GENERATIONS)
    print(f"  Dominant: {r1['dominant_strategy']} ({r1['dominant_count']}/{POPULATION_SIZE})")
    print(f"  Strategies: {r1['final_strategies']}")

    # Experiment 2: Multiplier mode with inherited reputation
    print("\n📊 Experiment 2: Multiplier mode + inherited reputation")
    print("-" * 40)
    r2 = run_experiment(mode="multiplier", inherit=True, generations=TOTAL_GENERATIONS)
    print(f"  Dominant: {r2['dominant_strategy']} ({r2['dominant_count']}/{POPULATION_SIZE})")
    print(f"  Strategies: {r2['final_strategies']}")
    print(f"  Avg Rep: {r2['avg_reputation']}")
    if 'reputation_by_strategy' in r2:
        print(f"  Rep by strategy: {r2['reputation_by_strategy']}")

    # Experiment 3: Exclusion mode
    print("\n📊 Experiment 3: Exclusion mode + inherited reputation")
    print("-" * 40)
    r3 = run_experiment(mode="exclusion", inherit=True, generations=TOTAL_GENERATIONS)
    print(f"  Dominant: {r3['dominant_strategy']} ({r3['dominant_count']}/{POPULATION_SIZE})")
    print(f"  Strategies: {r3['final_strategies']}")
    print(f"  Avg Rep: {r3['avg_reputation']}")

    # Experiment 4: Hybrid mode
    print("\n📊 Experiment 4: Hybrid mode + inherited reputation")
    print("-" * 40)
    r4 = run_experiment(mode="hybrid", inherit=True, generations=TOTAL_GENERATIONS)
    print(f"  Dominant: {r4['dominant_strategy']} ({r4['dominant_count']}/{POPULATION_SIZE})")
    print(f"  Strategies: {r4['final_strategies']}")
    print(f"  Avg Rep: {r4['avg_reputation']}")

    # Experiment 5: Multi-trial for statistical significance
    print("\n📊 Experiment 5: Multi-trial (5x) hybrid mode")
    print("-" * 40)
    r5 = run_experiment(mode="hybrid", inherit=True, generations=TOTAL_GENERATIONS, trials=5)
    print(f"  Dominant distribution: {r5['dominant_strategy_distribution']}")
    print(f"  Avg rep across trials: {r5['avg_reputation_across_trials']}")

    print("\n✅ Experiments complete.")
