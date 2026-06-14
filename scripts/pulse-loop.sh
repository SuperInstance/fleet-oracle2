#!/usr/bin/env bash
#
# pulse-loop.sh — Daemon that runs pulse.sh in a continuous loop and streams
# rotation events to fleet-event at :8782.
#
set -euo pipefail

LOGFILE="/tmp/construct-pulse-loop.log"
PIDFILE="/run/construct-pulse-loop.pid"
FEEDFILE="/home/ubuntu/.openclaw/workspace/construct/data/rotation-feed.json"
FLEET_EVENT_URL="http://localhost:8782/api/event"
PULSE_SCRIPT="/home/ubuntu/.openclaw/workspace/construct/scripts/pulse.sh"
SLEEP_INTERVAL=60

# ── Logging ──────────────────────────────────────────────────────────────────
log() {
    echo "[$(date -Iseconds)] $*" >> "$LOGFILE"
}

# ── Trap signals for clean shutdown ──────────────────────────────────────────
cleanup() {
    log "Received signal, shutting down cleanly..."
    [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE"
    exit 0
}
trap cleanup INT TERM

# ── Write PID ─────────────────────────────────────────────────────────────────
echo $$ > "$PIDFILE"
log "pulse-loop started with PID $$"

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
    iteration_start=$(date +%s)
    log "=== Iteration start ==="

    # Run pulse.sh in the current shell (source to inherit functions/vars)
    # shellcheck source=/dev/null
    if ! source "$PULSE_SCRIPT" >> "$LOGFILE" 2>&1; then
        log "ERROR: pulse.sh failed with exit code $?"
    fi

    # Collect the latest rotation-feed.json entry (last line = most recent)
    latest_entry=""
    if [[ -f "$FEEDFILE" ]]; then
        latest_entry=$(tail -1 "$FEEDFILE")
    fi

    if [[ -n "$latest_entry" ]]; then
        log "Latest feed entry: $(echo "$latest_entry" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d.get("id","?"), d.get("timestamp","?"), "combined_confidence="+str(d.get("combined_confidence","n/a")))
' 2>/dev/null || echo 'parse error')"

        # POST to fleet-event at :8782
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$FLEET_EVENT_URL" \
            -H "Content-Type: application/json" \
            -d "{\"topic\":\"rotation_feedback\",\"payload\":$latest_entry}" \
            --max-time 10 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            log "fleet-event POST OK (HTTP $http_code)"
        else
            log "fleet-event POST FAILED (HTTP $http_code)"
        fi
    else
        log "No feed entry found, skipping POST"
    fi

    log "=== Iteration complete ==="

    # Sleep in small increments so shutdown is responsive
    elapsed=$(($(date +%s) - iteration_start))
    remaining=$((SLEEP_INTERVAL - elapsed))
    while [[ $remaining -gt 0 ]]; do
        sleep $((remaining < 5 ? remaining : 5))
        remaining=$((SLEEP_INTERVAL - $(($(date +%s) - iteration_start))))
    done
done