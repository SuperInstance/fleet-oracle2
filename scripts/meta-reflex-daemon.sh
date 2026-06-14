#!/usr/bin/env bash
#
# meta-reflex-daemon.sh — The Keel: watches the watcher
#
# Monitors reflex and pulse loop logs, tracks which reflexes fire,
# and generates periodic meta-reports suggesting new reflex patterns.
#
# Usage:
#   meta-reflex-daemon.sh [--daemon] [--once] [--iterations N]
#   meta-reflex-daemon.sh --help
#
# Log output: /tmp/meta-reflex-daemon.log
# State file:  /tmp/meta-reflex-daemon.state.json
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

META_LOG="/tmp/meta-reflex-daemon.log"
REFLEX_LOG="${REFLEX_LOG:-/tmp/reflex-daemon.log}"
PULSE_LOG="${PULSE_LOG:-/tmp/construct-pulse-loop.log}"
STATE_FILE="/tmp/meta-reflex-daemon.state.json"
REPORT_INTERVAL="${REPORT_INTERVAL:-100}"   # iterations between reports
POLL_INTERVAL="${POLL_INTERVAL:-2}"         # seconds between log polls

# Fleet service endpoints for health check
declare -A FLEET_PORTS=(
  [oracle]=8795
  [log]=8781
  [event]=8782
  [conductor]=8769
  [headspace]=8800
  [gc-pid]=8080
)

# ─── State ────────────────────────────────────────────────────────────────────

# In-memory state (serialized to STATE_FILE on each report)
ITERATION=0
# Associative arrays for state tracking
# Using lowercase names to avoid conflicts with shell builtins
declare -A reflex_hits reflex_confidence reflex_triggers metric_samples correlation_buckets

# Initialize to avoid unbound variable errors with set -euo pipefail
reflex_hits=()
reflex_confidence=()
reflex_triggers=()
metric_samples=()
correlation_buckets=()

# Track correlation buckets: "disk>85+conf<0.3" → count
declare -A correlation_buckets

# ─── Logging ─────────────────────────────────────────────────────────────────

log_msg() {
  local level="${1:-INFO}"
  local msg="${2:-}"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S.%3N')
  echo "[$ts] [$level] $msg" >> "$META_LOG"
}

log_info()  { log_msg "INFO"  "$*"; }
log_warn()  { log_msg "WARN"  "$*"; }
log_error() { log_msg "ERROR" "$*"; }
log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    log_msg "DEBUG" "$*"
  fi
}

# ─── Utilities ────────────────────────────────────────────────────────────────

ts_to_epoch() {
  # Accepts ISO8601 or compact format, outputs epoch seconds
  local ts="$1"
  # Try ISO8601 first
  if date --version &>/dev/null 2>&1; then
    date -d "$ts" '+%s' 2>/dev/null && return
  fi
  # Fallback: strip TZ and parse
  date -d "${ts}Z" '+%s' 2>/dev/null || echo "0"
}

now_epoch() {
  date '+%s'
}

jq_available() {
  command -v jq &>/dev/null
}

# ─── Log Parsing ──────────────────────────────────────────────────────────────

# Parse a line from reflex-daemon.log
# Expected format: [TIMESTAMP] [LEVEL] reflex=FIRED name=disk-crisis confidence=0.95 metric=disk_usage value=87.3
parse_reflex_log() {
  local line="$1"
  local name confidence metric value ts

  # Extract fields using grep + sed (portable)
  ts=$(echo "$line" | grep -oP '^\[\K[^\]]+' | head -1 || echo "")
  name=$(echo "$line" | grep -oP 'name=\K[^ ]+' | head -1 || echo "")
  confidence=$(echo "$line" | grep -oP 'confidence=\K[^ ]+' | head -1 || echo "")
  metric=$(echo "$line" | grep -oP 'metric=\K[^ ]+' | head -1 || echo "")
  value=$(echo "$line" | grep -oP 'value=\K[^ ]+' | head -1 || echo "")

  if [[ -z "$name" ]]; then
    return 1
  fi

  echo "$ts|$name|$confidence|$metric|$value"
}

# Parse a line from construct-pulse-loop.log
# Expected format: [TIMESTAMP] pulse iteration=N confidence=X.Y disk_pct=N ...
parse_pulse_log() {
  local line="$1"
  local ts iteration confidence disk_pct load_avg ram_free

  ts=$(echo "$line" | grep -oP '^\[\K[^\]]+' | head -1 || echo "")
  iteration=$(echo "$line" | grep -oP 'iteration=\K[^ ]+' | head -1 || echo "")
  confidence=$(echo "$line" | grep -oP 'confidence=\K[^ ]+' | head -1 || echo "")
  disk_pct=$(echo "$line" | grep -oP 'disk_pct=\K[^ ]+' | head -1 || echo "")
  load_avg=$(echo "$line" | grep -oP 'load=\K[^ ]+' | head -1 || echo "")
  ram_free=$(echo "$line" | grep -oP 'ram_free=\K[^ ]+' | head -1 || echo "")

  echo "$ts|$iteration|$confidence|$disk_pct|$load_avg|$ram_free"
}

# ─── State Tracking ──────────────────────────────────────────────────────────

record_reflex_fire() {
  local name="$1"
  local confidence="${2:-}"
  local metric="$3"
  local value="$4"

  # Increment hit count
  local current="${reflex_hits[$name]:-0}"
  reflex_hits[$name]=$((current + 1))

  # Update confidence if provided
  if [[ -n "$confidence" ]]; then
    reflex_confidence[$name]="$confidence"
  fi

  # Update trigger metric
  if [[ -n "$metric" && -n "$value" ]]; then
    reflex_triggers[$name]="$value"
    metric_samples[$metric]="$value"
  fi

  log_debug "Reflex fired: $name (hits=${reflex_hits[$name]}) metric=$metric value=$value"
}

record_correlation() {
  local key="$1"
  local current="${correlation_buckets[$key]:-0}"
  correlation_buckets[$key]=$((current + 1))
}

build_correlation_key() {
  local disk_pct="${1:-}"
  local load_avg="${2:-}"
  local confidence="${3:-}"

  local key=""
  if [[ -n "$disk_pct" && "$disk_pct" -gt 85 ]]; then
    key="${key}disk>85+"
  fi
  if [[ -n "$load_avg" && $(echo "$load_avg > 4.0" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
    key="${key}load>4+"
  fi
  if [[ -n "$confidence" && $(echo "$confidence < 0.3" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
    key="${key}conf<0.3+"
  fi

  echo "${key%+}"
}

# ─── Report Generation ───────────────────────────────────────────────────────

generate_reflex_report() {
  local report_file="/tmp/meta-reflex-report-$(date '+%Y%m%dT%H%M%S').json"

  # Sort reflexes by hit count
  local top_reflexes_json="[]"
  if jq_available; then
    local reflex_array="[]"
    for name in "${!reflex_hits[@]}"; do
      reflex_array=$(jq \
        --arg name "$name" \
        --argjson hits "${reflex_hits[$name]}" \
        --arg confidence "${reflex_confidence[$name]:-null}" \
        --arg last_trigger "${reflex_triggers[$name]:-null}" \
        '. += [{name: $name, hits: $hits, confidence: ($confidence | if . == "null" then null else . end), last_trigger: ($last_trigger | if . == "null" then null else . end)}]' \
        <<< "$reflex_array" 2>/dev/null || echo "[]")
    done
    top_reflexes_json=$(echo "$reflex_array" | jq 'sort_by(-.hits)' 2>/dev/null || echo "[]")
  else
    # Fallback without jq: just list them
    for name in "${!reflex_hits[@]}"; do
      top_reflexes_json="${top_reflexes_json}\n  {\"name\":\"$name\",\"hits\":\"${reflex_hits[$name]}\"}"
    done
  fi

  # System metrics snapshot
  local disk_pct load_avg ram_free_mb uptime_days
  disk_pct=$(df / | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
  load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
  ram_free_mb=$(free -m 2>/dev/null | awk 'NR==2 {print $7}' || echo "0")
  uptime_days=$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null || echo "0")

  # Correlation analysis — find hot buckets
  local correlations_json="[]"
  if jq_available; then
    local corr_array="[]"
    for key in "${!correlation_buckets[@]}"; do
      corr_array=$(jq \
        --arg pattern "$key" \
        --argjson count "${correlation_buckets[$key]}" \
        '. += [{pattern: $pattern, count: $count}]' \
        <<< "$corr_array" 2>/dev/null || echo "[]")
    done
    correlations_json=$(echo "$corr_array" | jq 'sort_by(-.count)' 2>/dev/null || echo "[]")
  fi

  # Generate reflex suggestions based on correlation patterns
  local suggestions_json="[]"
  if jq_available; then
    suggestions_json=$(jq -n \
      --argjson disk_high_reflexes "${correlation_buckets[disk>85+conf<0.3]:-0}" \
      --argjson load_high_reflexes "${correlation_buckets[load>4+conf<0.3]:-0}" \
      --argjson oscillation_reflexes "${correlation_buckets[load>4+]:-0}" \
      '[
        if ($disk_high_reflexes > 3) then
          {suggestion: "load-crisis", trigger: "load_avg > 4.0 AND disk_usage > 85", confidence: 0.85, reason: "High disk + low confidence frequently co-occur"}
        else empty end,
        if ($load_high_reflexes > 5) then
          {suggestion: "ram-pressure", trigger: "ram_free_mb < 1024 AND load_avg > 3.0", confidence: 0.80, reason: "High load often precedes memory pressure"}
        else empty end,
        if ($oscillation_reflexes > 3) then
          {suggestion: "gc-oscillation-dampen", trigger: "pid_output_stddev > 0.3 AND load_avg > 2.0", confidence: 0.82, reason: "PID oscillation correlates with high load"}
        else empty end
      ]' 2>/dev/null || echo "[]")
  fi

  # Build the report
  local report_json
  report_json=$(jq -n \
    --arg timestamp "$(date -Iseconds)" \
    --argjson iteration "$ITERATION" \
    --argjson total_reflexes "${#reflex_hits[@]}" \
    --arg total_correlations "$(printf '%s\n' "${!correlation_buckets[@]}" | wc -l)" \
    --argjson disk_pct "$disk_pct" \
    --arg load_avg "$load_avg" \
    --argjson ram_free_mb "$ram_free_mb" \
    --argjson uptime_days "$uptime_days" \
    --argjson top_reflexes "$top_reflexes_json" \
    --argjson correlations "$correlations_json" \
    --argjson suggestions "$suggestions_json" \
    '{
      meta_version: "1.0",
      timestamp: $timestamp,
      iteration: $iteration,
      system: {
        disk_free_pct: (100 - $disk_pct),
        disk_usage_pct: $disk_pct,
        load_avg: ($load_avg | tonumber),
        ram_free_mb: $ram_free_mb,
        uptime_days: $uptime_days
      },
      reflex_stats: {
        total_reflexes: $total_reflexes,
        total_correlation_patterns: ($total_correlations | tonumber),
        top_reflexes: $top_reflexes,
        correlations: $correlations
      },
      suggestions: $suggestions
    }' 2>/dev/null || cat <<EOF
{
  "meta_version": "1.0",
  "timestamp": "$(date -Iseconds)",
  "iteration": $ITERATION,
  "system": {
    "disk_free_pct": $((100 - disk_pct)),
    "disk_usage_pct": $disk_pct,
    "load_avg": "$load_avg",
    "ram_free_mb": $ram_free_mb,
    "uptime_days": $uptime_days
  },
  "reflex_stats": {
    "total_reflexes": ${#reflex_hits[@]},
    "total_correlation_patterns": $(printf '%s\n' "${!correlation_buckets[@]}" | wc -l),
    "top_reflexes": $top_reflexes_json,
    "correlations": $correlations_json
  },
  "suggestions": $suggestions_json
}
EOF
  )

  echo "$report_json" > "$report_file"
  log_info "=== REFLEX REPORT (iter $ITERATION) ==="
  log_info "Active reflexes: ${#reflex_hits[@]}"
  log_info "Top reflex: $(echo "$report_json" | jq -r '.reflex_stats.top_reflexes[0].name // "none"' 2>/dev/null || echo "n/a")"
  log_info "Correlation patterns: $(printf '%s\n' "${!correlation_buckets[@]}" | wc -l)"
  log_info "Suggestions: $(echo "$report_json" | jq '.suggestions | length' 2>/dev/null || echo "0")"
  log_info "Report written to: $report_file"

  # Also print to meta log
  echo "$report_json" >> "$META_LOG"

  # Reset correlation buckets after report
  declare -A correlation_buckets

  return 0
}

# ─── Log Tailer ───────────────────────────────────────────────────────────────

# Track last-read position for each log file
declare -A LOG_POSITIONS

tail_log_since() {
  local logfile="$1"
  local pos="${LOG_POSITIONS[$logfile]:-0}"

  if [[ ! -f "$logfile" ]]; then
    return 1
  fi

  local file_size
  file_size=$(stat -c '%s' "$logfile" 2>/dev/null || stat -f '%z' "$logfile" 2>/dev/null || echo 0)

  # If file was rotated (size < pos), reset to beginning
  if ((pos > file_size)); then
    pos=0
  fi

  # Read new lines only
  if ((pos < file_size)); then
    tail -c "+$pos" "$logfile" 2>/dev/null | head -c "$((file_size - pos))"
    LOG_POSITIONS[$logfile]="$file_size"
  fi
}

# ─── Main Processing Loop ─────────────────────────────────────────────────────

process_logs() {
  local new_lines

  # Process reflex-daemon.log
  if [[ -f "$REFLEX_LOG" ]]; then
    new_lines=$(tail_log_since "$REFLEX_LOG")
    if [[ -n "$new_lines" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_reflex_log "$line" | while IFS='|' read -r ts name confidence metric value; do
          if [[ -n "$name" ]]; then
            record_reflex_fire "$name" "$confidence" "$metric" "$value"
          fi
        done
      done <<< "$new_lines"
    fi
  fi

  # Process construct-pulse-loop.log for correlation context
  if [[ -f "$PULSE_LOG" ]]; then
    new_lines=$(tail_log_since "$PULSE_LOG")
    if [[ -n "$new_lines" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_pulse_log "$line" | while IFS='|' read -r ts iteration confidence disk_pct load_avg ram_free; do
          if [[ -n "$disk_pct" ]]; then
            metric_samples[disk_pct]="$disk_pct"
          fi
          if [[ -n "$load_avg" ]]; then
            metric_samples[load_avg]="$load_avg"
          fi
          if [[ -n "$confidence" ]]; then
            metric_samples[confidence]="$confidence"
          fi
          # Build correlation key from pulse metrics
          local corr_key
          corr_key=$(build_correlation_key "${metric_samples[disk_pct]:-}" "${metric_samples[load_avg]:-}" "${metric_samples[confidence]:-}")
          if [[ -n "$corr_key" ]]; then
            record_correlation "$corr_key"
          fi
        done
      done <<< "$new_lines"
    fi
  fi
}

# ─── Daemon Mode ──────────────────────────────────────────────────────────────

daemon_loop() {
  log_info "Meta-reflex daemon starting (pid=$$)"
  log_info "Monitoring: $REFLEX_LOG, $PULSE_LOG"
  log_info "Report interval: every $REPORT_INTERVAL iterations"
  log_info "Poll interval: ${POLL_INTERVAL}s"

  # Initialize log positions
  for logfile in "$REFLEX_LOG" "$PULSE_LOG"; do
    if [[ -f "$logfile" ]]; then
      LOG_POSITIONS[$logfile]=$(stat -c '%s' "$logfile" 2>/dev/null || stat -f '%z' "$logfile" 2>/dev/null || echo 0)
    fi
  done

  while true; do
    process_logs

    ITERATION=$((ITERATION + 1))

    # Generate report every REPORT_INTERVAL iterations
    if ((ITERATION % REPORT_INTERVAL == 0)); then
      generate_reflex_report
    fi

    sleep "$POLL_INTERVAL"
  done
}

# ─── One-Shot Mode ─────────────────────────────────────────────────────────────

run_once() {
  log_info "Meta-reflex one-shot run"

  # Initialize log positions to end of files (only process new entries)
  for logfile in "$REFLEX_LOG" "$PULSE_LOG"; do
    if [[ -f "$logfile" ]]; then
      LOG_POSITIONS[$logfile]=$(stat -c '%s' "$logfile" 2>/dev/null || stat -f '%z' "$logfile" 2>/dev/null || echo 0)
    fi
  done

  process_logs
  ITERATION=1

  if ((${#reflex_hits[@]} > 0)); then
    generate_reflex_report
  else
    log_info "No reflex events found in this run"
  fi
}

# ─── Signal Handling ───────────────────────────────────────────────────────────

shutdown() {
  log_info "Meta-reflex daemon shutting down (iter=$ITERATION)"
  if [[ -n "${reflex_hits[*]:-}" ]]; then
    generate_reflex_report
  fi
  log_info "Shutdown complete"
  exit 0
}

trap shutdown INT TERM

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
meta-reflex-daemon.sh — The Keel: watching the watcher

Monitors reflex and pulse loop logs, tracks which reflexes fire,
and generates periodic meta-reports suggesting new reflex patterns.

USAGE
  meta-reflex-daemon.sh [--daemon|--once] [--iterations N]
  meta-reflex-daemon.sh --help

MODES
  --daemon   Run continuously as a daemon (default)
  --once     Process current log state once and exit

OPTIONS
  --iterations N   Override report interval (default: 100)
  DEBUG=1          Enable debug output

ENVIRONMENT
  REFLEX_LOG       Path to reflex-daemon.log (default: /tmp/reflex-daemon.log)
  PULSE_LOG         Path to construct-pulse-loop.log (default: /tmp/construct-pulse-loop.log)
  REPORT_INTERVAL  Iterations between reports (default: 100)
  POLL_INTERVAL    Seconds between log polls (default: 2)

OUTPUT
  /tmp/meta-reflex-daemon.log          Main meta log
  /tmp/meta-reflex-report-YYYYMMDDTHHMMSS.json   Periodic reports

EXIT
  0   Clean shutdown
  1   Error
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  local mode="daemon"

  while (( "$#" )); do
    case "$1" in
      --daemon)  mode="daemon"; shift ;;
      --once)    mode="once";   shift ;;
      --iterations)
        REPORT_INTERVAL="$2"; shift 2 ;;
      --help|-h)
        usage; exit 0 ;;
      --)
        shift; break ;;
      -*)
        echo "Unknown flag: $1" >&2; usage; exit 1 ;;
      *) break ;;
    esac
  done

  # Ensure log directory
  mkdir -p "$(dirname "$META_LOG")"

  case "$mode" in
    daemon) daemon_loop ;;
    once)   run_once ;;
  esac
}

main "$@"
