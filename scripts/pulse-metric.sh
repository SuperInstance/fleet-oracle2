#!/usr/bin/env bash
#
# pulse-metric.sh — Simplified construct pulse for crontab
#
# Runs every 5 minutes via crontab no matter what.
#   1. Collects system metrics (disk%, free RAM, load, active services, uptime)
#   2. Computes γ (complexity) = disk_pct * 10 + load * 100
#   3. Computes η (efficiency) = services_active * 10
#   4. POSTs γ/η to conservation-meter at :8798/api/report
#   5. Appends a rotation entry to data/rotation-feed.json (JSONL)
#   6. Optionally sends a bottle to harbor-daemon via TCP on port 8796
#
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
CONSERVATION_URL="http://localhost:8798/api/report"
HARBOR_HOST="127.0.0.1"
HARBOR_PORT=8796

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
ROTATION_FEED="${CONSTRUCT_DIR}/data/rotation-feed.json"
MAX_FEED_ENTRIES=1000

# ── Helpers ──────────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ts()  { date -u +%s; }
uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

log() { echo "[$(now_iso)] [pulse-metric] $*"; }
warn() { echo "[$(now_iso)] [pulse-metric] WARN: $*" >&2; }

# ── Step 1: Collect System Metrics ──────────────────────────────────────────
collect_metrics() {
  local disk_pct ram_free_mb load uptime_secs services_active

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

  # Emit JSON to stdout
  cat <<EOF
{
  "disk_pct": ${disk_pct},
  "ram_free_mb": ${ram_free_mb},
  "load": ${load},
  "uptime_secs": ${uptime_secs},
  "services_active": ${services_active}
}
EOF
}

# ── Step 2: Compute γ and η ──────────────────────────────────────────────────
# γ (complexity) = disk_pct * 10 + load * 100
# η (efficiency) = services_active * 10
compute_gamma_eta() {
  local metrics="$1"
  python3 -c "
import json
import sys

m = json.loads('''${metrics//\'/\\\'}''')
disk_pct = m.get('disk_pct', 50)
load = m.get('load', 1.0)
services = m.get('services_active', 1)

gamma = int(disk_pct * 10 + load * 100)
eta = int(services * 10)

print(json.dumps({'gamma': gamma, 'eta': eta}))
"
}

# ── Step 3: POST to Conservation Meter ────────────────────────────────────────
post_to_conservation() {
  local agent="$1"
  local gamma="$2"
  local eta="$3"
  local task="$4"
  local ts="$5"

  local payload
  payload=$(cat <<EOF
{
  "gamma": ${gamma},
  "eta": ${eta},
  "agent": "${agent}",
  "task": "${task}",
  "timestamp": "${ts}"
}
EOF
)

  local resp
  resp=$(curl -sf --max-time 10 \
    -X POST "$CONSERVATION_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || {
    warn "conservation-meter unreachable at $CONSERVATION_URL"
    return 1
  }

  log "conservation-meter accepted: $(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'), 'c='+str(d.get('c','?')))" 2>/dev/null || echo "$resp")"
  return 0
}

# ── Step 4: Append to Rotation Feed (JSONL) ──────────────────────────────────
append_to_feed() {
  local pulse_id="$1"
  local ts="$2"
  local gamma="$3"
  local eta="$4"
  local metrics="$5"

  local feed_entry
  feed_entry=$(python3 -c "
import json, sys

m = json.loads('''${metrics//\'/\\\'}''')
c = ${gamma} + ${eta}
entry = {
    'id': '${pulse_id}',
    'timestamp': '${ts}',
    'gamma': ${gamma},
    'eta': ${eta},
    'c': c,
    'combined_confidence': round(c / 2000.0, 2) if c <= 2000 else 1.0,
    'disk_pct': m.get('disk_pct'),
    'ram_free_mb': m.get('ram_free_mb'),
    'load': m.get('load'),
    'services_active': m.get('services_active'),
    'uptime_seconds': m.get('uptime_secs'),
    'source': 'pulse-metric-cron',
    'status': 'running'
}
print(json.dumps(entry))
")

  # Ensure the data directory and file exist
  mkdir -p "$(dirname "$ROTATION_FEED")"
  touch "$ROTATION_FEED"

  # Append as a single JSON line
  echo "$feed_entry" >> "$ROTATION_FEED"
  log "Appended to rotation-feed: $(echo "$feed_entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'γ={d[\"gamma\"]}, η={d[\"eta\"]}, C={d[\"c\"]}')" 2>/dev/null)"

  # Trim to MAX_FEED_ENTRIES (keep newest)
  local line_count
  line_count=$(wc -l < "$ROTATION_FEED")
  if (( line_count > MAX_FEED_ENTRIES )); then
    local trim_count=$(( line_count - MAX_FEED_ENTRIES ))
    tail -n "$MAX_FEED_ENTRIES" "$ROTATION_FEED" > "${ROTATION_FEED}.tmp"
    mv "${ROTATION_FEED}.tmp" "$ROTATION_FEED"
    log "Trimmed rotation-feed to ${MAX_FEED_ENTRIES} entries (removed ${trim_count} oldest)"
  fi
}

# ── Step 5: Send bottle to Harbor Daemon (optional) ──────────────────────────
send_harbor_bottle() {
  local pulse_id="$1"
  local ts="$2"
  local gamma="$3"
  local eta="$4"
  local metrics="$5"

  local bottle_payload
  bottle_payload=$(python3 -c "
import json, sys

m = json.loads('''${metrics//\'/\\\'}''')
expires = '${ts}'  # base for expiry
# Set expiry 1 hour from now
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
expires_at = (now + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')

bottle = {
    'uuid': '${pulse_id}',
    'sender': 'pulse-metric-cron',
    'recipient': 'conservation-meter',
    'priority': 3,
    'type': 'pulse_metric',
    'payload': json.dumps({
        'gamma': ${gamma},
        'eta': ${eta},
        'c': ${gamma} + ${eta},
        'disk_pct': m.get('disk_pct'),
        'ram_free_mb': m.get('ram_free_mb'),
        'load': m.get('load'),
        'services_active': m.get('services_active'),
    }),
    'expires_at': expires_at,
    'hop_count': 0
}
print(json.dumps(bottle))
")

  if echo "$bottle_payload" | nc -q 1 "$HARBOR_HOST" "$HARBOR_PORT" 2>/dev/null | grep -q '"status":"ok"'; then
    log "Bottle sent to harbor-daemon on port ${HARBOR_PORT}"
    return 0
  else
    warn "harbor-daemon unreachable on ${HARBOR_HOST}:${HARBOR_PORT}"
    return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  local pulse_id
  pulse_id=$(uuid)

  local ts
  ts=$(now_iso)

  log "=== Pulse Metric ${pulse_id} ==="

  # Step 1: Collect metrics
  log "Collecting system metrics..."
  local metrics
  metrics=$(collect_metrics)
  log "Metrics: disk_pct=$(echo "$metrics" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['disk_pct'])" 2>/dev/null), ram=$(echo "$metrics" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ram_free_mb'])" 2>/dev/null)MB, load=$(echo "$metrics" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['load'])" 2>/dev/null), services=$(echo "$metrics" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['services_active'])" 2>/dev/null)"

  # Step 2: Compute γ and η
  local ge
  ge=$(compute_gamma_eta "$metrics")
  local gamma eta
  gamma=$(echo "$ge" | python3 -c "import json,sys; print(json.load(sys.stdin)['gamma'])")
  eta=$(echo "$ge" | python3 -c "import json,sys; print(json.load(sys.stdin)['eta'])")
  log "Computed: γ=${gamma} (complexity), η=${eta} (efficiency), C=$((gamma + eta))"

  # Step 3: POST to conservation-meter
  log "POSTing to conservation-meter at ${CONSERVATION_URL}..."
  post_to_conservation "construct-pulse-cron" "$gamma" "$eta" "pulse-metric" "$ts" || true

  # Step 4: Append to rotation-feed
  log "Appending to rotation-feed..."
  append_to_feed "$pulse_id" "$ts" "$gamma" "$eta" "$metrics"

  # Step 5: Send bottle to harbor-daemon
  log "Sending bottle to harbor-daemon..."
  send_harbor_bottle "$pulse_id" "$ts" "$gamma" "$eta" "$metrics" || true

  # Step 6: Embed in headspace-rs
  log "Embedding pulse into headspace-rs..."
  bash "${SCRIPT_DIR}/pulse-embed.sh" || warn "headspace-rs embed failed; continuing"

  # Step 7: Fire pulse-webhook (ratio/confidence threshold alerts)
  log "Checking pulse-webhook thresholds..."
  bash "${SCRIPT_DIR}/pulse-webhook.sh" || warn "pulse-webhook check failed; continuing"

  # Step 8: Self-tuning notice — if GC aggression > 4.0, flag for attention
  local disk_pct_hook
  disk_pct_hook=$(collect_metrics 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('disk_pct',63))" 2>/dev/null || echo 63)
  local used_pct=$((100 - disk_pct_hook))
  local aggression_hook
  aggression_hook=$(/usr/local/bin/gc-pid-bridge "$used_pct" 2>/dev/null || echo "2.0")
  if (( $(echo "$aggression_hook > 4.0" | bc -l 2>/dev/null || echo 0) )); then
    log "NOTICE: GC aggression ${aggression_hook}x — high disk pressure. Consider tuning."
  fi

  log "=== Pulse Metric ${pulse_id} complete ==="
}

main "$@"
