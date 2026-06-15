#!/usr/bin/env bash
#
# gc-auto-evict.sh — GC eviction trigger wired to self-tuner setpoint
#
# Reads the current setpoint from pulse-self-tune-state.json.
# If setpoint <= 15 (stressed/critical zone), triggers gc-intelligent.sh --execute
# and sends a CONSTRUCT_EVICTION bottle to harbor-daemon.
#
# This closes the feedback loop: the construct stack MEASURES disk stress via
# pulse-self-tune.sh, but nothing was ACTING on it. Now gc-intelligent.sh
# gets triggered automatically when setpoint drops into the critical zone.
#
# Wired into pulse-metric.sh as the FINAL step (after self-tune).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
STATE="${CONSTRUCT_DIR}/data/pulse-self-tune-state.json"
GC_SCRIPT="${SCRIPT_DIR}/../scripts/gc-intelligent.sh"
LOG="${CONSTRUCT_DIR}/logs/gc-auto-evict.log"
HARBOR_HOST="127.0.0.1"
HARBOR_PORT=8796

TRIGGER_SETPOINT=15
DEFAULT_SETPOINT=20

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

log() { echo "[$(now_iso)] $*" >> "$LOG"; }

# ── Read current setpoint from state file ────────────────────────────────────
read_setpoint() {
  if [ ! -f "$STATE" ]; then
    echo "$DEFAULT_SETPOINT"
    return
  fi
  python3 -c "
import json, sys
try:
    d = json.load(open('$STATE'))
    print(d.get('setpoint', $DEFAULT_SETPOINT))
except:
    print($DEFAULT_SETPOINT)
" 2>/dev/null || echo "$DEFAULT_SETPOINT"
}

# ── Send CONSTRUCT_EVICTION bottle to harbor-daemon ─────────────────────────
send_eviction_bottle() {
  local pulse_id="$1"
  local setpoint="$2"
  local freed_kb="$3"
  local disk_pct="$4"

  local bottle
  bottle=$(python3 -c "
import json
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
expires_at = (now + timedelta(hours=24)).strftime('%Y-%m-%dT%H:%M:%SZ')

bottle = {
    'uuid': '$pulse_id',
    'sender': 'gc-auto-evict',
    'recipient': 'harbor-daemon',
    'priority': 2,
    'type': 'CONSTRUCT_EVICTION',
    'payload': json.dumps({
        'setpoint': $setpoint,
        'trigger': 'construct-auto',
        'freed_kb': $freed_kb,
        'disk_pct': $disk_pct,
        'reason': 'self-tune setpoint dropped to ${setpoint} (threshold ${TRIGGER_SETPOINT})'
    }),
    'expires_at': expires_at,
    'hop_count': 0
}
print(json.dumps(bottle))
")

  if echo "$bottle" | nc -q 1 "$HARBOR_HOST" "$HARBOR_PORT" 2>/dev/null | grep -q '"status":"ok"'; then
    log "Bottle CONSTRUCT_EVICTION sent to harbor-daemon"
    return 0
  else
    log "WARN: harbor-daemon unreachable on ${HARBOR_HOST}:${HARBOR_PORT} — bottle not sent"
    return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  local pulse_id
  pulse_id=$(uuid)

  log "=== gc-auto-evict run ==="

  # Read current setpoint
  local setpoint
  setpoint=$(read_setpoint)
  log "Current setpoint: ${setpoint}"

  # Check if we're in the stressed/critical zone
  local threshold_check
  threshold_check=$(python3 -c "print('trigger' if float('$setpoint') <= $TRIGGER_SETPOINT else 'skip')" 2>/dev/null || echo "skip")

  if [ "$threshold_check" != "trigger" ]; then
    log "Setpoint ${setpoint} > ${TRIGGER_SETPOINT} — GC relaxed enough, nothing to do"
    log "=== gc-auto-evict complete (skipped) ==="
    return 0
  fi

  log "Setpoint ${setpoint} <= ${TRIGGER_SETPOINT} — STRESSED/CRITICAL ZONE — triggering eviction"

  # Get current disk status for the bottle
  local disk_pct
  disk_pct=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}' 2>/dev/null || echo "?")

  # Run gc-intelligent.sh --execute
  local gc_output gc_exitcode="0"
  gc_output=$("$GC_SCRIPT" --execute 2>&1) || gc_exitcode=$?

  log "gc-intelligent.sh exit code: ${gc_exitcode}"

  # Parse freed_kb from output — look for size suffixes like 1.2G or 500M
  local freed_kb="0"
  freed_kb=$(echo "$gc_output" \
    | grep -iE 'reclaimed|evicted' \
    | grep -oE '[0-9]+\.?[0-9]*[KMG]' \
    | tail -1 \
    | tr -d '[:alpha:]' \
    || echo "0")

  log "gc-intelligent.sh freed: ${freed_kb}KB"

  # Send CONSTRUCT_EVICTION bottle to harbor-daemon
  send_eviction_bottle "$pulse_id" "$setpoint" "$freed_kb" "$disk_pct" || true

  log "=== gc-auto-evict complete (eviction triggered) ==="
  return 0
}

main "$@"
