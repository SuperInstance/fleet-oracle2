#!/usr/bin/env bash
#
# pulse-self-tune.sh — Self-tuning feedback loop for construct stack
#
# Reads conservation-meter ratio and adjusts gc-pid-bridge setpoint dynamically.
# The loop: measure system → evaluate stress → adjust GC → measure again.
#
# Theory: If the system is running hot (C trending up, ratio > 4), the GC should
# become more aggressive (lower setpoint = keep more free). If the system is
# cool (C stable, ratio < 2), the GC can relax (higher setpoint = use more disk).
#
# This is the "metabolic feedback" that makes the construct alive.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
LOG="${CONSTRUCT_DIR}/logs/pulse-self-tune.log"
STATE="${CONSTRUCT_DIR}/data/pulse-self-tune-state.json"

# PID controller — operates on the GC setpoint itself
MIN_SETPOINT=10   # Aggressive — keep 10% free minimum
MAX_SETPOINT=40   # Relaxed — allow 40% free
DEFAULT_SETPOINT=20

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

# ── Fetch conservation status ──────────────────────────────────────────────
fetch_conservation() {
  curl -sf --max-time 5 "http://localhost:8798/api/status" 2>/dev/null
}

# ── Current setpoint (from gc-pid-bridge or default) ───────────────────────
current_setpoint() {
  cat "$STATE" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('setpoint', $DEFAULT_SETPOINT))
except:
    print($DEFAULT_SETPOINT)
" 2>/dev/null || echo "$DEFAULT_SETPOINT"
}

# ── Compute new setpoint ──────────────────────────────────────────────────
compute_setpoint() {
  local ratio="$1"
  local trend="$2"  # Δ in γ over last N (positive = getting worse)
  local current="$3"

  # Core logic: ratio is stress indicator
  # ratio < 2 → cool → relax setpoint (more relaxed GC)
  # ratio 2-4 → nominal → keep setpoint
  # ratio > 4 → stressed → tighten setpoint (more aggressive GC)
  # ratio > 6 → critical → minimum setpoint

  python3 -c "
import json, sys

ratio = float('$ratio')
trend = int('$trend')
current = float('$current')
min_sp = $MIN_SETPOINT
max_sp = $MAX_SETPOINT
default = $DEFAULT_SETPOINT

# Base adjustment from ratio
if ratio >= 6.0:
    base = min_sp  # max pressure: minimum setpoint
elif ratio >= 4.0:
    # Map 4.0→6.0 linearly to setpoint range max_sp→min_sp
    t = (ratio - 4.0) / 2.0
    base = max_sp - (max_sp - min_sp) * t
elif ratio >= 2.0:
    # Nominal range: 2.0→4.0, setpoint stays near default
    base = default
else:
    # Cool: ratio < 2, allow setpoint to drift up toward max
    base = default + (max_sp - default) * (1.0 - ratio / 2.0)
    base = min(base, max_sp)

# Trend penalty: rising γ means things are getting worse
trend_penalty = 0
if trend > 0:
    trend_penalty = min(trend * 0.5, 5.0)  # up to 5 point penalty

new_sp = max(min_sp, min(max_sp, base - trend_penalty))

# Hysteresis: don't change more than 5 points per cycle
if abs(new_sp - current) > 5:
    new_sp = current + (5 if new_sp > current else -5)

print(f'{new_sp:.0f}', end='')
" 2>/dev/null || echo "$current"
}

# ── Apply setpoint ─────────────────────────────────────────────────────────
apply_setpoint() {
  local new_sp="$1"
  local old_sp="$2"

  # The gc-pid-bridge and gc-intelligent.sh need to be told the new setpoint.
  # gc-pid-bridge's setpoint is compile-time constant (hardcoded to 20).
  # For now, write the state and let gc-intelligent.sh read it.
  python3 -c "
import json, sys
d = {'setpoint': $new_sp, 'prev_setpoint': $old_sp, 'updated_at': '$(now_iso)'}
json.dump(d, sys.stdout)
" > "$STATE"

  log "Setpoint: ${old_sp} → ${new_sp} (Δ=$((new_sp - old_sp)))"
  return 0
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
  log "=== self-tune loop ==="

  # 1. Fetch current state
  local status
  status=$(fetch_conservation) || {
    log "ERROR: conservation-meter unreachable"
    return 1
  }

  local ratio burn_detected gamma_trend_str
  ratio=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ratio','null'))" 2>/dev/null || echo "null")
  burn_detected=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('burn_detected','false'))" 2>/dev/null || echo "false")

  if [[ "$ratio" == "null" ]]; then
    log "ERROR: null ratio from conservation-meter"
    return 1
  fi

  # 2. Compute trend: Δ in gamma_trend (last - first of last 5)
  local trend
  trend=$(echo "$status" | python3 -c "
import json,sys
d=json.load(sys.stdin)
g=d.get('gamma_trend',[])
if len(g) >= 5:
    print(g[-1] - g[-5])
elif len(g) >= 2:
    print(g[-1] - g[0])
else:
    print(0)
" 2>/dev/null || echo 0)

  # 3. Current setpoint
  local cur_sp
  cur_sp=$(current_setpoint)

  # 4. Burn override: if burn detected, go to minimum setpoint
  local new_sp
  if [[ "$burn_detected" == "true" ]]; then
    log "BURN DETECTED — forcing minimum setpoint ${MIN_SETPOINT}"
    new_sp=$MIN_SETPOINT
  else
    new_sp=$(compute_setpoint "$ratio" "$trend" "$cur_sp")
  fi

  # 5. Apply if changed
  if [[ "$new_sp" != "$cur_sp" ]]; then
    apply_setpoint "$new_sp" "$cur_sp"
    log "Applied: setpoint ${new_sp} (ratio=${ratio}, trend=${trend}, burn=${burn_detected})"
  else
    log "No change: setpoint=${new_sp} (ratio=${ratio})"
  fi

  log "=== self-tune loop complete ==="
}

main "$@"
