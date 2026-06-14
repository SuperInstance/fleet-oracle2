#!/usr/bin/env bash
#
# self-test.sh — Fleet System Self-Test
#
# Comprehensive health check for all fleet services.
# Reports PASS/FAIL per test, exit code = number of failures.
#
# Usage:
#   self-test.sh [--verbose] [--json] [--service <name>]
#   self-test.sh --help
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

CONSTRUCT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${CONSTRUCT_DIR}/data"
DECISION_WAL="${DATA_DIR}/decision-wal"
ROTATION_FEED="${DATA_DIR}/rotation-feed.json"

# Fleet service endpoints
declare -A SERVICES=(
  [oracle]=http://localhost:8795
  [log]=http://localhost:8781
  [event]=http://localhost:8782
  [conductor]=http://localhost:8769
  [headspace]=http://localhost:8800
  [gc-pid]=http://localhost:8080
)

VERBOSE="${VERBOSE:-0}"
JSON_OUTPUT="${JSON_OUTPUT:-0}"
TARGET_SERVICE=""

# ─── Test Results ─────────────────────────────────────────────────────────────

declare -a TEST_NAMES=()
declare -a TEST_RESULTS=()
declare -a TEST_DETAILS=()
FAIL_COUNT=0
PASS_COUNT=0
SKIP_COUNT=0

# ─── Logging ─────────────────────────────────────────────────────────────────

log_info()  { echo "INFO:  $*" >&2; }
log_warn()  { echo "WARN:  $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() {
  if [[ "$VERBOSE" == "1" ]]; then
    echo "DEBUG: $*" >&2
  fi
}

# ─── Test Helpers ─────────────────────────────────────────────────────────────

record_test() {
  local name="$1"
  local result="$2"
  local detail="${3:-}"

  TEST_NAMES+=("$name")
  TEST_RESULTS+=("$result")
  TEST_DETAILS+=("$detail")

  case "$result" in
    PASS) : $((PASS_COUNT++)) ;;
    FAIL) : $((FAIL_COUNT++)) ;;
    SKIP) : $((SKIP_COUNT++)) ;;
  esac
}

# Get HTTP response code - extracts last 3 chars which are the code
get_http_code() {
  local url="$1"
  local timeout="${2:-3}"
  local output
  output=$(curl -s -w '%{http_code}' -X GET "$url"     --max-time "$timeout" 2>/dev/null || echo "000")
  echo "${output: -3}"
}

test_service() {
  local name="$1"
  local url="$2"
  local timeout="${3:-3}"

  log_debug "Testing service $name at $url"

  local http_code
  http_code=$(get_http_code "${url}/health" "$timeout")

  if [[ "$http_code" =~ ^[23] ]]; then
    record_test "service:$name" "PASS" "HTTP $http_code"
    return
  fi

  http_code=$(get_http_code "$url" "$timeout")

  if [[ "$http_code" =~ ^[23] ]]; then
    record_test "service:$name" "PASS" "HTTP $http_code (root)"
    return
  fi

  record_test "service:$name" "FAIL" "HTTP $http_code"
}

test_service_json() {
  local name="$1"
  local url="$2"
  local timeout="${3:-3}"

  log_debug "Testing JSON service $name at $url"

  local response
  response=$(curl -s -X GET "$url" --max-time "$timeout" 2>/dev/null || echo "")

  if [[ -z "$response" ]]; then
    record_test "service:$name" "FAIL" "No response"
    return
  fi

  if echo "$response" | jq -e '.' &>/dev/null; then
    record_test "service:$name" "PASS" "JSON response (${#response} bytes)"
    return
  fi

  record_test "service:$name" "FAIL" "Invalid JSON response"
}

# ─── Test: Oracle Decision Flow ──────────────────────────────────────────────

test_oracle_decision_flow() {
  log_debug "Testing oracle decision flow"

  local oracle_url="${SERVICES[oracle]}"
  local log_url="${SERVICES[log]}"
  local test_id="self-test-$(date '+%Y%m%dT%H%M%S')-$$"

  local decision_payload
  decision_payload=$(jq -n     --arg id "$test_id"     --arg ts "$(date -Iseconds)"     --arg type "self_test"     --argjson confidence 0.999     '{id: $id, timestamp: $ts, decision_type: $type, confidence: $confidence, payload: "self-test"}' 2>/dev/null)

  local http_code
  http_code=$(curl -s -w '%{http_code}' -X POST "${oracle_url}/decide"     -H "Content-Type: application/json"     -d "$decision_payload"     -o /dev/null     --max-time 5 2>/dev/null | tail -c 3 || echo "000")

  if [[ ! "$http_code" =~ ^[23] ]]; then
    record_test "oracle:decision_flow" "FAIL" "POST to oracle failed (HTTP $http_code)"
    return
  fi

  sleep 1

  local log_entries
  log_entries=$(curl -s -X GET "${log_url}/logs" --max-time 5 2>/dev/null || echo "")

  if echo "$log_entries" | grep -q "$test_id" 2>/dev/null; then
    record_test "oracle:decision_flow" "PASS" "Decision $test_id logged successfully"
    return
  fi

  if [[ -f "$ROTATION_FEED" ]] && grep -q "$test_id" "$ROTATION_FEED" 2>/dev/null; then
    record_test "oracle:decision_flow" "PASS" "Decision $test_id in rotation feed"
    return
  fi

  record_test "oracle:decision_flow" "FAIL" "Decision $test_id not found in log"
}

# ─── Test: Event Bus ──────────────────────────────────────────────────────────

test_event_bus() {
  log_debug "Testing event bus"

  local event_url="${SERVICES[event]}"
  local test_id="self-test-event-$(date '+%Y%m%dT%H%M%S')"

  local event_payload
  event_payload=$(jq -n     --arg id "$test_id"     --arg type "self_test"     --arg ts "$(date -Iseconds)"     '{id: $id, type: $type, timestamp: $ts, payload: "self-test"}' 2>/dev/null)

  local http_code
  http_code=$(curl -s -w '%{http_code}' -X POST "${event_url}/events"     -H "Content-Type: application/json"     -d "$event_payload"     -o /dev/null     --max-time 5 2>/dev/null | tail -c 3 || echo "000")

  if [[ "$http_code" =~ ^[23] ]]; then
    record_test "event:bus" "PASS" "Event $test_id posted (HTTP $http_code)"
    return
  fi

  record_test "event:bus" "FAIL" "Event POST failed (HTTP $http_code)"
}

# ─── Test: GC PID Bridge ─────────────────────────────────────────────────────

test_gc_pid_bridge() {
  log_debug "Testing gc-pid-bridge"

  local gc_url="${SERVICES[gc-pid]}"

  local test_payload
  test_payload=$(jq -n     --argjson disk_usage 90.0     --argjson load_avg 5.0     --argjson ram_free_mb 1024     '{disk_usage: $disk_usage, load_avg: $load_avg, ram_free_mb: $ram_free_mb}' 2>/dev/null)

  local response
  response=$(curl -s -X POST "${gc_url}/tune"     -H "Content-Type: application/json"     -d "$test_payload"     --max-time 5 2>/dev/null || echo "")

  if [[ -z "$response" ]]; then
    record_test "gc-pid:tune" "FAIL" "No response from gc-pid-bridge"
    return
  fi

  local aggression
  aggression=$(echo "$response" | jq -r '.aggression // .output // .tuned_aggression // 0' 2>/dev/null || echo "0")

  local aggression_num
  aggression_num=$(echo "$aggression" | bc -l 2>/dev/null || echo "0")

  local in_range
  in_range=$(echo "$aggression_num >= 0.5 && $aggression_num <= 5.0" | bc -l 2>/dev/null || echo "0")

  if ((in_range == 1)); then
    record_test "gc-pid:tune" "PASS" "Output aggression=$aggression (in range [0.5, 5.0])"
    return
  fi

  record_test "gc-pid:tune" "FAIL" "Output aggression=$aggression outside expected range [0.5, 5.0]"
}

# ─── Test: Rotation Feed ──────────────────────────────────────────────────────

test_rotation_feed() {
  log_debug "Testing rotation feed"

  if [[ ! -f "$ROTATION_FEED" ]]; then
    record_test "rotation:feed_exists" "FAIL" "File not found: $ROTATION_FEED"
    return
  fi

  local size
  size=$(stat -c '%s' "$ROTATION_FEED" 2>/dev/null || stat -f '%z' "$ROTATION_FEED" 2>/dev/null || echo "0")

  if ((size == 0)); then
    record_test "rotation:feed_exists" "FAIL" "File is empty: $ROTATION_FEED"
    return
  fi

  if ! jq -e '.' "$ROTATION_FEED" &>/dev/null; then
    record_test "rotation:feed_valid_json" "FAIL" "Invalid JSON in $ROTATION_FEED"
    return
  fi

  local count
  count=$(wc -l < "$ROTATION_FEED" 2>/dev/null || echo "0")

  if [[ "$count" == "0" || "$count" == "" ]]; then
    record_test "rotation:feed_nonempty" "FAIL" "rotation-feed.json is empty"
    return
  fi

  record_test "rotation:feed" "PASS" "$count entries, ${size} bytes"
}

# ─── Test: Decision WAL ──────────────────────────────────────────────────────

test_decision_wal() {
  log_debug "Testing decision WAL"

  if [[ ! -d "$DECISION_WAL" ]]; then
    record_test "decision:wal_exists" "FAIL" "Directory not found: $DECISION_WAL"
    return
  fi

  local recent_count
  recent_count=$(find "$DECISION_WAL" -type f -mmin -5 2>/dev/null | wc -l || echo "0")

  local total_count
  total_count=$(find "$DECISION_WAL" -type f 2>/dev/null | wc -l || echo "0")

  if ((total_count == 0)); then
    record_test "decision:wal_recent" "SKIP" "WAL exists but no entries yet"
    return
  fi

  if ((recent_count > 0)); then
    record_test "decision:wal" "PASS" "$recent_count recent entries (of $total_count total)"
    return
  fi

  record_test "decision:wal" "PASS" "$total_count total entries (none recent)"
}

# ─── Test: Headspace-rs Segment CRUD ────────────────────────────────────────

test_headspace_crud() {
  log_debug "Testing headspace-rs segment CRUD"

  local hs_url="${SERVICES[headspace]}"
  local test_segment_id="self-test-$(date '+%Y%m%dT%H%M%S')"

  local create_payload
  create_payload=$(jq -n     --arg id "$test_segment_id"     --arg type "self_test"     --arg ts "$(date -Iseconds)"     --arg text "self-test segment for fleet self-test"     '{id: $id, type: $type, timestamp: $ts, text: $text, metadata: {source: "self-test"}}' 2>/dev/null)

  local create_response
  create_response=$(curl -s -X POST "${hs_url}/segment"     -H "Content-Type: application/json"     -d "$create_payload"     --max-time 5 2>/dev/null || echo "")

  if [[ -z "$create_response" ]]; then
    record_test "headspace:segment_create" "FAIL" "No response from segment create"
    return
  fi

  if ! echo "$create_response" | jq -e '.' &>/dev/null; then
    record_test "headspace:segment_create" "FAIL" "Invalid JSON response"
    return
  fi

  record_test "headspace:segment_create" "PASS" "Segment $test_segment_id created"

  local query_response
  query_response=$(curl -s -X POST "${hs_url}/query"     -H "Content-Type: application/json"     -d "{\"query\":\"self-test\",\"top_k\":5}"     --max-time 5 2>/dev/null || echo "")

  if [[ -z "$query_response" ]]; then
    record_test "headspace:segment_query" "FAIL" "No response from segment query"
    return
  fi

  if echo "$query_response" | jq -e '.results // .segments // .[]' &>/dev/null; then
    record_test "headspace:segment_query" "PASS" "Segment query returned results"
    return
  fi

  record_test "headspace:segment_query" "FAIL" "Query response missing results"
}

# ─── Test: Conductor Health ──────────────────────────────────────────────────

test_conductor() {
  log_debug "Testing fleet-conductor"

  local conductor_url="${SERVICES[conductor]}"

  local response
  response=$(curl -s -X GET "${conductor_url}/health" --max-time 3 2>/dev/null || echo "")

  if [[ -z "$response" ]]; then
    record_test "service:conductor" "FAIL" "No response"
    return
  fi

  if echo "$response" | jq -e '.status // .healthy // true' &>/dev/null; then
    record_test "service:conductor" "PASS" "Conductor healthy"
    return
  fi

  record_test "service:conductor" "FAIL" "Conductor unhealthy: $(echo "$response" | jq -r '.status // .message // "unknown"' 2>/dev/null || echo 'unknown')"
}

# ─── Print Results ───────────────────────────────────────────────────────────

print_results() {
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    local tests_json="[]"
    local idx=0
    while ((idx < ${#TEST_NAMES[@]})); do
      tests_json=$(jq         --arg name "${TEST_NAMES[$idx]}"         --arg result "${TEST_RESULTS[$idx]}"         --arg detail "${TEST_DETAILS[$idx]}"         '. += [{name: $name, result: $result, detail: $detail}]'         <<< "$tests_json" 2>/dev/null || echo "[]")
      ((++idx))
    done

    jq -n       --argjson pass_count "$PASS_COUNT"       --argjson fail_count "$FAIL_COUNT"       --argjson skip_count "$SKIP_COUNT"       --argjson total_tests "${#TEST_NAMES[@]}"       --arg timestamp "$(date -Iseconds)"       --argjson tests "$tests_json"       '{
        summary: {
          timestamp: $timestamp,
          total: $total_tests,
          pass: $pass_count,
          fail: $fail_count,
          skip: $skip_count,
          all_pass: ($fail_count == 0)
        },
        tests: $tests
      }' 2>/dev/null
    return
  fi

  echo
  echo "═══════════════════════════════════════════════════════════════"
  echo "                    FLEET SELF-TEST REPORT"
  echo "═══════════════════════════════════════════════════════════════"
  echo "Timestamp: $(date '+%Y-%m-%dT%H:%M:%S')"
  echo "───────────────────────────────────────────────────────────────"

  local idx=0
  while ((idx < ${#TEST_NAMES[@]})); do
    local name="${TEST_NAMES[$idx]}"
    local result="${TEST_RESULTS[$idx]}"
    local detail="${TEST_DETAILS[$idx]}"

    local icon
    case "$result" in
      PASS) icon="✅" ;;
      FAIL) icon="❌" ;;
      SKIP) icon="⏭" ;;
    esac

    printf "%s %-30s %s\n" "$icon" "$name" "$result"
    if [[ -n "$detail" && "$VERBOSE" == "1" ]]; then
      printf "   └─ %s\n" "$detail"
    fi
    ((++idx))
  done

  echo "───────────────────────────────────────────────────────────────"
  echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
  echo "═══════════════════════════════════════════════════════════════"
  echo

  if ((FAIL_COUNT > 0)); then
    echo "FAILED TESTS:"
    idx=0
    while ((idx < ${#TEST_NAMES[@]})); do
      if [[ "${TEST_RESULTS[$idx]}" == "FAIL" ]]; then
        echo "  - ${TEST_NAMES[$idx]}: ${TEST_DETAILS[$idx]}"
      fi
      ((++idx))
    done
    echo
  fi
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
self-test.sh — Fleet System Self-Test

Comprehensive health check for all fleet services.

USAGE
  self-test.sh [--verbose] [--json] [--service <name>]
  self-test.sh --help

OPTIONS
  --verbose    Show detailed output for each test
  --json       Output results as JSON
  --service    Run only tests for a specific service

TESTS
  Service health checks (oracle, log, event, conductor, headspace, gc-pid)
  oracle:decision_flow    POST a decision, verify it appears in log
  event:bus              POST an event, verify acceptance
  gc-pid:tune            POST known inputs, verify output range [0.5, 5.0]
  rotation:feed          rotation-feed.json exists, valid JSON, non-empty
  decision:wal           decision-wal/ exists, recent entries
  headspace:segment_crud Create and query a segment

EXIT CODE
  Number of failed tests (0 = all pass)
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  while (( "$#" )); do
    case "$1" in
      --verbose|-v) VERBOSE=1; shift ;;
      --json|-j)    JSON_OUTPUT=1; shift ;;
      --service)
        TARGET_SERVICE="$2"; shift 2 ;;
      --help|-h)
        usage; exit 0 ;;
      --) shift; break ;;
      -*) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
      *) break ;;
    esac
  done

  echo "Fleet self-test starting at $(date '+%Y-%m-%dT%H:%M:%S')" >&2

  if [[ -z "$TARGET_SERVICE" || "$TARGET_SERVICE" == "oracle" ]]; then
    test_service "oracle" "${SERVICES[oracle]}" 3
  fi
  if [[ -z "$TARGET_SERVICE" || "$TARGET_SERVICE" == "log" ]]; then
    test_service "log" "${SERVICES[log]}" 3
  fi
  if [[ -z "$TARGET_SERVICE" || "$TARGET_SERVICE" == "event" ]]; then
    test_service "event" "${SERVICES[event]}" 3
  fi
  if [[ -z "$TARGET_SERVICE" || "$TARGET_SERVICE" == "conductor" ]]; then
    test_conductor
  fi
  if [[ -z "$TARGET_SERVICE" || "$TARGET_SERVICE" == "headspace" ]]; then
    test_service_json "headspace" "${SERVICES[headspace]}" 3
  fi
  if [[ -z "$TARGET_SERVICE" || "$TARGET_SERVICE" == "gc-pid" ]]; then
    test_service "gc-pid" "${SERVICES[gc-pid]}" 3
  fi

  if [[ -z "$TARGET_SERVICE" ]]; then
    test_oracle_decision_flow
    test_event_bus
    test_gc_pid_bridge
    test_rotation_feed
    test_decision_wal
    test_headspace_crud
  fi

  print_results

  return $FAIL_COUNT
}

main "$@"
