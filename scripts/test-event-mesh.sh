#!/usr/bin/env bash
#
# test-event-mesh.sh — Tests the fleet event pipeline:
#   Step 1: POST a test event to fleet-event at :8782
#   Step 2: Read it back from fleet-log at :8781
#   Writes full report to /tmp/event-mesh-test.log
#
set -euo pipefail

LOGFILE="/tmp/event-mesh-test.log"
FLEET_EVENT_URL="http://localhost:8782/api/event"
FLEET_LOG_URL="http://localhost:8781/api/query"

# ── Init log ──────────────────────────────────────────────────────────────────
echo "========================================" >> "$LOGFILE"
echo "Event Mesh Test — $(date -Iseconds)" >> "$LOGFILE"
echo "========================================" >> "$LOGFILE"

pass_count=0
fail_count=0

# ── Helper: record result ─────────────────────────────────────────────────────
record() {
    local step="$1"
    local status="$2"
    local detail="$3"
    echo "[$step] $status — $detail" >> "$LOGFILE"
    if [[ "$status" == "PASS" ]]; then
        ((pass_count++))
    else
        ((fail_count++))
    fi
}

# ── Step 1: POST test event to fleet-event :8782 ─────────────────────────────
echo "" >> "$LOGFILE"
echo "--- Step 1: POST to fleet-event :8782 ---" >> "$LOGFILE"

test_id="test-$(date +%s)-$$"
test_event=$(cat <<EOF
{
  "id": "$test_id",
  "topic": "rotation_feedback",
  "severity": "info",
  "message": "Event mesh test message",
  "payload": {
    "test": true,
    "timestamp": "$(date -Iseconds)"
  }
}
EOF
)

echo "Payload: $test_event" >> "$LOGFILE"

http_code=$(curl -s -o /tmp/event-mesh-post-response.json -w "%{http_code}" \
    -X POST "$FLEET_EVENT_URL" \
    -H "Content-Type: application/json" \
    -d "$test_event" \
    --max-time 10 2>/dev/null || echo "000")

response_body=$(cat /tmp/event-mesh-post-response.json 2>/dev/null || echo "")

if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "202" ]]; then
    echo "Response body: $response_body" >> "$LOGFILE"
    record "STEP1" "PASS" "fleet-event accepted event (HTTP $http_code)"
else
    echo "Response body: $response_body" >> "$LOGFILE"
    record "STEP1" "FAIL" "fleet-event rejected event (HTTP $http_code)"
fi

# ── Step 2: Query fleet-log at :8781 for our test event ─────────────────────
echo "" >> "$LOGFILE"
echo "--- Step 2: Query fleet-log :8781 for event ---" >> "$LOGFILE"

# Try fetching recent logs and search for our test_id
log_response=$(curl -s -X GET "${FLEET_LOG_URL}?topic=rotation_feedback&limit=10" \
    --max-time 10 2>/dev/null || echo "")

echo "Log response (first 500 chars): ${log_response:0:500}" >> "$LOGFILE"

if echo "$log_response" | grep -q "$test_id"; then
    record "STEP2" "PASS" "Event found in fleet-log (ID: $test_id)"
else
    # Fallback: try querying all recent events
    log_response_all=$(curl -s -X GET "${FLEET_LOG_URL}?limit=20" \
        --max-time 10 2>/dev/null || echo "")
    if echo "$log_response_all" | grep -q "$test_id"; then
        record "STEP2" "PASS" "Event found in fleet-log via fallback query (ID: $test_id)"
    else
        record "STEP2" "FAIL" "Event ID $test_id not found in fleet-log response"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "" >> "$LOGFILE"
echo "========================================" >> "$LOGFILE"
echo "SUMMARY: $pass_count passed, $fail_count failed" >> "$LOGFILE"
echo "========================================" >> "$LOGFILE"

# ── Console output ────────────────────────────────────────────────────────────
echo ""
echo "=== Event Mesh Test Results ==="
echo "STEP1 fleet-event POST  : $(grep '\[STEP1\]' "$LOGFILE" | tail -1)"
echo "STEP2 fleet-log query   : $(grep '\[STEP2\]' "$LOGFILE" | tail -1)"
echo "Overall                 : $pass_count PASS, $fail_count FAIL"
echo "Full report             : $LOGFILE"
echo ""