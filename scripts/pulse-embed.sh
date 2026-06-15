#!/usr/bin/env bash
#
# pulse-embed.sh — Embed latest rotation entry into headspace-rs
#
# Reads the latest rotation entry from data/rotation-feed.json,
# creates a deterministic 384-dim embedding from the metric values,
# and POSTs it to headspace-rs at :9090/api/segment.
#
# Two embedding strategies:
#   1. "text-hash" — MD5-hash the text representation, seeded deterministically
#   2. "metric-projection" — Distribute each metric across a band of dimensions
#
# Default: metric-projection (produces semantically sensible similarities)
#
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
HEADSPACE_URL="http://localhost:9090"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
ROTATION_FEED="${CONSTRUCT_DIR}/data/rotation-feed.json"

# Embedding dimension (must match headspace-rs)
DIM=384

# ─── Helpers ────────────────────────────────────────────────────────────────
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [pulse-embed] $*"; }
warn() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [pulse-embed] WARN: $*" >&2; }

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

# ─── Step 2: Build text representation ──────────────────────────────────────
build_text() {
  local entry="$1"
  python3 -c "
import json, sys

e = json.loads('''${entry//\'/\\\'}''')
g = e.get('gamma', 0)
eta = e.get('eta', 0)
c = e.get('c', 0)
d = e.get('disk_pct', 0)
r = e.get('ram_free_mb', 0)
l = e.get('load', 0.0)
s = e.get('services_active', 0)
ts = e.get('timestamp', '')
uid = e.get('id', '')

text = f'gamma={g} eta={eta} c={c} disk={d} ram={r} load={l} services={s}'
print(text)
"
}

# ─── Step 3: Generate 384-dim embedding ──────────────────────────────────────
# Strategy: metric-projection
# Map each scalar to a band of dimensions, producing deterministic f32 vectors
# that cosine similarity can meaningfully compare.
generate_embedding() {
  local entry="$1"
  python3 -c "
import json, sys, hashlib, struct

e = json.loads('''${entry//\'/\\\'}''')
gamma = e.get('gamma', 0)
eta = e.get('eta', 0)
c = e.get('c', 0)
disk = e.get('disk_pct', 0)
ram = e.get('ram_free_mb', 0)
load = e.get('load', 0.0)
services = e.get('services_active', 0)
ts = e.get('timestamp', '')
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
# Band 0: gamma (dims 0-53)
band_size = DIM // 7  # = 54
for i in range(band_size):
    vec[i] = n_gamma * (1.0 - i / band_size * 0.3)

# Band 1: eta (dims 54-107)
offset = band_size
for i in range(band_size):
    vec[offset + i] = n_eta * (1.0 - i / band_size * 0.3)

# Band 2: c (dims 108-161)
offset = band_size * 2
for i in range(band_size):
    vec[offset + i] = n_c * (1.0 - i / band_size * 0.3)

# Band 3: disk (dims 162-215)
offset = band_size * 3
for i in range(band_size):
    vec[offset + i] = n_disk * (1.0 - i / band_size * 0.3)

# Band 4: ram (dims 216-269)
offset = band_size * 4
for i in range(band_size):
    vec[offset + i] = n_ram * (1.0 - i / band_size * 0.3)

# Band 5: load (dims 270-323)
offset = band_size * 5
for i in range(band_size):
    vec[offset + i] = n_load * (1.0 - i / band_size * 0.3)

# Band 6: services (dims 324-377) — 54 dims (54*7=378, pad to 384)
offset = band_size * 6
for i in range(band_size):
    vec[offset + i] = n_services * (1.0 - i / band_size * 0.3)

# Seed dims 378-383 with hash of the entry id for uniqueness
h = hashlib.sha256(uid.encode()).digest()
for i in range(6):
    vec[378 + i] = (h[i] / 255.0) * 0.1  # small noise to break ties

# Normalize to unit vector for cosine similarity
norm = sum(x*x for x in vec) ** 0.5
if norm > 0:
    vec = [x / norm for x in vec]

# Print as JSON list
print(json.dumps(vec))
"
}

# ─── Step 4: POST to headspace-rs ────────────────────────────────────────────
post_to_headspace() {
  local text="$1"
  local embedding="$2"
  local entry="$3"

  # Extract id from the entry, or generate one
  local seg_id
  seg_id=$(echo "$entry" | python3 -c "
import json, sys
e = json.load(sys.stdin)
print(e.get('id', ''))
" 2>/dev/null || echo "")

  if [[ -z "$seg_id" ]]; then
    seg_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
  fi

  local payload
  payload=$(cat <<EOF
{
  "id": "${seg_id}",
  "text": "${text}",
  "embedding": ${embedding}
}
EOF
)

  local resp
  resp=$(curl -sf --max-time 10 \
    -X POST "${HEADSPACE_URL}/api/segment" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || {
    warn "headspace-rs unreachable at ${HEADSPACE_URL}"
    return 1
  }

  log "headspace-rs stored: id=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null), dims=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('dimensions','?'))" 2>/dev/null)"
  return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  log "=== Pulse Embed ==="

  # Step 1: Read latest rotation entry
  local entry
  entry=$(read_latest_entry) || {
    warn "No rotation entry available; skipping embed"
    return 1
  }

  log "Read latest rotation entry"

  # Step 2: Build text representation
  local text
  text=$(build_text "$entry")
  log "Text: ${text}"

  # Step 3: Generate embedding
  local embedding
  embedding=$(generate_embedding "$entry")
  log "Generated ${DIM}-dim embedding"

  # Step 4: POST to headspace-rs
  post_to_headspace "$text" "$embedding" "$entry" || {
    warn "Failed to store segment in headspace-rs"
    return 1
  }

  # Step 5: Verify status
  local status
  status=$(curl -sf --max-time 5 "${HEADSPACE_URL}/api/status" 2>/dev/null || echo '{"segments":-1}')
  local seg_count
  seg_count=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('segments',-1))" 2>/dev/null || echo "-1")
  log "headspace-rs status: ${seg_count} segments"

  log "=== Pulse Embed complete ==="
}

main "$@"
