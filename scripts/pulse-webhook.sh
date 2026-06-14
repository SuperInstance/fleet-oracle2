#!/usr/bin/env bash
#
# pulse-webhook.sh — Fires on significant rotation events.
#   - combined_confidence drops below 0.3  → warning alert to fleet-event
#   - combined_confidence jumps above 0.8  → celebration info entry to fleet-event
#
set -euo pipefail

FEEDFILE="/home/ubuntu/.openclaw/workspace/construct/data/rotation-feed.json"
FLEET_EVENT_URL="http://localhost:8782/api/event"
LOGFILE="/tmp/construct-pulse-webhook.log"
THRESHOLD_LOW=0.3
THRESHOLD_HIGH=0.8

log() {
    echo "[$(date -Iseconds)] $*" >> "$LOGFILE"
}

# ── Load latest entry ─────────────────────────────────────────────────────────
if [[ ! -f "$FEEDFILE" ]]; then
    log "ERROR: rotation-feed.json not found"
    exit 1
fi

latest_entry=$(tail -1 "$FEEDFILE")

# ── Extract combined_confidence ───────────────────────────────────────────────
confidence=$(echo "$latest_entry" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("combined_confidence", "null"))
' 2>/dev/null)

if [[ "$confidence" == "null" || -z "$confidence" ]]; then
    log "ERROR: could not parse combined_confidence from feed entry"
    exit 1
fi

log "Parsed confidence: $confidence"

# ── Fire webhook based on threshold ───────────────────────────────────────────
if (( $(echo "$confidence < $THRESHOLD_LOW" | bc -l) )); then
    log "Confidence below $THRESHOLD_LOW — posting WARNING event"

    event_payload=$(echo "$latest_entry" | python3 -c "
import json, sys, uuid
d = json.load(sys.stdin)
event = {
    \"id\": str(uuid.uuid4()),
    \"topic\": \"rotation_alert\",
    \"severity\": \"alert\",
    \"message\": \"Rotation confidence dropped below ${THRESHOLD_LOW}: ${confidence}\",
    \"payload\": d
}
print(json.dumps(event))
")
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$FLEET_EVENT_URL" \
        -H "Content-Type: application/json" \
        -d "$event_payload" \
        --max-time 10 2>/dev/null || echo "000")
    log "POST alert result: HTTP $http_code"

elif (( $(echo "$confidence > $THRESHOLD_HIGH" | bc -l) )); then
    log "Confidence above $THRESHOLD_HIGH — posting CELEBRATION event"

    event_payload=$(echo "$latest_entry" | python3 -c "
import json, sys, uuid
d = json.load(sys.stdin)
event = {
    \"id\": str(uuid.uuid4()),
    \"topic\": \"rotation_celebration\",
    \"severity\": \"info\",
    \"message\": \"Rotation confidence jumped above ${THRESHOLD_HIGH}: ${confidence}\",
    \"payload\": d
}
print(json.dumps(event))
")
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$FLEET_EVENT_URL" \
        -H "Content-Type: application/json" \
        -d "$event_payload" \
        --max-time 10 2>/dev/null || echo "000")
    log "POST celebration result: HTTP $http_code"

else
    log "Confidence $confidence — no webhook trigger (thresholds: low=${THRESHOLD_LOW}, high=${THRESHOLD_HIGH})"
fi