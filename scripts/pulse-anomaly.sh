#!/usr/bin/env bash
#
# pulse-anomaly.sh — Detect state vector anomalies via headspace-rs
#
# Runs as Step 7.5 in pulse-metric.sh. It:
#   1. Generates the current 384-dim state vector (same method as pulse-embed.sh)
#   2. POSTs to headspace-rs /api/query to find the most similar historical segment
#   3. If cosine similarity < 0.85, flags as ANOMALOUS
#   4. Logs the anomaly and sends a CONCERN bottle to harbor-daemon
#   5. If >3 consecutive anomalies detected, sends a DRIFT bottle (priority 1)
#
# Persistence: tracks consecutive anomalies in data/.anomaly-state.json
#
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
HEADSPACE_URL="http://localhost:9090"
HARBOR_HOST="127.0.0.1"
HARBOR_PORT=8796

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
ROTATION_FEED="${CONSTRUCT_DIR}/data/rotation-feed.json"
ANOMALY_STATE="${CONSTRUCT_DIR}/data/.anomaly-state.json"

SIMILARITY_THRESHOLD=0.85   # Below this = anomalous
MAX_CONSECUTIVE_BEFORE_DRIFT=3
DIM=384

# ─── Helpers ────────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ts()  { date -u +%s; }
uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

log()  { echo "[$(now_iso)] [pulse-anomaly] $*"; }
warn() { echo "[$(now_iso)] [pulse-anomaly] WARN: $*" >&2; }

# ─── Load / save anomaly state ──────────────────────────────────────────────
load_state() {
  local default='{"consecutive_anomalies":0,"last_anomaly_ts":null,"last_normal_ts":null,"last_similarity":1.0,"anomaly_history":[]}'
  if [[ -f "$ANOMALY_STATE" ]]; then
    python3 -c "
import json
with open('$ANOMALY_STATE') as f:
    try:
        d = json.load(f)
    except:
        d = json.loads('$default')
print(json.dumps(d))
"
  else
    echo "$default"
  fi
}

save_state() {
  local state_json="$1"
  mkdir -p "$(dirname "$ANOMALY_STATE")"
  echo "$state_json" > "$ANOMALY_STATE"
}

update_state_anomaly() {
  local similarity="$1"
  local state="$2"
  python3 -c "
import json
s = json.loads('''${state//\'/\\\'}''')
s['consecutive_anomalies'] = s.get('consecutive_anomalies', 0) + 1
s['last_anomaly_ts'] = '$(now_iso)'
s['last_similarity'] = ${similarity}
h = s.get('anomaly_history', [])
h.append({'ts': '$(now_iso)', 'similarity': ${similarity}})
if len(h) > 100:
    h = h[-100:]
s['anomaly_history'] = h
print(json.dumps(s))
"
}

update_state_normal() {
  local similarity="$1"
  local state="$2"
  python3 -c "
import json
s = json.loads('''${state//\'/\\\'}''')
s['consecutive_anomalies'] = 0
s['last_normal_ts'] = '$(now_iso)'
s['last_similarity'] = ${similarity}
print(json.dumps(s))
"
}

# ─── Step 1: Read latest rotation entry ──────────────────────────────────────
read_latest_entry() {
  if [[ ! -f "$ROTATION_FEED" ]]; then
    warn "rotation-feed not found: $ROTATION_FEED"
    return 1
  fi

  local last_line
  last_line="$(tail -1 "$ROTATION_FEED" 2>/dev/null)" || {
    warn "failed to read last line of rotation-feed"
    return 1
  }

  if [[ -z "$last_line" ]]; then
    warn "rotation-feed is empty"
    return 1
  fi

  echo "$last_line"
  return 0
}

# ─── Step 2: Generate current state vector (same method as pulse-embed.sh) ────
generate_vector() {
  local entry="$1"
  python3 -c "
import json, sys, hashlib

e = json.loads('''${entry//\'/\\\'}''')
gamma = e.get('gamma', 0)
eta = e.get('eta', 0)
c = e.get('c', 0)
disk = e.get('disk_pct', 0)
ram = e.get('ram_free_mb', 0)
load = e.get('load', 0.0)
services = e.get('services_active', 0)
uid = e.get('id', '')

DIM = 384
vec = [0.0] * DIM

# Normalize each metric to [0, 1] range
n_gamma = gamma / 1000.0
n_eta = eta / 500.0
n_c = c / 2000.0
n_disk = disk / 100.0
n_ram = ram / 65536.0
n_load = min(load / 10.0, 1.0)
n_services = services / 100.0

# Distribute each metric across a dedicated band of dimensions
band_size = DIM // 7  # = 54
for i in range(band_size):
    vec[i] = n_gamma * (1.0 - i / band_size * 0.3)

offset = band_size
for i in range(band_size):
    vec[offset + i] = n_eta * (1.0 - i / band_size * 0.3)

offset = band_size * 2
for i in range(band_size):
    vec[offset + i] = n_c * (1.0 - i / band_size * 0.3)

offset = band_size * 3
for i in range(band_size):
    vec[offset + i] = n_disk * (1.0 - i / band_size * 0.3)

offset = band_size * 4
for i in range(band_size):
    vec[offset + i] = n_ram * (1.0 - i / band_size * 0.3)

offset = band_size * 5
for i in range(band_size):
    vec[offset + i] = n_load * (1.0 - i / band_size * 0.3)

offset = band_size * 6
for i in range(band_size):
    vec[offset + i] = n_services * (1.0 - i / band_size * 0.3)

# Seed dims 378-383 with hash of the entry id for uniqueness
h = hashlib.sha256(uid.encode()).digest()
for i in range(6):
    vec[378 + i] = (h[i] / 255.0) * 0.1

# Normalize to unit vector
norm = sum(x*x for x in vec) ** 0.5
if norm > 0:
    vec = [x / norm for x in vec]

print(json.dumps(vec))
"
}

# ─── Step 3: Query headspace-rs for nearest neighbor ────────────────────────
query_headspace() {
  local vector="$1"

  local text
  text="anomaly-check-$(now_iso)"

  local payload
  payload=$(cat <<EOF
{"text": "${text}", "embedding": ${vector}, "k": 5}
EOF
)

  local resp
  resp=$(curl -sf --max-time 10 \
    -X POST "${HEADSPACE_URL}/api/query" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || {
    warn "headspace-rs unreachable at ${HEADSPACE_URL}"
    return 1
  }

  echo "$resp"
  return 0
}

# ─── Step 4: Send bottle to harbor-daemon ────────────────────────────────────
send_harbor_bottle() {
  local priority="$1"
  local bottle_type="$2"
  local payload_msg="$3"

  local bottle_id
  bottle_id=$(uuid)

  local expires_ts
  # Bottle expires 2 hours from now
  expires_ts=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) + timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

  local bottle_payload
  bottle_payload=$(cat <<EOF
{
  "uuid": "${bottle_id}",
  "sender": "pulse-anomaly",
  "recipient": "construct-supervisor",
  "priority": ${priority},
  "type": "${bottle_type}",
  "payload": $(echo "$payload_msg" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))"),
  "expires_at": "${expires_ts}",
  "hop_count": 0
}
EOF
)

  if echo "$bottle_payload" | nc -q 1 "$HARBOR_HOST" "$HARBOR_PORT" 2>/dev/null | grep -q '"status":"ok"'; then
    log "Bottle ${bottle_type} (pri=${priority}) sent to harbor-daemon"
    return 0
  else
    warn "harbor-daemon unreachable on ${HARBOR_HOST}:${HARBOR_PORT}"
    return 1
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  log "=== Pulse Anomaly Detection ==="

  # Step 1: Read latest rotation entry
  local entry
  entry=$(read_latest_entry) || {
    warn "No rotation entry available; skipping anomaly check"
    return 1
  }
  log "Read latest rotation entry"

  # Step 2: Generate current state vector
  local vector
  vector=$(generate_vector "$entry")
  log "Generated state vector"

  # Step 3: Query headspace-rs
  local query_result
  query_result=$(query_headspace "$vector") || {
    warn "headspace-rs query failed; skipping anomaly check"
    return 1
  }
  log "Queried headspace-rs"

  # Step 4: Parse the query result
  local top_similarity top_id
  top_similarity=$(echo "$query_result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
results = d.get('results', [])
if results:
    print(results[0].get('score', 0))
else:
    print('0')
" 2>/dev/null || echo "0")

  top_id=$(echo "$query_result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
results = d.get('results', [])
if results:
    print(results[0].get('id', 'unknown'))
else:
    print('none')
" 2>/dev/null || echo "unknown")

  log "Top match: id=${top_id}, similarity=${top_similarity}"

  # Step 5: Compare against threshold
  local state
  state=$(load_state)

  # Use python3 to do the float comparison reliably
  local is_anomalous
  is_anomalous=$(python3 -c "
sim = float('${top_similarity}')
thresh = float('${SIMILARITY_THRESHOLD}')
print('true' if sim < thresh else 'false')
")

  if [[ "$is_anomalous" == "true" ]]; then
    local consecutive
    consecutive=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('consecutive_anomalies', 0))")
    log "⚠️  ANOMALY DETECTED: similarity=${top_similarity} < threshold=${SIMILARITY_THRESHOLD} (consecutive count: $((consecutive + 1)))"

    # Update state with anomaly
    state=$(update_state_anomaly "$top_similarity" "$state")
    save_state "$state"

    # Build the payload detail
    local anomaly_detail
    anomaly_detail=$(cat <<EOF
{
  "event": "state_anomaly",
  "similarity": ${top_similarity},
  "threshold": ${SIMILARITY_THRESHOLD},
  "top_match_id": "${top_id}",
  "gamma": $(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('gamma',0))"),
  "eta": $(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('eta',0))"),
  "c": $(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('c',0))"),
  "disk_pct": $(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('disk_pct',0))"),
  "ram_free_mb": $(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ram_free_mb',0))"),
  "load": $(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('load',0.0))"),
  "services_active": $(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('services_active',0))"),
  "consecutive": $((consecutive + 1))
}
EOF
)

    # Send CONCERN bottle
    send_harbor_bottle 3 "CONCERN" "State anomaly detected: similarity=${top_similarity}, threshold=${SIMILARITY_THRESHOLD}, consecutive=$((consecutive + 1))" || true

    # If >3 consecutive anomalies, send DRIFT bottle (priority 1 = highest)
    if (( consecutive + 1 >= MAX_CONSECUTIVE_BEFORE_DRIFT )); then
      log "🚨 DRIFT DETECTED: ${MAX_CONSECUTIVE_BEFORE_DRIFT}+ consecutive anomalies — sending DRIFT alert"
      send_harbor_bottle 1 "DRIFT" "System state drift detected: ${consecutive}+ consecutive state anomalies, latest similarity=${top_similarity}" || true
    fi

    # Log anomaly detail to construct data directory
    mkdir -p "${CONSTRUCT_DIR}/data/anomalies"
    echo "$anomaly_detail" >> "${CONSTRUCT_DIR}/data/anomalies/pulse-anomalies.jsonl"

    log "⚠️  Anomaly recorded to data/anomalies/pulse-anomalies.jsonl"
  else
    log "✅ State normal: similarity=${top_similarity} >= threshold=${SIMILARITY_THRESHOLD}"

    # Update state (reset consecutive count)
    state=$(update_state_normal "$top_similarity" "$state")
    save_state "$state"
  fi

  log "=== Pulse Anomaly Detection complete ==="
}

main "$@"
