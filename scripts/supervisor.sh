#!/usr/bin/env bash
# =============================================================================
# supervisor.sh — Process supervisor with exponential backoff restart
# =============================================================================
# Usage:
#   supervisor.sh <service-name> "<command>" [args...]
#   supervisor.sh fleet-oracle "node /path/to/server.js"
#
# Behaviour:
#   - Forks the given command as a child process
#   - Records the child's PID
#   - Monitors the child via /proc
#   - On child death: restarts with exponential backoff (1s, 2s, 4s … 60s max)
#   - On SIGTERM/SIGINT: sends graceful shutdown to child, waits 5s, force-kills
#   - Logs everything to /tmp/<service-name>-supervisor.log
# =============================================================================

set -o pipefail

# ─── Arguments ────────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <service-name> \"<command>\" [args...]" >&2
  echo "Example: $0 fleet-oracle \"node /home/ubuntu/.openclaw/workspace/construct/server.js\"" >&2
  exit 1
fi

SERVICE_NAME="$1"
shift
COMMAND="$*"

if [[ -z "$COMMAND" ]]; then
  echo "ERROR: No command specified." >&2
  exit 1
fi

# ─── Paths ────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_DIR}/${SERVICE_NAME}-supervisor.log"
PID_DIR="${PID_DIR:-/tmp}"
PID_FILE="${PID_DIR}/${SERVICE_NAME}.pid"

# ─── Logging ───────────────────────────────────────────────────────────────────

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "[${ts}] [${SERVICE_NAME}] $*" >> "$LOG_FILE"
}

log_start() {
  log "START — supervisor pid=$$ spawned for command: $COMMAND"
}

# ─── Backoff state ──────────────────────────────────────────────────────────────

BACKOFF_SECS=1
MAX_BACKOFF_SECS=60
GRACEFUL_WAIT_SECS=5

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Write PID file
write_pid() {
  echo "$CHILD_PID" > "$PID_FILE"
}

# Clear PID file
clear_pid() {
  rm -f "$PID_FILE"
}

# Check if a PID is alive
is_alive() {
  local pid=$1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Check if a PID file is valid and process is alive
check_pid() {
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null)
  if [[ -n "$pid" ]]; then
    is_alive "$pid"
    return $?
  fi
  return 1
}

# ─── Signal handling ───────────────────────────────────────────────────────────

# shellcheck disable=SC2154
terminate() {
  log "RECV ${SIGNAL:-SIGTERM} — initiating graceful shutdown"

  if [[ -n "$CHILD_PID" ]] && is_alive "$CHILD_PID"; then
    log "Sending SIGTERM to child PID $CHILD_PID"
    kill -TERM "$CHILD_PID" 2>/dev/null

    # Wait up to GRACEFUL_WAIT_SECS for graceful exit
    local waited=0
    while is_alive "$CHILD_PID" && ((waited < GRACEFUL_WAIT_SECS)); do
      sleep 1
      ((waited++))
    done

    if is_alive "$CHILD_PID"; then
      log "Child PID $CHILD_PID still alive after ${GRACEFUL_WAIT_SECS}s — sending SIGKILL"
      kill -KILL "$CHILD_PID" 2>/dev/null
      sleep 1
    else
      log "Child PID $CHILD_PID exited gracefully"
    fi
  fi

  clear_pid
  log "SUPERVISOR EXIT"
  exit 0
}

# Register signal handlers
trap 'SIGNAL=SIGTERM terminate' SIGTERM
trap 'SIGNAL=SIGINT  terminate' SIGINT

# ─── Child process starter ───────────────────────────────────────────────────

start_child() {
  log "SPAWNING child: $COMMAND"
  # Run in subshell so we can capture the PID reliably
  (
    exec bash -c "$COMMAND"
  ) &
  CHILD_PID=$!
  log "Child started with PID $CHILD_PID"
  write_pid
}

# ─── Main loop ────────────────────────────────────────────────────────────────

log_start

# If a PID file already exists and the process is alive, we're restarting
# a previous instance — clear it first
if check_pid; then
  log "WARNING: stale PID file found for PID $(cat "$PID_FILE"). Clearing."
  clear_pid
fi

while true; do
  start_child

  # Track the child's lifecycle
  while is_alive "$CHILD_PID"; do
    sleep 2
  done

  # Child has died — capture exit code
  wait "$CHILD_PID" 2>/dev/null
  EXIT_CODE=$?
  log "Child PID $CHILD_PID died with exit code ${EXIT_CODE}"

  clear_pid

  # Reset backoff on clean exit (exit code 0)
  if [[ "$EXIT_CODE" -eq 0 ]]; then
    log "Clean exit — resetting backoff"
    BACKOFF_SECS=1
    log "SUPERVISOR EXIT (clean)"
    exit 0
  fi

  # Exponential backoff
  log "RESTART in ${BACKOFF_SECS}s (backoff level: ${BACKOFF_SECS}s, max: ${MAX_BACKOFF_SECS}s)"
  sleep "$BACKOFF_SECS"

  # Double backoff, cap at max
  BACKOFF_SECS=$((BACKOFF_SECS * 2))
  if ((BACKOFF_SECS > MAX_BACKOFF_SECS)); then
    BACKOFF_SECS=$MAX_BACKOFF_SECS
  fi
done
