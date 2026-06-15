#!/usr/bin/env bash
#
# pulse-gamma-predictor.sh — Gamma spike/dip predictor wrapper.
#
# Calls gamma-predictor.py, then:
#   - SPIKE prediction → sends bottle to harbor (port 8796) + segment to headspace-rs
#   - DIP  prediction → same alert flow
#   - HIGH_PLATEAU   → lower-priority advisory
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
PREDICTOR="${SCRIPT_DIR}/gamma-predictor.py"
LOG_DIR="${CONSTRUCT_DIR}/logs"
HARBOR_HOST="127.0.0.1"
HARBOR_PORT=8796
HEADSPACE_URL="http://localhost:9090"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()   { echo "[$(now_iso)] [pulse-gamma-predictor] $*"; }
warn()  { echo "[$(now_iso)] [pulse-gamma-predictor] WARN: $*" >&2; }
uuid()  { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

main() {
  local ts
  ts=$(now_iso)
  log "=== Gamma Predictor Run ==="

  # Step 1: Run the predictor
  local prediction_json
  prediction_json="$("${PREDICTOR}" 2>/dev/null)" || {
    warn "gamma-predictor.py failed"
    return 1
  }

  local prediction
  prediction="$(echo "$prediction_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('prediction','ERROR'))")"
  local priority
  priority="$(echo "$prediction_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('alert_priority',0))")"
  local current_gamma
  current_gamma="$(echo "$prediction_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_gamma',0))")"
  local expected_gamma
  expected_gamma="$(echo "$prediction_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('expected_gamma',0))")"

  log "Prediction: ${prediction} (γ=${current_gamma}, expected=${expected_gamma}, priority=${priority})"

  # Step 2: Alert on actionable predictions
  if [[ "${prediction}" == "SPIKE" || "${prediction}" == "DIP" ]]; then
    local summary
    summary="gamma-prediction|${prediction}|γ=${current_gamma}|expected_γ=${expected_gamma}|$(now_iso)"

    # ── Send bottle to harbor-daemon ──────────────────────────────────────
    local bottle_payload
    bottle_payload="$(python3 -c "
import json, uuid
now = __import__('datetime').datetime.now(__import__('datetime').timezone.utc)
expires = (now + __import__('datetime').timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
bottle = {
    'uuid': str(uuid.uuid4()),
    'sender': 'gamma-predictor',
    'recipient': 'oracle2',
    'priority': 3 if '${prediction}' == 'DIP' else 5,
    'type': 'gamma_prediction',
    'payload': json.dumps({
        'prediction': '${prediction}',
        'current_gamma': ${current_gamma},
        'expected_gamma': ${expected_gamma},
    }),
    'expires_at': expires,
    'hop_count': 0
}
print(json.dumps(bottle))
")"

    if echo "$bottle_payload" | nc -q 1 "$HARBOR_HOST" "$HARBOR_PORT" 2>/dev/null | grep -q '"status":"ok"'; then
      log "Bottle sent to harbor-daemon: ${summary}"
    else
      warn "harbor-daemon unreachable on ${HARBOR_HOST}:${HARBOR_PORT}"
    fi

    # ── Post segment to headspace-rs ──────────────────────────────────────
    local headspace_payload
    headspace_payload="$(cat <<EOF
{
  "text": "${summary}",
  "embedding": [],
  "metadata": {
    "source": "gamma-predictor",
    "prediction": "${prediction}",
    "current_gamma": ${current_gamma},
    "expected_gamma": ${expected_gamma},
    "timestamp": "$(now_iso)"
  }
}
EOF
)"

    local hs_resp
    hs_resp="$(curl -sf --max-time 5 -X POST "${HEADSPACE_URL}/api/segment" \
      -H "Content-Type: application/json" \
      -d "$headspace_payload" 2>/dev/null)" || {
      warn "headspace-rs POST failed"
    }
    if [[ -n "${hs_resp:-}" ]]; then
      log "Segment posted to headspace-rs: $(echo "$hs_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null)"
    fi
  elif [[ "${prediction}" == "HIGH_PLATEAU" ]]; then
    # Lower-priority — just log, no bottle
    log "HIGH_PLATEAU advisory (γ=${current_gamma}): monitoring"
  fi

  log "=== Gamma Predictor Run complete ==="
}

main "$@"
