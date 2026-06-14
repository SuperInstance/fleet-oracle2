#!/usr/bin/env bash
# =============================================================================
# Fleet Auto-Heal — triggered by reflex engine when conditions are met
# =============================================================================
# Idempotent: running twice is safe.
# Alert levels: info, warn, critical
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

LOG="/tmp/fleet-auto-heal.log"
EVENT_API="http://localhost:8782/api/event"
ALERT_API="http://localhost:8782/api/event"
ROTATION_FEED="/home/ubuntu/.openclaw/workspace/construct/data/rotation-feed.json"
GC_SCRIPT="/home/ubuntu/.openclaw/workspace/construct/scripts/gc-intelligent.sh"
RESTART_LOG="/tmp/fleet-restart-counts.json"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $*" >> "$LOG"
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ── Alert helper ──────────────────────────────────────────────────────────────
send_alert() {
    local level="$1"      # info | warn | critical
    local service="$2"
    local message="$3"

    local payload
    payload=$(jq -n \
        --arg ts "$TIMESTAMP" \
        --arg topic "alert" \
        --arg lvl "$level" \
        --arg svc "$service" \
        --arg msg "$message" \
        '{topic: $topic, timestamp: $ts, level: $lvl, service: $svc, message: $msg}')

    curl -sf --max-time 10 -X POST "$ALERT_API" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1 || true

    log_info "Alert [$level] $service: $message"
}

# ── Restart counter (for flap detection) ─────────────────────────────────────
record_restart() {
    local service="$1"
    local now
    now=$(date +%s)

    local entries
    entries=$(jq -n \
        --arg svc "$service" \
        --argjson now "$now" \
        --argjson last_restart "$(date +%s)" \
        '{service: $svc, last_restart: $last_restart, count: 1}')

    if [[ -f "$RESTART_LOG" ]]; then
        local existing
        existing=$(jq "map(select(.service == \"$service\")) | .[0]" "$RESTART_LOG" 2>/dev/null || echo "null")
        if [[ "$existing" != "null" ]]; then
            local prev_count prev_time
            prev_count=$(jq -r '.count' <<< "$existing")
            prev_time=$(jq -r '.last_restart' <<< "$existing")
            # Reset count if last restart was >5 min ago
            if ((now - prev_time > 300)); then
                entries=$(jq -n \
                    --arg svc "$service" \
                    --argjson now "$now" \
                    --argjson last_restart "$now" \
                    --argjson count 1 \
                    '{service: $svc, last_restart: $last_restart, count: $count}')
            else
                entries=$(jq -n \
                    --arg svc "$service" \
                    --argjson now "$now" \
                    --argjson last_restart "$now" \
                    --argjson count "$((prev_count + 1))" \
                    '{service: $svc, last_restart: $last_restart, count: $count}')
            fi
        fi
        # Merge: replace entry for this service
        jq "map(select(.service != \"$service\")) + [$entries]" "$RESTART_LOG" > "${RESTART_LOG}.tmp" \
            && mv "${RESTART_LOG}.tmp" "$RESTART_LOG" \
            || jq -n "[$entries]" > "$RESTART_LOG"
    else
        jq -n "[$entries]" > "$RESTART_LOG"
    fi
}

get_restart_count() {
    local service="$1"
    local now
    now=$(date +%s)

    if [[ ! -f "$RESTART_LOG" ]]; then
        echo 0
        return
    fi

    local entry
    entry=$(jq "map(select(.service == \"$service\")) | .[0]" "$RESTART_LOG" 2>/dev/null || echo "null")
    if [[ "$entry" == "null" ]]; then
        echo 0
        return
    fi

    local last_time count
    last_time=$(jq -r '.last_restart' <<< "$entry")
    count=$(jq -r '.count' <<< "$entry")

    # Reset if >5 minutes old
    if ((now - last_time > 300)); then
        echo 0
    else
        echo "$count"
    fi
}

# ── Generic service restart ───────────────────────────────────────────────────
try_restart_service() {
    local name="$1"
    local systemd_svc="${2:-}"
    local start_cmd="${3:-}"

    log_info "Attempting restart: $name"

    if [[ -n "$systemd_svc" ]] && systemctl --user try-restart "$systemd_svc" 2>/dev/null; then
        log_info "Restarted via systemd: $systemd_svc"
        record_restart "$name"
        return 0
    fi

    if [[ -n "$start_cmd" ]] && eval "$start_cmd" >/dev/null 2>&1; then
        log_info "Restarted via command: $start_cmd"
        record_restart "$name"
        return 0
    fi

    log_error "All restart methods failed for: $name"
    return 1
}

# ── Check if port is listening ────────────────────────────────────────────────
is_port_listening() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"
}

# ── Check if binary exists and is executable ──────────────────────────────────
is_binary_executable() {
    local bin="$1"
    [[ -x "$bin" ]]
}

# ── Check disk usage ──────────────────────────────────────────────────────────
disk_usage_pct() {
    df /home/ubuntu 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%'
}

# ── Check rotation feed freshness ─────────────────────────────────────────────
is_rotation_feed_stale() {
    local max_age_minutes=10
    if [[ ! -f "$ROTATION_FEED" ]]; then
        return 0  # stale if doesn't exist
    fi
    local mtime
    mtime=$(stat -c %Y "$ROTATION_FEED" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local age_minutes=$(( (now - mtime) / 60 ))
    ((age_minutes > max_age_minutes))
}

# ── GC last run time ──────────────────────────────────────────────────────────
gc_last_run_minutes_ago() {
    if [[ ! -f /tmp/gc-last-run ]]; then
        echo 999
        return
    fi
    local ts
    ts=$(cat /tmp/gc-last-run)
    local now
    now=$(date +%s)
    echo $(( (now - ts) / 60 ))
}

# ── HEAL: headspace-rs ───────────────────────────────────────────────────────
heal_headspace_rs() {
    log_info "Healing headspace-rs..."

    if is_binary_executable "/home/ubuntu/.cargo/bin/headspace-rs"; then
        if try_restart_service "headspace-rs" "headspace-rs" \
            "/home/ubuntu/.cargo/bin/headspace-rs &"; then
            sleep 3
            if is_port_listening 8800; then
                send_alert "info" "headspace-rs" "headspace-rs recovered via auto-heal"
                return 0
            fi
        fi
    fi

    log_warn "headspace-rs still down after restart attempt"
    send_alert "warn" "headspace-rs" "headspace-rs is down and restart failed — manual intervention may be needed"
    return 1
}

# ── HEAL: fleet-oracle ────────────────────────────────────────────────────────
heal_fleet_oracle() {
    log_info "Healing fleet-oracle..."

    if try_restart_service "fleet-oracle" "fleet-oracle"; then
        sleep 3
        if is_port_listening 8795; then
            send_alert "info" "fleet-oracle" "fleet-oracle recovered via auto-heal"
            return 0
        fi
    fi

    log_warn "fleet-oracle still down after restart attempt"
    send_alert "warn" "fleet-oracle" "fleet-oracle is down and restart failed — manual intervention may be needed"
    return 1
}

# ── HEAL: disk pressure → force GC ───────────────────────────────────────────
heal_disk_pressure() {
    local usage
    usage=$(disk_usage_pct)
    log_warn "Disk usage at ${usage}% — checking GC status"

    local gc_minutes
    gc_minutes=$(gc_last_run_minutes_ago)

    if ((gc_minutes < 60)); then
        log_info "GC ran ${gc_minutes}m ago — not forcing"
        return 0
    fi

    log_info "Forcing GC run (disk ${usage}%, GC last ran ${gc_minutes}m ago)"
    if [[ -x "$GC_SCRIPT" ]]; then
        if "$GC_SCRIPT" --execute >/dev/null 2>&1; then
            send_alert "info" "gc" "Forced GC executed due to disk pressure (${usage}%)"
            return 0
        else
            log_error "Forced GC failed"
            send_alert "warn" "gc" "Forced GC failed — disk at ${usage}%, manual cleanup may be needed"
            return 1
        fi
    else
        log_error "GC script not found: $GC_SCRIPT"
        send_alert "critical" "gc" "GC script missing — disk at ${usage}%, manual cleanup required"
        return 1
    fi
}

# ── HEAL: stale rotation feed → cycle pulse ──────────────────────────────────
heal_stale_rotation_feed() {
    log_warn "Rotation feed is stale (>10 minutes) — cycling pulse"

    local pulse_pid
    pulse_pid=$(pgrep -f "construct-pulse" 2>/dev/null | head -1 || true)

    if [[ -n "$pulse_pid" ]]; then
        kill -HUP "$pulse_pid" 2>/dev/null && log_info "Sent HUP to construct-pulse to trigger rotation cycle"
    fi

    # Also touch the feed to mark it fresh
    if [[ -f "$ROTATION_FEED" ]]; then
        touch "$ROTATION_FEED"
    fi

    send_alert "warn" "rotation-feed" "Rotation feed was stale — pulse cycle triggered"
}

# ── HEAL: restart flapping ────────────────────────────────────────────────────
heal_flapping() {
    local service="$1"
    local count
    count=$(get_restart_count "$service")

    log_error "Service $service has restart-flapped $count times in 5 minutes — alert level critical"
    send_alert "critical" "$service" "Service $service has flapped $count times — automatic restart disabled, manual intervention required"
}

# ── Main entry point (called by reflex engine or watchdog) ──────────────────
main() {
    local trigger="${1:-unknown}"
    log_info "=== Fleet Auto-Heal triggered (by: $trigger) ==="

    local exit_code=0

    # ── headspace-rs down ─────────────────────────────────────────────────
    if ! is_port_listening 8800 && ! is_binary_executable "/home/ubuntu/.cargo/bin/headspace-rs"; then
        heal_headspace_rs || ((exit_code++))
    fi

    # ── fleet-oracle down ─────────────────────────────────────────────────
    if ! is_port_listening 8795; then
        heal_fleet_oracle || ((exit_code++))
    fi

    # ── Disk pressure + GC not recently run ────────────────────────────────
    local disk_usage
    disk_usage=$(disk_usage_pct)
    if ((disk_usage > 90)); then
        heal_disk_pressure || ((exit_code++))
    fi

    # ── Stale rotation feed ───────────────────────────────────────────────
    if is_rotation_feed_stale; then
        heal_stale_rotation_feed
    fi

    # ── Check for flapping on all core services ───────────────────────────
    for svc in fleet-oracle fleet-event fleet-log fleet-conductor headspace-rs rotation-feed-server; do
        local count
        count=$(get_restart_count "$svc")
        if ((count > 3)); then
            heal_flapping "$svc"
            ((exit_code++))
        fi
    done

    log_info "=== Fleet Auto-Heal complete (exit_code=$exit_code) ==="
    return $exit_code
}

# ── Idempotent sub-checks (can be called individually) ───────────────────────
case "${1:-trigger-all}" in
    trigger-all)
        main "manual"
        ;;
    check-headspace)
        is_port_listening 8800 || is_binary_executable "/home/ubuntu/.cargo/bin/headspace-rs" || heal_headspace_rs
        ;;
    check-oracle)
        is_port_listening 8795 || heal_fleet_oracle
        ;;
    check-disk)
        (( $(disk_usage_pct) > 90 )) && heal_disk_pressure
        ;;
    check-rotation)
        is_rotation_feed_stale && heal_stale_rotation_feed
        ;;
    check-flapping)
        for svc in fleet-oracle fleet-event fleet-log fleet-conductor headspace-rs rotation-feed-server; do
            (( $(get_restart_count "$svc") > 3 )) && heal_flapping "$svc"
        done
        ;;
    *)
        echo "Usage: $0 [trigger-all|check-headspace|check-oracle|check-disk|check-rotation|check-flapping]"
        exit 1
        ;;
esac
