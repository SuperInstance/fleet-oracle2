#!/usr/bin/env bash
#
# reflex-daemon.sh — Background reflex event processor
#
# Runs as a long-lived daemon that:
#   - Listens on stdin for JSONL reflex events
#   - Matches events against reflexes.json
#   - Executes matched reflex actions
#   - Logs to /tmp/reflex-daemon.log
#
# Input format (JSONL — one JSON object per line):
#   { "metric": "disk_usage", "value": 87.3, "service": "gc-pid-bridge", "timestamp": "..." }
#   { "type": "health_check", "service": "fleet-oracle", "failures": 3, "timestamp": "..." }
#
# Feeds:
#   - Pipe from construct pulse:    pulse ... | reflex-daemon.sh
#   - Fleet-event webhook:           fleet-event --hook reflex-daemon.sh
#   - Manual curl:                   echo '{"metric":"..."}' | reflex-daemon.sh
#   - Fleet-midi agents:            fleet-midi-* output | reflex-daemon.sh
#
# Options:
#   --reflex-file <path>   Path to reflexes.json (default: construct/reflex/reflexes.json)
#   --log-file <path>      Log file path (default: /tmp/reflex-daemon.log)
#   --poll-interval <ms>   Metric polling interval (default: 1000)
#   --once                 Process stdin and exit (no loop)
#   --verbose              Enable verbose output
#   --dry-run              Print actions without executing
#   --help                 Show help
#
# Signal handling:
#   SIGINT / SIGTERM — graceful shutdown (finish current event, then exit)
#   SIGHUP            — reload reflexes.json
#
# Exit codes:
#   0   Normal exit
#   1   Error (invalid input, file not found)
#   2   Interrupted (SIGINT/SIGTERM received)
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REFLEX_FILE="$(dirname "$SCRIPT_DIR")/reflex/reflexes.json"
DEFAULT_LOG_FILE="/tmp/reflex-daemon.log"
DEFAULT_POLL_INTERVAL_MS=1000

LOG_PREFIX="[reflex-daemon]"
LOG_FILE="${REFLEX_DAEMON_LOG:-$DEFAULT_LOG_FILE}"
REFLEX_FILE="${REFLEX_FILE:-$DEFAULT_REFLEX_FILE}"
POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-$DEFAULT_POLL_INTERVAL_MS}"

# ─── Globals ───────────────────────────────────────────────────────────────────

VERBOSE=false
DRY_RUN=false
ONCE_MODE=false
RUNNING=true
LAST_RELOAD=0

# In-memory reflex cache
declare -A REFLEX_CACHE=()
declare -A REFLEX_METRICS=()  # metric_name → reflex names

# Stats
STATS_FIRED=0
STATS_MISSED=0
STATS_ERRORS=0
STATS_STARTED="$(date +%s)"

# ─── Logging ───────────────────────────────────────────────────────────────────

log() {
  local level="$1"
  shift
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  local msg="$LOG_PREFIX [$level] $ts $*"
  echo "$msg" >> "$LOG_FILE"
  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    echo "$msg" >&2
  elif [[ "$VERBOSE" == "true" ]]; then
    echo "$msg"
  fi
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "$VERBOSE" == "true" ]] && log "DEBUG" "$@" || true; }
log_hit()   { log "HIT" "$@"; }
log_miss()  { log "MISS" "$@"; }

# ─── Reflex Cache Management ───────────────────────────────────────────────────

reload_reflexes() {
  if [[ ! -f "$REFLEX_FILE" ]]; then
    log_error "Reflex file not found: $REFLEX_FILE"
    return 1
  fi

  log_info "Reloading reflexes from: $REFLEX_FILE"

  # Clear existing cache
  REFLEX_CACHE=()
  REFLEX_METRICS=()

  local count
  count=$(jq 'length' "$REFLEX_FILE" 2>/dev/null || echo 0)
  if ((count == 0)); then
    log_warn "No reflexes found in $REFLEX_FILE"
    return 0
  fi

  local idx=0
  while ((idx < count)); do
    local name metric threshold operator window_seconds cooldown_seconds enabled
    name=$(jq -r ".[$idx].name" "$REFLEX_FILE" 2>/dev/null)
    metric=$(jq -r ".[$idx].trigger.metric" "$REFLEX_FILE" 2>/dev/null)
    threshold=$(jq -r ".[$idx].trigger.threshold" "$REFLEX_FILE" 2>/dev/null)
    operator=$(jq -r ".[$idx].trigger.operator // \"gt\"" "$REFLEX_FILE" 2>/dev/null)
    window_seconds=$(jq -r ".[$idx].trigger.window_seconds // 60" "$REFLEX_FILE" 2>/dev/null)
    cooldown_seconds=$(jq -r ".[$idx].trigger.cooldown_seconds // 60" "$REFLEX_FILE" 2>/dev/null)
    enabled=$(jq -r ".[$idx].enabled // true" "$REFLEX_FILE" 2>/dev/null)

    if [[ "$enabled" != "true" ]]; then
      ((idx++))
      continue
    fi

    # Store full reflex JSON
    local reflex_json
    reflex_json=$(jq ".[$idx]" "$REFLEX_FILE")
    REFLEX_CACHE[$name]="$reflex_json"

    # Index by metric for fast lookup
    if [[ -n "${REFLEX_METRICS[$metric]:-}" ]]; then
      REFLEX_METRICS[$metric]="${REFLEX_METRICS[$metric]},$name"
    else
      REFLEX_METRICS[$metric]="$name"
    fi

    ((idx++))
  done

  LAST_RELOAD=$(date +%s)
  log_info "Loaded $((${#REFLEX_CACHE[@]})) reflexes, indexed $((${#REFLEX_METRICS[@]})) metrics"
  return 0
}

# ─── Metric Evaluation ─────────────────────────────────────────────────────────

evaluate_condition() {
  local operator="$1"
  local threshold="$2"
  local value="$3"

  case "$operator" in
    gt)   (( $(echo "$value > $threshold" | bc -l) )) ;;
    gte)  (( $(echo "$value >= $threshold" | bc -l) )) ;;
    lt)   (( $(echo "$value < $threshold" | bc -l) )) ;;
    lte)  (( $(echo "$value <= $threshold" | bc -l) )) ;;
    eq)   [[ "$(echo "$value == $threshold" | bc -l)" == "1" ]] ;;
    ne)   [[ "$(echo "$value != $threshold" | bc -l)" == "1" ]] ;;
    *)
      log_warn "Unknown operator: $operator, defaulting to gt"
      (( $(echo "$value > $threshold" | bc -l) ))
      ;;
  esac
}

# ─── Cooldown Management ───────────────────────────────────────────────────────

declare -A REFLEX_LAST_FIRED=()

check_cooldown() {
  local name="$1"
  local cooldown_seconds="$2"

  local last_fired="${REFLEX_LAST_FIRED[$name]:-0}"
  local now
  now=$(date +%s)
  local elapsed=$((now - last_fired))

  if ((elapsed < cooldown_seconds)); then
    log_debug "Reflex '$name' in cooldown ($elapsed < $cooldown_seconds seconds)"
    return 1
  fi
  return 0
}

mark_fired() {
  local name="$1"
  REFLEX_LAST_FIRED[$name]=$(date +%s)
}

# ─── Action Execution ──────────────────────────────────────────────────────────

execute_action() {
  local reflex_name="$1"
  local event_json="$2"

  local reflex_json="${REFLEX_CACHE[$reflex_name]}"
  if [[ -z "$reflex_json" ]]; then
    log_error "Reflex not found in cache: $reflex_name"
    return 1
  fi

  local endpoint method timeout_ms body_template
  endpoint=$(jq -r '.action.endpoint' <<< "$reflex_json")
  method=$(jq -r '.action.method // "POST"' <<< "$reflex_json")
  timeout_ms=$(jq -r '.action.timeout_ms // 5000' <<< "$reflex_json")
  body_template=$(jq -r '.action.body_template' <<< "$reflex_json")

  # Substitute variables from event
  local metric_value target_service
  metric_value=$(jq -r '.value // .metric_value // empty' <<< "$event_json")
  target_service=$(jq -r '.service // .target_service // empty' <<< "$event_json")

  local body
  body=$(echo "$body_template" | \
    sed "s/{{metric_value}}/$metric_value/g" | \
    sed "s/{{target_service}}/$target_service/g" | \
    sed 's/{{[^}]*}}/""/g' 2>/dev/null || echo "$body_template")

  log_info "Firing reflex '$reflex_name' → $method $endpoint (timeout: ${timeout_ms}ms)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would execute: $method $endpoint with body: $body"
    return 0
  fi

  local response
  local http_code

  # Execute with timeout
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X "$method" \
    "$endpoint" \
    -H "Content-Type: application/json" \
    -H "X-Reflex-Source: $reflex_name" \
    -H "X-Reflex-Event: $(jq -r '.type // "metric"' <<< "$event_json")" \
    -d "$body" \
    --max-time "$((timeout_ms / 1000))" \
    2>/dev/null) || http_code="000"

  if [[ "$http_code" =~ ^[2-3][0-9][0-9]$ ]]; then
    log_hit "Reflex '$reflex_name' fired successfully (HTTP $http_code)"
    ((STATS_FIRED++))
    return 0
  else
    log_warn "Reflex '$reflex_name' action failed (HTTP $http_code)"
    ((STATS_ERRORS++))
    return 1
  fi
}

execute_secondary_actions() {
  local reflex_name="$1"
  local event_json="$2"

  local reflex_json="${REFLEX_CACHE[$reflex_name]}"
  local secondary_count
  secondary_count=$(jq '.secondary_actions | length' <<< "$reflex_json" 2>/dev/null || echo 0)

  if ((secondary_count == 0)); then
    return 0
  fi

  local idx=0
  while ((idx < secondary_count)); do
    local action_type path args
    action_type=$(jq -r ".secondary_actions[$idx].type // \"script\"" <<< "$reflex_json")
    path=$(jq -r ".secondary_actions[$idx].path" <<< "$reflex_json")
    args=$(jq -r ".secondary_actions[$idx].args | join(\" \")" <<< "$reflex_json" 2>/dev/null || echo "")

    if [[ "$action_type" == "script" && -f "$path" ]]; then
      log_debug "Executing secondary action: $path $args"
      if [[ "$DRY_RUN" == "false" ]]; then
        bash "$path" $args &>/dev/null || log_warn "Secondary action failed: $path"
      fi
    fi

    ((idx++))
  done
}

# ─── Event Processing ──────────────────────────────────────────────────────────

process_event() {
  local event_json="$1"

  # Validate JSON
  if ! jq -e '.' <<< "$event_json" &>/dev/null; then
    log_error "Invalid JSON event: ${event_json:0:100}"
    ((STATS_ERRORS++))
    return 1
  fi

  local metric event_type
  metric=$(jq -r '.metric // .type // empty' <<< "$event_json")
  event_type=$(jq -r '.type // "metric"' <<< "$event_json")

  if [[ -z "$metric" ]]; then
    log_error "Event missing metric/type field: ${event_json:0:100}"
    ((STATS_ERRORS++))
    return 1
  fi

  log_debug "Processing event: metric=$metric, type=$event_type"

  # Fast path: look up reflexes indexed by this metric
  local reflex_names="${REFLEX_METRICS[$metric]:-}"
  if [[ -z "$reflex_names" ]]; then
    log_miss "No reflexes for metric: $metric"
    ((STATS_MISSED++))
    return 0
  fi

  local IFS=',' read -ra MATCHED_NAMES <<< "$reflex_names"
  local fired_count=0

  for name in "${MATCHED_NAMES[@]}"; do
    local reflex_json="${REFLEX_CACHE[$name]}"
    [[ -z "$reflex_json" ]] && continue

    local threshold operator window_seconds cooldown_seconds
    threshold=$(jq -r '.trigger.threshold' <<< "$reflex_json")
    operator=$(jq -r '.trigger.operator // "gt"' <<< "$reflex_json")
    window_seconds=$(jq -r '.trigger.window_seconds // 60' <<< "$reflex_json")
    cooldown_seconds=$(jq -r '.trigger.cooldown_seconds // 60' <<< "$reflex_json")

    # Check cooldown
    check_cooldown "$name" "$cooldown_seconds" || continue

    # Get metric value from event
    local value
    value=$(jq -r '.value // .metric_value // empty' <<< "$event_json")

    if [[ -z "$value" ]]; then
      log_debug "Event missing value for metric $metric, skipping condition check"
      continue
    fi

    # Evaluate condition
    if evaluate_condition "$operator" "$threshold" "$value"; then
      log_info "Reflex '$name' triggered: $metric $operator $threshold (value: $value)"

      if execute_action "$name" "$event_json"; then
        mark_fired "$name"
        ((fired_count++))
        execute_secondary_actions "$name" "$event_json"
      fi
    else
      log_debug "Reflex '$name' condition not met: $value $operator $threshold"
    fi
  done

  if ((fired_count == 0)); then
    ((STATS_MISSED++))
  fi

  return 0
}

# ─── Signal Handling ───────────────────────────────────────────────────────────

handle_signal() {
  local sig="$1"
  log_info "Received $sig, initiating graceful shutdown..."
  RUNNING=false
}

setup_signals() {
  trap 'handle_signal SIGINT' SIGINT
  trap 'handle_signal SIGTERM' SIGTERM
  trap 'reload_reflexes; log_info "Reflexes reloaded via SIGHUP"' SIGHUP
}

# ─── Stats Reporting ───────────────────────────────────────────────────────────

report_stats() {
  local uptime=$(( $(date +%s) - STATS_STARTED ))
  log_info "Stats: fired=${STATS_FIRED}, missed=${STATS_MISSED}, errors=${STATS_ERRORS}, uptime=${uptime}s, cached_reflexes=${#REFLEX_CACHE[@]}"
}

# ─── Main Loop ──────────────────────────────────────────────────────────────────

main_loop() {
  log_info "Reflex daemon starting..."
  log_info "Reflex file: $REFLEX_FILE"
  log_info "Log file: $LOG_FILE"
  log_info "Poll interval: ${POLL_INTERVAL_MS}ms"

  reload_reflexes || {
    log_error "Failed to load reflexes, exiting"
    exit 1
  }

  setup_signals

  # Open stdin for reading (batch mode: JSONL lines)
  local line_number=0
  while [[ "$RUNNING" == "true" ]]; do
    if IFS= read -r line; then
      ((line_number++))
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      process_event "$line"
    else
      # EOF reached
      if [[ "$ONCE_MODE" == "true" ]]; then
        log_info "EOF received (--once mode), exiting"
        break
      fi
      log_info "EOF on stdin, waiting for input..."
      break
    fi
  done

  report_stats
  log_info "Reflex daemon stopped (processed $line_number events)"
}

# ─── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
reflex-daemon.sh — Background reflex event processor

USAGE
  reflex-daemon.sh [options]
  pulse ... | reflex-daemon.sh
  echo '{"metric":"disk_usage","value":87}' | reflex-daemon.sh --once

OPTIONS
  --reflex-file <path>   Path to reflexes.json (default: construct/reflex/reflexes.json)
  --log-file <path>      Log file path (default: /tmp/reflex-daemon.log)
  --poll-interval <ms>   Metric polling interval (default: 1000)
  --once                 Process stdin and exit (no loop)
  --verbose              Enable verbose output
  --dry-run              Print actions without executing
  --help                 Show this help

INPUT FORMAT (JSONL)
  { "metric": "disk_usage", "value": 87.3, "service": "gc-pid-bridge" }
  { "type": "health_check", "service": "fleet-oracle", "failures": 3 }
  { "metric": "combined_confidence", "value": 0.25 }

SIGNALS
  SIGINT / SIGTERM   Graceful shutdown
  SIGHUP             Reload reflexes.json

EXIT CODES
  0   Normal exit
  1   Error (invalid input, file not found)
  2   Interrupted (SIGINT/SIGTERM)
EOF
}

# ─── Entry Point ───────────────────────────────────────────────────────────────

main() {
  # Check jq availability
  if ! command -v jq &>/dev/null; then
    echo "[reflex-daemon] ERROR: jq is required but not installed" >&2
    exit 1
  fi

  if ! command -v bc &>/dev/null; then
    echo "[reflex-daemon] ERROR: bc is required but not installed" >&2
    exit 1
  fi

  # Parse arguments
  while (( "$#" )); do
    case "$1" in
      --reflex-file)
        REFLEX_FILE="$2"
        shift 2
        ;;
      --log-file)
        LOG_FILE="$2"
        shift 2
        ;;
      --poll-interval)
        POLL_INTERVAL_MS="$2"
        shift 2
        ;;
      --once)
        ONCE_MODE=true
        shift
        ;;
      --verbose|-v)
        VERBOSE=true
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "[reflex-daemon] ERROR: Unknown flag: $1" >&2
        usage
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"

  main_loop
}

main "$@"
