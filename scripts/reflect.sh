#!/usr/bin/env bash
#
# reflect.sh — The Vane: analyze patterns, detect drift
#
# Cron-friendly script that reads fleet data, computes metrics,
# and generates a fleet pulse report.
#
# Usage:
#   reflect.sh [--dry-run] [--output-file <path>]
#   reflect.sh --help
#
# Output:
#   Fleet pulse JSON → POST to fleet-event at :8782/api/event
#                     + append to pulse-history.jsonl
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${CONSTRUCT_DIR}/data"
ROTATION_FEED="${DATA_DIR}/rotation-feed.json"
GC_LEDGER="${DATA_DIR}/gc-ledger/ledger.jsonl"
PULSE_HISTORY="${DATA_DIR}/pulse-history.jsonl"

FLEET_EVENT_HOST="${FLEET_EVENT_HOST:-localhost}"
FLEET_EVENT_PORT="${FLEET_EVENT_PORT:-8782}"
FLEET_EVENT_URL="http://${FLEET_EVENT_HOST}:${FLEET_EVENT_PORT}/api/event"

HEADSPACE_HOST="${HEADSPACE_HOST:-localhost}"
HEADSPACE_PORT="${HEADSPACE_PORT:-8800}"
HEADSPACE_URL="http://${HEADSPACE_HOST}:${HEADSPACE_PORT}/health"

LOG_PREFIX="[reflect]"
DRY_RUN="${DRY_RUN:-0}"
OUTPUT_FILE=""

# ─── Logging ───────────────────────────────────────────────────────────────────

log_info()  { echo "$LOG_PREFIX $(date '+%Y-%m-%dT%H:%M:%S') INFO:  $*" >&2; }
log_warn()  { echo "$LOG_PREFIX $(date '+%Y-%m-%dT%H:%M:%S') WARN:  $*" >&2; }
log_error() { echo "$LOG_PREFIX $(date '+%Y-%m-%dT%H:%M:%S') ERROR: $*" >&2; }

# ─── Dependency Check ─────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in jq curl bc; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]} > 0)); then
    log_error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

# ─── System Metrics ───────────────────────────────────────────────────────────

get_system_metrics() {
  # Returns: disk_free_pct ram_free_mb load_avg uptime_days
  local disk_free load_avg ram_free_mb uptime_days

  disk_free=$(df / | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
  load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
  ram_free_mb=$(free -m 2>/dev/null | awk 'NR==2 {print $7}' || echo "0")
  uptime_days=$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null || echo "0")

  echo "$disk_free|$load_avg|$ram_free_mb|$uptime_days"
}

# ─── Rotation Feed Analysis ───────────────────────────────────────────────────

analyze_rotation_feed() {
  local feed_file="$1"
  local max_entries="${2:-100}"

  if [[ ! -f "$feed_file" ]]; then
    log_warn "Rotation feed not found: $feed_file"
    echo "0|flat|0|{}"
    return
  fi

  # Read last N entries
  local entries
  entries=$(tail -n "$max_entries" "$feed_file" 2>/dev/null || echo "")

  if [[ -z "$entries" ]]; then
    echo "0|flat|0|{}"
    return
  fi

  local count
  count=$(echo "$entries" | jq -s 'length' 2>/dev/null || echo "0")

  if ((count == 0)); then
    echo "0|flat|0|{}"
    return
  fi

  # Compute average confidence
  local avg_confidence
  avg_confidence=$(echo "$entries" | jq -s '[.[].combined_confidence // .[].rotation_confidence // 0] | add / length' 2>/dev/null || echo "0")

  # Compute confidence trend: compare first third avg vs last third avg
  local first_avg last_avg trend
  first_avg=$(echo "$entries" | jq -s '.[0:(length/3 | floor)] | [.[].combined_confidence // .[].rotation_confidence // 0] | add / length' 2>/dev/null || echo "0")
  last_avg=$(echo "$entries" | jq -s '.[(-length/3 | floor):] | [.[].combined_confidence // .[].rotation_confidence // 0] | add / length' 2>/dev/null || echo "0")

  local diff
  diff=$(echo "$first_avg - $last_avg" | bc -l 2>/dev/null || echo "0")

  if (( $(echo "$diff > 0.05" | bc -l 2>/dev/null || echo 0) )); then
    trend="up"
  elif (( $(echo "$diff < -0.05" | bc -l 2>/dev/null || echo 0) )); then
    trend="down"
  else
    trend="flat"
  fi

  # Decision type distribution (by needs_attention flag)
  local decision_types_json
  decision_types_json=$(echo "$entries" | jq -s '{
    rotation: (. | map(select(.rotation_confidence != null)) | length),
    attention: (. | map(select(.needs_attention == true)) | length),
    entropy_anomaly: (. | map(select(.entropy_surprise > 0.5)) | length),
    rhythm_anomaly: (. | map(select(.rhythm_anomaly > 0.1)) | length)
  }' 2>/dev/null || echo "{}")

  # Round avg_confidence to 3 decimal places
  avg_confidence=$(printf "%.3f" "$avg_confidence" 2>/dev/null || echo "0.000")

  echo "${avg_confidence}|${trend}|${count}|${decision_types_json}"
}

# ─── GC Ledger Analysis ───────────────────────────────────────────────────────

analyze_gc_ledger() {
  local ledger_file="$1"
  local max_entries="${2:-50}"

  if [[ ! -f "$ledger_file" ]]; then
    log_warn "GC ledger not found: $ledger_file"
    echo "0.0|0|0|[]"
    return
  fi

  local entries
  entries=$(tail -n "$max_entries" "$ledger_file" 2>/dev/null || echo "")

  if [[ -z "$entries" ]]; then
    echo "0.0|0|0|[]"
    return
  fi

  local count
  count=$(echo "$entries" | jq -s 'length' 2>/dev/null || echo "0")

  if ((count == 0)); then
    echo "0.0|0|0|[]"
    return
  fi

  # Average aggression
  local avg_aggression
  avg_aggression=$(echo "$entries" | jq -s '[.[].aggression // .[].aggression_level // 0] | add / length' 2>/dev/null || echo "0")

  # Total bytes freed (convert to MB)
  local total_bytes
  total_bytes=$(echo "$entries" | jq -s '[.[].bytes_freed // .[].freed_bytes // 0] | add' 2>/dev/null || echo "0")
  local total_freed_mb
  total_freed_mb=$(echo "scale=2; $total_bytes / 1048576" | bc -l 2>/dev/null || echo "0")

  # Slow evals: entries where eval_time_ms > 100
  local slow_evals_json
  slow_evals_json=$(echo "$entries" | jq -s '[.[ select(.eval_time_ms > 100)] | .[].eval_time_ms // empty]' 2>/dev/null || echo "[]")

  avg_aggression=$(printf "%.2f" "$avg_aggression" 2>/dev/null || echo "0.00")

  echo "${avg_aggression}|${total_freed_mb}|${count}|${slow_evals_json}"
}

# ─── Headspace-rs Vector Count ────────────────────────────────────────────────

get_headspace_stats() {
  local url="${1:-${HEADSPACE_URL}}"

  local response
  response=$(curl -s -f -X GET "$url" --max-time 3 2>/dev/null || echo "")

  if [[ -z "$response" ]]; then
    echo "0|unknown"
    return
  fi

  local vector_count segment_count
  vector_count=$(echo "$response" | jq -r '.vector_count // .segments // .count // 0' 2>/dev/null || echo "0")
  segment_count=$(echo "$response" | jq -r '.segment_count // .collections // 0' 2>/dev/null || echo "0")

  echo "${vector_count}|${segment_count}"
}

# ─── Reflex Stats ─────────────────────────────────────────────────────────────

get_reflex_stats() {
  # Read from meta-reflex-daemon state if available
  local state_file="/tmp/meta-reflex-daemon.state.json"
  local hit_count=0
  local active_reflexes=0
  local top_reflex=""

  if [[ -f "$state_file" ]]; then
    hit_count=$(jq -r '[.reflex_stats.top_reflexes[].hits // 0] | add' "$state_file" 2>/dev/null || echo "0")
    active_reflexes=$(jq -r '.reflex_stats.total_reflexes // 0' "$state_file" 2>/dev/null || echo "0")
    top_reflex=$(jq -r '.reflex_stats.top_reflexes[0].name // ""' "$state_file" 2>/dev/null || echo "")
  fi

  # Fallback: count from reflexes.json hit_count fields
  if ((active_reflexes == 0)); then
    local reflex_file="${CONSTRUCT_DIR}/reflex/reflexes.json"
    if [[ -f "$reflex_file" ]]; then
      active_reflexes=$(jq 'length' "$reflex_file" 2>/dev/null || echo "0")
      top_reflex=$(jq -r '. | sort_by(-.hit_count) | .[0].name // ""' "$reflex_file" 2>/dev/null || echo "")
      hit_count=$(jq '[.[].hit_count // 0] | add' "$reflex_file" 2>/dev/null || echo "0")
    fi
  fi

  echo "${hit_count}|${active_reflexes}|${top_reflex}"
}

# ─── Fleet Pulse Report Builder ───────────────────────────────────────────────

build_fleet_pulse() {
  local ts
  ts=$(date -Iseconds)

  # System metrics
  local sys_metrics
  sys_metrics=$(get_system_metrics)
  IFS='|' read -r disk_free_pct load_avg ram_free_mb uptime_days <<< "$sys_metrics"

  # Rotation analysis
  local rotation_data
  rotation_data=$(analyze_rotation_feed "$ROTATION_FEED" 100)
  IFS='|' read -r avg_confidence trend total_decisions decision_types <<< "$rotation_data"

  # GC analysis
  local gc_data
  gc_data=$(analyze_gc_ledger "$GC_LEDGER" 50)
  IFS='|' read -r avg_aggression total_freed_mb gc_action_count slow_evals <<< "$gc_data"

  # Headspace stats
  local hs_stats
  hs_stats=$(get_headspace_stats)
  IFS='|' read -r vector_count segment_count <<< "$hs_stats"

  # Reflex stats
  local reflex_data
  reflex_data=$(get_reflex_stats)
  IFS='|' read -r reflex_hit_count active_reflexes top_reflex <<< "$reflex_data"

  # Build the JSON report
  local report_json
  report_json=$(jq -n \
    --arg timestamp "$ts" \
    --argjson avg_confidence "$avg_confidence" \
    --arg trend "$trend" \
    --argjson total_decisions "$total_decisions" \
    --arg decision_types "$decision_types" \
    --argjson disk_free_pct "$disk_free_pct" \
    --argjson ram_free_mb "$ram_free_mb" \
    --arg load_avg "$load_avg" \
    --argjson uptime_days "$uptime_days" \
    --argjson avg_aggression "$avg_aggression" \
    --argjson total_freed_mb "$total_freed_mb" \
    --argjson gc_action_count "$gc_action_count" \
    --arg slow_evals "$slow_evals" \
    --argjson reflex_hit_count "$reflex_hit_count" \
    --argjson active_reflexes "$active_reflexes" \
    --arg top_reflex "$top_reflex" \
    --argjson vector_count "$vector_count" \
    --argjson segment_count "$segment_count" \
    '{
      timestamp: $timestamp,
      rotation: {
        avg_confidence: $avg_confidence,
        trend: $trend,
        total_decisions: $total_decisions,
        decision_types: $decision_types
      },
      system: {
        disk_free_pct: $disk_free_pct,
        ram_free_mb: $ram_free_mb,
        load_avg: $load_avg,
        uptime_days: $uptime_days
      },
      gc: {
        avg_aggression: $avg_aggression,
        total_freed_mb: $total_freed_mb,
        action_count: $gc_action_count,
        slow_evals: $slow_evals
      },
      reflex: {
        hit_count: $reflex_hit_count,
        active_reflexes: $active_reflexes,
        top_reflex: $top_reflex
      },
      headspace: {
        vector_count: $vector_count,
        segment_count: $segment_count
      }
    }' 2>/dev/null || cat <<EOF
{
  "timestamp": "$ts",
  "rotation": {
    "avg_confidence": $avg_confidence,
    "trend": "$trend",
    "total_decisions": $total_decisions,
    "decision_types": $decision_types
  },
  "system": {
    "disk_free_pct": $disk_free_pct,
    "ram_free_mb": $ram_free_mb,
    "load_avg": "$load_avg",
    "uptime_days": $uptime_days
  },
  "gc": {
    "avg_aggression": $avg_aggression,
    "total_freed_mb": $total_freed_mb,
    "action_count": $gc_action_count,
    "slow_evals": $slow_evals
  },
  "reflex": {
    "hit_count": $reflex_hit_count,
    "active_reflexes": $active_reflexes,
    "top_reflex": "$top_reflex"
  },
  "headspace": {
    "vector_count": $vector_count,
    "segment_count": $segment_count
  }
}
EOF
  )

  echo "$report_json"
}

# ─── Fleet Event POST ─────────────────────────────────────────────────────────

post_to_fleet_event() {
  local payload="$1"
  local topic="${2:-fleet_pulse}"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[DRY-RUN] Would POST to $FLEET_EVENT_URL topic=$topic"
    echo "$payload" | jq '.' 2>/dev/null || echo "$payload"
    return 0
  fi

  local event_payload
  event_payload=$(echo "$payload" | jq \
    --arg topic "$topic" \
    '{ type: $topic, payload: ., timestamp: now | todateiso8601 }' 2>/dev/null || echo "$payload")

  local response
  local http_code

  http_code=$(curl -s -f -w '%{http_code}' -X POST "$FLEET_EVENT_URL" \
    -H "Content-Type: application/json" \
    -d "$event_payload" \
    -o /dev/null \
    --max-time 10 2>/dev/null || echo "000")

  if [[ "$http_code" =~ ^[23] ]]; then
    log_info "Fleet pulse posted to $topic (HTTP $http_code)"
    return 0
  else
    log_warn "Fleet event POST failed (HTTP $http_code)"
    return 1
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_deps

  while (( "$#" )); do
    case "$1" in
      --dry-run)   DRY_RUN=1; shift ;;
      --output-file)
        OUTPUT_FILE="$2"; shift 2 ;;
      --help|-h)
        cat <<'EOH'
reflect.sh — The Vane: analyze patterns, detect drift

Generates a fleet pulse report from rotation feed, GC ledger,
headspace-rs, and system metrics.

USAGE
  reflect.sh [--dry-run] [--output-file <path>]

OPTIONS
  --dry-run        Print report without posting or saving
  --output-file    Write report to file instead of posting

ENVIRONMENT
  FLEET_EVENT_HOST   Fleet event host (default: localhost)
  FLEET_EVENT_PORT   Fleet event port (default: 8782)
  HEADSPACE_HOST     Headspace-rs host (default: localhost)
  HEADSPACE_PORT     Headspace-rs port (default: 8800)

OUTPUT
  Fleet pulse JSON → POST to http://host:8782/api/event (topic: fleet_pulse)
                   → Append to data/pulse-history.jsonl
EOH
        exit 0 ;;
      --) shift; break ;;
      -*) echo "Unknown flag: $1" >&2; exit 1 ;;
      *) break ;;
    esac
  done

  log_info "Generating fleet pulse report"

  local report
  report=$(build_fleet_pulse)

  # Print to stdout if output file specified
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$report" > "$OUTPUT_FILE"
    log_info "Report written to: $OUTPUT_FILE"
  fi

  # Always print summary
  echo "$report" | jq -r '
    "Fleet Pulse Report (\(.timestamp))",
    "  Rotation:  avg_confidence=\(.rotation.avg_confidence) trend=\(.rotation.trend) decisions=\(.rotation.total_decisions)",
    "  System:   disk_free=\(.system.disk_free_pct)% ram_free=\(.system.ram_free_mb)MB load=\(.system.load_avg)",
    "  GC:       avg_aggression=\(.gc.avg_aggression) freed_mb=\(.gc.total_freed_mb) actions=\(.gc.action_count)",
    "  Reflex:   hits=\(.reflex.hit_count) active=\(.reflex.active_reflexes) top=\(.reflex.top_reflex // "none")",
    "  Headspace: vectors=\(.headspace.vector_count) segments=\(.headspace.segment_count)"
  ' 2>/dev/null || echo "$report"

  # POST to fleet event bus
  local post_ok=0
  post_to_fleet_event "$report" "fleet_pulse" || post_ok=$?

  # Append to pulse history
  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$(dirname "$PULSE_HISTORY")"
    echo "$report" >> "$PULSE_HISTORY"
    log_info "Appended to: $PULSE_HISTORY"
  fi

  if ((post_ok != 0)); then
    log_warn "Fleet event POST had issues (non-fatal)"
  fi

  log_info "Fleet pulse complete"
}

main "$@"
