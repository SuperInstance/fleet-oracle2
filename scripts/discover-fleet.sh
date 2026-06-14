#!/usr/bin/env bash
# discover-fleet.sh — Scan host for fleet services and register them
# Scans port ranges 8780-8800 and 2160-2175

set -euo pipefail

REGISTRY_DIR="/home/ubuntu/.openclaw/workspace/construct/registry"
SERVICES_FILE="${REGISTRY_DIR}/services.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORTS_RANGE1="8780-8800"
PORTS_RANGE2="2160-2175"

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

# Get all listening ports in range from ss output
get_open_ports() {
    local range="$1"
    local start end
    start=${range%%-*}
    end=${range##*-}

    ss -tlnp 2>/dev/null | awk 'NR>1 {
        split($4, a, ":");
        port = a[length(a)];
        if (port >= '"${start}"' && port <= '"${end}"') print port
    }' | sort -n | uniq
}

# Probe a port for fleet service info
probe_port() {
    local port="$1"
    local url="http://localhost:${port}"

    # Try common health endpoints
    for endpoint in "/api/status" "/health" "/status" "/api/health" ""; do
        local target="${url}${endpoint}"
        local response
        response=$(curl -sf --max-time 2 "${target}" 2>/dev/null) && {
            # Try to extract service name from response
            local service_name=""
            if echo "${response}" | jq -e '.service // .name // .service_name // .app' >/dev/null 2>&1; then
                service_name=$(echo "${response}" | jq -r '.service // .name // .service_name // .app' 2>/dev/null)
            fi
            echo "${response}" | jq -n \
                --arg port "${port}" \
                --arg name "${service_name}" \
                --argjson resp "${response}" \
                '{port: ($port | tonumber), name: $name, response: $resp}'
            return 0
        }
    done
    return 1
}

discover_services() {
    init_registry
    jq_req

    echo "Discovering fleet services on ports ${PORTS_RANGE1}, ${PORTS_RANGE2}..."

    local all_ports=()
    while IFS= read -r port; do
        all_ports+=("$port")
    done < <(get_open_ports "${PORTS_RANGE1}")
    while IFS= read -r port; do
        all_ports+=("$port")
    done < <(get_open_ports "${PORTS_RANGE2}")

    if [[ ${#all_ports[@]} -eq 0 ]]; then
        echo "No open ports found in fleet ranges."
        return 0
    fi

    echo "Found ${#all_ports[@]} open port(s). Probing..."

    local discovered=()
    local data
    data=$(read_registry)

    for port in "${all_ports[@]}"; do
        echo -n "  Probing :${port}... " >&2
        local result
        if result=$(probe_port "${port}" 2>/dev/null); then
            local service_name
            service_name=$(echo "${result}" | jq -r '.name' 2>/dev/null)

            # If no name in response, try to infer from port
            if [[ -z "${service_name}" ]] || [[ "${service_name}" == "null" ]]; then
                service_name="fleet-$(echo "${port}" | tr -d ' ')"
            fi

            echo "found '${service_name}'" >&2

            local registered_at
            registered_at=$(date -Iseconds)

            local entry
            entry=$(jq -n \
                --arg port "${port}" \
                --arg host "localhost" \
                --arg protocol "http" \
                --arg endpoint "/api/status" \
                --arg reg "${registered_at}" \
                --argjson resp "$(echo "${result}" | jq '.response' 2>/dev/null)" \
                '{
                    port: ($port | tonumber),
                    host: $host,
                    protocol: $protocol,
                    health_endpoint: $endpoint,
                    registered_at: $reg,
                    metadata: {discovered: true, response: $resp}
                }')

            # Only add if not already registered with same port
            local existing
            existing=$(echo "${data}" | jq -r ".[\"${service_name}\"].port // empty")
            if [[ -z "${existing}" ]]; then
                data=$(echo "${data}" | jq --arg name "${service_name}" --argjson entry "${entry}" \
                    '.[$name] = $entry')
                discovered+=("${service_name} on :${port}")
            fi
        else
            echo "no response" >&2
        fi
    done

    write_registry "${data}"

    # Report
    local count=${#discovered[@]}
    if [[ ${count} -eq 0 ]]; then
        echo "Discovered 0 services."
    else
        local list
        list=$(IFS=,; echo "${discovered[*]}")
        echo "Discovered ${count} services: ${list}"
    fi
}

discover_services
