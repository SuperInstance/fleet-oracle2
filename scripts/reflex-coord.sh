#!/usr/bin/env bash
#
# reflex-coord.sh — Fleet-wide reflex coordination CLI
#
# Usage:
#   reflex-coord.sh --teach <json-file> [--service <name>|--all]
#   reflex-coord.sh --list [--service <name>|--all]
#   reflex-coord.sh --test <reflex-name> [--service <name>|--all]
#   reflex-coord.sh --purge <reflex-name> [--service <name>|--all]
#   reflex-coord.sh --propagate [--json <file>]
#
# Flags:
#   --teach <file>     Load reflexes from JSON file and register with target services
#   --list            List active reflexes from target services
#   --test <name>     Dry-run trigger test for named reflex
#   --purge <name>    Remove named reflex from target services
#   --propagate       Propagate reflexes to all fleet services via fleet-event bus
#   --service <name>  Target specific service (default: all known services)
#   --all             Target all known fleet services
#   --verbose         Enable verbose output
#   --dry-run         Print actions without executing
#
# Examples:
#   reflex-coord.sh --teach construct/reflex/reflexes.json --all
#   reflex-coord.sh --list --service fleet-oracle
#   reflex-coord.sh --test disk-crisis --all
#   reflex-coord.sh --propagate --json construct/reflex/reflexes.json
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFLEX_DIR="$(dirname "$SCRIPT_DIR")/reflex"
DEFAULT_REFLEX_JSON="${REFLEX_DIR}/reflexes.json"
LOG_PREFIX="[reflex-coord]"

# Known fleet services and their reflex endpoints
declare -A SERVICE_ENDPOINTS=(
  ["fleet-oracle"]="http://localhost:8795"
  ["fleet-log"]="http://localhost:8791"
  ["fleet-event"]="http://localhost:8792"
  ["fleet-conductor"]="http://localhost:8793"
  ["nebula"]="http://localhost:8789"
  ["gc-pid-bridge"]="http://localhost:8080"
  ["headspace-rs"]="http://localhost:8800"
)

# Fleet-midi agents (16 instances on :2160–:2175)
FLEET_MIDI_BASE_PORT=2160
FLEET_MIDI_COUNT=16

# ─── Globals ───────────────────────────────────────────────────────────────────

VERBOSE=false
DRY_RUN=false
TARGET_SERVICE=""
COMMAND=""
REFLEX_FILE="$DEFAULT_REFLEX_JSON"
REFLEX_NAME=""
PROPAGATE=false

# ─── Logging ───────────────────────────────────────────────────────────────────

log_info() {
  echo "$LOG_PREFIX $(date '+%Y-%m-%dT%H:%M:%S') INFO: $*"
}

log_warn() {
  echo "$LOG_PREFIX $(date '+%Y-%m-%dT%H:%M:%S') WARN: $*" >&2
}

log_error() {
  echo "$LOG_PREFIX $(date '+%Y-%m-%dT%H:%M:%S') ERROR: $*" >&2
}

log_debug() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "$LOG_PREFIX $(date '+%Y-%m-%dT%H:%M:%S') DEBUG: $*"
  fi
}

# ─── Dependencies ─────────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]} > 0)); then
    log_error "Missing required commands: ${missing[*]}"
    log_error "Install with: apt install jq curl  # or brew install jq curl"
    exit 1
  fi
}

# ─── Service Discovery ─────────────────────────────────────────────────────────

get_all_services() {
  local services=()
  for svc in "${!SERVICE_ENDPOINTS[@]}"; do
    services+=("$svc")
  done
  # Add fleet-midi agents
  for i in $(seq 0 $((FLEET_MIDI_COUNT - 1))); do
    services+=("fleet-midi-$i")
  done
  printf '%s\n' "${services[@]}"
}

get_service_endpoint() {
  local svc="$1"
  if [[ "$svc" == fleet-midi-* ]]; then
    local idx="${svc#fleet-midi-}"
    local port=$((FLEET_MIDI_BASE_PORT + idx))
    echo "http://localhost:$port"
  else
    echo "${SERVICE_ENDPOINTS[$svc]:-}"
  fi
}

resolve_service_name() {
  local input="$1"
  # Exact match
  if [[ -v SERVICE_ENDPOINTS[$input] ]] || [[ "$input" =~ ^fleet-midi-[0-9]+$ ]]; then
    echo "$input"
    return
  fi
  # Partial match (e.g., "oracle" → "fleet-oracle")
  for svc in "${!SERVICE_ENDPOINTS[@]}"; do
    if [[ "$svc" == *"$input"* ]]; then
      echo "$svc"
      return
    fi
  done
  echo ""
}

# ─── HTTP Helpers ───────────────────────────────────────────────────────────────

http_get() {
  local url="$1"
  local opts="${2:-}"
  curl -s -f -X GET "$url" $opts
}

http_post() {
  local url="$1"
  local body="$2"
  local opts="${3:-}"
  curl -s -f -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$body" \
    $opts
}

http_delete() {
  local url="$1"
  local opts="${2:-}"
  curl -s -f -X DELETE "$url" $opts
}

service_reachable() {
  local endpoint="$1"
  curl -s -f -X GET "${endpoint}/health" &>/dev/null || \
  curl -s -f -X GET "${endpoint}" &>/dev/null || \
  return 1
}

# ─── Reflex JSON Helpers ───────────────────────────────────────────────────────

validate_reflex_json() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log_error "Reflex file not found: $file"
    return 1
  fi

  # Check it's valid JSON with array
  if ! jq -e 'type == "array"' "$file" &>/dev/null; then
    log_error "Reflex file must contain a JSON array: $file"
    return 1
  fi

  # Check each reflex has required fields
  local count
  count=$(jq 'length' "$file")
  log_debug "Validating $count reflexes from $file"

  local idx=0
  while ((idx < count)); do
    local name
    name=$(jq -r ".[$idx].name // empty" "$file" 2>/dev/null)
    if [[ -z "$name" ]]; then
      log_error "Reflex at index $idx missing required field: name"
      return 1
    fi

    local metric
    metric=$(jq -r ".[$idx].trigger.metric // empty" "$file" 2>/dev/null)
    if [[ -z "$metric" ]]; then
      log_error "Reflex '$name' missing required field: trigger.metric"
      return 1
    fi

    local threshold
    threshold=$(jq -r ".[$idx].trigger.threshold // empty" "$file" 2>/dev/null)
    if [[ -z "$threshold" ]]; then
      log_error "Reflex '$name' missing required field: trigger.threshold"
      return 1
    fi

    local endpoint
    endpoint=$(jq -r ".[$idx].action.endpoint // empty" "$file" 2>/dev/null)
    if [[ -z "$endpoint" ]]; then
      log_error "Reflex '$name' missing required field: action.endpoint"
      return 1
    fi

    ((idx++))
  done

  log_debug "All ${count} reflexes validated successfully"
  return 0
}

# ─── Core Operations ──────────────────────────────────────────────────────────

do_teach() {
  local file="$1"
  local target_svc="${2:-}"

  log_info "Teaching reflexes from: $file"

  if ! validate_reflex_json "$file"; then
    return 1
  fi

  local count
  count=$(jq 'length' "$file")

  if [[ -n "$target_svc" ]]; then
    # Single service
    local services=("$target_svc")
    _teach_to_services "$file" "$count" "${services[@]}"
  else
    # All services
    _teach_to_services "$file" "$count" $(get_all_services)
  fi
}

_teach_to_services() {
  local file="$1"
  local count="$2"
  shift 2
  local services=("$@")

  local success_count=0
  local fail_count=0

  for svc in "${services[@]}"; do
    local endpoint
    endpoint=$(get_service_endpoint "$svc")
    if [[ -z "$endpoint" ]]; then
      log_warn "Unknown service: $svc, skipping"
      ((fail_count++))
      continue
    fi

    if ! service_reachable "$endpoint"; then
      log_warn "Service not reachable: $svc ($endpoint), skipping"
      ((fail_count++))
      continue
    fi

    log_debug "Teaching reflexes to $svc at $endpoint"

    local idx=0
    local svc_success=0
    while ((idx < count)); do
      local reflex_json
      reflex_json=$(jq ".[$idx]" "$file")

      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would POST /reflex/teach to $svc: $(jq -c '.name' <<< "$reflex_json")"
        ((svc_success++))
      else
        local response
        if response=$(http_post "${endpoint}/reflex/teach" "$reflex_json" 2>&1); then
          log_debug "Taught $(jq -r '.name' <<< "$reflex_json") to $svc"
          ((svc_success++))
        else
          log_warn "Failed to teach $(jq -r '.name' <<< "$reflex_json") to $svc: ${response:0:200}"
        fi
      fi

      ((idx++))
    done

    if ((svc_success > 0)); then
      ((success_count++))
      log_info "Taught $svc: $svc_success/$count reflexes registered"
    fi
  done

  log_info "Teach complete: $success_count services succeeded, $fail_count failed"
}

do_list() {
  local target_svc="${1:-}"

  if [[ -n "$target_svc" ]]; then
    _list_from_services "$target_svc"
  else
    _list_from_services $(get_all_services)
  fi
}

_list_from_services() {
  local services=("$@")

  for svc in "${services[@]}"; do
    local endpoint
    endpoint=$(get_service_endpoint "$svc")
    if [[ -z "$endpoint" ]]; then
      continue
    fi

    if ! service_reachable "$endpoint" 2>/dev/null; then
      log_debug "Service not reachable: $svc"
      continue
    fi

    local response
    response=$(http_get "${endpoint}/reflex/list" 2>/dev/null) || {
      log_debug "Could not list reflexes from $svc"
      continue
    }

    local count
    count=$(echo "$response" | jq 'length' 2>/dev/null || echo 0)

    echo "=== $svc (${endpoint}) — $count reflexes ==="
    if ((count > 0)); then
      echo "$response" | jq -r '.[] | "  [\(.confidence)] \(.name): \(.trigger.metric) \(.trigger.operator) \(.trigger.threshold) | hits=\(.hit_count)"' 2>/dev/null || echo "$response"
    fi
    echo
  done
}

do_test() {
  local reflex_name="$1"
  local target_svc="${2:-}"

  log_info "Testing reflex: $reflex_name"

  if [[ -z "$reflex_name" ]]; then
    log_error "--test requires a reflex name"
    return 1
  fi

  local reflex_json
  reflex_json=$(jq -c ".[] | select(.name == \"$reflex_name\")" "$REFLEX_FILE" 2>/dev/null) || {
    log_error "Reflex not found: $reflex_name"
    return 1
  }

  log_debug "Found reflex: $reflex_json"

  if [[ -n "$target_svc" ]]; then
    local services=("$target_svc")
    _test_reflex "$reflex_name" "$reflex_json" "${services[@]}"
  else
    _test_reflex "$reflex_name" "$reflex_json" $(get_all_services)
  fi
}

_test_reflex() {
  local name="$1"
  local reflex_json="$2"
  shift 2
  local services=("$@")

  for svc in "${services[@]}"; do
    local endpoint
    endpoint=$(get_service_endpoint "$svc")
    if [[ -z "$endpoint" ]] || ! service_reachable "$endpoint" 2>/dev/null; then
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would POST /reflex/test to $svc: $name"
      continue
    fi

    local response
    if response=$(http_post "${endpoint}/reflex/test" "$reflex_json" 2>&1); then
      echo "=== $svc: TEST OK ==="
      echo "$response" | jq '.' 2>/dev/null || echo "$response"
    else
      echo "=== $svc: TEST FAILED ==="
      echo "${response:0:200}" >&2
    fi
  done
}

do_purge() {
  local reflex_name="$1"
  local target_svc="${2:-}"

  log_info "Purging reflex: $reflex_name"

  if [[ -z "$reflex_name" ]]; then
    log_error "--purge requires a reflex name"
    return 1
  fi

  if [[ -n "$target_svc" ]]; then
    local services=("$target_svc")
    _purge_from_services "$reflex_name" "${services[@]}"
  else
    _purge_from_services "$reflex_name" $(get_all_services)
  fi
}

_purge_from_services() {
  local name="$1"
  shift
  local services=("$@")

  local success_count=0
  local fail_count=0

  for svc in "${services[@]}"; do
    local endpoint
    endpoint=$(get_service_endpoint "$svc")
    if [[ -z "$endpoint" ]]; then
      continue
    fi

    if ! service_reachable "$endpoint" 2>/dev/null; then
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would DELETE /reflex/purge/$name from $svc"
      ((success_count++))
      continue
    fi

    local response
    if response=$(http_delete "${endpoint}/reflex/purge/${name}" 2>&1); then
      log_info "Purged $name from $svc"
      ((success_count++))
    else
      log_warn "Failed to purge $name from $svc: ${response:0:100}"
      ((fail_count++))
    fi
  done

  log_info "Purge complete: $success_count succeeded, $fail_count failed"
}

do_propagate() {
  local file="${1:-$DEFAULT_REFLEX_JSON}"

  log_info "Propagating reflexes via fleet-event bus from: $file"

  if ! validate_reflex_json "$file"; then
    return 1
  fi

  local fleet_event_endpoint="${SERVICE_ENDPOINTS[fleet-event]}"
  if ! service_reachable "$fleet_event_endpoint" 2>/dev/null; then
    log_error "fleet-event service not reachable at $fleet_event_endpoint"
    return 1
  fi

  local count
  count=$(jq 'length' "$file")
  local idx=0
  local propagated=0

  while ((idx < count)); do
    local reflex_json
    reflex_json=$(jq ".[$idx]" "$file")
    local name
    name=$(jq -r '.[$idx].name' "$file")

    local event_payload
    event_payload=$(jq -c \
      --arg name "$name" \
      '{ type: "reflex.teach", payload: .[], timestamp: now | todateiso8601 }' \
      "$file")

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] Would emit fleet-event: $event_payload"
      ((propagated++))
    else
      local response
      if response=$(http_post "${fleet_event_endpoint}/events" "$event_payload" 2>&1); then
        log_info "Propagated reflex '$name' via fleet-event"
        ((propagated++))
      else
        log_warn "Failed to propagate reflex '$name': ${response:0:200}"
      fi
    fi

    ((idx++))
  done

  log_info "Propagation complete: $propagated/$count reflexes emitted to fleet-event"
}

# ─── Fleet-Midi Batch Helpers ──────────────────────────────────────────────────

do_teach_midi_batch() {
  local file="$1"
  local batch_size="${2:-4}"

  log_info "Batch-teaching reflexes to fleet-midi agents (batch size: $batch_size)"

  if ! validate_reflex_json "$file"; then
    return 1
  fi

  local count
  count=$(jq 'length' "$file")

  # Teach all reflexes to first midi in batch, then replicate
  local first_midi_idx=0
  local first_endpoint="http://localhost:$((FLEET_MIDI_BASE_PORT + first_midi_idx))"

  if ! service_reachable "$first_endpoint" 2>/dev/null; then
    log_error "First fleet-midi agent not reachable at $first_endpoint"
    return 1
  fi

  log_info "Teaching reflexes to anchor agent fleet-midi-$first_midi_idx"
  local idx=0
  while ((idx < count)); do
    local reflex_json
    reflex_json=$(jq ".[$idx]" "$file")
    local name
    name=$(jq -r ".[$idx].name" "$file")

    if [[ "$DRY_RUN" == "false" ]]; then
      http_post "${first_endpoint}/reflex/teach" "$reflex_json" &>/dev/null || {
        log_warn "Failed to teach $name to anchor"
      }
    fi
    ((idx++))
  done

  log_info "Broadcasting to remaining $((FLEET_MIDI_COUNT - 1)) fleet-midi agents"

  # Broadcast to remaining midi agents
  for i in $(seq 1 $((FLEET_MIDI_COUNT - 1))); do
    local endpoint="http://localhost:$((FLEET_MIDI_BASE_PORT + i))"
    if service_reachable "$endpoint" 2>/dev/null; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would sync reflexes to fleet-midi-$i"
      else
        http_post "${endpoint}/reflex/sync" '{"source": "fleet-midi-0"}' &>/dev/null || {
          log_warn "Failed to sync to fleet-midi-$i"
        }
      fi
    fi
  done

  log_info "Fleet-midi batch teach complete"
}

# ─── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
reflex-coord.sh — Fleet-wide reflex coordination CLI

USAGE
  reflex-coord.sh --teach <json-file> [--service <name>|--all]
  reflex-coord.sh --list [--service <name>|--all]
  reflex-coord.sh --test <reflex-name> [--service <name>|--all]
  reflex-coord.sh --purge <reflex-name> [--service <name>|--all]
  reflex-coord.sh --propagate [--json <file>]
  reflex-coord.sh --midi-batch <json-file> [--batch-size <n>]

FLAGS
  --teach <file>      Load reflexes from JSON file and register with target services
  --list              List active reflexes from target services
  --test <name>       Dry-run trigger test for named reflex
  --purge <name>      Remove named reflex from target services
  --propagate         Propagate reflexes to all fleet services via fleet-event bus
  --midi-batch <file> Batch-teach reflexes to fleet-midi agents
  --service <name>    Target specific service (default: all known services)
  --all               Target all known fleet services
  --verbose           Enable verbose output
  --dry-run           Print actions without executing
  --help              Show this help

EXAMPLES
  reflex-coord.sh --teach construct/reflex/reflexes.json --all
  reflex-coord.sh --list --service fleet-oracle
  reflex-coord.sh --test disk-crisis --all
  reflex-coord.sh --purge disk-crisis --service gc-pid-bridge
  reflex-coord.sh --propagate
  reflex-coord.sh --teach construct/reflex/reflexes.json --service fleet-midi-0 --verbose

SERVICE NAMES
  fleet-oracle, fleet-log, fleet-event, fleet-conductor, nebula,
  gc-pid-bridge, headspace-rs, fleet-midi-0 through fleet-midi-15

EXIT CODES
  0   Success
  1   Error (invalid args, unreachable service, validation failure)
  2   Partial success (some services failed)
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────────

main() {
  check_deps

  # Parse arguments
  while (( "$#" )); do
    case "$1" in
      --teach)
        COMMAND="teach"
        REFLEX_FILE="$2"
        shift 2
        ;;
      --list)
        COMMAND="list"
        shift
        ;;
      --test)
        COMMAND="test"
        REFLEX_NAME="$2"
        shift 2
        ;;
      --purge)
        COMMAND="purge"
        REFLEX_NAME="$2"
        shift 2
        ;;
      --propagate)
        COMMAND="propagate"
        shift
        ;;
      --midi-batch)
        COMMAND="midi-batch"
        REFLEX_FILE="$2"
        shift 2
        ;;
      --service)
        TARGET_SERVICE="$2"
        shift 2
        ;;
      --all)
        TARGET_SERVICE="__all__"
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
        log_error "Unknown flag: $1"
        usage
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ -z "$COMMAND" ]]; then
    log_error "No command specified. Use --help for usage."
    exit 1
  fi

  # Resolve target service
  local resolved_svc=""
  if [[ -n "$TARGET_SERVICE" && "$TARGET_SERVICE" != "__all__" ]]; then
    resolved_svc=$(resolve_service_name "$TARGET_SERVICE")
    if [[ -z "$resolved_svc" ]]; then
      log_error "Unknown service: $TARGET_SERVICE"
      exit 1
    fi
  fi

  log_debug "Command: $COMMAND, Target: ${resolved_svc:-all}, File: $REFLEX_FILE"

  case "$COMMAND" in
    teach)
      do_teach "$REFLEX_FILE" "$resolved_svc"
      ;;
    list)
      do_list "$resolved_svc"
      ;;
    test)
      do_test "$REFLEX_NAME" "$resolved_svc"
      ;;
    purge)
      do_purge "$REFLEX_NAME" "$resolved_svc"
      ;;
    propagate)
      do_propagate "$REFLEX_FILE"
      ;;
    midi-batch)
      do_teach_midi_batch "$REFLEX_FILE"
      ;;
    *)
      log_error "Unknown command: $COMMAND"
      exit 1
      ;;
  esac
}

main "$@"
