#!/usr/bin/env bash
# fleet-bootstrap.sh — Fleet OS Bootstrap
# Single entry point to initialize the fleet communication backbone

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="/home/ubuntu/.openclaw/workspace/construct/registry"
SERVICES_FILE="${REGISTRY_DIR}/services.json"
FLEET_OS="${REGISTRY_DIR}/../../FLEET_OS.md"
VERSION="0.1.0"

main() {
    echo "═══════════════════════════════════════════════════════════"
    echo "  Fleet OS v${VERSION} — Bootstrap"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # ── Step 1: Discover Fleet Services ────────────────────────────────────────
    echo "[1/4] Discovering fleet services..."
    "${SCRIPT_DIR}/discover-fleet.sh"
    echo ""

    # ── Step 2: Print Fleet Status Banner ───────────────────────────────────────
    echo "[2/4] Fleet Status"
    echo "───────────────────────────────────────────────────"

    if [[ -f "${SERVICES_FILE}" ]] && [[ -s "${SERVICES_FILE}" ]]; then
        local count
        count=$(jq 'length' "${SERVICES_FILE}" 2>/dev/null || echo "0")
        echo "  Services registered: ${count}"

        echo "  Service listing:"
        jq -r 'to_entries[] | "    • \(.key) → localhost:\(.value.port) [\(if .value.metadata.discovered then "discovered" else "registered" end)]"' \
            "${SERVICES_FILE}" 2>/dev/null || true
    else
        echo "  No services registered."
    fi
    echo ""

    # ── Step 3: Source FLEET_OS.md Summary ───────────────────────────────────────
    echo "[3/4] Fleet Executive Summary"
    echo "───────────────────────────────────────────────────"
    if [[ -f "${FLEET_OS}" ]]; then
        echo ""
        head -n 40 "${FLEET_OS}"
        echo ""
    else
        echo "  FLEET_OS.md not found. Run fleet init first."
        echo ""
    fi

    # ── Step 4: System Health Check ─────────────────────────────────────────────
    echo "[4/4] System Health"
    echo "───────────────────────────────────────────────────"

    # Disk
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5 " used (" $4 " available)"}')
    echo "  Disk: ${disk_usage}"

    # Memory
    local mem_info
    mem_info=$(free -h | awk 'NR==2 {print $3 " / " $2}')
    echo "  Memory: ${mem_info}"

    # Load
    local loadavg
    loadavg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "n/a")
    echo "  Load avg: ${loadavg}"

    # Uptime
    local uptime
    uptime=$(uptime -p 2>/dev/null || uptime)
    echo "  Uptime: ${uptime}"

    # Registry health
    echo ""
    echo "  Registry health:"
    "${SCRIPT_DIR}/registry.sh" health 2>/dev/null | sed 's/^/    /' || echo "    (health check unavailable)"
    echo ""

    # ── Final Report ─────────────────────────────────────────────────────────────
    local total
    total=$(jq 'length' "${SERVICES_FILE}" 2>/dev/null || echo "0")
    local pulse
    pulse=$(date -Iseconds)

    echo "═══════════════════════════════════════════════════════════"
    echo "  Fleet OS v${VERSION} — ${total} services registered"
    echo "  Status: OPERATIONAL"
    echo "  Last pulse: ${pulse}"
    echo "═══════════════════════════════════════════════════════════"
}

main "$@"
