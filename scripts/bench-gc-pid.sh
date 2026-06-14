#!/usr/bin/env bash
# =============================================================================
# bench-gc-pid.sh — Benchmark gc-pid-bridge (Rust + NEON) vs bash bc math
# =============================================================================
# Compares:
#   1. gc-pid-bridge binary (Rust, ARM NEON-optimized)
#   2. bash bc math fallback (stateless proportional PID)
#   3. Full pid_calc function (bridge + burn-rate boost)
#
# Outputs JSON report to construct/data/bench-gc-pid.json
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/.."
DATA_DIR="$WORKSPACE/data"
BRIDGE="/home/ubuntu/.openclaw/workspace/gc-pid-bridge/target/release/gc-pid-bridge"

ITERATIONS=100
TEST_PCTS=(5 15 30 45 50 60 70 80 85 95)
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

mkdir -p "$DATA_DIR"

# ── Fallback: pure bc math (no trend, no burn-rate) ─────────────────────────
# Mirrors the pid_calc fallback path from gc-intelligent.sh, isolated.
bc_fallback() {
  local disk_pct="$1"    # free% (0-100)
  local setpoint="${2:-20}"
  local kp="${3:-5.0}"
  local ki="${4:-0.5}"
  local kd="${5:-0.2}"

  local error
  error=$(echo "scale=2; $setpoint - $disk_pct" | bc 2>/dev/null || echo 0)
  local output
  output=$(echo "scale=3; ($kp*$error)" | bc -l 2>/dev/null || echo 1.0)

  # Clamp
  local clamped
  clamped=$(echo "
    scale=4;
    if ($output < 0.5) 0.5 else if ($output > $kp) $kp else $output
  " | bc -l 2>/dev/null || echo 1.0)
  echo "$clamped"
}

# ── Measure one batch ───────────────────────────────────────────────────────
# Runs $1 invocations of command "${@:2}" and returns wall-clock ms.
time_n_calls() {
  local n="$1"; shift
  local start end elapsed_ms

  start=$(date +%s%N)
  for ((i=0; i<n; i++)); do
    "$@" >/dev/null 2>&1
  done
  end=$(date +%s%N)

  elapsed_ms=$(( (end - start) / 1000000 ))
  echo "$elapsed_ms"
}

# Warm-up: let caches settle
"$BRIDGE" 50 >/dev/null 2>&1
bc_fallback 50 >/dev/null
sleep 0.1

# ── Run benchmarks ──────────────────────────────────────────────────────────
RESULTS_JSON=""
SEP=""

for disk_pct in "${TEST_PCTS[@]}"; do
  used_pct=$(echo "100 - $disk_pct" | bc)

  # 1) Bridge (100x)
  bridge_ms=$(time_n_calls "$ITERATIONS" "$BRIDGE" "$used_pct")

  # 2) Bash bc math (100x)
  bc_ms=$(time_n_calls "$ITERATIONS" bc_fallback "$disk_pct")

  # 3) Single aggression values for comparison
  bridge_val=$("$BRIDGE" "$used_pct" 2>/dev/null || echo "0")
  bc_val=$(bc_fallback "$disk_pct")

  # Speedup: bc_ms / bridge_ms (higher = faster bridge)
  speedup=$(echo "scale=4; if ($bridge_ms > 0) $bc_ms / $bridge_ms else 0" | bc -l 2>/dev/null || echo 0)

  RESULTS_JSON+="${SEP}{\"disk_pct\":${disk_pct},\"bridge_ms\":${bridge_ms},\"bc_ms\":${bc_ms},\"speedup\":${speedup},\"bridge_aggression\":${bridge_val},\"bc_aggression\":${bc_val}}"
  SEP=","
done

# ── Write JSON report ───────────────────────────────────────────────────────
cat > "$DATA_DIR/bench-gc-pid.json" <<JSONEOF
{
  "tested_at": "${TIMESTAMP}",
  "iterations": ${ITERATIONS},
  "results": [${RESULTS_JSON}]
}
JSONEOF

echo "✅ Report written: $DATA_DIR/bench-gc-pid.json"
