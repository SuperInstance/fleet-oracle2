#!/usr/bin/env bash
#
# pulse-cf-feed.sh — Feed live construct metrics to fleet-dashboard-api Worker
#
# Reads current conservation state from the construct, then POSTs it to:
#   https://fleet-dashboard-api.casey-digennaro.workers.dev
#
# Two POSTs per cycle:
#   1. POST /api/fleet/config  — agentCount + coherence bias
#   2. POST /api/fleet/history — tick-level γ/η appended to time series
#
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
FLEET_API_BASE="${FLEET_API_BASE:-https://fleet-dashboard-api.casey-digennaro.workers.dev}"
CONSERVATION_STATUS_URL="${CONSERVATION_STATUS_URL:-http://localhost:8798/api/status}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Helpers ──────────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ts()  { date -u +%s; }
uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }
log() { echo "[$(now_iso)] [pulse-cf-feed] $*"; }
warn() { echo "[$(now_iso)] [pulse-cf-feed] WARN: $*" >&2; }

# ── Step 1: Read Conservation State ──────────────────────────────────────────
fetch_conservation_state() {
  local resp
  resp=$(curl -sf --max-time 10 "$CONSERVATION_STATUS_URL" 2>/dev/null) || {
    warn "Conservation status unreachable at $CONSERVATION_STATUS_URL"
    echo ""
    return 1
  }
  echo "$resp"
}

# ── Step 2: POST /api/fleet/config ───────────────────────────────────────────
# Maps construct C (total = γ + η) → agentCount, and ratio → coherence bias.
#   - agentCount is derived from recent_reports count or C magnitude
#   - bias is clamped ratio γ/(γ+η), normalized to [0,1]
post_fleet_config() {
  local status_json="$1"
  local agent_count bias

  # Derive agentCount from the number of recent reports, or from gamma_trend length
  agent_count=$(echo "$status_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
reports = d.get('recent_reports', [])
# Use recent report count if available, otherwise length of gamma_trend or default 46
count = len(reports) if reports else len(d.get('gamma_trend', [])) or 46
print(max(1, min(10000, count * 2)))
" 2>/dev/null) || agent_count=46

  # Compute bias from current ratio
  bias=$(echo "$status_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ratio = d.get('ratio', 1.5)
# ratio = gamma / eta, map to bias in [0, 1]
# ratio 0.25 → bias 0.1 (low coherence), ratio 4.0 → bias 0.9 (high coherence)
# pivot around ratio ≈ 1.5 (approx midpoint of observed data)
raw = max(0.0, min(1.0, (ratio - 0.2) / 3.8))
print(round(raw, 4))
" 2>/dev/null) || bias=0.5

  local payload
  payload=$(cat <<EOF
{
  "agentCount": ${agent_count},
  "bias": ${bias}
}
EOF
)

  local resp
  resp=$(curl -sf --max-time 15 \
    -X POST "${FLEET_API_BASE}/api/fleet/config" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || {
    warn "POST /api/fleet/config failed (Worker may be updating)"
    return 1
  }

  log "POST /api/fleet/config: agentCount=${agent_count}, bias=${bias} → $(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ok', d))" 2>/dev/null || echo "$resp")"
  return 0
}

# ── Step 3: POST /api/fleet/history ──────────────────────────────────────────
# Pushes the most recent γ/η data points as a history entry tick.
# The Worker's internal simulation also ticks, but this gives it real data.
post_fleet_history() {
  local status_json="$1"
  local feed_file="${CONSTRUCT_DIR}/data/rotation-feed.json"

  # Build a time-series data point from the conservation state
  local tick gamma eta

  tick=$(now_ts)

  gamma=$(echo "$status_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
gamma_trend = d.get('gamma_trend', [])
print(gamma_trend[-1] if gamma_trend else '640')
" 2>/dev/null) || gamma=640

  eta=$(echo "$status_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
eta_trend = d.get('eta_trend', [])
print(eta_trend[-1] if eta_trend else '380')
" 2>/dev/null) || eta=380

  # Normalize γ/η to [0, 1.585] range (the Worker's native scale)
  # Our construct reports γ+η ~1000-1300, so scale down
  # Also grab the most recent rotation-feed entry for richer data
  local normalized_gamma normalized_eta
  normalized_gamma=$(python3 -c "
import sys
# Rotational scale: our C ≈ 1000-1300 → normalize to ~0.7-0.9 × 1.585
raw = float('${gamma}')
scale = raw / 1400.0  # 1400 = approximate max observed
print(round(scale * 1.585, 6))
" 2>/dev/null) || normalized_gamma=0.7925

  normalized_eta=$(python3 -c "
raw = float('${eta}')
scale = raw / 400.0  # 400 = approximate max observed
print(round(scale * 1.585, 6))
" 2>/dev/null) || normalized_eta=0.7925

  local payload
  payload=$(cat <<EOF
{
  "tick": ${tick},
  "gamma": ${normalized_gamma},
  "eta": ${normalized_eta}
}
EOF
)

  local resp
  resp=$(curl -sf --max-time 15 \
    -X POST "${FLEET_API_BASE}/api/fleet/history" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || {
    warn "POST /api/fleet/history failed"
    return 1
  }

  log "POST /api/fleet/history: tick=${tick}, γ=${normalized_gamma}, η=${normalized_eta} → $(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d)" 2>/dev/null || echo "$resp")"
  return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  local pulse_id
  pulse_id=$(uuid)

  log "=== Pulse CF Feed ${pulse_id} ==="

  # Step 1: Read conservation state
  log "Fetching conservation state from ${CONSERVATION_STATUS_URL}..."
  local status_json
  status_json=$(fetch_conservation_state) || {
    warn "Cannot fetch conservation state; skipping CF feed"
    return 1
  }

  # Log what we got
  local c_val ratio_val
  c_val=$(echo "$status_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('current_c','?'))" 2>/dev/null)
  ratio_val=$(echo "$status_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ratio','?'))" 2>/dev/null)
  log "Conservation state: C=${c_val}, ratio=${ratio_val}"

  # Step 2: POST config
  log "POSTing /api/fleet/config..."
  post_fleet_config "$status_json" || true

  # Step 3: POST history
  log "POSTing /api/fleet/history..."
  post_fleet_history "$status_json" || true

  log "=== Pulse CF Feed ${pulse_id} complete ==="
}

main "$@"
