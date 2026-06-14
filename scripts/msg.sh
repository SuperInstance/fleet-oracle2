#!/usr/bin/env bash
# msg.sh — Fleet Message Bus CLI
# Usage: msg.sh <command> [args...]

set -euo pipefail

REGISTRY_DIR="/home/ubuntu/.openclaw/workspace/construct/registry"
SERVICES_FILE="${REGISTRY_DIR}/services.json"

EVENT_SERVICE="fleet-event"
LOG_SERVICE="fleet-log"
EVENT_PORT="${EVENT_PORT:-8782}"
LOG_PORT="${LOG_PORT:-8783}"
EVENT_HOST="${EVENT_HOST:-localhost}"
LOG_HOST="${LOG_HOST:-localhost}"

# ── Helpers ────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: msg.sh <command> [args...]

Commands:
  send <topic> <payload>
      Send an event to the fleet event bus.
      payload is JSON string or '-p <file>' to read from file.

  read <topic> [count]
      Read last N messages for a topic from fleet-log.
      Default count is 10.

  topics
      List known topics from fleet-log.

  status
      Check connection to fleet-event and fleet-log services.

  sub <topic>
      Subscribe to a topic. Polls every 5s, outputs JSONL to stdout.
      Ctrl-C to stop.

Examples:
  msg.sh send my-topic '{"msg":"hello"}'
  msg.sh read my-topic 5
  msg.sh topics
  msg.sh status
  msg.sh sub my-topic

EOF
    exit 1
}

# Resolve service port from registry or use defaults
resolve_port() {
    local service="$1"
    local default_port="$2"

    if [[ -f "${SERVICES_FILE}" ]] && [[ -s "${SERVICES_FILE}" ]]; then
        local port
        port=$(jq -r ".[\"${service}\"].port // empty" "${SERVICES_FILE}" 2>/dev/null || echo "")
        if [[ -n "${port}" ]] && [[ "${port}" != "null" ]]; then
            echo "${port}"
            return
        fi
    fi
    echo "${default_port}"
}

get_event_port() { resolve_port "${EVENT_SERVICE}" "${EVENT_PORT}"; }
get_log_port() { resolve_port "${LOG_SERVICE}" "${LOG_PORT}"; }

event_url() { echo "http://${EVENT_HOST}:$(get_event_port)/api/event"; }
log_url() { echo "http://${LOG_HOST}:$(get_log_port)/api/log"; }

status_check() {
    local name="$1"
    local url="$2"
    if curl -sf --max-time 3 "${url}" >/dev/null 2>&1; then
        echo "  ${name}: CONNECTED (${url})"
        return 0
    else
        echo "  ${name}: UNAVAILABLE (${url})"
        return 1
    fi
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_send() {
    local topic="$1"
    local payload="$2"

    local url
    url=$(event_url)

    local body
    body=$(jq -n \
        --arg topic "${topic}" \
        --argjson payload "$(echo "${payload}" | jq . 2>/dev/null || echo "\"${payload}\"")" \
        --arg ts "$(date -Iseconds)" \
        '{topic: $topic, payload: $payload, timestamp: $ts}')

    local response
    if response=$(curl -sf -X POST -H "Content-Type: application/json" \
        -d "${body}" "${url}/${topic}" 2>&1); then
        echo "Sent to ${topic}: ${response}"
    else
        echo "Error: Failed to send to ${url}/${topic}" >&2
        echo "${response}" >&2
        exit 1
    fi
}

cmd_read() {
    local topic="$1"
    local count="${2:-10}"

    local url
    url=$(log_url)

    local response
    if response=$(curl -sf -G --max-time 5 \
        --data-urlencode "topic=${topic}" \
        --data "count=${count}" \
        "${url}/read" 2>&1); then
        echo "${response}" | jq -r '.messages[] | @json' 2>/dev/null || echo "${response}"
    else
        echo "Error: Failed to read from ${url}/read" >&2
        echo "${response}" >&2
        exit 1
    fi
}

cmd_topics() {
    local url
    url=$(log_url)

    local response
    if response=$(curl -sf --max-time 5 "${url}/topics" 2>&1); then
        echo "Known topics:"
        echo "${response}" | jq -r '.topics[]' 2>/dev/null || echo "${response}" | jq .
    else
        echo "Error: Failed to get topics from ${url}/topics" >&2
        echo "${response}" >&2
        exit 1
    fi
}

cmd_status() {
    echo "Fleet Message Bus Status"
    echo "========================"

    local event_port log_port
    event_port=$(get_event_port)
    log_port=$(get_log_port)

    echo "Resolved ports: event=${event_port}, log=${log_port}"
    echo ""

    status_check "${EVENT_SERVICE}" "http://${EVENT_HOST}:${event_port}/api/event" || true
    status_check "${LOG_SERVICE}" "http://${LOG_HOST}:${log_port}/api/log" || true
}

cmd_sub() {
    local topic="$1"

    echo "Subscribing to '${topic}' (Ctrl-C to stop)..."

    while true; do
        local url
        url=$(log_url)

        local response
        if response=$(curl -sf -G --max-time 10 \
            --data-urlencode "topic=${topic}" \
            --data "poll=true" \
            "${url}/read" 2>/dev/null); then
            echo "${response}" | jq -r '.messages[] | @json' 2>/dev/null || true
        fi

        sleep 5
    done
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local cmd="$1"
    shift

    case "${cmd}" in
        send)
            [[ $# -ge 1 ]] || { echo "Error: send requires <topic> <payload>" >&2; exit 1; }
            cmd_send "$1" "${2:-{}}"
            ;;
        read)
            [[ $# -ge 1 ]] || { echo "Error: read requires <topic> [count]" >&2; exit 1; }
            cmd_read "$1" "${2:-10}"
            ;;
        topics)
            cmd_topics
            ;;
        status)
            cmd_status
            ;;
        sub)
            [[ $# -ge 1 ]] || { echo "Error: sub requires <topic>" >&2; exit 1; }
            cmd_sub "$1"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "Unknown command: ${cmd}" >&2
            usage
            ;;
    esac
}

main "$@"
