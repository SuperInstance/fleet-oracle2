#!/usr/bin/env bash
# registry.sh — Fleet Service Registry CLI
# Usage: registry.sh <command> [args...]

set -euo pipefail

REGISTRY_DIR="/home/ubuntu/.openclaw/workspace/construct/registry"
SERVICES_FILE="${REGISTRY_DIR}/services.json"

# ── Helpers ────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: registry.sh <command> [args...]

Commands:
  register <service-name> <port> [metadata-json]
      Register a service. metadata-json is optional JSON object.

  unregister <service-name>
      Remove a service from the registry.

  list
      List all registered services.

  get <service-name>
      Get details for a specific service.

  health
      Ping each registered service and report status.

EOF
    exit 1
}

init_registry() {
    mkdir -p "${REGISTRY_DIR}"
    if [[ ! -f "${SERVICES_FILE}" ]]; then
        echo "{}" > "${SERVICES_FILE}"
    fi
}

jq_req() {
    command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }
}

read_registry() {
    if [[ ! -f "${SERVICES_FILE}" ]] || [[ ! -s "${SERVICES_FILE}" ]]; then
        echo "{}"
        return
    fi
    cat "${SERVICES_FILE}"
}

write_registry() {
    local data="$1"
    echo "${data}" > "${SERVICES_FILE}"
}

list_services() {
    init_registry
    local data
    data=$(read_registry)
    if [[ "${data}" == "{}" ]] || [[ -z "${data}" ]] || [[ "${data}" == "null" ]]; then
        echo "No services registered."
        return
    fi
    echo "${data}" | jq -r 'keys[]' 2>/dev/null || echo "${data}" | jq -r 'to_entries[] | .key'
}

get_service() {
    init_registry
    local name="$1"
    local data
    data=$(read_registry)
    local result
    result=$(echo "${data}" | jq -r ".[\"${name}\"] // null" 2>/dev/null)
    if [[ "${result}" == "null" ]]; then
        echo "Service '${name}' not found." >&2
        exit 1
    fi
    echo "${result}" | jq .
}

register_service() {
    init_registry
    jq_req
    local name="$1"
    local port="$2"
    local metadata
    if [[ $# -ge 3 ]] && [[ -n "$3" ]]; then
        metadata="$3"
    else
        metadata="{}"
    fi

    # Validate JSON if provided and not empty
    if [[ -n "${metadata}" ]] && [[ "${metadata}" != "{}" ]]; then
        echo "${metadata}" | jq . >/dev/null 2>&1 || {
            echo "Error: metadata must be valid JSON" >&2
            exit 1
        }
    else
        metadata="{}"
    fi

    local data
    data=$(read_registry)

    # Check if service already exists and preserve registered_at
    local registered_at
    registered_at=$(echo "${data}" | jq -r ".[\"${name}\"].registered_at // \"$(date -Iseconds)\"")

    local entry
    entry=$(jq -n \
        --arg name "${name}" \
        --arg port "${port}" \
        --arg host "localhost" \
        --arg protocol "http" \
        --arg endpoint "/api/status" \
        --arg reg "${registered_at}" \
        --argjson meta "${metadata}" \
        '{
            port: ($port | tonumber),
            host: $host,
            protocol: $protocol,
            health_endpoint: $endpoint,
            registered_at: $reg,
            metadata: $meta
        }')

    # Merge or create
    local new_data
    new_data=$(echo "${data}" | jq --arg name "${name}" --argjson entry "${entry}" \
        '.[$name] = $entry')

    write_registry "${new_data}"
    echo "Registered: ${name} on :${port}"
}

unregister_service() {
    init_registry
    jq_req
    local name="$1"
    local data
    data=$(read_registry)

    local exists
    exists=$(echo "${data}" | jq -r ".[\"${name}\"] // null")
    if [[ "${exists}" == "null" ]]; then
        echo "Service '${name}' not found." >&2
        exit 1
    fi

    local new_data
    new_data=$(echo "${data}" | jq --arg name "${name}" 'del(.[$name])')
    write_registry "${new_data}"
    echo "Unregistered: ${name}"
}

check_health() {
    init_registry
    jq_req
    local data
    data=$(read_registry)

    if [[ "${data}" == "{}" ]] || [[ -z "${data}" ]] || [[ "${data}" == "null" ]]; then
        echo "No services registered."
        return
    fi

    local count
    count=$(echo "${data}" | jq 'length')
    echo "Checking health of ${count} service(s)..."

    echo "${data}" | jq -r '
        to_entries[] |
        "  \(.key): " +
        (try
            (if (.value.protocol + "://" + .value.host + ":" + (.value.port | tostring) + .value.health_endpoint | if startswith("http") then . else "http://" + . end) as $url |
            $url | if contains("://") then . else "http://" + . end |
            (curl -sf --max-time 3 \(.) >/dev/null 2>&1 | if . == 0 then "HEALTHY" else "DOWN" end)
            ) // "DOWN"
        else "DOWN" end)
    ' 2>/dev/null || {
        # Fallback: try curl on each
        echo "${data}" | jq -r 'to_entries[] | "\(.key) \(.value.protocol)://\(.value.host):\(.value.port)\(.value.health_endpoint)"' 2>/dev/null | while read -r name url; do
            if curl -sf --max-time 3 "${url}" >/dev/null 2>&1; then
                echo "  ${name}: HEALTHY"
            else
                echo "  ${name}: DOWN"
            fi
        done
    }
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local cmd="$1"
    shift

    case "${cmd}" in
        register)
            [[ $# -ge 2 ]] || { echo "Error: register requires <name> <port> [metadata]" >&2; exit 1; }
            if [[ $# -ge 3 ]] && [[ -n "$3" ]]; then
                register_service "$1" "$2" "$3"
            else
                register_service "$1" "$2"
            fi
            ;;
        unregister)
            [[ $# -ge 1 ]] || { echo "Error: unregister requires <name>" >&2; exit 1; }
            unregister_service "$1"
            ;;
        list)
            list_services
            ;;
        get)
            [[ $# -ge 1 ]] || { echo "Error: get requires <name>" >&2; exit 1; }
            get_service "$1"
            ;;
        health)
            check_health
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
