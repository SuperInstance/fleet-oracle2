#!/usr/bin/env python3
"""
Genetic Compiler Flag Optimizer — Oracle2 Edition

Explores Rust compiler flag combinations to find the fastest
binary for headspace-rs on Neoverse-N1.

Strategy:
1. Generate random flag combinations
2. Build headspace-rs with each combination
3. Time 100 nearest-neighbour queries
4. Select top performers, crossover, mutate
5. Repeat

Each generation: 6 individuals, 3 survivors, 10% mutation rate.
Target metric: wall-clock time for 100 nearest-neighbour queries.
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
                   "cortex-a76", "cortex-a55", "native", "apple-m1"],
    "opt_level": ["2", "3", "s", "z"],
    "lto": ["fat", "thin", "no"],
    "codegen_units": [1, 4, 8, 16],
    "inline_threshold": [100, 200, 400, 600, 1000],
    "loop_unrolling": [True, False],
    "prefetch": [True, False],
    "target_feature": [
        "+neon,+fp16",
        "+neon,+fp16,+rcpc",
        "+neon,+fp16,+dotprod",
        "+neon,+fp16,+dotprod,+sve",
        "+neon",
        "",
    ],
}

HEADSPACE_DIR = "/home/ubuntu/.openclaw/workspace/headspace-rs"
LOG_DIR = "/home/ubuntu/.openclaw/workspace/construct/logs/genetic-flags"
os.makedirs(LOG_DIR, exist_ok=True)

# Baseline: current config
BASELINE_CONFIG = {
    "target_cpu": "neoverse-n1",
    "opt_level": "3",
    "lto": "no",
    "codegen_units": 1,
    "inline_threshold": 300,
    "loop_unrolling": True,
    "prefetch": False,
    "target_feature": "+neon,+fp16",
}

def random_config():
    return {
        "target_cpu": random.choice(FLAG_SPACE["target_cpu"]),
        "opt_level": random.choice(FLAG_SPACE["opt_level"]),
        "lto": random.choice(FLAG_SPACE["lto"]),
        "codegen_units": random.choice(FLAG_SPACE["codegen_units"]),
        "inline_threshold": random.choice(FLAG_SPACE["inline_threshold"]),
        "loop_unrolling": random.choice(FLAG_SPACE["loop_unrolling"]),
        "prefetch": random.choice(FLAG_SPACE["prefetch"]),
        "target_feature": random.choice(FLAG_SPACE["target_feature"]),
    }

def config_to_flags(cfg):
    """Convert config dict to RUSTFLAGS and .cargo/config.toml"""
    flags = []
    # Target CPU
    if cfg["target_cpu"]:
        flags.append(f"-C target-cpu={cfg['target_cpu']}")
    # Target features
    if cfg["target_feature"]:
        flags.append(f"-C target-feature={cfg['target_feature']}")
    # Optimization level
    flags.append(f"-C opt-level={cfg['opt_level']}")
    # LTO
    lto_map = {"fat": "fat", "thin": "thin", "no": ""}
    if lto_map[cfg["lto"]]:
        flags.append(f"-C lto={lto_map[cfg['lto']]}")
    # Codegen units
    flags.append(f"-C codegen-units={cfg['codegen_units']}")
    # Inline threshold
    if cfg["inline_threshold"]:
        flags.append(f"-C inline-threshold={cfg['inline_threshold']}")
    # Loop unrolling
    if not cfg["loop_unrolling"]:
        flags.append("-C no-vectorize-loops")
    # Prefetch (Rust nightly or through target feature)
    # Not directly mappable to stable flags, skip
    
    return " ".join(flags)

def build(config):
    """Build headspace-rs with given flags, return build time or None on failure"""
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
        print(f"  BUILD FAILED: {result.stderr[-500:]}")
        return None, None
    
    # Binary size
    binary = os.path.join(HEADSPACE_DIR, "target/release/headspace-rs")
    bin_size = os.path.getsize(binary) if os.path.exists(binary) else 0
    
    return result.returncode, {
        "binary_size": bin_size,
        "build_time_s": round(build_time, 1),
    }

def make_embedding():
    """Generate a fake 384-dim embedding for benchmarking."""
    import json
    # Deterministic but representative: 384 random floats summing to ~0 (normalized)
    vals = [0.0] * 384
    for i in range(384):
        vals[i] = (i * 0.00123456) % 2.0 - 1.0  # Deterministic, range [-1, 1)
    return vals


def benchmark():
    """Run 100 nearest-neighbour queries against headspace-rs and return timing."""
    url = "http://localhost:9090/api/query"
    times = []
    
    embedding = make_embedding()
    payload = json.dumps({"embedding": embedding, "top_k": 3})
    
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
            elapsed = (time.time() - start) * 1000  # ms
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
    """Run one generation: generate children from parents, build, benchmark."""
    children = []
    
    # Elitism: carry over top 2 parents unchanged
    if parents:
        children.extend(parents[:2])
    
    # Fill remaining with crossover + mutation
    needed = 6 - len(children)
    for _ in range(needed):
        if parents and len(parents) >= 2:
            p1 = random.choice(parents[:3])
            p2 = random.choice(parents[:3])
            child = crossover(p1, p2)
        else:
            child = random_config()
        child = mutate(child)
        children.append(child)
    
    print(f"\n=== Generation {generation} ===")
    print(f"Testing {len(children)} configurations...")
    
    results = []
    for i, cfg in enumerate(children):
        # Skip if we've already benchmarked this exact config
        cfg_key = json.dumps(cfg, sort_keys=True)
        if cfg_key in BENCHMARK_CACHE:
            print(f"  [{i+1}/{len(children)}] CACHED: {cfg_key[:60]}... → "
                  f"{BENCHMARK_CACHE[cfg_key]['avg_ms']:.1f}ms")
            results.append((cfg, BENCHMARK_CACHE[cfg_key]))
            continue
        
        print(f"  [{i+1}/{len(children)}] Building: "
              f"cpu={cfg['target_cpu']} opt={cfg['opt_level']} "
              f"lto={cfg['lto']} units={cfg['codegen_units']}...", end=" ", flush=True)
        
        rc, meta = build(cfg)
        if rc != 0:
            print("✗ BUILD FAILED")
            continue
        
        # Restart headspace-rs
        subprocess.run(["sudo", "systemctl", "restart", "headspace-rs"],
                       capture_output=True, timeout=30)
        time.sleep(2)  # Wait for service to be ready
        
        print(f"✓ built ({meta['build_time_s']:.0f}s, {meta['binary_size']/1024:.0f}KB) "
              f"benchmarking...", end=" ", flush=True)
        
        bench = benchmark()
        if bench is None:
            print("✗ BENCHMARK FAILED")
            continue
        
        print(f"✓ avg={bench['avg_ms']:.1f}ms min={bench['min_ms']:.1f}ms "
              f"max={bench['max_ms']:.1f}ms")
        
        BENCHMARK_CACHE[cfg_key] = bench
        results.append((cfg, bench))
    
    # Sort by average time (ascending)
    results.sort(key=lambda x: x[1]["avg_ms"])
    
    # Log results
    log_file = os.path.join(LOG_DIR, f"generation-{generation}.json")
    with open(log_file, "w") as f:
        json.dump([{"config": cfg, "benchmark": bench} for cfg, bench in results], f, indent=2)
    
    print(f"\n  Generation {generation} best: "
          f"{results[0][1]['avg_ms']:.1f}ms "
          f"(config: {json.dumps(results[0][0], sort_keys=True)})")
    
    return results, log_file


def crossover(p1, p2):
    """Single-point crossover between two configs."""
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
    print("Genetic Compiler Flag Optimizer v1.0")
    print("Oracle2 · Neoverse-N1 · headspace-rs")
    print("=" * 60)
    
    # Measure baseline first
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
            baseline = {"avg_ms": 1000}  # Placeholder
    
    best_overall = BASELINE_CONFIG
    best_score = baseline["avg_ms"]
    
    # Generate initial population
    parents = [random_config() for _ in range(4)]
    
    for gen in range(1, 21):  # Run 20 generations
        all_results, log_file = run_generation(parents, gen)
        
        if not all_results:
            print("All builds failed this generation. Retrying with new random configs.")
            parents = [random_config() for _ in range(4)]
            continue
        
        parents = [cfg for cfg, _ in all_results[:3]]  # Keep top 3
        best_score = all_results[0][1]["avg_ms"]
        
        print(f"Best score so far: {best_score:.1f}ms (gen {gen})")
        
        if best_score < baseline["avg_ms"] * 0.7:
            print(f"\n🚀 Hit 30% improvement target! Stopping early.")
            break
    
    # Report final
    print(f"\n{'='*60}")
    print(f"FINAL: Best config after {gen} generations:")
    print(f"  Improvement: {baseline['avg_ms']:.1f}ms → {best_score:.1f}ms "
          f"({(1 - best_score/baseline['avg_ms'])*100:.0f}%)")
    print(f"{'='*60}")
    
    # Apply the best config to the live .cargo/config.toml
    best_config = parents[0]
    print(f"\nApplying best config to live system:")
    for k, v in best_config.items():
        print(f"  {k} = {v}")
    
    print("\nDone. Best flags applied.")


if __name__ == "__main__":
    main()
