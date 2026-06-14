#!/usr/bin/env bash
# pulse.sh — Construct relay pulse
#
# Every 15 minutes (via systemd timer):
#   1. Collects system metrics (disk, RAM, load, uptime, services)
#   2. POSTs to fleet-oracle (:8795/api/decide) for a decision
#   3. Logs rotation fields from oracle response to fleet-log (:8781)
#   4. Appends rotation data to rotation-feed.json (JSONL, max 1000 entries)
#   5. POSTs rotation data to fleet-event (:8782/api/events)
#
# Rotation fields captured:
#   - rotation_cycle_error  — system state inconsistency
#   - rotation_cognitive    — PID cascade cognitive output
#   - rotation_confidence   — reflex posterior confidence coverage
#   - combined_confidence   — oracle's combined confidence score
#
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
ORACLE_URL="http://localhost:8795/api/decide"
FLEET_LOG_URL="http://localhost:8781/api/logs"
FLEET_EVENT_URL="http://localhost:8782/api/events"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
ROTATION_FEED="${CONSTRUCT_DIR}/data/rotation-feed.json"
MAX_FEED_ENTRIES=1000

# ── Helpers ────────────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ts()  { date -u +%s; }
uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

log() { echo "[$(now_iso)] [pulse] $*"; }
warn() { echo "[$(now_iso)] [pulse] WARN: $*" >&2; }

# ── Step 1: Collect System Metrics ────────────────────────────────────────────
collect_metrics() {
  local disk_pct ram_free_mb load uptime_secs services_active pid_commands ternary_vote temporal_window

  # Disk usage percentage for root partition
  disk_pct=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
  disk_pct="${disk_pct:-50}"

  # Free RAM in MB
  ram_free_mb=$(free -m | awk '/^Mem:/ {print $7}')
  ram_free_mb="${ram_free_mb:-4000}"

  # 1-minute load average
  load=$(uptime | sed 's/.*load average[s]*:[[:space:]]*//' | awk -F', ' '{print $1}')
  load="${load:-1.0}"

  # Uptime in seconds
  uptime_secs=$(cat /proc/uptime 2>/dev/null | awk '{print $1}' | cut -d. -f1)
  uptime_secs="${uptime_secs:-3600}"

  # Count active systemd services
  services_active=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l)
  services_active="${services_active:-1}"

  # Count running user processes (approximation of pid pressure)
  pid_commands=$(ps aux --no-headers 2>/dev/null | wc -l)
  pid_commands="${pid_commands:-10}"

  # Ternary vote: 1 for execute, 0 for explore, -1 for retreat
  # Inferred from load: high load = retreat, low = execute
  local load_int
  load_int=$(echo "$load" | awk '{printf "%d", $1}')
  if   (( load_int >= 8 )); then ternary_vote=-1
  elif (( load_int >= 4 )); then ternary_vote=0
  else                           ternary_vote=1
  fi

  # Temporal window: time since last pulse in seconds (default 900 = 15min)
  temporal_window=900

  # Emit JSON to stdout
  cat <<EOF
{
  "disk_pct": ${disk_pct},
  "ram_free_mb": ${ram_free_mb},
  "load": ${load},
  "uptime_secs": ${uptime_secs},
  "services_active": ${services_active},
  "pid_commands": ${pid_commands},
  "ternary_vote": ${ternary_vote},
  "temporal_window": ${temporal_window}
}
EOF
}

# ── Step 2: Query Oracle ───────────────────────────────────────────────────────
query_oracle() {
  local metrics="$1"
  local resp

  resp=$(curl -sf --max-time 30 \
    -X POST "$ORACLE_URL" \
    -H "Content-Type: application/json" \
    -d "$metrics" 2>/dev/null) || {
    warn "Oracle unreachable at $ORACLE_URL"
    echo ""
    return 1
  }

  echo "$resp"
}

# ── Step 3: Extract Rotation Fields ────────────────────────────────────────────
# Uses python3 for reliable JSON parsing (avoids jq dependency)
extract_rotation_fields() {
  local oracle_resp="$1"

  if [[ -z "$oracle_resp" ]]; then
    cat <<EOF
{
  "rotation_cycle_error": null,
  "rotation_cognitive": null,
  "rotation_confidence": null,
  "combined_confidence": null,
  "needs_attention": null,
  "recommendation": null,
  "decision_count": null,
  "svm_trained": null
}
EOF
    return 0
  fi

  python3 -c "
import json, sys

data = json.loads('''${oracle_resp//\'/\\\'}''')
dec = data.get('decision', {})
stat = data.get('oracle_status', {})

result = {
    'rotation_cycle_error': dec.get('rotation_cycle_error'),
    'rotation_cognitive': dec.get('rotation_cognitive'),
    'rotation_confidence': dec.get('rotation_confidence'),
    'combined_confidence': dec.get('combined_confidence'),
    'needs_attention': dec.get('needs_attention'),
    'recommendation': dec.get('recommendation'),
    'entropy_surprise': dec.get('entropy_surprise'),
    'rhythm_anomaly': dec.get('rhythm_anomaly'),
    'svm_prediction': dec.get('svm_prediction'),
    'decision_count': stat.get('decision_count'),
    'rotation_total': stat.get('rotation_total'),
    'svm_trained': stat.get('svm_trained'),
    'svm_confidence': dec.get('svm_confidence'),
}

print(json.dumps(result))
"
}

# ── Step 4: Log to Fleet-Log (:8781) ──────────────────────────────────────────
log_to_fleet() {
  local pulse_id="$1"
  local ts="$2"
  local rotation_data="$3"
  local metrics="$4"

  # fleet-log metadata expects HashMap<String, String> — convert all values to strings
  local rotation_feed_payload
  rotation_feed_payload=$(echo "$rotation_data" | python3 -c "
import json, sys
r = json.load(sys.stdin)
# Convert all values to strings for fleet-log's HashMap<String, String>
def to_str(v):
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, float):
        return f'{v:.8f}'
    return str(v)

payload = {}
for key in ['rotation_cycle_error', 'rotation_cognitive', 'rotation_confidence',
            'combined_confidence', 'needs_attention', 'svm_prediction',
            'entropy_surprise', 'rhythm_anomaly', 'svm_confidence']:
    payload[key] = to_str(r.get(key))
print(json.dumps(payload))
")

  local log_payload
  log_payload=$(cat <<EOF
{
  "source": "construct-pulse",
  "entries": [
    {
      "id": "${pulse_id}",
      "timestamp": "${ts}",
      "level": "info",
      "service": "construct-pulse",
      "message": "pulse rotation feedback",
      "metadata": ${rotation_feed_payload}
    }
  ]
}
EOF
)

  local resp
  resp=$(curl -sf --max-time 10 \
    -X POST "$FLEET_LOG_URL" \
    -H "Content-Type: application/json" \
    -d "$log_payload" 2>/dev/null) || {
    warn "fleet-log unreachable at $FLEET_LOG_URL"
    return 1
  }

  log "fleet-log accepted: $(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d)" 2>/dev/null || echo "$resp")"
  return 0
}

# ── Step 5: Append to Rotation Feed (JSONL) ───────────────────────────────────
append_to_feed() {
  local pulse_id="$1"
  local ts="$2"
  local rotation_data="$3"
  local metrics="$4"

  # Build a single JSONL line from rotation data + metrics + timestamp
  local feed_entry
  feed_entry=$(echo "$rotation_data" | python3 -c "
import json, sys
r = json.load(sys.stdin)
metrics = json.loads('''${metrics//\'/\\\'}''')
entry = {
    'id': '${pulse_id}',
    'timestamp': '${ts}',
    'rotation_cycle_error': r.get('rotation_cycle_error'),
    'rotation_cognitive': r.get('rotation_cognitive'),
    'rotation_confidence': r.get('rotation_confidence'),
    'combined_confidence': r.get('combined_confidence'),
    'needs_attention': r.get('needs_attention'),
    'entropy_surprise': r.get('entropy_surprise'),
    'rhythm_anomaly': r.get('rhythm_anomaly'),
    'svm_prediction': r.get('svm_prediction'),
    'svm_confidence': r.get('svm_confidence'),
    'decision_count': r.get('decision_count'),
    'rotation_total': r.get('rotation_total'),
    'disk_pct': metrics.get('disk_pct'),
    'ram_free_mb': metrics.get('ram_free_mb'),
    'load': metrics.get('load'),
    'services_active': metrics.get('services_active'),
}
print(json.dumps(entry))
")

  # Append to JSONL file
  echo "$feed_entry" >> "$ROTATION_FEED"
  log "Appended to rotation-feed"

  # Trim to MAX_FEED_ENTRIES (keep newest)
  local line_count
  line_count=$(wc -l < "$ROTATION_FEED")
  if (( line_count > MAX_FEED_ENTRIES )); then
    local trim_count=$(( line_count - MAX_FEED_ENTRIES ))
    # Use a temp file to trim oldest entries
    tail -n "$MAX_FEED_ENTRIES" "$ROTATION_FEED" > "${ROTATION_FEED}.tmp"
    mv "${ROTATION_FEED}.tmp" "$ROTATION_FEED"
    log "Trimmed rotation-feed to ${MAX_FEED_ENTRIES} entries (removed ${trim_count} oldest)"
  fi
}

# ── Step 6: POST to Fleet-Event (:8782) with rotation data ────────────────────
post_to_fleet_event() {
  local pulse_id="$1"
  local ts="$2"
  local rotation_data="$3"
  local metrics="$4"

  local event_payload
  event_payload=$(cat <<EOF
{
  "event_type": "rotation_feedback",
  "source": "construct-pulse",
  "payload": $(echo "$rotation_data" | python3 -c "
import json, sys
r = json.load(sys.stdin)
# Build a compact payload string for fleet-event
items = {
    'pulse_id': '${pulse_id}',
    'rotation_cycle_error': r.get('rotation_cycle_error'),
    'rotation_cognitive': r.get('rotation_cognitive'),
    'rotation_confidence': r.get('rotation_confidence'),
    'combined_confidence': r.get('combined_confidence'),
    'needs_attention': r.get('needs_attention'),
    'recommendation': r.get('recommendation'),
}
# fleet-event expects payload as a string
print(json.dumps(json.dumps(items)))
"),
  "ternary_merit": $(echo "$rotation_data" | python3 -c "
import json, sys
r = json.load(sys.stdin)
conf = r.get('combined_confidence') or 0.0
# Map combined_confidence 0.0-1.0 to i8 range -128 to 127
merit = int(max(-128, min(127, conf * 100.0)))
print(merit)
"),
  "timestamp": "${ts}"
}
EOF
)

  local resp
  resp=$(curl -sf --max-time 10 \
    -X POST "$FLEET_EVENT_URL" \
    -H "Content-Type: application/json" \
    -d "$event_payload" 2>/dev/null) || {
    warn "fleet-event unreachable at $FLEET_EVENT_URL"
    return 1
  }

  log "fleet-event accepted: $(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d)" 2>/dev/null || echo "$resp")"
  return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  local pulse_id
  pulse_id=$(uuid)

  local ts
  ts=$(now_iso)

  log "=== Construct Pulse ${pulse_id} ==="

  # Step 1: Collect metrics
  log "Collecting system metrics..."
  local metrics
  metrics=$(collect_metrics)
  log "Metrics: $(echo "$metrics" | python3 -c "import json,sys; d=json.load(sys.stdin); print({k:v for k,v in d.items() if k != 'ternary_vote'})" 2>/dev/null || echo "$metrics")"

  # Step 2: Query oracle
  log "Querying oracle at ${ORACLE_URL}..."
  local oracle_resp
  oracle_resp=$(query_oracle "$metrics") || true

  if [[ -z "$oracle_resp" ]]; then
    warn "Oracle returned no response — skipping rotation feedback pipeline"
    # Still log metrics to rotation feed with null rotation fields
    local empty_rotation
    empty_rotation=$(cat <<'PYEOF'
{
  "rotation_cycle_error": null,
  "rotation_cognitive": null,
  "rotation_confidence": null,
  "combined_confidence": null,
  "needs_attention": null,
  "recommendation": null,
  "decision_count": null,
  "rotation_total": null,
  "svm_trained": null,
  "entropy_surprise": null,
  "rhythm_anomaly": null,
  "svm_prediction": null,
  "svm_confidence": null
}
PYEOF
)
    append_to_feed "$pulse_id" "$ts" "$empty_rotation" "$metrics"
    log "=== Pulse ${pulse_id} complete (oracle unavailable) ==="
    exit 0
  fi

  log "Oracle response received"

  # Step 3: Extract rotation fields
  local rotation_data
  rotation_data=$(extract_rotation_fields "$oracle_resp")
  log "Rotation data: $(echo "$rotation_data" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print({
    'cycle_error': r.get('rotation_cycle_error'),
    'cognitive': r.get('rotation_cognitive'),
    'confidence': r.get('rotation_confidence'),
    'combined': r.get('combined_confidence'),
    'needs_attention': r.get('needs_attention'),
})
" 2>/dev/null)"

  # Step 4: Log to fleet-log
  log "Logging to fleet-log..."
  log_to_fleet "$pulse_id" "$ts" "$rotation_data" "$metrics" || true

  # Step 5: Append to rotation-feed.json (JSONL)
  log "Appending to rotation-feed..."
  append_to_feed "$pulse_id" "$ts" "$rotation_data" "$metrics"

  # Step 6: POST to fleet-event with rotation data
  log "Posting to fleet-event..."
  post_to_fleet_event "$pulse_id" "$ts" "$rotation_data" "$metrics" || true

  log "=== Pulse ${pulse_id} complete ==="
}

main "$@"
