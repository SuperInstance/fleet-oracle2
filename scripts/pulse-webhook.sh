#!/usr/bin/env bash
#
# pulse-webhook.sh — Monitor conservation-meter ratio and fire alert bottles.
#
# Queries the conservation-meter at :8798/api/status and evaluates the
# γ/η ratio against configurable thresholds:
#
#   ratio <  3.0  → green (no alert)
#   ratio >= 3.0  → WARNING bottle to harbor-daemon
#   ratio >= 5.0  → ALARM bottle to harbor-daemon
#   burn_detected → BURN_ALERT bottle
#   confidence < 0.3 (from rotation-feed) → LOW_CONFIDENCE bottle
#
# Bottles are sent as newline-terminated JSON over TCP to the harbor
# daemon on port 8796.  All activity is logged to PULSE_WEBHOOK_LOG.
#
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
CONSERVATION_URL="${CONSERVATION_URL:-http://localhost:8798/api/status}"
HARBOR_HOST="${HARBOR_HOST:-127.0.0.1}"
HARBOR_PORT="${HARBOR_PORT:-8796}"
PULSE_WEBHOOK_LOG="${PULSE_WEBHOOK_LOG:-/tmp/pulse-webhook.log}"

RATIO_WARN="${RATIO_WARN:-3.0}"
RATIO_CRIT="${RATIO_CRIT:-5.0}"
CONFIDENCE_LOW="${CONFIDENCE_LOW:-0.3}"
BOTTLE_TTL_HOURS="${BOTTLE_TTL_HOURS:-1}"

# Rotation feed (for confidence extraction)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(dirname "$SCRIPT_DIR")"
ROTATION_FEED="${CONSTRUCT_DIR}/data/rotation-feed.json"

# ── Helpers ───────────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

log() { echo "[$(now_iso)] [pulse-webhook] $*" >> "$PULSE_WEBHOOK_LOG"; }

# ── Fetch conservation-meter status ───────────────────────────────────────────
fetch_status() {
  curl -sf --max-time 10 "$CONSERVATION_URL" 2>/dev/null
}

# ── Send a single bottle to harbor-daemon over TCP ────────────────────────────
# Bottle format matches harbor-daemon's expected Bottle struct.
send_harbor_bottle() {
  local alert_type="$1"   # e.g. RATIO_WARNING, RATIO_ALARM, BURN_ALERT, LOW_CONFIDENCE
  local alert_body="$2"   # human/machine-readable summary
  local priority="$3"     # 1-5

  local bottle_id
  bottle_id=$(uuid)
  local ts
  ts=$(now_iso)

  # Compute expiry
  local expires_at
  expires_at=$(python3 -c "
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
exp = now + timedelta(hours=${BOTTLE_TTL_HOURS})
print(exp.strftime('%Y-%m-%dT%H:%M:%SZ'))
")

  # Build bottle JSON — must contain the fields harbor-daemon expects:
  # uuid, sender, recipient, priority, type, payload, expires_at, hop_count
  local bottle
  bottle=$(python3 -c "
import json
b = {
    'uuid': '${bottle_id}',
    'type': '${alert_type}',
    'sender': 'pulse-webhook',
    'recipient': 'construct-fleet',
    'priority': ${priority},
    'payload': json.dumps({
        'alert': '${alert_type}',
        'body': '${alert_body}',
        'timestamp': '${ts}',
        'source': 'pulse-webhook'
    }),
    'expires_at': '${expires_at}',
    'hop_count': 0
}
print(json.dumps(b))
")

  # Send over TCP and read the response
  local resp
  resp=$(echo "$bottle" | nc -q 2 "$HARBOR_HOST" "$HARBOR_PORT" 2>/dev/null) || {
    log "ERROR: nc send to harbor-daemon failed"
    return 1
  }

  local harbor_status
  harbor_status=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "parse_error")

  if [[ "$harbor_status" == "ok" ]]; then
    log "BOTTLE SENT: ${alert_type} | id=${bottle_id} | ${alert_body} | harbor=${harbor_status}"
    return 0
  else
    local harbor_msg
    harbor_msg=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message','?'))" 2>/dev/null || echo "$resp")
    log "ERROR: Harbor rejected bottle ${bottle_id}: ${harbor_status} — ${harbor_msg}"
    return 1
  fi
}

# ── Extract latest combined_confidence from rotation-feed ─────────────────────
get_latest_confidence() {
  if [[ ! -f "$ROTATION_FEED" ]]; then
    echo "null"
    return
  fi

  python3 -c "
import json, sys
try:
    with open('${ROTATION_FEED}', 'r') as f:
        lines = f.readlines()
    if not lines:
        print('null')
        sys.exit(0)
    last = json.loads(lines[-1].strip())
    print(last.get('combined_confidence', 'null'))
except Exception:
    print('null')
" 2>/dev/null
}

# ── Main evaluation ───────────────────────────────────────────────────────────
main() {
  log "=== pulse-webhook check ==="

  # 1. Fetch conservation-meter status
  local status_json
  status_json=$(fetch_status) || {
    log "ERROR: Failed to fetch ${CONSERVATION_URL}"
    return 1
  }

  # 2. Extract key fields
  local ratio burn_detected
  ratio=$(echo "$status_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ratio','null'))" 2>/dev/null || echo "null")
  burn_detected=$(echo "$status_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('burn_detected','null'))" 2>/dev/null || echo "null")

  if [[ "$ratio" == "null" ]]; then
    log "ERROR: Could not parse ratio from conservation-meter response"
    return 1
  fi

  local current_c
  current_c=$(echo "$status_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('current_c','?'))" 2>/dev/null || echo "?")

  log "Conservation status: ratio=${ratio}, C=${current_c}, burn_detected=${burn_detected}"

  # 3. Priority: burn_detected → ALARM first
  if [[ "$burn_detected" == "true" ]]; then
    log "BURN DETECTED — firing BURN_ALERT bottle"
    send_harbor_bottle "BURN_ALERT" "burn_detected=true ratio=${ratio} C=${current_c}" 5 || true
    # Don't return — also check ratio thresholds
  fi

  # 4. Ratio thresholds (use python for float comparison)
  local alert_level
  alert_level=$(python3 -c "
ratio = float('${ratio}')
warn = float('${RATIO_WARN}')
crit = float('${RATIO_CRIT}')
if ratio >= crit:
    print('ALARM')
elif ratio >= warn:
    print('WARNING')
else:
    print('OK')
")

  case "$alert_level" in
    ALARM)
      log "Ratio ${ratio} >= ${RATIO_CRIT} — firing RATIO_ALARM bottle"
      send_harbor_bottle "RATIO_ALARM" "ratio=${ratio} C=${current_c} threshold=${RATIO_CRIT}" 5 || true
      ;;
    WARNING)
      log "Ratio ${ratio} >= ${RATIO_WARN} — firing RATIO_WARNING bottle"
      send_harbor_bottle "RATIO_WARNING" "ratio=${ratio} C=${current_c} threshold=${RATIO_WARN}" 3 || true
      ;;
    *)
      log "Ratio ${ratio} < ${RATIO_WARN} — nominal (green)"
      ;;
  esac

  # 5. Confidence check (from rotation-feed, not conservation-meter)
  local confidence
  confidence=$(get_latest_confidence)
  if [[ "$confidence" != "null" ]]; then
    local conf_low
    conf_low=$(python3 -c "
conf = float('${confidence}')
low = float('${CONFIDENCE_LOW}')
print('true' if conf < low else 'false')
")
    if [[ "$conf_low" == "true" ]]; then
      log "Confidence ${confidence} < ${CONFIDENCE_LOW} — firing LOW_CONFIDENCE bottle"
      send_harbor_bottle "LOW_CONFIDENCE" "combined_confidence=${confidence} threshold=${CONFIDENCE_LOW}" 4 || true
    fi
  fi

  log "=== pulse-webhook check complete ==="
}

main "$@"

# ── Telegram alerting ─────────────────────────────────────────────────────────
# Sends an urgent message to the operator's Telegram via the gateway's bot token.
# Uses a shell-friendly POST to the Telegram Bot API.

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-8673869550:AAFydhVjoY1ML3kFh_H9HHDvxhM4ASbM6lY}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-8709904335}"
TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-true}"  # opt-in: set to true to enable
# Cooldown: prevent alert spam (max 1 per 30 min per alert type)
TELEGRAM_COOLDOWN_DIR="${TELEGRAM_COOLDOWN_DIR:-/tmp/construct-webhook-cooldown}"
mkdir -p "$TELEGRAM_COOLDOWN_DIR"

send_telegram() {
  local alert_type="$1"
  local message="$2"

  if [[ "$TELEGRAM_ENABLED" != "true" ]]; then
    return 0
  fi

  # Cooldown: skip if we sent this alert type within the last 30 minutes
  local cooldown_file="${TELEGRAM_COOLDOWN_DIR}/${alert_type}"
  if [[ -f "$cooldown_file" ]]; then
    local age
    age=$(($(date +%s) - $(stat -c %Y "$cooldown_file" 2>/dev/null || echo 0)))
    if [[ $age -lt 1800 ]]; then
      log "Telegram cooldown: ${alert_type} sent ${age}s ago (< 1800s)"
      return 0
    fi
  fi

  local payload
  payload=$(python3 -c "
import json
msg = '🔧 [Construct Stack]\\n'
msg += 'Alert: ${alert_type}\\n'
msg += '${message}'
print(json.dumps({'chat_id': '${TELEGRAM_CHAT_ID}', 'text': msg, 'parse_mode': 'HTML'}))
")

  local resp
  resp=$(curl -sf -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || {
    log "WARNING: Telegram send failed (muted)"
    return 1
  }

  # Touch cooldown file
  touch "$cooldown_file"
  log "Telegram sent: ${alert_type}"
}

# Override send_harbor_bottle to also send Telegram for high-priority alerts
# This wraps the existing function — alerts with priority >= 4 also go to Telegram.
_original_send_harbor_bottle() {
  send_harbor_bottle "$@"
}

send_harbor_bottle() {
  local alert_type="$1"
  local alert_body="$2"
  local priority="$3"

  # Call original
  _original_send_harbor_bottle "$alert_type" "$alert_body" "$priority"

  # Also send Telegram for priority >= 4 (ALARM, BURN)
  if [[ "$priority" -ge 4 ]] && [[ "$TELEGRAM_ENABLED" == "true" ]]; then
    send_telegram "$alert_type" "$alert_body"
  fi
}
