#!/usr/bin/env bash
# =============================================================================
# Fleet Watchdog — health check and auto-recovery
# =============================================================================
# Runs every 2 minutes via systemd timer.
# Exits: 0=all healthy, 1=degraded, 2=some down, 3=errors
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Paths ────────────────────────────────────────────────────────────────────
LOG="/tmp/fleet-watchdog.log"
SUMMARY_JSON="/tmp/fleet-watchdog-summary.json"
EVENT_API="http://localhost:8782/api/event"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ── Utility helpers ─────────────────────────────────────────────────────────
is_port_listening() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"
}

is_binary_executable() {
    local bin="$1"
    [[ -x "$bin" ]]
}

systemd_try_restart() {
    local svc="$1"
    systemctl --user try-restart "$svc" 2>/dev/null
}

http_health_check() {
    local url="$1"
    curl -sf --max-time 5 "$url" >/dev/null 2>&1
}

# ── Service definitions ─────────────────────────────────────────────────────
# Each entry: name|port|http_endpoint|binary_path|systemd_service|restart_cmd
# http_endpoint may be empty (skip HTTP check)
# binary_path may be empty (no binary check)
# systemd_service may be empty (no systemd restart)
# restart_cmd may be empty (use systemd or built-in)

declare -A SERVICES

# Core fleet services
SERVICES["fleet-oracle"]="8795|http://localhost:8795/health||fleet-oracle|"
SERVICES["fleet-log"]="8781|http://localhost:8781/health||fleet-log|"
SERVICES["fleet-event"]="8782|http://localhost:8782/health||fleet-event|"
SERVICES["fleet-conductor"]="8769|http://localhost:8769/health||fleet-conductor|"
SERVICES["headspace-rs"]="8800|http://localhost:8800/health|/home/ubuntu/.cargo/bin/headspace-rs|headspace-rs|"
SERVICES["rotation-feed-server"]="8796|http://localhost:8796/health||rotation-feed-server|"

# Midi fleet agents (16 agents on ports 2160-2175)
for i in $(seq 0 15); do
    port=$((2160 + i))
    SERVICES["fleet-midi-$i"]="$port|http://localhost:$port/health||fleet-midi@$i|"
done

# Daemons (construct pulse, reflex, meta-reflex — no HTTP endpoint, use binary check)
SERVICES["construct-pulse"]="0|||/home/ubuntu/.openclaw/workspace/construct/scripts/construct-pulse-daemon.sh|construct-pulse"
SERVICES["reflex-daemon"]="0|||/home/ubuntu/.openclaw/workspace/construct/scripts/reflex-daemon.sh|reflex-daemon"
SERVICES["meta-reflex-daemon"]="0|||/home/ubuntu/.openclaw/workspace/construct/scripts/meta-reflex-daemon.sh|meta-reflex-daemon"

# GC pid bridge (Rust binary)
SERVICES["gc-pid-bridge"]="0|||/home/ubuntu/.cargo/bin/gc-pid-bridge|gc-pid-bridge|"

# ── State tracking ───────────────────────────────────────────────────────────
declare -A SERVICE_STATUS
declare -A SERVICE_ACTION
RESTARTED=()
FAILED_RESTART=()
ERRORS=()

# ── Per-service check ─────────────────────────────────────────────────────────
check_service() {
    local name="$1"
    local spec="${SERVICES[$name]}"
    local port http_endpoint binary systemd_svc restart_cmd

    # Parse spec
    port=$(echo "$spec" | cut -d'|' -f1)
    http_endpoint=$(echo "$spec" | cut -d'|' -f2)
    binary=$(echo "$spec" | cut -d'|' -f3)
    systemd_svc=$(echo "$spec" | cut -d'|' -f4)
    restart_cmd=$(echo "$spec" | cut -d'|' -f5)

    local status="down"
    local action="none"
    local reason=""

    # ── Port check (skip for port 0 — daemons with no fixed port) ──────────
    if [[ "$port" != "0" ]]; then
        if ! is_port_listening "$port"; then
            reason="port $port not listening"
            status="down"
        elif [[ -n "$http_endpoint" ]]; then
            # HTTP health check
            if http_health_check "$http_endpoint"; then
                status="healthy"
            else
                reason="HTTP health check failed: $http_endpoint"
                status="degraded"
            fi
        else
            status="healthy"
        fi
    else
        # Daemon / binary-checked service
        if [[ -n "$binary" ]]; then
            if is_binary_executable "$binary"; then
                status="healthy"
            else
                reason="binary not found or not executable: $binary"
                status="down"
            fi
        else
            status="healthy"
        fi
    fi

    # ── Attempt restart if DOWN ────────────────────────────────────────────
    if [[ "$status" == "down" ]]; then
        log_warn "Service DOWN: $name — $reason"

        local restarted=false

        if [[ -n "$systemd_svc" ]]; then
            log_info "Attempting systemd try-restart: $systemd_svc"
            if systemd_try_restart "$systemd_svc"; then
                log_info "Restarted via systemd: $systemd_svc"
                restarted=true
            else
                log_error "systemd try-restart failed: $systemd_svc"
                ERRORS+=("$name: systemd restart failed")
                action="failed"
            fi
        fi

        if [[ "$restarted" == "false" && -n "$restart_cmd" ]]; then
            log_info "Attempting restart command: $restart_cmd"
            if eval "$restart_cmd" >/dev/null 2>&1; then
                log_info "Restarted via command: $restart_cmd"
                restarted=true
            else
                log_error "restart command failed: $restart_cmd"
                ERRORS+=("$name: restart command failed")
                action="failed"
            fi
        fi

        if [[ "$restarted" == "true" ]]; then
            action="restarted"
            RESTARTED+=("$name")

            # Re-check after restart
            sleep 2
            if [[ "$port" != "0" ]] && is_port_listening "$port"; then
                if [[ -n "$http_endpoint" ]]; then
                    http_health_check "$http_endpoint" && status="healthy" || status="degraded"
                else
                    status="healthy"
                fi
                if [[ "$status" == "healthy" ]]; then
                    action="none"
                    log_info "Service recovered: $name"
                fi
            elif [[ "$port" == "0" && -n "$binary" ]] && is_binary_executable "$binary"; then
                status="healthy"
                action="none"
                log_info "Service recovered: $name"
            fi
        fi
    fi

    SERVICE_STATUS["$name"]="$status"
    SERVICE_ACTION["$name"]="$action"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_info "=== Fleet Watchdog cycle started ==="

    # Count services
    local total=${#SERVICES[@]}
    local healthy=0 degraded=0 down=0

    for svc in "${!SERVICES[@]}"; do
        check_service "$svc"
    done

    for svc in "${!SERVICES[@]}"; do
        case "${SERVICE_STATUS[$svc]}" in
            healthy) ((healthy++)) ;;
            degraded) ((degraded++)) ;;
            down)    ((down++))    ;;
        esac
    done

    # ── Build JSON summary ──────────────────────────────────────────────────
    local restarted_json
    if [[ ${#RESTARTED[@]} -eq 0 ]]; then
        restarted_json="[]"
    else
        restarted_json=$(printf '%s\n' "${RESTARTED[@]}" | jq -R . | jq -s .)
    fi

    local services_json="{"
    local first=true
    for svc in "${!SERVICES[@]}"; do
        local port_spec="${SERVICES[$svc]}"
        local port=$(echo "$port_spec" | cut -d'|' -f1)
        [[ "$port" == "0" ]] && port="null" || port="$port"

        local entry
        entry=$(jq -n \
            --arg name "$svc" \
            --argjson port "$port" \
            --arg status "${SERVICE_STATUS[$svc]}" \
            --arg action "${SERVICE_ACTION[$svc]}" \
            '{port: $port, status: $status, action: $action}')
        
        if [[ "$first" == "true" ]]; then
            first=false
        else
            services_json+=","
        fi
        services_json+="\"$svc\": $entry"
    done
    services_json+="}"

    cat > "$SUMMARY_JSON" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "total_services": $total,
  "healthy": $healthy,
  "degraded": $degraded,
  "down": $down,
  "restarted": $restarted_json,
  "services": $services_json
}
EOF

    log_info "Summary: healthy=$healthy degraded=$degraded down=$down restarted=${#RESTARTED[@]}"

    # ── POST to fleet-event ───────────────────────────────────────────────
    local payload
    payload=$(jq -n \
        --arg ts "$TIMESTAMP" \
        --argjson total "$total" \
        --argjson healthy "$healthy" \
        --argjson degraded "$degraded" \
        --argjson down "$down" \
        --argjson restarted "$(printf '%s\n' "${RESTARTED[@]}" | jq -R . | jq -s .)" \
        '{topic: "watchdog", timestamp: $ts, total_services: $total, healthy: $healthy, degraded: $degraded, down: $down, restarted: $restarted}')

    if curl -sf --max-time 10 -X POST "$EVENT_API" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1; then
        log_info "Posted watchdog event to fleet-event"
    else
        log_warn "Failed to POST watchdog event to fleet-event (service may be down)"
        ERRORS+=("fleet-event POST failed")
    fi

    log_info "=== Fleet Watchdog cycle complete ==="

    # ── Exit code ──────────────────────────────────────────────────────────
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        return 3
    elif [[ "$down" -gt 0 ]]; then
        return 2
    elif [[ "$degraded" -gt 0 ]]; then
        return 1
    fi
    return 0
}

main "$@"
