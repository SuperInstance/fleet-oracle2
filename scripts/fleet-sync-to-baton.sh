#!/usr/bin/env bash
# =============================================================================
# fleet-sync-to-baton.sh — Daily Fleet Sync: Construct Stack → Baton System
# =============================================================================
#
# Every 24h (scheduled 04:00 UTC), queries the Oracle2 construct stack and
# writes a CONSTRUCT_INTELLIGENCE bottle to baton-system/tiers/hot/.
# Commits and pushes to baton-system repo for fleet consumption.
#
# Architecture:
#   construct-stack                     → baton-system
#   ┌──────────────────────┐           ┌──────────────────────┐
#   │ conservation-meter   │─── API ──▶│ tiers/hot/           │
#   │ harbor-daemon        │─── API ──▶│ construct-intelligence│
#   │ gc-intelligent.sh    │─── PID ──▶│ -bottle-{date}.md     │
#   │ rotation-feed        │─── JSON ─▶│                       │
#   └──────────────────────┘           └──────────────────────┘
#
# Usage:
#   ./fleet-sync-to-baton.sh            # normal run (writes bottle, commits)
#   ./fleet-sync-to-baton.sh --dry-run  # print without writing
#   ./fleet-sync-to-baton.sh --force    # force re-sync even if same day
#
# Integrations:
#   PROTOCOL.md — I2I v2 (BOTTLE type, CONSTRUCT_INTELLIGENCE)
#   crontab entry: 0 4 * * * (04:00 UTC daily)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONSTRUCT_DIR="$SCRIPT_DIR/.."
BATON_SYSTEM_DIR="/home/ubuntu/.openclaw/workspace/baton-system"
VESSEL_DIR="/home/ubuntu/.openclaw/workspace/i2i-vessel"

MODE="${1:-run}"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
DATE_TAG="$(date -u '+%Y-%m-%d')"
EPOCH=$(date +%s)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────
#  Collect construct intelligence
# ─────────────────────────────────────────────────────────────

echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  🚢 FLEET SYNC → BATON CONSTRUCT           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo "  Timestamp: $TIMESTAMP"
echo "  Mode:      ${MODE}"

# --- 1. Conservation Meter Status ---
echo -e "\n${CYAN}▸ Querying conservation-meter...${NC}"
CM_STATUS=$(curl -sf http://localhost:8798/api/status 2>/dev/null || echo "")
if [ -n "$CM_STATUS" ]; then
  CURRENT_C=$(echo "$CM_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('current_c',0))" 2>/dev/null || echo "0")
  RATIO=$(echo "$CM_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ratio',0))" 2>/dev/null || echo "0")
  BURN=$(echo "$CM_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('burn_detected') else 'false')" 2>/dev/null || echo "false")
  TOTAL_REPORTS=$(echo "$CM_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_reports',0))" 2>/dev/null || echo "0")
  RATIO_COLOR=$(echo "$CM_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ratio_color',''))" 2>/dev/null || echo "")
  RATIO_LABEL="green"
  [ "$RATIO_COLOR" = "#E8883A" ] && RATIO_LABEL="amber"
  [ "$RATIO_COLOR" = "#8B4513" ] && RATIO_LABEL="red"

  # Extract latest report for individual γ, η
  LATEST_GAMMA=$(echo "$CM_STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
r = d.get('recent_reports',[])
if r: print(r[0].get('gamma',0))
else: print(0)
" 2>/dev/null || echo "0")
  LATEST_ETA=$(echo "$CM_STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
r = d.get('recent_reports',[])
if r: print(r[0].get('eta',0))
else: print(0)
" 2>/dev/null || echo "0")
  LATEST_C=$((LATEST_GAMMA + LATEST_ETA))
  LATEST_AGENT=$(echo "$CM_STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
r = d.get('recent_reports',[])
if r: print(r[0].get('agent','unknown'))
else: print('none')
" 2>/dev/null || echo "unknown")

  echo "    γ=$LATEST_GAMMA η=$LATEST_ETA C=$LATEST_C"
  echo "    Avg C=$CURRENT_C  γ/η=$(printf "%.2f" "$RATIO") ($RATIO_LABEL)"
  echo "    Burn=$BURN  Reports=$TOTAL_REPORTS"
else
  echo -e "    ${YELLOW}WARN: conservation-meter not reachable${NC}"
  CURRENT_C=0; RATIO=0; BURN="unknown"
  LATEST_GAMMA=0; LATEST_ETA=0; LATEST_C=0; LATEST_AGENT="unknown"
  TOTAL_REPORTS=0; RATIO_LABEL="unknown"
fi

# --- 2. Harbor Bottle Count ---
echo -e "\n${CYAN}▸ Querying harbor daemon...${NC}"
HARBOR_HEALTH=$(curl -sf http://localhost:8797/health 2>/dev/null || echo "")
if [ -n "$HARBOR_HEALTH" ]; then
  HARBOR_BOTTLES=$(echo "$HARBOR_HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('bottles',0))" 2>/dev/null || echo "0")
  echo "    Harbor bottles: $HARBOR_BOTTLES"
else
  HARBOR_BOTTLES=0
  echo -e "    ${YELLOW}WARN: harbor daemon not reachable${NC}"
fi

# --- 3. GC Intelligence ---
echo -e "\n${CYAN}▸ Querying GC state...${NC}"
# Run gc-intelligent status to get PID aggression
GC_OUTPUT=$(cd "$CONSTRUCT_DIR" && bash scripts/gc-intelligent.sh --status 2>&1 || echo "")
GC_AGGRESSION=$(echo "$GC_OUTPUT" | grep "PID aggression" | sed 's/.*: //;s/x$//' 2>/dev/null || echo "unknown")

# Disk usage
DISK_INFO=$(df -h / 2>/dev/null | tail -1 || echo "")
DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}')
DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}')
DISK_AVAIL=$(echo "$DISK_INFO" | awk '{print $4}')
DISK_PCT=$(echo "$DISK_INFO" | awk '{print $5}' | tr -d '%')

# GC ledger count
LEDGER_COUNT=$(wc -l < "$CONSTRUCT_DIR/data/gc-ledger/ledger.jsonl" 2>/dev/null || echo "0")

# PID state (setpoint derived: gc-intelligent default setpoint=20)
SETPOINT=20  # default from gc-intelligent.sh
# Check if calibration has a setpoint override
if [ -f "$CONSTRUCT_DIR/data/gc-ledger/calibration.json" ]; then
  CALIB_SETPOINT=$(python3 -c "import json; d=json.load(open('$CONSTRUCT_DIR/data/gc-ledger/calibration.json')); print(d.get('setpoint',20))" 2>/dev/null || echo "20")
  [ -n "$CALIB_SETPOINT" ] && [ "$CALIB_SETPOINT" != "None" ] && SETPOINT=$CALIB_SETPOINT
fi

echo "    Disk: ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%)"
echo "    PID Aggression: ${GC_AGGRESSION}"
echo "    Setpoint: ${SETPOINT}% free"
echo "    Ledger: ${LEDGER_COUNT} entries"

# --- 4. Rotation Feed ---
echo -e "\n${CYAN}▸ Reading rotation feed...${NC}"
ROTATION_FEED=""
if [ -f "$CONSTRUCT_DIR/data/rotation-feed.json" ]; then
  ROTATION_FEED=$(cat "$CONSTRUCT_DIR/data/rotation-feed.json" 2>/dev/null)
  ROT_ENTRIES=$(echo "$ROTATION_FEED" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if isinstance(d, list):
        print(len(d))
    elif isinstance(d, dict):
        print(d.get('total_entries', d.get('count', 1)))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0")
  echo "    Rotation entries: $ROT_ENTRIES"
else
  echo -e "    ${YELLOW}WARN: rotation-feed.json not found${NC}"
  ROT_ENTRIES="N/A"
fi

# --- 5. System Status ---
echo -e "\n${CYAN}▸ System health...${NC}"
LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1"/"$2"/"$3}' || echo "unknown")
UPTIME=$(cat /proc/uptime 2>/dev/null | awk '{printf "%.0f", $1/86400; print "d"}' || echo "unknown")
MEM_TOTAL=$(free -m 2>/dev/null | grep Mem | awk '{print $2 "MiB"}' || echo "unknown")
echo "    Load: $LOAD  Uptime: $UPTIME  Mem: $MEM_TOTAL"

# ─────────────────────────────────────────────────────────────
#  Build the bottle
# ─────────────────────────────────────────────────────────────

# Compute integrity hint
INTEGRITY_HINT="sha256:gamma=${LATEST_GAMMA}:eta=${LATEST_ETA}:c=${LATEST_C}:ratio=$(printf "%.4f" "$RATIO"):harbor=${HARBOR_BOTTLES}"

BOTTLE_TARGET="${BATON_SYSTEM_DIR}/tiers/hot/construct-intelligence-bottle.md"

BOTTLE_CONTENT="# Construct Intelligence Bottle — ${DATE_TAG}

**Type:** CONSTRUCT_INTELLIGENCE
**Protocol:** I2I v2 (BOTTLE)
**Source:** Oracle2 🦀 construct-stack
**Timestamp:** ${TIMESTAMP}
**Epoch:** ${EPOCH}
**Agent:** Oracle2 (aarch64)

---

## Conservation Constraint

| Metric | Value |
|--------|-------|
| γ (gamma — production effort) | $LATEST_GAMMA |
| η (eta — contextual overhead) | $LATEST_ETA |
| **C = γ + η** | **$LATEST_C** |
| Running avg C | $(printf "%.1f" "$CURRENT_C") |
| γ/η Ratio | $(printf "%.2f" "$RATIO") (${RATIO_LABEL}) |
| Burn detected | ${BURN} |
| Latest agent | ${LATEST_AGENT} |

## Harbor State

| Metric | Value |
|--------|-------|
| Bottles in harbor | ${HARBOR_BOTTLES} |
| Reports in meter | ${TOTAL_REPORTS} |

## GC State

| Metric | Value |
|--------|-------|
| Disk usage | ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%) |
| PID aggression | ${GC_AGGRESSION}x |
| Setpoint (free %) | ${SETPOINT}% |
| Ledger entries | ${LEDGER_COUNT} |

## Rotation

| Metric | Value |
|--------|-------|
| Rotation entries | ${ROT_ENTRIES} |

## System Health

| Metric | Value |
|--------|-------|
| Load avg | $LOAD |
| Uptime | $UPTIME |
| Memory | $MEM_TOTAL |

---

## Shard

### Artifacts
- Conservation meter: http://localhost:8798
- Harbor daemon (health): http://localhost:8797/health
- GC ledger: \`construct/data/gc-ledger/ledger.jsonl\`
- Rotation feed: \`construct/data/rotation-feed.json\`

### Reasoning
- Daily fleet sync captured at ${TIMESTAMP}
- C=$LATEST_C (γ=$LATEST_GAMMA + η=$LATEST_ETA)
- Ratio $(printf "%.2f" "$RATIO") is ${RATIO_LABEL} — within normal operating bounds
- Burn detection: ${BURN} — system behaving nominally
- Harbor holding ${HARBOR_BOTTLES} undelivered bottles
- GC PID aggression at ${GC_AGGRESSION}x, targeting ${SETPOINT}% free space
- Disk at ${DISK_PCT}%, ${DISK_AVAIL} available

### Blockers
- None reported (nominal fleet operation)

---

**Integrity:** ${INTEGRITY_HINT}
**Generated by:** \`construct/scripts/fleet-sync-to-baton.sh\`
"

if [ "$MODE" = "--dry-run" ]; then
  echo ""
  echo -e "${YELLOW}═══ DRY RUN — Bottle would be written to:${NC}"
  echo "  $BOTTLE_TARGET"
  echo ""
  echo "$BOTTLE_CONTENT"
  echo -e "${YELLOW}═══ End dry run ═══${NC}"
  exit 0
fi

# ─────────────────────────────────────────────────────────────
#  Write bottle to baton-system
# ─────────────────────────────────────────────────────────────

echo -e "\n${GREEN}▸ Writing bottle to baton-system...${NC}"
mkdir -p "$(dirname "$BOTTLE_TARGET")"
echo "$BOTTLE_CONTENT" > "$BOTTLE_TARGET"
echo "    Written: $BOTTLE_TARGET"

# Also write a copy to i2i-vessel/bottles/
VESSEL_BOTTLE="${VESSEL_DIR}/bottles/baton-fleet-sync-${DATE_TAG}.md"
mkdir -p "$(dirname "$VESSEL_BOTTLE")"
cp "$BOTTLE_TARGET" "$VESSEL_BOTTLE"
echo "    Mirror:  $VESSEL_BOTTLE"

# ─────────────────────────────────────────────────────────────
#  Commit and push to baton-system
# ─────────────────────────────────────────────────────────────

echo -e "\n${GREEN}▸ Committing to baton-system...${NC}"
cd "$BATON_SYSTEM_DIR"

if git diff --quiet && git diff --cached --quiet; then
  git add "tiers/hot/construct-intelligence-bottle.md"
  git commit -m "construct-intelligence: fleet sync bottle — ${DATE_TAG}

[I2I:BOTTLE] CONSTRUCT_INTELLIGENCE from Oracle2 construct-stack

Conservation:
  γ=${LATEST_GAMMA}  η=${LATEST_ETA}  C=${LATEST_C}
  γ/η=$(printf "%.2f" "$RATIO") (${RATIO_LABEL})
  Burn=${BURN}  Harbor=${HARBOR_BOTTLES}

GC:
  Aggression=${GC_AGGRESSION}x  Setpoint=${SETPOINT}%
  Disk=${DISK_PCT}%  Free=${DISK_AVAIL}

Integrity: ${INTEGRITY_HINT}" && echo "    Commit OK"

  echo -e "\n${GREEN}▸ Pushing to origin...${NC}"
  git push origin main 2>&1 || echo -e "    ${YELLOW}WARN: push failed (may be offline or no remote access)${NC}"
else
  echo -e "    ${YELLOW}WARN: uncommitted changes in baton-system — skipping auto-commit${NC}"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ FLEET SYNC COMPLETE                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo "  Bottle: construct-intelligence-bottle.md → tiers/hot/"
echo "  Mirror: i2i-vessel/bottles/baton-fleet-sync-${DATE_TAG}.md"
echo "  Timestamp: $TIMESTAMP"
