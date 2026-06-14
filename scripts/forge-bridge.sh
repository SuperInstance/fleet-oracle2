#!/usr/bin/env bash
# forge-bridge.sh — Wire forgemaster-shell into the construct fleet node.
#
# Checks whether forgemaster-shell is present (via state/.forge/ marker),
# exports fleet service endpoints as forge env vars, and writes a structured
# forge-context bundle that any agent can consume on cold-start.
#
# Usage:
#   bash construct/scripts/forge-bridge.sh          # check + bundle
#   bash construct/scripts/forge-bridge.sh --dry  # show what would be written
#   bash construct/scripts/forge-bridge.sh --env  # export env vars only

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSTRUCT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$(cd "$CONSTRUCT_DIR/.." && pwd)"
STATE_DIR="$WORKSPACE/state"
FORGE_STATE_DIR="$STATE_DIR/.forge"
FORGE_BUNDLE="${CONSTRUCT_DIR}/data/forge-bundle.json"
BATON_DIR="$WORKSPACE/baton-system"
HEADSPACERS_DIR="$WORKSPACE/headspace-rs"
REFLEX_DIR="$CONSTRUCT_DIR/reflex"

# ── Fleet service map ─────────────────────────────────────────────────────────
declare -A FLEET_PORTS=(
  [oracle]=8795
  [log]=8781
  [event]=8782
  [conductor]=8769
  [headspace-rs]=8800
  [headroom-proxy]=8788
)

# ── CLI ──────────────────────────────────────────────────────────────────────
DRY_RUN=0
ENV_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry|-n) DRY_RUN=1 ;;
    --env|-e) ENV_ONLY=1 ;;
    -h|--help)
      sed -n '4,18p' "$0"
      exit 0
      ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ok()   { echo "[forge-bridge] OK   $*"; }
warn() { echo "[forge-bridge] WARN $*"; }
info() { echo "[forge-bridge] INFO $*"; }

# ── Step 1: Detect forgemaster-shell ─────────────────────────────────────────
hdr() { echo ""; echo "=== $* ==="; }

hdr "Forgemaster Detection"
if [ -d "$FORGE_STATE_DIR" ] && [ -f "$FORGE_STATE_DIR/CONTEXT.md" ]; then
  ok "forgemaster-shell detected (state/.forge/CONTEXT.md present)"
  FORGE_INSTALLED=1
else
  warn "forgemaster-shell not detected. Run scripts/forge-apply.sh first."
  FORGE_INSTALLED=0
fi

# ── Step 2: Export fleet env vars ────────────────────────────────────────────
hdr "Fleet Environment Variables"
for svc in "${!FLEET_PORTS[@]}"; do
  port="${FLEET_PORTS[$svc]}"
  # Use eval-safe assignment: uppercase key, strip hyphens for var name
  var_name="FORGE_${svc^^}"
  var_name="${var_name//-/_}"   # headspace-rs → FORGE_HEADSPACE_RS
  export "$var_name=http://localhost:${port}"
  ok "$var_name=http://localhost:${port}"
done

# Also export gc-pid-bridge path
if [ -x "$WORKSPACE/gc-pid-bridge/target/release/gc-pid-bridge" ]; then
  export FORGE_GC_PID_BRIDGE="$WORKSPACE/gc-pid-bridge/target/release/gc-pid-bridge"
elif command -v gc-pid-bridge &>/dev/null; then
  export FORGE_GC_PID_BRIDGE="$(command -v gc-pid-bridge)"
else
  export FORGE_GC_PID_BRIDGE=""
fi
ok "FORGE_GC_PID_BRIDGE=${FORGE_GC_PID_BRIDGE:-<not found>}"

# Export baton hot tier path
export FORGE_BATON_HOT="$BATON_DIR/tiers/hot"
ok "FORGE_BATON_HOT=${FORGE_BATON_HOT}"

# Export headspace-rs vector store
HS_PORT="${FLEET_PORTS[headspace-rs]}"
export FORGE_HEADSPACE_RS="http://localhost:${HS_PORT}"
ok "FORGE_HEADSPACE_RS=${FORGE_HEADSPACE_RS}"

if [ "$ENV_ONLY" = 1 ]; then
  ok "Env vars exported. Exiting (--env mode)."
  exit 0
fi

# ── Step 3: Collect forge context bundle ─────────────────────────────────────
hdr "Forge Context Bundle"

# Last baton flush timestamp (most recent hot tier file)
BATON_FLUSH_TS="null"
if [ -d "$BATON_DIR/tiers/hot" ]; then
  latest_hot=$(find "$BATON_DIR/tiers/hot" -maxdepth 1 -type f -name "*.md" -o -name "*.i2i.md" 2>/dev/null |
               xargs ls -t 2>/dev/null | head -1)
  if [ -n "$latest_hot" ] && [ -f "$latest_hot" ]; then
    BATON_FLUSH_TS=$(stat -c %Y "$latest_hot" 2>/dev/null | xargs -I{} date -u -d @{} +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "null")
  fi
fi

# GC PID config
PID_KP="10.00" PID_KI="1.00" PID_KD="0.10"
if [ -f "$WORKSPACE/state/.forge/forging-log.md" ]; then
  last_adj=$(grep -A2 "Meta-GC Adjustment" "$WORKSPACE/state/.forge/forging-log.md" 2>/dev/null | tail -6 | grep -oP "Kp=\K[0-9.]+|Ki=\K[0-9.]+|Kd=\K[0-9.]+" | head -3)
  if [ -n "$last_adj" ]; then
    PID_KP=$(echo "$last_adj" | head -1)
    PID_KI=$(echo "$last_adj" | sed -n '2p')
    PID_KD=$(echo "$last_adj" | sed -n '3p')
  fi
fi

# Active reflexes list
ACTIVE_REFLEXES="[]"
if [ -f "$REFLEX_DIR/reflexes.json" ]; then
  ACTIVE_REFLEXES=$(cat "$REFLEX_DIR/reflexes.json" 2>/dev/null || echo "[]")
elif [ -d "$REFLEX_DIR" ]; then
  reflex_names=$(find "$REFLEX_DIR" -maxdepth 1 -name "*.md" -o -name "*.json" 2>/dev/null |
                 xargs -I{} basename {} 2>/dev/null | grep -v REFLEX_DESIGN | sort)
  if [ -n "$reflex_names" ]; then
    ACTIVE_REFLEXES=$(echo "$reflex_names" | python3 -c "import json,sys; names=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(names))" 2>/dev/null || echo "[]")
  fi
fi

# Rotation feed entry count
ROTATION_COUNT=0
if [ -f "$CONSTRUCT_DIR/data/rotation-feed.json" ]; then
  ROTATION_COUNT=$(wc -l < "$CONSTRUCT_DIR/data/rotation-feed.json" 2>/dev/null || echo 0)
fi

# Headspace-rs status
HEADSPACE_STATUS="unknown"
if curl -sf --max-time 2 "http://localhost:${FLEET_PORTS[headspace-rs]}/health" &>/dev/null; then
  HEADSPACE_STATUS="ok"
elif curl -sf --max-time 2 "http://localhost:${FLEET_PORTS[headspace-rs]}/api/health" &>/dev/null; then
  HEADSPACE_STATUS="ok"
else
  HEADSPACE_STATUS="unreachable"
fi

# Service health summary
declare -A SERVICE_HEALTH
for svc in "${!FLEET_PORTS[@]}"; do
  port="${FLEET_PORTS[$svc]}"
  http_code=$(curl -sf --max-time 2 -o /dev/null -w "%{http_code}" "http://localhost:${port}/api/health" 2>/dev/null ||
              curl -sf --max-time 2 -o /dev/null -w "%{http_code}" "http://localhost:${port}/health" 2>/dev/null ||
              echo "000")
  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    SERVICE_HEALTH[$svc]="ok"
  else
    SERVICE_HEALTH[$svc]="down"
  fi
done

# Build JSON bundle via Python (avoids bash heredoc quoting issues)
BUNDLE=$(python3 - <<'PYEOF'
import os, json, subprocess, urllib.request, urllib.error, datetime, re

WORKSPACE = os.environ.get('WORKSPACE', '/home/ubuntu/.openclaw/workspace')
BATON_DIR = os.path.join(WORKSPACE, 'baton-system')
FORGE_STATE_DIR = os.path.join(WORKSPACE, 'state', '.forge')
CONSTRUCT_DIR = os.path.join(WORKSPACE, 'construct')
REFLEX_DIR = os.path.join(CONSTRUCT_DIR, 'reflex')
FORGE_INSTALLED = os.path.isdir(FORGE_STATE_DIR) and os.path.isfile(os.path.join(FORGE_STATE_DIR, 'CONTEXT.md'))

FLEET_PORTS = {'oracle': 8795, 'log': 8781, 'event': 8782, 'conductor': 8769, 'headspace-rs': 8800, 'headroom-proxy': 8788}

# Generated timestamp
ts = subprocess.check_output(['date', '-u', '+%Y-%m-%dT%H:%M:%SZ']).decode().strip()


# Last baton flush
baton_flush_ts = None
hot_tier = os.path.join(BATON_DIR, 'tiers', 'hot')
if os.path.isdir(hot_tier):
    files = [(f, os.path.getmtime(os.path.join(hot_tier, f)))
             for f in os.listdir(hot_tier)
             if f.endswith('.md') or f.endswith('.i2i.md')]
    if files:
        latest = sorted(files, key=lambda x: x[1], reverse=True)[0][1]
        baton_flush_ts = datetime.datetime.fromtimestamp(latest).strftime('%Y-%m-%dT%H:%M:%SZ')


# GC PID config
pid_kp, pid_ki, pid_kd = '10.00', '1.00', '0.10'
forge_log = os.path.join(FORGE_STATE_DIR, 'forging-log.md')
if os.path.isfile(forge_log):
    with open(forge_log) as f:
        content = f.read()
    matches = list(re.finditer(r'Meta-GC Adjustment.*?Kp=([0-9.]+).*?Ki=([0-9.]+).*?Kd=([0-9.]+)', content, re.DOTALL))
    if matches:
        m = matches[-1]
        pid_kp, pid_ki, pid_kd = m.group(1), m.group(2), m.group(3)

# Active reflexes
active_reflexes = []
reflexes_json = os.path.join(REFLEX_DIR, 'reflexes.json')
if os.path.isfile(reflexes_json):
    with open(reflexes_json) as f:
        active_reflexes = json.load(f)
elif os.path.isdir(REFLEX_DIR):
    for f in os.listdir(REFLEX_DIR):
        if f not in ('REFLEX_DESIGN.md', 'reflexes.json') and (f.endswith('.md') or f.endswith('.json')):
            active_reflexes.append(f)

# Rotation feed count
rotation_count = 0
feed_file = os.path.join(CONSTRUCT_DIR, 'data', 'rotation-feed.json')
if os.path.isfile(feed_file):
    with open(feed_file) as f:
        rotation_count = len([l for l in f if l.strip()])


# Service health
def check_health(port):
    for path in ('/api/health', '/health'):
        try:
            req = urllib.request.Request(f'http://localhost:{port}{path}')
            urllib.request.urlopen(req, timeout=2)
            return 'ok'
        except: pass
    return 'down'

svc_health = {svc: check_health(port) for svc, port in FLEET_PORTS.items()}


# GC PID binary
gc_pid_binary = ''
if os.path.isfile(os.path.join(WORKSPACE, 'gc-pid-bridge', 'target', 'release', 'gc-pid-bridge')):
    gc_pid_binary = os.path.join(WORKSPACE, 'gc-pid-bridge', 'target', 'release', 'gc-pid-bridge')
elif os.path.isfile(os.path.join(WORKSPACE, 'gc-pid-bridge', 'target', 'release', 'gc-pid-bridge')):
    gc_pid_binary = os.path.join(WORKSPACE, 'gc-pid-bridge', 'target', 'release', 'gc-pid-bridge')

bundle = {
    'generated_at': ts,
    'forgemaster_installed': FORGE_INSTALLED,
    'fleet_services': {
        'oracle':         {'name': 'fleet-oracle',        'port': 8795, 'url': 'http://localhost:8795', 'health': svc_health['oracle'],         'role': 'LLM decision engine, reflex teacher, rotation oracle 5th engine'},
        'log':            {'name': 'fleet-log',           'port': 8781, 'url': 'http://localhost:8781', 'health': svc_health['log'],            'role': 'Fleet log sink, reflex hit/miss audit trail'},
        'event':          {'name': 'fleet-event',         'port': 8782, 'url': 'http://localhost:8782', 'health': svc_health['event'],          'role': 'Fleet event bus, reflex propagation backbone'},
        'conductor':     {'name': 'fleet-conductor',     'port': 8769, 'url': 'http://localhost:8769', 'health': svc_health['conductor'],      'role': 'Fleet orchestration, multi-service reflex coordination'},
        'headspace-rs':   {'name': 'headspace-rs',        'port': 8800, 'url': 'http://localhost:8800', 'health': svc_health['headspace-rs'],    'role': 'ARM-optimized vector embedding sidecar, reflex memory backend'},
        'headroom-proxy': {'name': 'headroom-proxy',     'port': 8788, 'url': 'http://localhost:8788', 'health': svc_health['headroom-proxy'], 'role': 'Context compression proxy, injects GC ledger + swarm state + baton context'},
    },
    'agent_protocol_endpoints': {
        'nebula':              'https://fleet-murmur-worker.casey-digennaro.workers.dev',
        'nebula_register':     'https://fleet-murmur-worker.casey-digennaro.workers.dev/api/agent/register',
        'nebula_discover':      'https://fleet-murmur-worker.casey-digennaro.workers.dev/api/agent/discover',
        'nebula_task':         'https://fleet-murmur-worker.casey-digennaro.workers.dev/api/agent/task',
        'i2i_vessel':          '/tmp/i2i-vessel/',
        'baton_hot_tier':      os.path.join(BATON_DIR, 'tiers', 'hot'),
        'baton_immortal_tier': os.path.join(BATON_DIR, 'tiers', 'immortal'),
    },
    'gc_pid_config': {
        'Kp': pid_kp, 'Ki': pid_ki, 'Kd': pid_kd,
        'setpoint': '10', 'deadband': '1.0',
        'binary': gc_pid_binary or '<not found>',
    },
    'headspace_rs_vector_store': {
        'port': 8800, 'dimensions': 384, 'embedding_model': 'BGE (DeepInfra)',
        'collections': ['reflex_triggers', 'baton_contexts', 'gc_patterns'],
        'api_segment': 'http://localhost:8800/api/segment',
        'api_query':    'http://localhost:8800/api/query',
    },
    'active_reflexes': active_reflexes,
    'reflex_engine': {
        'design_doc':                    os.path.join(REFLEX_DIR, 'REFLEX_DESIGN.md'),
        'fast_path_latency_budget_ms':   100,
        'slow_path_latency_budget_ms':   5000,
        'confidence_threshold_silent':  0.7,
        'confidence_threshold_locked':  0.9,
    },
    'rotation_oracle': {
        'feed_file':        feed_file,
        'entry_count':      rotation_count,
        'cadence_minutes':  15,
        '5th_engine':       'rotation oracle — ternary SVM cascade: cycle_error + cognitive + confidence',
    },
    'last_baton_flush': baton_flush_ts,
    'midi_fleet': {
        'agent_count': 16, 'port_range': '2160-2175', 'repository': 'SuperInstance/fleet-midi-*',
    },
    'forgemaster_protocol': {
        'context_file':      os.path.join(FORGE_STATE_DIR, 'CONTEXT.md'),
        'log_file':          os.path.join(FORGE_STATE_DIR, 'forging-log.md'),
        'heartbeat_tasks':   os.path.join(WORKSPACE, 'HEARTBEAT.md'),
        'slogan':            'The forge never cools — execute, do not plan.',
        'gc_bottle_integration': 'baton-system/tiers/hot/ — git-committed, evidence-based',
    },
}
print(json.dumps(bundle, indent=2))
PYEOF
)

# Write bundle
if [ "$DRY_RUN" = 1 ]; then
  ok "DRY-RUN: would write ${FORGE_BUNDLE}"
  echo "$BUNDLE" | python3 -m json.tool &>/dev/null && ok "JSON valid" || warn "JSON may have issues"
else
  mkdir -p "$(dirname "$FORGE_BUNDLE")"
  echo "$BUNDLE" > "$FORGE_BUNDLE"
  if python3 -m json.tool "$FORGE_BUNDLE" &>/dev/null; then
    ok "forge-bundle.json written ($(wc -c < "$FORGE_BUNDLE") bytes)"
  else
    warn "JSON validation failed — bundle not written"
    exit 1
  fi
fi

echo ""
ok "Forge bridge complete."
[ "$FORGE_INSTALLED" = 0 ] && echo "[forge-bridge] HINT: run  bash scripts/forge-apply.sh  to install forgemaster-shell"
exit 0
