#!/usr/bin/env bash
# =============================================================================
# start-fleet.sh — Fleet startup orchestration script
# =============================================================================
# Starts all fleet services in dependency order using supervisor.sh.
# Detects already-running services and skips them.
# Logs to /tmp/fleet-startup.log
#
# Services started in order:
#   1. gc-pid-bridge
#   2. headspace-rs
#   3. fleet-log
#   4. fleet-event
#   5. fleet-oracle
#   6. fleet-conductor
#   7. rotation-feed-server
#   8. pulse-loop
#   9. reflex-daemon
#  10. meta-reflex-daemon
#
# IMPORTANT: Does NOT start or enable systemd services.
#            Use 'systemctl enable --now <service>' for permanent installation.
# =============================================================================

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────────

CONSTRUCT_DIR="/home/ubuntu/.openclaw/workspace/construct"
SYSTEMD_DIR="${CONSTRUCT_DIR}/systemd"
SCRIPTS_DIR="${CONSTRUCT_DIR}/scripts"
LOG_FILE="${LOG_FILE:-/tmp/fleet-startup.log}"
SUPERVISOR="${SCRIPTS_DIR}/supervisor.sh"

# PID file directory (created on demand)
PID_DIR="${PID_DIR:-/tmp}"
mkdir -p "$PID_DIR"

# ─── Logging ────────────────────────────────────────────────────────────────────

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "[${ts}] $*" >> "$LOG_FILE"
}

log_section() {
  log ""
  log "══════════════════════════════════════════════════════════"
  log "  $*"
  log "══════════════════════════════════════════════════════════"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Check if a port is already listening (returns 0 if open, 1 if not)
port_open() {
  local port=$1
  ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0 || return 1
}

# Check if a PID file exists and the process is alive
pid_alive() {
  local name=$1
  local pidfile="${PID_DIR}/${name}.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  return 1
}

# Check if a systemd service is active
systemd_active() {
  local svc=$1
  systemctl is-active "$svc" >/dev/null 2>&1
}

# Check if a binary exists
binary_exists() {
  [[ -x "$1" ]]
}

# Report a service start result
report() {
  local action=$1
  local name=$2
  local detail="${3:-}"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  if [[ "$action" == "START" ]]; then
    printf "[%s] ✅ START   %-25s %s\n" "$ts" "$name" "${detail}"
    log "START $name ${detail}"
  elif [[ "$action" == "SKIP" ]]; then
    printf "[%s] ⏭  SKIP   %-25s %s\n" "$ts" "$name" "${detail}"
    log "SKIP $name ${detail}"
  elif [[ "$action" == "FAIL" ]]; then
    printf "[%s] ❌ FAIL   %-25s %s\n" "$ts" "$name" "${detail}"
    log "FAIL $name ${detail}"
  fi
}

# ─── Service definitions ─────────────────────────────────────────────────────
# Each entry: name | port | binary/script | systemd-service | depends-on
#
# We track running state by:
#   - systemd services: check systemctl is-active
#   - supervised processes: check PID file in /run/<name>.pid
#   - raw binaries: check if binary is alive via /proc or port

declare -A SERVICES

# SERVICE:NAME,PORT,BINARY,SYSTEMD,DEPS,COMMAND_TEMPLATE
# PORT=0 means no TCP port check needed

# gc-pid-bridge
SERVICES["gc-pid-bridge"]="0|0|${CONSTRUCT_DIR}/gc-pid-bridge/target/release/gc-pid-bridge|none|gc-pid-bridge|/home/ubuntu/.openclaw/workspace/gc-pid-bridge/target/release/gc-pid-bridge"

# headspace-rs
SERVICES["headspace-rs"]="8800|0|${CONSTRUCT_DIR}/headspace-rs/target/release/headspace-rs|none|headspace-rs|/home/ubuntu/.openclaw/workspace/headspace-rs/target/release/headspace-rs --port 8800"

# fleet-log
SERVICES["fleet-log"]="8781|/usr/local/bin/fleet-log|fleet-log.service|gc-pid-bridge,headspace-rs|/usr/local/bin/fleet-log"

# fleet-event
SERVICES["fleet-event"]="8782|/usr/local/bin/fleet-event|fleet-event.service|gc-pid-bridge,headspace-rs,fleet-log|/usr/local/bin/fleet-event"

# fleet-oracle
SERVICES["fleet-oracle"]="8795|/usr/local/bin/fleet-oracle|fleet-oracle.service|gc-pid-bridge,headspace-rs,fleet-log,fleet-event|/usr/local/bin/fleet-oracle"

# fleet-conductor
SERVICES["fleet-conductor"]="8769|/home/linuxbrew/.linuxbrew/bin/node /home/ubuntu/.openclaw/workspace/fleet-conductor/src/server.js|fleet-conductor.service|gc-pid-bridge,headspace-rs,fleet-log,fleet-event,fleet-oracle|/home/linuxbrew/.linuxbrew/bin/node /home/ubuntu/.openclaw/workspace/fleet-conductor/src/server.js"

# rotation-feed-server
SERVICES["rotation-feed-server"]="8796|/usr/bin/python3 ${SCRIPTS_DIR}/rotation-feed-server.py|none|gc-pid-bridge,headspace-rs,fleet-log,fleet-event,fleet-oracle|/usr/bin/python3 ${SCRIPTS_DIR}/rotation-feed-server.py"

# pulse-loop (bash script, Type=forking via supervisor)
SERVICES["pulse-loop"]="0|0|${SCRIPTS_DIR}/pulse-loop.sh|construct-pulse-loop.service|gc-pid-bridge,headspace-rs,fleet-log,fleet-event,fleet-oracle|/bin/bash ${SCRIPTS_DIR}/pulse-loop.sh"

# reflex-daemon
SERVICES["reflex-daemon"]="0|0|${SCRIPTS_DIR}/reflex-daemon.sh|reflex-daemon.service|gc-pid-bridge,headspace-rs,fleet-log,fleet-event,fleet-oracle|/bin/bash ${SCRIPTS_DIR}/reflex-daemon.sh"

# meta-reflex-daemon
SERVICES["meta-reflex-daemon"]="0|0|${SCRIPTS_DIR}/meta-reflex-daemon.sh|meta-reflex-daemon.service|reflex-daemon|/bin/bash ${SCRIPTS_DIR}/meta-reflex-daemon.sh"

# ─── Health check helpers ─────────────────────────────────────────────────────

check_service_healthy() {
  local name=$1
  local port=$2
  local binary=$3
  local systemd_svc=$4

  # If systemd service is active, it's healthy
  if [[ "$systemd_svc" != "none" ]] && systemd_active "$systemd_svc"; then
    return 0
  fi

  # If supervised PID is alive, it's healthy
  if pid_alive "$name"; then
    return 0
  fi

  # If binary is running (checked via PID from ss or ps), it's healthy
  if [[ "$port" != "0" ]] && port_open "$port"; then
    return 0
  fi

  return 1
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           FLEET STARTUP ORCHESTRATION                     ║"
  echo "║  Log: ${LOG_FILE}"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""

  log_section "FLEET STARTUP BEGIN"

  local started_count=0
  local skipped_count=0
  local failed_count=0

  # Service order (dependency order)
  local order=(
    "gc-pid-bridge"
    "headspace-rs"
    "fleet-log"
    "fleet-event"
    "fleet-oracle"
    "fleet-conductor"
    "rotation-feed-server"
    "pulse-loop"
    "reflex-daemon"
    "meta-reflex-daemon"
  )

  for name in "${order[@]}"; do
    # Parse service definition
    IFS='|' read -r port binary systemd_svc deps cmd <<< "${SERVICES[$name]}"

    log "Processing service: $name (port=$port, binary=$binary, systemd=$systemd_svc)"

    # Check if already healthy
    if check_service_healthy "$name" "$port" "$binary" "$systemd_svc"; then
      report "SKIP" "$name" "already running"
      ((skipped_count++))
      continue
    fi

    # Check dependencies
    local depsatisfied=true
    for dep in $(echo "$deps" | tr ',' ' '); do
      if [[ -n "$dep" ]] && ! check_service_healthy "$dep" "" "" ""; then
        # Dependency not running — skip this service
        report "SKIP" "$name" "dependency not met: $dep"
        ((skipped_count++))
        depsatisfied=false
        break
      fi
    done

    if [[ "$depsatisfied" != "true" ]]; then
      continue
    fi

    # Use supervisor.sh for managed startup
    if [[ -x "$SUPERVISOR" ]]; then
      log "Starting $name via supervisor.sh: $cmd"
      "$SUPERVISOR" "$name" "$cmd" &
      sleep 1

      # Brief wait for startup
      sleep 2

      if check_service_healthy "$name" "$port" "$binary" "$systemd_svc"; then
        report "START" "$name" "supervisor pid=$(cat "${PID_DIR}/${name}.pid" 2>/dev/null || echo 'unknown')"
        ((started_count++))
      else
        report "FAIL" "$name" "did not come up within timeout"
        ((failed_count++))
      fi
    else
      # supervisor.sh not available — try direct start
      log "WARNING: supervisor.sh not found, using direct start for $name"
      if [[ "$binary" == *"python"* ]] || [[ "$binary" == *"bash"* ]]; then
        nohup bash -c "$cmd" >/dev/null 2>&1 &
      else
        nohup "$cmd" >/dev/null 2>&1 &
      fi
      sleep 3
      if check_service_healthy "$name" "$port" "$binary" "$systemd_svc"; then
        report "START" "$name" "direct start"
        ((started_count++))
      else
        report "FAIL" "$name" "direct start failed"
        ((failed_count++))
      fi
    fi
  done

  log_section "FLEET STARTUP COMPLETE"
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  RESULTS:                                               ║"
  echo "║    ✅ Started : $started_count"
  echo "║    ⏭  Skipped: $skipped_count"
  echo "║    ❌ Failed : $failed_count"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "Full log: $LOG_FILE"

  log "STARTED=$started_count SKIPPED=$skipped_count FAILED=$failed_count"

  if ((failed_count > 0)); then
    exit 1
  fi
  exit 0
}

main "$@"
