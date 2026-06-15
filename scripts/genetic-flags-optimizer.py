#!/usr/bin/env python3
"""
Genetic Compiler Flag Optimizer — Oracle2 Edition

Explores Rust compiler flag combinations to find the fastest
binary for headspace-rs on Neoverse-N1.

Strategy:
1. Generate random flag combinations
2. Build headspace-rs with each combination
3. Time 10 nearest-neighbour queries
4. Select top performers, crossover, mutate
5. Repeat

Each generation: 6 individuals, 3 survivors, 10% mutation rate.
Target metric: wall-clock time for 10 nearest-neighbour queries.

Known constraints (ARM64, Rust 1.86+):
- LTO is disabled: embed-bitcode=no is default on ARM64 cross targets,
  which is incompatible with -C lto
- inline-threshold is deprecated (no-op in Rust 1.86+)
- We filter invalid combos at generation time
"""

import subprocess
import random
import time
import json
import os
import sys
import itertools

FLAG_SPACE = {
    "target_cpu": ["neoverse-n1", "neoverse-v1", "generic",
                   "cortex-a76", "cortex-a55", "native"],
    "opt_level": ["2", "3", "s", "z"],
    "lto": ["no"],  # LTO disabled on ARM64 Rust 1.86+
    "codegen_units": [1, 4, 8, 16],
    "loop_unrolling": [True, False],
    "target_feature": [
        "+neon,+fp16",
        "+neon,+fp16,+rcpc",
        "+neon,+fp16,+dotprod",
        "+neon",
        "",
    ],
}

HEADSPACE_DIR = "/home/ubuntu/.openclaw/workspace/headspace-rs"
LOG_DIR = "/home/ubuntu/.openclaw/workspace/construct/logs/genetic-flags"
os.makedirs(LOG_DIR, exist_ok=True)

# Baseline: current config (known working)
BASELINE_CONFIG = {
    "target_cpu": "neoverse-n1",
    "opt_level": "3",
    "lto": "no",
    "codegen_units": 1,
    "loop_unrolling": True,
    "target_feature": "+neon,+fp16",
}

def is_valid_config(cfg):
    """Reject flag combos known to fail on ARM64 release builds."""
    if cfg["lto"] != "no":
        return False
    return True

def random_config():
    """Generate a random valid config, rerolling until valid."""
    while True:
        cfg = {
            "target_cpu": random.choice(FLAG_SPACE["target_cpu"]),
            "opt_level": random.choice(FLAG_SPACE["opt_level"]),
            "lto": random.choice(FLAG_SPACE["lto"]),
            "codegen_units": random.choice(FLAG_SPACE["codegen_units"]),
            "loop_unrolling": random.choice(FLAG_SPACE["loop_unrolling"]),
            "target_feature": random.choice(FLAG_SPACE["target_feature"]),
        }
        if is_valid_config(cfg):
            return cfg

def config_to_flags(cfg):
    """Convert config dict to RUSTFLAGS string."""
    flags = []
    if cfg["target_cpu"]:
        flags.append(f"-C target-cpu={cfg['target_cpu']}")
    if cfg["target_feature"]:
        flags.append(f"-C target-feature={cfg['target_feature']}")
    flags.append(f"-C opt-level={cfg['opt_level']}")
    lto_map = {"no": ""}
    if cfg["lto"] in lto_map and lto_map[cfg["lto"]]:
        flags.append(f"-C lto={lto_map[cfg['lto']]}")
    flags.append(f"-C codegen-units={cfg['codegen_units']}")
    if not cfg["loop_unrolling"]:
        flags.append("-C no-vectorize-loops")
    return " ".join(flags)

def build(config):
    """Build headspace-rs with given flags, return build metadata or None."""
    flags = config_to_flags(config)
    env = os.environ.copy()
    env["RUSTFLAGS"] = flags

    start = time.time()
    result = subprocess.run(
        ["cargo", "build", "--release", "-q"],
        cwd=HEADSPACE_DIR,
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
    )
    build_time = time.time() - start

    if result.returncode != 0:
        for line in result.stderr.splitlines()[:3]:
            print(f"  {line}")
        return None, None

    binary = os.path.join(HEADSPACE_DIR, "target/release/headspace-rs")
    bin_size = os.path.getsize(binary) if os.path.exists(binary) else 0

    return result.returncode, {
        "binary_size": bin_size,
        "build_time_s": round(build_time, 1),
    }

def make_embedding():
    """Generate a deterministic 384-dim embedding."""
    return [(i * 0.00123456) % 2.0 - 1.0 for i in range(384)]

def benchmark():
    """Run 10 nearest-neighbour queries, return timing stats."""
    url = "http://localhost:9090/api/query"
    times = []
    embedding = make_embedding()

    for _ in range(10):
        payload = json.dumps({"embedding": embedding, "top_k": 3})
        start = time.time()
        try:
            result = subprocess.run(
                ["curl", "-s", "-X", "POST", url,
                 "-H", "Content-Type: application/json",
                 "-d", payload],
                capture_output=True, text=True, timeout=10,
            )
            elapsed = (time.time() - start) * 1000
            if result.returncode == 0 and result.stdout.strip():
                times.append(elapsed)
        except:
            pass

    if len(times) < 3:
        return None

    return {
        "avg_ms": sum(times) / len(times),
        "min_ms": min(times),
        "max_ms": max(times),
        "samples": len(times),
    }

def run_generation(parents, generation):
    """One generation: children -> build -> benchmark -> select."""
    children = []
    if parents:
        children.extend(parents[:2])  # Elitism

    needed = 6 - len(children)
    for _ in range(needed):
        if parents and len(parents) >= 2:
            p1 = random.choice(parents[:3])
            p2 = random.choice(parents[:3])
            child = crossover(p1, p2)
        else:
            child = random_config()
        child = mutate(child)
        if not is_valid_config(child):
            child = random_config()
        children.append(child)

    print(f"\n=== Generation {generation} ===")
    print(f"Testing {len(children)} configurations...")

    results = []
    for i, cfg in enumerate(children):
        cfg_key = json.dumps(cfg, sort_keys=True)
        if cfg_key in BENCHMARK_CACHE:
            print(f"  [{i+1}/{len(children)}] CACHED: {cfg_key[:60]}... = "
                  f"{BENCHMARK_CACHE[cfg_key]['avg_ms']:.1f}ms")
            results.append((cfg, BENCHMARK_CACHE[cfg_key]))
            continue

        print(f"  [{i+1}/{len(children)}] Building: "
              f"cpu={cfg['target_cpu']} opt={cfg['opt_level']} "
              f"units={cfg['codegen_units']}...", end=" ", flush=True)

        rc, meta = build(cfg)
        if rc != 0:
            print("FAILED")
            continue

        subprocess.run(["sudo", "systemctl", "restart", "headspace-rs"],
                       capture_output=True, timeout=30)
        time.sleep(2)

        print(f"built ({meta['build_time_s']:.0f}s, {meta['binary_size']/1024:.0f}KB) "
              f"benchmarking...", end=" ", flush=True)

        bench = benchmark()
        if bench is None:
            print("BENCH FAILED")
            continue

        print(f"avg={bench['avg_ms']:.1f}ms min={bench['min_ms']:.1f}ms "
              f"max={bench['max_ms']:.1f}ms")

        BENCHMARK_CACHE[cfg_key] = bench
        results.append((cfg, bench))

    results.sort(key=lambda x: x[1]["avg_ms"])

    log_file = os.path.join(LOG_DIR, f"generation-{generation}.json")
    with open(log_file, "w") as f:
        json.dump([{"config": cfg, "benchmark": bench} for cfg, bench in results], f, indent=2)

    if results:
        print(f"\n  Generation {generation} best: "
              f"{results[0][1]['avg_ms']:.1f}ms "
              f"(config: {json.dumps(results[0][0], sort_keys=True)})")

    return results, log_file

def crossover(p1, p2):
    """Single-point crossover."""
    keys = list(p1.keys())
    split = random.randint(1, len(keys) - 1)
    child = {}
    for i, k in enumerate(keys):
        child[k] = p1[k] if i < split else p2[k]
    return child

def mutate(cfg):
    """10% mutation rate per gene."""
    child = cfg.copy()
    for k in FLAG_SPACE:
        if random.random() < 0.10:
            child[k] = random.choice(FLAG_SPACE[k])
    return child

def main():
    global BENCHMARK_CACHE
    BENCHMARK_CACHE = {}

    print("=" * 60)
    print("Genetic Compiler Flag Optimizer v2.0")
    print("Oracle2 - Neoverse-N1 - headspace-rs")
    print("=" * 60)

    print("\n--- Baseline ---")
    print(f"Config: {json.dumps(BASELINE_CONFIG)}")
    rc, meta = build(BASELINE_CONFIG)
    if rc == 0:
        subprocess.run(["sudo", "systemctl", "restart", "headspace-rs"],
                       capture_output=True, timeout=30)
        time.sleep(2)
        baseline = benchmark()
        if baseline:
            print(f"Baseline: avg={baseline['avg_ms']:.1f}ms "
                  f"min={baseline['min_ms']:.1f}ms max={baseline['max_ms']:.1f}ms")
            BLS_KEY = json.dumps(BASELINE_CONFIG, sort_keys=True)
            BENCHMARK_CACHE[BLS_KEY] = baseline
        else:
            print("WARNING: Baseline benchmark failed. Starting blind.")
            baseline = {"avg_ms": 1000}
    else:
        print("FATAL: Baseline build failed. Aborting.")
        sys.exit(1)

    best_score = baseline["avg_ms"]
    gen = 0

    # Generate initial valid population
    parents = []
    seen = set()
    while len(parents) < 4:
        cfg = random_config()
        key = json.dumps(cfg, sort_keys=True)
        if key not in seen:
            seen.add(key)
            parents.append(cfg)

    for gen in range(1, 21):
        all_results, log_file = run_generation(parents, gen)

        if not all_results:
            print("All builds failed. Retrying with fresh population.")
            parents = []
            seen = set()
            while len(parents) < 4:
                cfg = random_config()
                key = json.dumps(cfg, sort_keys=True)
                if key not in seen:
                    seen.add(key)
                    parents.append(cfg)
            continue

        parents = [cfg for cfg, _ in all_results[:3]]
        best_score = all_results[0][1]["avg_ms"]

        print(f"Best score so far: {best_score:.1f}ms (gen {gen})")

        if best_score < baseline["avg_ms"] * 0.7:
            print(f"\nHit 30% improvement target! Stopping early.")
            break

    print(f"\n{'='*60}")
    print(f"FINAL: Best config after {gen} generations:")
    print(f"  Improvement: {baseline['avg_ms']:.1f}ms -> {best_score:.1f}ms "
          f"({(1 - best_score/baseline['avg_ms'])*100:.0f}%)")
    print(f"{'='*60}")

    best_config = parents[0]
    print(f"\nBest config:")
    for k, v in best_config.items():
        print(f"  {k} = {v}")
    print()

if __name__ == "__main__":
    main()
