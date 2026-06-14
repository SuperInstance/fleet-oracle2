#!/usr/bin/env bash
# init-agent.sh — New agent initialization on the fleet
# Usage: init-agent.sh [--quiet] [--register <agent-name>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="/home/ubuntu/.openclaw/workspace/construct/registry"
SERVICES_FILE="${REGISTRY_DIR}/services.json"
FLEET_OS="${REGISTRY_DIR}/../../FLEET_OS.md"

QUIET=false
AGENT_NAME=""

# ── Helpers ────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: init-agent.sh [options]

Options:
  --quiet           Suppress welcome banner
  --register <name> Register this agent with the fleet
  -h, --help        Show this help

EOF
    exit 1
}

print_banner() {
    local data
    data=$(cat "${SERVICES_FILE}" 2>/dev/null || echo "{}")

    local count
    count=$(echo "${data}" | jq 'length' 2>/dev/null || echo "0")

    local services
    services=$(echo "${data}" | jq -r 'to_entries[] | "  • \(.key) → localhost:\(.value.port)"' 2>/dev/null | tr '\n' ',' | sed 's/,/  /g')

    cat <<EOF
╔══════════════════════════════════════════════════════════════╗
║              FLEET OS — AGENT INITIALIZATION                 ║
╠══════════════════════════════════════════════════════════════╣
║  Welcome, agent.                                            ║
║  Fleet services discovered: ${count}                              ║
${services:-  (none yet)}
╚══════════════════════════════════════════════════════════════╝
EOF
}

print_fleet_summary() {
    if [[ -f "${FLEET_OS}" ]]; then
        echo ""
        echo "═══ FLEET EXECUTIVE SUMMARY (FLEET_OS.md) ═══"
        echo ""
        # Print first 50 lines as executive summary
        head -n 50 "${FLEET_OS}"
        echo ""
    fi
}

register_self() {
    local name="$1"
    local port="${AGENT_PORT:-8795}"

    "${SCRIPT_DIR}/registry.sh" register "${name}" "${port}" \
        "$(jq -n --arg name "${name}" --arg host "$(hostname)" '{type: "agent", hostname: $host, name: $name}')" 2>/dev/null || \
        echo "Warning: Could not register agent (registry may be unavailable)"
}

# ── Parse Args ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)
            QUIET=true
            shift
            ;;
        --register)
            AGENT_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# ── Main ───────────────────────────────────────────────────────────────────

# Check if registry exists
if [[ ! -f "${SERVICES_FILE}" ]] || [[ ! -s "${SERVICES_FILE}" ]]; then
    echo "No registry found. Running fleet discovery..."
    "${SCRIPT_DIR}/discover-fleet.sh"
fi

# Register this agent if requested
if [[ -n "${AGENT_NAME}" ]]; then
    register_self "${AGENT_NAME}"
fi

# Print banner unless quiet
if [[ "${QUIET}" != "true" ]]; then
    print_banner
    print_fleet_summary
fi
