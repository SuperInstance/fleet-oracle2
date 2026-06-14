#!/usr/bin/env bash
# health.sh — Fleet backend health check
#
# Pings fleet-oracle (:8795), fleet-log (:8781), fleet-event (:8782)
# and emits one JSONL line per service plus a summary at the end.
#
# Usage: ./health.sh
#   Output: JSONL lines to stdout, summary to stderr at the end.
#
set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────────
ORACLE_HOST="localhost"
ORACLE_PORT="8795"
LOG_HOST="localhost"
LOG_PORT="8781"
EVENT_HOST="localhost"
EVENT_PORT="8782"

TIMEOUT_SECS=5

# ─── Helpers ───────────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ping_service() {
  local host="$1"
  local port="$2"
  local name="$3"

  local start end latency_ms http_code resp

  start=$(date -u +%s%3N)

  # Try /api/health first, fall back to /health for services with a different layout
  http_code=$(curl -sf \
    --max-time "$TIMEOUT_SECS" \
    -o /dev/null \
    -w "%{http_code}" \
    "http://${host}:${port}/api/health" 2>/dev/null)

  if [[ "$http_code" == "000" ]] || [[ "$http_code" =~ ^404$ ]]; then
    http_code=$(curl -sf \
      --max-time "$TIMEOUT_SECS" \
      -o /dev/null \
      -w "%{http_code}" \
      "http://${host}:${port}/health" 2>/dev/null) || http_code="000"
  fi

  end=$(date -u +%s%3N)
  latency_ms=$(( end - start ))

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    printf '{"service":"%s","status":"ok","latency_ms":%s,"time":"%s"}\n' \
      "$name" "$latency_ms" "$(now_iso)"
    return 0
  fi

  # For fleet-event: no GET health endpoint — probe with a lightweight POST event
  if [[ "$name" == "fleet-event" ]]; then
    start=$(date -u +%s%3N)
    http_code=$(curl -sf \
      --max-time "$TIMEOUT_SECS" \
      -o /dev/null \
      -w "%{http_code}" \
      -X POST \
      -H "Content-Type: application/json" \
      -d "{\"event_type\":\"health_check\",\"source\":\"health.sh\",\"payload\":\"{}\",\"ternary_merit\":0,\"timestamp\":\"$(now_iso)\"}" \
      "http://${host}:${port}/api/events" 2>/dev/null) || http_code="000"
    end=$(date -u +%s%3N)
    latency_ms=$(( end - start ))
  fi

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    printf '{"service":"%s","status":"ok","latency_ms":%s,"time":"%s"}\n' \
      "$name" "$latency_ms" "$(now_iso)"
    return 0
  else
    printf '{"service":"%s","status":"down","latency_ms":%s,"time":"%s","detail":"http_%s"}\n' \
      "$name" "$latency_ms" "$(now_iso)" "$http_code"
    return 1
  fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────
main() {
  local total=0 ok=0 down=0
  local line

  while IFS= read -r line; do
    total=$(( total + 1 ))
    echo "$line"
    if [[ "$line" == *'"status":"ok"'* ]]; then
      ok=$(( ok + 1 ))
    else
      down=$(( down + 1 ))
    fi
  done < <(
    ping_service "$ORACLE_HOST" "$ORACLE_PORT" "fleet-oracle" || true
    ping_service "$LOG_HOST"    "$LOG_PORT"    "fleet-log"    || true
    ping_service "$EVENT_HOST"  "$EVENT_PORT"  "fleet-event"  || true
  )

  echo
  if (( down == 0 )); then
    echo "[$(now_iso)] [health] SUMMARY: all ${total}/${total} services healthy" >&2
    exit 0
  else
    echo "[$(now_iso)] [health] SUMMARY: ${ok}/${total} healthy, ${down} DOWN" >&2
    exit 1
  fi
}

main "$@"