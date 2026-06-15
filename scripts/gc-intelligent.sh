#!/usr/bin/env bash
# =============================================================================
# gc-intelligent.sh — Self-Aware Garbage Collection System v2
# =============================================================================
#
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  NOTICE: This copy lives in the construct repo for versioning.          ║
# ║  Live production file at workspace/scripts/gc-intelligent.sh             ║
# ║  Do NOT edit this copy for production — edit the live file instead.     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# Core philosophy:
#   "A garbage collector that cannot examine its own past mistakes
#    is doomed to repeat them."
#
# Architecture:
#   gc-intelligent.sh  ← orchestrator (this file)
#   gc-predictor.py    ← deep analytics engine (JSONL reader, trend/prediction)
#   data/gc-ledger/    ← decision ledger (JSONL)
#   data/gc-compost/   ← soft-delete heap with TTL
#   .gc-pin            ← per-path protection manifest
#
# Usage:
#   gc-intelligent.sh [--execute|--deep|--calibrate|--audit|--status|--register <path>]
#
#   --execute      Normal GC cycle (cold artifacts, idle .venv, logs)
#   --deep         Aggressive GC (+ package caches, journal vacuum)
#   --calibrate    Burn-in: establish PID baseline from historical data
#   --audit        Deep analysis of past GC patterns
#   --status       Dry-run + prediction report (default)
#   --register     Register a path as protected: --register <path>:tier
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/.."
DATA_DIR="$WORKSPACE/data/gc-ledger"
COMPOST_DIR="$WORKSPACE/data/gc-compost"
PINNING_FILE="$WORKSPACE/.gc-pin"
LEDGER_FILE="$DATA_DIR/ledger.jsonl"
TREND_DB="$DATA_DIR/trend.json"
PATTERN_DB="$DATA_DIR/patterns.json"
PID_STATE="$DATA_DIR/pid-state.json"  # Calibration store (fallback PID only)
SELF_LOG="$DATA_DIR/gc-intelligent.log"
CALIBRATION_FILE="$DATA_DIR/calibration.json"
PREDICTOR="$SCRIPT_DIR/gc-predictor.py"
MAX_LEDGER_LINES=50000
MAX_LOG_LINES=5000
WARN_PCT=20
CRIT_PCT=12

mkdir -p "$DATA_DIR" "$COMPOST_DIR"

MODE="${1:-dry-run}"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EPOCH=$(date +%s)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'

# ═══════════════════════════════════════════════════════════════
#  UTILITY
# ═══════════════════════════════════════════════════════════════

log_self() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$SELF_LOG"; }

ledger_entry() {
  local a="$1" i="$2" s="$3" r="$4" t="$5" ok="$6" f="${7:-0}"
  printf '{"ts":"%s","epoch":%d,"action":"%s","item":"%s","size_kb":%d,"reason":"%s","tier":"%s","success":%s,"freed_kb":%d}\n' \
    "$TIMESTAMP" "$EPOCH" "$a" "$i" "${s:-0}" "$r" "$t" "$ok" "$f" >> "$LEDGER_FILE"
}

mb2h() {
  local m="${1:-0}"; [ "$m" -ge 1048576 ] && echo "$((m/1048576)).$(((m%1048576)*10/1048576))TB" && return
  [ "$m" -ge 1024 ] && echo "$((m/1024)).$(((m%1024)*10/1024))G" || echo "${m}M"
}

emoji() { [ "$1" -ge 25 ] && echo "🟢"; [ "$1" -ge 15 ] && [ "$1" -lt 25 ] && echo "🟡"; [ "$1" -lt 15 ] && echo "🔴"; }

# ═══════════════════════════════════════════════════════════════
#  .gc-pin REGISTRY
# ═══════════════════════════════════════════════════════════════

load_pins() {
  cat <<'BUILTIN'
# Immortal
memory/*:immortal
MEMORY.md:immortal
SOUL.md:immortal
IDENTITY.md:immortal
USER.md:immortal
TOOLS.md:immortal
AGENTS.md:immortal
baton-system:immortal
i2i-vessel:immortal
zeroclaws:immortal
scripts:immortal
.git:immortal
secrets/:immortal
.gc-pin:immortal
data/gc-ledger:immortal
data/gc-compost:immortal
# Hot
pincher:hot
lever-runner:hot
fleet-conductor:hot
fleet-daemon:hot
# Patterns
*.service:immortal
.profile:immortal
.bashrc:immortal
BUILTIN
  [ -f "$PINNING_FILE" ] && grep -v '^#' "$PINNING_FILE" || true
}

check_pin() {
  local path="$1"
  while IFS=':' read -r pat tier; do
    pat="${pat// /}"; tier="${tier// /}"
    [ -z "$pat" ] || [ -z "$tier" ] && continue
    if [[ "$path" == *"$pat"* ]] || [[ "$path" == $pat ]]; then echo "$tier"; return 0; fi
  done < <(load_pins)
  echo ""
}

# ═══════════════════════════════════════════════════════════════
#  PID CONTROLLER — gc-pid-bridge (ARM-optimized Rust binary via ternary-pid)
# ═══════════════════════════════════════════════════════════════
# v1.2.0: Neoverse-N1 optimized, single-arg interface.
# Falls back to bash bc math if the bridge isn't available.

PID_BRIDGE="${PID_BRIDGE:-$(command -v gc-pid-bridge 2>/dev/null || echo '')}"

# PID: returns aggression multiplier (0.5..Kp, clamped to pid-state Kp or 5.0)
# Args: disk_pct, burn_rate, trend, setpoint, kp, ki, kd
#   (setpoint/ki/kd passed only to the Rust bridge for documentation;
#    bridge uses its own PID internals. Fallback bc math uses them directly.)
pid_calc() {
  local disk_pct="$1" burn_rate="$2" trend="$3"
  local setpoint="${4:-20}"
  local kp="${5:-5.0}" ki="${6:-0.5}" kd="${7:-0.2}"

  if [ -n "$PID_BRIDGE" ] && [ -x "$PID_BRIDGE" ]; then
    # v1.2.0+: single-argument interface — gc-pid-bridge <current_usage>
    # Bridge expects USED% (0=empty, 100=full), but gc-intelligent.sh historically
    # passes free% (e.g. from `df ... awk '$5'` gsub-ed). Invert if needed:
    #   - if disk_pct <= 100, treat as free% and convert to used% (100 - disk_pct)
    #   - this matches setpoint semantics (setpoint=20 = aim for 20% free)
    # v2.0.0 (2026-06-14): fix semantic bug — previously passed free% as if it were
    # used%, which inverted aggression. Now correctly normalize.
    local bridge_input="$disk_pct"
    if (( $(echo "$disk_pct <= 100" | bc -l 2>/dev/null || echo 0) )); then
      # Invert: free% → used% (bridge expects used% for setpoint=20 free-space PID)
      bridge_input=$(echo "scale=2; 100 - $disk_pct" | bc 2>/dev/null || echo "$disk_pct")
    fi
    local aggression
    aggression=$("$PID_BRIDGE" "$bridge_input" 2>/dev/null) || aggression=""

    if [ -n "$aggression" ]; then
      # Burn-rate boost for accelerating disk fills
      if [ "$trend" = "1" ] && [ -n "$burn_rate" ]; then
        local boost
        boost=$(echo "scale=4; $burn_rate * 0.0005" | bc -l 2>/dev/null || echo 0)
        aggression=$(echo "scale=4; $aggression + $boost" | bc -l 2>/dev/null || echo "$aggression")
        # Clamp to Kp ceiling
        (( $(echo "$aggression > $kp" | bc -l) )) && aggression="$kp"
      fi
      echo "$aggression"
      return 0
    fi
  fi

  # Fallback: bash bc math (stateless, simple proportional)
  local error; error=$(echo "scale=2; $setpoint - $disk_pct" | bc 2>/dev/null || echo 0)
  local output; output=$(echo "scale=3; ($kp*$error)" | bc -l 2>/dev/null || echo 1.0)
  [ "$trend" = "1" ] && output=$(echo "scale=3; $output+(${burn_rate:-0}*0.005)" | bc -l 2>/dev/null || echo "$output")
  (( $(echo "$output < 0.5" | bc -l) )) && output=0.5
  (( $(echo "$output > $kp" | bc -l) )) && output="$kp"
  echo "$output"
}

# ═══════════════════════════════════════════════════════════════
#  COMPOST HEAP (soft-delete with TTL)
# ═══════════════════════════════════════════════════════════════

compost_drop() {
  local src="$1" ttl="${2:-72}"
  local name; name=$(echo "$src" | tr '/' '_' | tr -d '[:space:]')
  local dst="$COMPOST_DIR/${name}__${EPOCH}"
  echo "$src" > "$dst.origin"
  local exp=$(( EPOCH + ttl * 3600 ))
  cat > "$dst.meta" << EOMETA
ttl_hours=$ttl
expire_epoch=$exp
moved_epoch=$EPOCH
source=$src
EOMETA
  mv "$src" "$dst" 2>/dev/null && return 0
  return 1
}

compost_expire() {
  local freed=0 now=$EPOCH
  for meta in "$COMPOST_DIR"/*.meta; do
    [ ! -f "$meta" ] && continue
    local exp; exp=$(grep '^expire_epoch=' "$meta" 2>/dev/null | cut -d= -f2 || echo 0)
    [ "$exp" -eq 0 ] && continue
    if [ "$now" -gt "$exp" ]; then
      local d="${meta%.meta}"
      if [ -f "$d" ]; then
        local sk; sk=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
        rm -f "$d" "$d.origin" "$meta" 2>/dev/null
        freed=$(( freed + sk ))
      else rm -f "$d.origin" "$meta" 2>/dev/null; fi
    fi
  done; echo "$freed"
}

compost_list() {
  echo -e "\n${CYAN}  ♻️  Compost Heap:${NC}"
  local tk=0 c=0
  for meta in "$COMPOST_DIR"/*.meta; do
    [ ! -f "$meta" ] && continue; c=$((c+1))
    local d="${meta%.meta}"
    local sk exp ttl src rm; sk=$(du -sk "$d" 2>/dev/null | awk '{print $1}' || echo 0)
    exp=$(grep '^expire_epoch=' "$meta" 2>/dev/null | cut -d= -f2 || echo 0)
    ttl=$(grep '^ttl_hours=' "$meta" 2>/dev/null | cut -d= -f2 || echo 0)
    src=$(cat "${d}.origin" 2>/dev/null || echo "?")
    rm=$(( (exp - EPOCH) / 3600 )); [ "$rm" -lt 0 ] && rm=0
    tk=$(( tk + sk ))
    echo -e "     📄 ${src##*/} — $(mb2h $((sk/1024))) (TTL ${ttl}h, ${rm}h left)"
  done
  [ "$c" -eq 0 ] && echo "     (empty)" || echo -e "     ${YELLOW}Total: $(mb2h $((tk/1024))) in ${c} items${NC}"
}

# ═══════════════════════════════════════════════════════════════
#  PHASE 1: SENSORS
# ═══════════════════════════════════════════════════════════════

phase_measure() {
  local du dt da; read -r du dt da <<< "$(df -m / | tail -1 | awk '{print $3,$2,$4}')"
  local pd=$(( (dt - du) * 100 / dt ))
  local ri; ri=$(free -m | tail -2 | head -1 | awk '{print $3,$2,$7}')
  local lo; lo=$(cat /proc/loadavg | awk '{print $1,$2,$3}')
  local ic; ic=$(emoji "$pd")
  echo -e "${BLUE}═══ PHASE 1: SENSORS ═══${NC}"
  echo -e "  ${ic} Disk: ${pd}% free | ${da}M avail / ${dt}M total"
  echo -e "  🧠 RAM:  $(echo "$ri" | awk '{print $1}')M/$(echo "$ri" | awk '{print $2}')M used"
  echo -e "  ⚡ Load: $lo"
  # Data line for consumers — tagged so main() can pick it out
  echo "DATA:$da $dt $pd"
}

# ═══════════════════════════════════════════════════════════════
#  PHASE 2: DISCERN (via Python predictor)
# ═══════════════════════════════════════════════════════════════

phase_discern() {
  echo -e "\n${BLUE}═══ PHASE 2: DISCERN — Pattern Analysis ═══${NC}"
  if [ ! -f "$PREDICTOR" ]; then echo "  Predictor not found"; echo "DATA:0 999 0"; return; fi
  local lc=0; [ -f "$LEDGER_FILE" ] && lc=$(wc -l < "$LEDGER_FILE") || true
  if [ "$lc" -lt 3 ]; then echo "  Not enough data ($lc entries, need ≥3)."; echo "DATA:0 999 0"; return; fi

  # Run predictor, capture both display and data
  export GC_LEDGER_FILE="$LEDGER_FILE" GC_TREND_DB="$TREND_DB" GC_PATTERN_DB="$PATTERN_DB"
  local pred_out; pred_out=$(python3 "$PREDICTOR" 2>&1) || true
  
  # Display lines (everything except DATA: lines)
  echo "$pred_out" | grep -v '^BURN_RATE:\|^HOURS_CRIT:\|^TREND:\|^DATA:' || true
  
  # Parse machine-readable output
  local burn=0 crit=999 trend=0
  while IFS= read -r line; do
    case "$line" in
      BURN_RATE:*) burn="${line#BURN_RATE:}" ;;
      HOURS_CRIT:*) crit="${line#HOURS_CRIT:}" ;;
      TREND:*) trend="${line#TREND:}" ;;
    esac
  done <<< "$pred_out"

  echo "DATA:$burn $crit $trend"
}

# ═══════════════════════════════════════════════════════════════
#  PHASE 3: EVICT
# ═══════════════════════════════════════════════════════════════

phase_evict() {
  local avail="$1" total="$2" pct="$3" aggr="$4" deep="${5:-false}"
  local execute=false; [ "$MODE" = "--execute" ] || [ "$MODE" = "--deep" ] && execute=true
  local tfk=0
  local base_age=86400
  local age_thresh; age_thresh=$(echo "scale=0; $base_age / $aggr" | bc 2>/dev/null || echo "$base_age")
  [ "$age_thresh" -lt 3600 ] && age_thresh=3600
  local dry_msg="🔍 Would evict (dry-run)"

  echo -e "\n${RED}═══ PHASE 3: EVICT (aggression: ${aggr}x) ═══${NC}"
  [ "$deep" = true ] && echo -e "  ${MAG}Deep mode — clearing caches${NC}"

  # ── Build artifacts ──
  echo -e "\n${YELLOW}  [Cold: Build Artifacts — age > $(($age_thresh/3600))h, >10M]${NC}"
  while IFS= read -r d; do
    [ -z "$d" ] || [ ! -d "$d" ] && continue
    local pi; pi=$(check_pin "$d"); [ -n "$pi" ] && echo -e "    ${GREEN}🔒 ${pi}: $d${NC}" && continue
    local sk; sk=$(du -sk "$d" 2>/dev/null | awk '{print $1}'); [ -z "$sk" ] && continue; [ "$sk" -lt 10240 ] && continue
    local mt; mt=$(stat -c "%Y" "$d" 2>/dev/null || echo 0); local ag=$(( EPOCH - mt )); [ "$ag" -lt "$age_thresh" ] && continue
    local pa; pa=$(dirname "$d" 2>/dev/null || echo "")
    [ -n "$pa" ] && [ -d "$pa/.git" ] && local lg; lg=$(cd "$pa" && git log -1 --format="%at" 2>/dev/null || echo 0) && [ $((EPOCH - lg)) -lt 43200 ] && echo -e "    ${CYAN}🕐 Active: $d${NC}" && continue
    local sh; sh=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    echo -e "    ${RED}🗑  $sh — ${d##*/}${NC} (age $((ag/3600))h)"
    ledger_entry "evict" "$d" "$sk" "stale-build-artifact" "cold" "true"
    if $execute; then
      if compost_drop "$d" 72; then echo -e "      ${YELLOW}♻️  Composted (72h TTL)${NC}"
      else rm -rf "$d" 2>/dev/null && echo -e "      ${GREEN}✅ Evicted${NC}" || echo -e "      ${RED}❌ Failed${NC}"; fi
      tfk=$(( tfk + sk ))
    else echo -e "      ${YELLOW}$dry_msg${NC}"; fi
  done < <(find /tmp /home/ubuntu -maxdepth 6 \( -name "target" -o -name "dist" -o -name "build" -o -name "node_modules" \) -type d -size +10M 2>/dev/null | sort -u || true)

  # ── Idle .venv ──
  echo -e "\n${YELLOW}  [Cold: Idle .venv >100M]${NC}"
  while IFS= read -r d; do
    [ -z "$d" ] || [ ! -d "$d" ] && continue
    local pi; pi=$(check_pin "$d"); [ -n "$pi" ] && continue
    local sk; sk=$(du -sk "$d" 2>/dev/null | awk '{print $1}'); [ -z "$sk" ] && continue; [ "$sk" -lt 102400 ] && continue
    local sn; sn=$(basename "$(dirname "$d")" 2>/dev/null || echo "")
    if systemctl is-active --quiet "${sn}.service" 2>/dev/null || systemctl is-active --quiet "${sn}-*.service" 2>/dev/null; then echo -e "    ${GREEN}🔒 Active: $d${NC}"; continue; fi
    local mt; mt=$(stat -c "%Y" "$d" 2>/dev/null || echo 0); [ $((EPOCH - mt)) -lt 604800 ] && echo -e "    ${CYAN}🕐 Recent: $d${NC}" && continue
    local sh; sh=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    echo -e "    ${RED}🗑  $sh — ${d##*/}${NC}"
    ledger_entry "evict" "$d" "$sk" "idle-venv" "cold" "true"
    if $execute; then rm -rf "$d" 2>/dev/null && tfk=$(( tfk + sk )) && echo -e "      ${GREEN}✅ Evicted${NC}" || echo -e "      ${RED}❌ Failed${NC}"
    else echo -e "      ${YELLOW}$dry_msg${NC}"; fi
  done < <(find /home/ubuntu -maxdepth 4 -name ".venv" -type d -size +100M 2>/dev/null | sort -u || true)

  # ── Deep: Package caches ──
  if [ "$deep" = true ]; then
    echo -e "\n${MAG}  [Deep: Package Caches]${NC}"
    for entry in "/home/ubuntu/.npm/_cacache:npm" "/home/ubuntu/.cache/pip:pip" "/home/ubuntu/.cargo/registry:cargo"; do
      local cd="${entry%%:*}" cn="${entry##*:}"
      [ ! -d "$cd" ] && continue
      local pi; pi=$(check_pin "$cd"); [ -n "$pi" ] && echo -e "    ${GREEN}🔒 Pinned: $cd${NC}" && continue
      local ck; ck=$(du -sk "$cd" 2>/dev/null | awk '{print $1}'); [ -z "$ck" ] || [ "$ck" -lt 10240 ] && continue
      local ch; ch=$(du -sh "$cd" 2>/dev/null | awk '{print $1}')
      echo -e "    ${RED}🗑  $ch — $cn cache${NC}"
      if $execute; then rm -rf "$cd" 2>/dev/null && tfk=$(( tfk + ck )) && echo -e "      ${GREEN}✅ Cleared${NC}" || echo -e "      ${RED}❌ Failed${NC}"
      else echo -e "      ${YELLOW}$dry_msg${NC}"; fi
      ledger_entry "evict" "$cd" "$ck" "cache-$cn" "cold" "true" "$ck"
    done
  fi

  # ── Journal ──
  echo -e "\n${YELLOW}  [System: Journal & Logs]${NC}"
  if $execute; then
    local bj; bj=$(du -sk /var/log/journal 2>/dev/null | awk '{print $1}' || echo 0)
    local vac="300M"; [ "$deep" = true ] && vac="200M"
    sudo journalctl --vacuum-size="$vac" 2>/dev/null || true
    sudo find /var/log \( -name "*.gz" -o -name "*.old" -o -name "*.1" \) -delete 2>/dev/null || true
    sudo truncate -s 0 /var/log/syslog 2>/dev/null || true
    local aj; aj=$(du -sk /var/log/journal 2>/dev/null | awk '{print $1}' || echo 0)
    local js=$(( bj - aj )); [ "$js" -lt 0 ] && js=0
    echo -e "    ${GREEN}✅ Recovered $(mb2h $((js/1024)))${NC}"
    tfk=$(( tfk + js )); ledger_entry "cleanup" "system-logs" "$js" "log-cleanup" "system" "true" "$js"
  else echo -e "    ${YELLOW}$dry_msg (journal vacuum)${NC}"; fi

  # ── Git pack GC ──
  echo -e "\n${YELLOW}  [Warm: Git Pack GC]${NC}"
  for d in "$WORKSPACE"/pincher-legacy-mine/*/; do
    [ ! -d "$d/.git" ] && continue
    local n; n=$(basename "$d"); local bk; bk=$(du -sk "$d/.git" 2>/dev/null | awk '{print $1}')
    echo -e "    📦 $n — $(du -sh "$d/.git" 2>/dev/null | awk '{print $1}')"
    if $execute; then
      (cd "$d" && git gc --aggressive --prune=now 2>/dev/null)
      local ak; ak=$(du -sk "$d/.git" 2>/dev/null | awk '{print $1}')
      local sv=$(( bk - ak ))
      if [ "$sv" -gt 0 ]; then
        echo -e "      ${GREEN}✅ Recovered $(mb2h $((sv/1024)))${NC}"
        tfk=$(( tfk + sv )); ledger_entry "gc-git" "$d/.git" "$sv" "git-pack-gc" "warm" "true" "$sv"
      else echo -e "      ${CYAN}Already optimized${NC}"; fi
    else echo -e "      ${YELLOW}🔍 Would GC (dry-run)${NC}"; fi
  done

  # ── Compost expiration ──
  echo -e "\n${YELLOW}  [Compost: Expire old soft-deletes]${NC}"
  local cf; cf=$(compost_expire)
  if $execute && [ "$cf" -gt 0 ]; then
    echo -e "    ${GREEN}✅ Hard-deleted $(mb2h $((cf/1024))) from compost${NC}"
    tfk=$(( tfk + cf ))
  elif [ "$cf" -gt 0 ]; then echo -e "    ${YELLOW}🔍 Would hard-delete $(mb2h $((cf/1024))) from compost${NC}"
  else echo -e "    ${CYAN}Nothing expired${NC}"; fi

  echo -e "\n${GREEN}────────────────────────────────────────${NC}"
  $execute && echo -e "${GREEN}  Total reclaimed: $(mb2h $((tfk/1024)))${NC}" || echo -e "${YELLOW}  Would reclaim: $(mb2h $((tfk/1024))) (dry-run)${NC}"
  echo -e "${GREEN}────────────────────────────────────────${NC}"
  echo "$tfk"
}

# ═══════════════════════════════════════════════════════════════
#  PHASE 4: SELF-AUDIT
# ═══════════════════════════════════════════════════════════════

phase_self_audit() {
  local exe=false; [ "$MODE" = "--execute" ] || [ "$MODE" = "--deep" ] && exe=true
  echo -e "\n${BLUE}═══ PHASE 4: SELF-AUDIT ═══${NC}"

  # Prune ledger
  local ll; ll=$(wc -l < "$LEDGER_FILE" 2>/dev/null || echo 0)
  if [ "$ll" -gt "$MAX_LEDGER_LINES" ]; then
    local rm=$(( ll - MAX_LEDGER_LINES ))
    echo -e "  ${YELLOW}Ledger: ${ll} lines > ${MAX_LEDGER_LINES}. Pruning ${rm} oldest.${NC}"
    if $exe; then tail -n "$MAX_LEDGER_LINES" "$LEDGER_FILE" > "$LEDGER_FILE.tmp" && mv "$LEDGER_FILE.tmp" "$LEDGER_FILE"
      ledger_entry "self-audit" "ledger" "$rm" "ledger-prune" "self" "true" "0"; echo -e "  ${GREEN}✅ Pruned${NC}"
    else echo -e "  ${YELLOW}🔍 Would prune${NC}"; fi
  else echo -e "  ${GREEN}Ledger: ${ll} entries (ok)${NC}"; fi

  # Prune self-log
  local sl; sl=$(wc -l < "$SELF_LOG" 2>/dev/null || echo 0)
  if [ "$sl" -gt "$MAX_LOG_LINES" ]; then
    echo -e "  ${YELLOW}Self-log: ${sl} lines > ${MAX_LOG_LINES}. Trimming.${NC}"
    if $exe; then tail -n "$MAX_LOG_LINES" "$SELF_LOG" > "$SELF_LOG.tmp" && mv "$SELF_LOG.tmp" "$SELF_LOG"
      echo -e "  ${GREEN}✅ Trimmed${NC}"; fi
  else echo -e "  ${GREEN}Self-log: ${sl} lines (ok)${NC}"; fi

  # Validate trend/pattern DBs
  for db in "$TREND_DB" "$PATTERN_DB"; do
    if [ -f "$db" ]; then
      python3 -c "import json; json.load(open('$db'))" 2>/dev/null && echo -e "  ${GREEN}${db##*/}: valid${NC}" || {
        echo -e "  ${RED}${db##*/}: corrupt — resetting${NC}"
        if $exe; then echo '{}' > "$db"; ledger_entry "self-audit" "${db##*/}" "0" "corrupt-db-reset" "self" "true"; fi
      }
    fi
  done

  # PID bridge check (gc-pid-bridge binary)
  if [ -n "$PID_BRIDGE" ] && [ -x "$PID_BRIDGE" ]; then
    echo -e "  ${GREEN}PID bridge: $PID_BRIDGE${NC}"
  else
    echo -e "  ${YELLOW}PID bridge: not found (will use bash fallback)${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════════
#  PHASE 5: SUMMARY
# ═══════════════════════════════════════════════════════════════

phase_summary() {
  local avail="$1" total="$2" pct="$3" freed="$4" agg="$5" burn="$6" crit="$7"
  local ic; ic=$(emoji "$pct")
  echo -e "\n${BLUE}═══ PHASE 5: SUMMARY ═══${NC}"
  echo -e "  ${ic} Disk: ${pct}% free (${avail}M) — PID: ${agg}x aggression"
  echo -e "  ${ic} Reclaimed: $(mb2h $((freed/1024))) — Burn rate: ${burn} MB/h"
  [ "$crit" != "999" ] && echo -e "  ⏰ Predicted ${crit}h until 10% threshold"
  
  # Alert if critical
  if [ "$pct" -lt "$CRIT_PCT" ]; then
    echo -e "  ${RED}🚨 CRITICAL: disk at ${pct}% — below ${CRIT_PCT}% threshold${NC}"
    touch "$DATA_DIR/.gc-alert"
  elif [ "$pct" -lt "$WARN_PCT" ]; then
    echo -e "  ${YELLOW}⚠️  Warning: disk at ${pct}% — below ${WARN_PCT}%${NC}"
    touch "$DATA_DIR/.gc-alert"
  else
    rm -f "$DATA_DIR/.gc-alert" 2>/dev/null || true
  fi

  compost_list
  
  local ll; ll=$(wc -l < "$LEDGER_FILE" 2>/dev/null || echo 0)
  echo -e "  📊 Ledger: ${ll} entries | $(mb2h $(du -sk "$DATA_DIR" 2>/dev/null | awk '{print $1}')) GC metadata"
  echo "SUMMARY:${ic} Disk ${pct}% (${avail}M), reclaimed $(mb2h $((freed/1024))), PID ${agg}x, burn ${burn} MB/h, ${crit}h crit"
}

# ═══════════════════════════════════════════════════════════════
#  PHASE 6: FLEET SYNC
# ═══════════════════════════════════════════════════════════════

phase_fleet_sync() {
  echo -e "\n${BLUE}═══ PHASE 6: FLEET GC SYNC ═══${NC}"
  local bd="$WORKSPACE/baton-system"; [ ! -d "$bd" ] && echo "  No baton-system, skipping" && return
  local gf="$bd/tiers/hot/gc-intelligence-bottle.md"
  local ll; ll=$(wc -l < "$LEDGER_FILE" 2>/dev/null || echo 0)
  local di; di=$(df -h / | tail -1)

  # Build patterns section
  local patterns="(first run — building baseline)"
  if [ -f "$PATTERN_DB" ] && [ "$(wc -c < "$PATTERN_DB")" -gt 10 ]; then
    patterns=$(python3 -c "
import json
with open('$PATTERN_DB') as f:
    p = json.load(f)
for r in p.get('top_reasons', [])[:5]:
    print(f'- {r[\"reason\"]}: {r[\"count\"]}x')
" 2>/dev/null) || patterns="(unavailable)"
  fi

  cat > "$gf" <<-BOTTLE
# GC Intelligence Bottle — $(date -u '+%Y-%m-%d %H:%M UTC')

**Source:** Oracle2 gc-intelligent.sh v2  
**Type:** GC_SYNC  
**Status:** $(echo "$MODE" | tr -d '-')

## State
\`\`\`
$di
Ledger: ${ll} entries
PID aggression: $(grep '"last_adjustment"' "$PID_STATE" 2>/dev/null | grep -oP '[\d.]+' | tail -1 || echo "1.0")
\`\`\`

## Key Patterns
${patterns}

## Manifest
| File | Purpose |
|------|---------|
| scripts/gc-intelligent.sh | Orchestrator (shell — phases, compost, PID) |
| scripts/gc-predictor.py | Deep analytics (JSONL reader, trend, prediction) |

---

_Generated by gc-intelligent.sh v2_  
_The GC that knows it's a GC_
BOTTLE

  if [ -d "$bd/.git" ]; then
    (cd "$bd" && git add "$gf" && git commit -m "gc-intelligence: $(date -u '+%Y-%m-%d %H:%M UTC')" --allow-empty 2>/dev/null) || true
    echo -e "  ${GREEN}✅ Bottle committed: tiers/hot/gc-intelligence-bottle.md${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════

main() {
  local is_deep=false
  [ "$MODE" = "--deep" ] && is_deep=true

  echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  🔮 GC-INTELLIGENT v2 — Self-Aware GC    ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
  echo "  Mode: $MODE | Time: $TIMESTAMP"

  log_self "INFO" "GC run starting (mode=$MODE, deep=$is_deep)"
  ledger_entry "cycle-start" "gc-run" "0" "cycle-start-$MODE" "system" "true" "0"

  # Phase 1: Sensors
  local disk_data
  disk_data=$(phase_measure)
  local avail total pct
  avail=$(echo "$disk_data" | grep '^DATA:' | head -1 | cut -d: -f2 | cut -d' ' -f1)
  total=$(echo "$disk_data" | grep '^DATA:' | head -1 | cut -d: -f2 | cut -d' ' -f2)
  pct=$(echo  "$disk_data" | grep '^DATA:' | head -1 | cut -d: -f2 | cut -d' ' -f3)

  # Phase 2: Discern
  local discern_output
  discern_output=$(phase_discern)
  local burn_rate hours_crit trend
  burn_rate=$(echo "$discern_output" | grep '^DATA:' | head -1 | cut -d: -f2 | cut -d' ' -f1)
  hours_crit=$(echo "$discern_output" | grep '^DATA:' | head -1 | cut -d: -f2 | cut -d' ' -f2)
  trend=$(echo "$discern_output" | grep '^DATA:' | head -1 | cut -d: -f2 | cut -d' ' -f3)
  [ -z "$burn_rate" ] && burn_rate=0
  [ -z "$hours_crit" ] && hours_crit=999
  [ -z "$trend" ] && trend=0

  # Phase 2b: Swarm advisor (optional policy override)
  local advisor_setpoint advisor_deadband advisor_integral
  advisor_setpoint=""
  if command -v python3 &>/dev/null && [ -f "${WORKSPACE}/scripts/ternary-gc-advisor.py" ]; then
    local advisor_out
    advisor_out=$(python3 "${WORKSPACE}/scripts/ternary-gc-advisor.py" --recommend 2>/dev/null || echo '')
    if [ -n "$advisor_out" ]; then
      advisor_setpoint=$(echo "$advisor_out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('recommendation',{}).get('setpoint',20))" 2>/dev/null || echo "")
      advisor_deadband=$(echo "$advisor_out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('recommendation',{}).get('deadband',1.0))" 2>/dev/null || echo "")
      advisor_integral=$(echo "$advisor_out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('recommendation',{}).get('integral_limit',20.0))" 2>/dev/null || echo "")
      [ -n "$advisor_setpoint" ] && echo -e "  ${CYAN}Advisor: setpoint=${advisor_setpoint} deadband=${advisor_deadband:-1.0}${NC}"
    fi
  fi

  # Phase 2c: PID calc (with optional advisor override)
  local aggression
  # Load PID parameters from swarm-optimized state file
  local pid_kp="5.0" pid_ki="0.5" pid_kd="0.2"
  if [ -f "$PID_STATE" ]; then
    local pid_json
    pid_json=$(cat "$PID_STATE" 2>/dev/null || echo '')
    if [ -n "$pid_json" ]; then
      pid_kp=$(echo "$pid_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kp',5.0))" 2>/dev/null || echo "5.0")
      pid_ki=$(echo "$pid_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ki',0.5))" 2>/dev/null || echo "0.5")
      pid_kd=$(echo "$pid_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kd',0.2))" 2>/dev/null || echo "0.2")
    fi
  fi
  if [ -n "$advisor_setpoint" ]; then
    aggression=$(pid_calc "$pct" "$burn_rate" "$trend" "$advisor_setpoint" "$pid_kp" "$pid_ki" "$pid_kd")
  else
    aggression=$(pid_calc "$pct" "$burn_rate" "$trend" "20" "$pid_kp" "$pid_ki" "$pid_kd")
  fi
  echo -e "  🎛️  PID aggression: ${aggression}x"

  # Phase 3: Evict
  local freed_kb
  if [ "$MODE" = "--execute" ] || [ "$MODE" = "--deep" ]; then
    freed_kb=$(phase_evict "$avail" "$total" "$pct" "$aggression" "$is_deep")
  else
    freed_kb=$(phase_evict "$avail" "$total" "$pct" "$aggression" "$is_deep")
  fi
  freed_kb=$(echo "$freed_kb" | tail -1)

  # Phase 4: Self-audit
  phase_self_audit

  # Phase 5: Summary
  phase_summary "$avail" "$total" "$pct" "$freed_kb" "$aggression" "$burn_rate" "$hours_crit"

  # Phase 6: Fleet sync
  phase_fleet_sync

  ledger_entry "cycle-end" "gc-run" "0" "cycle-end-$MODE" "system" "true" "$freed_kb"
  log_self "INFO" "GC complete — freed $(mb2h $((freed_kb/1024)))"
}

# ═══════════════════════════════════════════════════════════════
#  CALIBRATE MODE — runs PID auto-tuning from historical data
# ═══════════════════════════════════════════════════════════════

calibrate_mode() {
  echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  🔧 CALIBRATE — PID Auto-Tuning           ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

  if [ ! -f "$LEDGER_FILE" ] || [ "$(wc -l < "$LEDGER_FILE")" -lt 5 ]; then
    echo "  Not enough ledger data for calibration. Run --execute a few times first."
    exit 0
  fi

  echo "  Analyzing ledger to determine optimal PID constants..."
  python3 <<-PYEOF 2>&1
import json, sys
from collections import defaultdict

entries = []
with open('$LEDGER_FILE') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            if e.get('epoch'): entries.append(e)
        except: pass

if len(entries) < 5:
    print("  Not enough entries")
    sys.exit(0)

# Find typical reclaim amount
evictions = [e for e in entries if e.get('freed_kb', 0) > 0]
if not evictions:
    print("  No evictions recorded — nothing to calibrate")
    sys.exit(0)

avg_freed_mb = sum(e['freed_kb'] for e in evictions) / len(evictions) / 1024

# Times between evictions
entries.sort(key=lambda e: e.get('epoch', 0))
gaps = []
for i in range(1, len(entries)):
    g = entries[i].get('epoch', 0) - entries[i-1].get('epoch', 0)
    if 0 < g < 86400: gaps.append(g)

avg_gap_s = sum(gaps) / max(len(gaps), 1)
avg_gap_h = avg_gap_s / 3600

# Compute Kp based on how quickly we need to respond
# If gaps are tight (frequent fills), higher Kp
if avg_gap_h < 4:
    Kp = 2.0
    Ki = 0.5
    Kd = 0.2
elif avg_gap_h < 12:
    Kp = 1.5
    Ki = 0.3
    Kd = 0.1
else:
    Kp = 1.0
    Ki = 0.2
    Kd = 0.05

print(f"  Avg recovery: {avg_freed_mb:.1f} MB per eviction")
print(f"  Avg time between cycles: {avg_gap_h:.1f}h")
print(f"  Recommended PID: Kp={Kp}, Ki={Ki}, Kd={Kd}")
print(f"  Setpoint: 20% free")

# Write calibration
with open('$CALIBRATION_FILE', 'w') as f:
    json.dump({
        'avg_freed_mb': round(avg_freed_mb, 1),
        'avg_cycle_gap_h': round(avg_gap_h, 1),
        'recommended_Kp': Kp,
        'recommended_Ki': Ki,
        'recommended_Kd': Kd,
        'total_evictions': len(evictions),
        'calibrated_at': '$TIMESTAMP'
    }, f, indent=2)

# Save calibration to pid-state (used by fallback only)
import os
pid_path = os.path.expanduser('$PID_STATE')
cal = {'Kp': Kp, 'Ki': Ki, 'Kd': Kd, 'setpoint': 20, 'calibration_runs': 1}
if os.path.exists(pid_path):
    with open(pid_path) as f:
        cal = json.load(f)
    cal['Kp'] = Kp
    cal['Ki'] = Ki
    cal['Kd'] = Kd
    cal['calibration_runs'] = cal.get('calibration_runs', 0) + 1
with open(pid_path, 'w') as f:
    json.dump(cal, f, indent=2)

print(f"\n  ✅ PID constants calibrated: Kp={Kp}, Ki={Ki}, Kd={Kd} (run #{cal['calibration_runs']})")
PYEOF
}

# ═══════════════════════════════════════════════════════════════
#  AUDIT MODE
# ═══════════════════════════════════════════════════════════════

audit_mode() {
  echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  🔍 GC AUDIT — Deep Pattern Analysis      ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

  if [ ! -f "$LEDGER_FILE" ] || [ "$(wc -l < "$LEDGER_FILE")" -lt 2 ]; then
    echo "  No ledger data yet. Run --execute first."
    exit 0
  fi

  export GC_LEDGER_FILE="$LEDGER_FILE"
  python3 "$PREDICTOR" audit 2>&1

  # Compost heap status
  local ck; ck=$(compost_list 2>/dev/null | tail -1)
  [ -n "$ck" ] && echo -e "\n  📦 Compost: $ck items" || true
}

# ═══════════════════════════════════════════════════════════════
#  REGISTER MODE
# ═══════════════════════════════════════════════════════════════

register_mode() {
  local entry="${2:-}"
  if [ -z "$entry" ] || [[ "$entry" != *:* ]]; then
    echo "Usage: $0 --register <path>:<tier>"
    echo "  e.g. $0 --register /path/to/my-project:immortal"
    echo "  Tiers: immortal, hot, warm, cold"
    exit 1
  fi
  local path="${entry%%:*}" tier="${entry##*:}"
  if [ "$tier" != "immortal" ] && [ "$tier" != "hot" ] && [ "$tier" != "warm" ] && [ "$tier" != "cold" ]; then
    echo "  Invalid tier '$tier'. Use: immortal, hot, warm, cold"
    exit 1
  fi
  echo "$path:$tier" >> "$PINNING_FILE"
  echo -e "  ${GREEN}✅ Registered $path as $tier in .gc-pin${NC}"
}

# ═══════════════════════════════════════════════════════════════
#  DISPATCH
# ═══════════════════════════════════════════════════════════════

case "${1:-}" in
  --execute)    main ;;
  --deep)       MODE="--deep"; main ;;
  --calibrate)  calibrate_mode ;;
  --audit)      audit_mode ;;
  --register)   register_mode "$@" ;;
  --status|--dry-run|"") main ;;
  *)
    echo "Usage: $0 [--execute|--deep|--calibrate|--audit|--status|--register]"
    echo ""
    [ -n "${1:-}" ] && echo "Unknown mode: $1"
    exit 1
    ;;
esac
