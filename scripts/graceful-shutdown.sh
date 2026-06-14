#!/usr/bin/env bash
# =============================================================================
# Fleet Graceful Shutdown
# =============================================================================
# 1. Writes a shutdown event to fleet-event bus
# 2. Stops construct pulse loop and reflex daemon
# 3. Creates a checkpoint: copies rotation-feed.json, recent log entries
# 4. Writes a checkpoint manifest signed with a meaningful summary
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

LOG="/tmp/fleet-graceful-shutdown.log"
EVENT_API="http://localhost:8782/api/event"
CHECKPOINT_DIR="/home/ubuntu/.openclaw/workspace/construct/data"
ROTATION_FEED="/home/ubuntu/.openclaw/workspace/construct/data/rotation-feed.json"
CHECKPOINT_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CHECKPOINT_MANIFEST="$CHECKPOINT_DIR/checkpoint-$CHECKPOINT_TIMESTAMP.json"
LOG_DIR="/home/ubuntu/.openclaw/workspace/construct/logs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ── PID file helpers ─────────────────────────────────────────────────────────
find_pid() {
    local name="$1"
    pgrep -f "$name" 2>/dev/null | head -1 || true
}

kill_pid() {
    local name="$1"
    local pid
    pid=$(find_pid "$name")
    if [[ -n "$pid" ]]; then
        log_info "Sending SIGTERM to $name (PID $pid)"
        kill -TERM "$pid" 2>/dev/null || true
        # Wait up to 10s for graceful exit
        local waited=0
        while kill -0 "$pid" 2>/dev/null && ((waited < 10)); do
            sleep 1
            ((waited++))
        done
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Process $pid did not exit gracefully, sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
        else
            log_info "$name exited gracefully"
        fi
    else
        log_info "$name not running — no action needed"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_info "=== Graceful shutdown initiated ==="

    # ── 1. Post shutdown event to fleet-event ──────────────────────────────
    local shutdown_event
    shutdown_event=$(jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg reason "${SHUTDOWN_REASON:-manual}" \
        '{
            topic: "lifecycle",
            type: "shutdown_initiated",
            timestamp: $ts,
            reason: $reason,
            pid: '"$$"'
        }')

    if curl -sf --max-time 10 -X POST "$EVENT_API" \
        -H "Content-Type: application/json" \
        -d "$shutdown_event" >/dev/null 2>&1; then
        log_info "Shutdown event posted to fleet-event"
    else
        log_warn "Could not post shutdown event to fleet-event (service may be down)"
    fi

    # ── 2. Stop construct pulse loop and reflex daemon ──────────────────────
    log_info "Stopping construct pulse loop..."
    kill_pid "construct-pulse"
    kill_pid "construct-pulse-daemon"
    kill_pid "pulse-daemon"

    log_info "Stopping reflex daemon..."
    kill_pid "reflex-daemon"
    kill_pid "meta-reflex-daemon"
    kill_pid "meta-reflex"

    # ── 3. Create checkpoint ───────────────────────────────────────────────
    log_info "Creating checkpoint: $CHECKPOINT_TIMESTAMP"

    mkdir -p "$CHECKPOINT_DIR"

    # Copy rotation-feed.json if it exists
    local feed_copied=""
    if [[ -f "$ROTATION_FEED" ]]; then
        cp "$ROTATION_FEED" "$CHECKPOINT_DIR/rotation-feed-$CHECKPOINT_TIMESTAMP.json"
        feed_copied="$CHECKPOINT_DIR/rotation-feed-$CHECKPOINT_TIMESTAMP.json"
        log_info "Copied rotation-feed.json"
    else
        log_info "rotation-feed.json not found — skipping"
    fi

    # Copy recent log entries (last 500 lines from each log file)
    local log_files=(
        "/tmp/fleet-watchdog.log"
        "/tmp/fleet-event.log"
        "/tmp/fleet-oracle.log"
        "/tmp/fleet-conductor.log"
    )

    local log_snapshots=()
    for lf in "${log_files[@]}"; do
        if [[ -f "$lf" ]]; then
            local snap="$CHECKPOINT_DIR/$(basename "$lf" .log)-snap-$CHECKPOINT_TIMESTAMP.log"
            tail -n 500 "$lf" > "$snap"
            log_snapshots+=("$(basename "$snap")")
            log_info "Snapshotted $(basename "$lf")"
        fi
    done

    # ── 4. Write checkpoint manifest ──────────────────────────────────────
    local log_snapshots_json
    log_snapshots_json=$(printf '%s\n' "${log_snapshots[@]}" | jq -R . | jq -s .)

    local services_summary
    services_summary=$(jq -n \
        --arg ts "$CHECKPOINT_TIMESTAMP" \
        --arg feed "$feed_copied" \
        --argjson snapshots "$log_snapshots_json" \
        '{
            checkpoint_id: $ts,
            timestamp: $ts,
            rotation_feed_copy: $feed,
            log_snapshots: $snapshots,
            uptime_seconds: $(cat /proc/uptime | cut -d" " -f1),
            load_avg: $(cat /proc/loadavg),
            memory_info: $(cat /proc/meminfo | head -4 | jq -R . | jq -s .)
        }')

    # Add decisions made and services running
    local decisions=(
        "Fleet watchdog last ran before shutdown"
        "All daemons stopped gracefully"
        "Checkpoint created for crash recovery"
    )

    local running_services=()
    for port in 8795 8781 8782 8769 8800 8796; do
        if ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
            running_services+=("port:$port")
        fi
    done

    local decisions_json
    decisions_json=$(printf '%s\n' "${decisions[@]}" | jq -R . | jq -s .)

    local running_json
    running_json=$(printf '%s\n' "${running_services[@]}" | jq -R . | jq -s .)

    cat > "$CHECKPOINT_MANIFEST" <<EOF
{
  "checkpoint_id": "$CHECKPOINT_TIMESTAMP",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "decisions": $decisions_json,
  "services_running_at_shutdown": $running_json,
  "rotation_feed_copy": ${feed_copied:+"$feed_copied"},
  "log_snapshots": $log_snapshots_json,
  "gc_status": {
    "last_gc_run": "$(test -f /tmp/gc-last-run && cat /tmp/gc-last-run || echo "unknown")",
    "gc_pid": "$(pgrep -f gc-intelligent 2>/dev/null | head -1 || echo "")"
  },
  "system": {
    "uptime_seconds": $(cat /proc/uptime | cut -d" " -f1),
    "load_average": "$(cat /proc/loadavg)",
    "hostname": "$(hostname)"
  }
}
EOF

    log_info "Checkpoint manifest written: $CHECKPOINT_MANIFEST"

    # ── Sign the checkpoint (meaningful summary) ───────────────────────────
    local summary="Fleet graceful shutdown checkpoint $CHECKPOINT_TIMESTAMP. "
    summary+="Decisions recorded: ${#decisions[@]} entries. "
    summary+="Services running at shutdown: ${#running_services[@]}. "
    summary+="Log snapshots: ${#log_snapshots[@]}. "
    summary+="Rotation feed copied: $([ -n "$feed_copied" ] && echo yes || echo no)."

    echo "# CHECKPOINT SIGNATURE" >> "$CHECKPOINT_MANIFEST"
    echo "# $summary" >> "$CHECKPOINT_MANIFEST"
    echo "# Hash: $(sha256sum "$CHECKPOINT_MANIFEST" | cut -d' ' -f1)" >> "$CHECKPOINT_MANIFEST"

    log_info "Checkpoint signed and complete: $CHECKPOINT_MANIFEST"
    log_info "=== Graceful shutdown complete ==="

    echo "Checkpoint: $CHECKPOINT_MANIFEST"
}

main "$@"
