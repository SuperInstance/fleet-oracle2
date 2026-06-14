#!/usr/bin/env bash
#
# decode-wal.sh — Inspects /home/ubuntu/.openclaw/workspace/construct/data/decision-wal/
# Reads all .json files and prints a summary table:
#   Filename | Timestamp | Decision | Confidence | Latency
# Plus a summary row: total decisions, avg confidence, min/max confidence
#
set -euo pipefail

WAL_DIR="/home/ubuntu/.openclaw/workspace/construct/data/decision-wal"
OUTPUT="/tmp/wal-summary.log"

# ── Check directory exists ────────────────────────────────────────────────────
if [[ ! -d "$WAL_DIR" ]]; then
    echo "ERROR: decision-wal directory not found: $WAL_DIR" >&2
    exit 1
fi

# ── Collect all .json files ───────────────────────────────────────────────────
mapfile -t wal_files < <(find "$WAL_DIR" -maxdepth 1 -name "*.json" -type f | sort)

if [[ ${#wal_files[@]} -eq 0 ]]; then
    echo "No .json files found in $WAL_DIR" >&2
    exit 0
fi

# ── Parse each file and collect rows ─────────────────────────────────────────
declare -a rows
declare -a confidences
total=0
min_conf=999999
max_conf=-999999

for filepath in "${wal_files[@]}"; do
    filename=$(basename "$filepath")

    # Parse JSON fields; use python for portability
    parsed=$(python3 -c "
import json, sys, os

filepath = '$filepath'
try:
    with open(filepath) as f:
        d = json.load(f)

    ts      = d.get('timestamp',      d.get('ts',        'n/a'))
    decision= d.get('decision',        d.get('action',    d.get('choice',  'n/a')))
    conf    = d.get('confidence',     d.get('combined_confidence', d.get('score', 'n/a')))
    latency = d.get('latency_ms',     d.get('latency',   d.get('duration_ms', 'n/a')))

    # Normalize decision to string
    if isinstance(decision, (int, float)):
        decision = str(decision)
    elif not isinstance(decision, str):
        decision = 'n/a'

    # Normalize confidence
    if isinstance(conf, (int, float)):
        conf_f = float(conf)
        print(f'{ts}\t{decision}\t{conf_f}\t{latency}')
    else:
        print(f'{ts}\t{decision}\t{n/a}\t{latency}')
except Exception as e:
    print(f'ERROR\t{e}\t\t')
" 2>/dev/null || echo "ERROR\tparse failed\t\t")

    IFS=$'\t' read -r ts decision conf latency <<< "$parsed"

    if [[ "$conf" != "n/a" && "$conf" != "ERROR" ]]; then
        confidences+=("$conf")
        total=$(python3 -c "print($total + $conf)" 2>/dev/null)
        min_conf=$(python3 -c "print(min($min_conf, $conf))" 2>/dev/null)
        max_conf=$(python3 -c "print(max($max_conf, $conf))" 2>/dev/null)
    fi

    rows+=("$filename|$ts|$decision|$conf|$latency")
done

# ── Print summary table ───────────────────────────────────────────────────────
{
    echo "============================================================"
    echo "Decision WAL Summary — $(date -Iseconds)"
    echo "Directory: $WAL_DIR"
    echo "============================================================"
    printf "%-45s %-28s %-12s %-12s %s\n" "Filename" "Timestamp" "Decision" "Confidence" "Latency"
    echo "------------------------------------------------------------"

    for row in "${rows[@]}"; do
        IFS='|' read -r fn ts decision conf latency <<< "$row"
        printf "%-45s %-28s %-12s %-12s %s\n" "$fn" "$ts" "$decision" "$conf" "$latency"
    done

    echo "------------------------------------------------------------"
    echo ""

    # Summary row
    count=${#confidences[@]}
    if [[ $count -gt 0 ]]; then
        avg_conf=$(python3 -c "print(round($total / $count, 6))")
        printf "%s\n" "Summary: $count decisions | avg_confidence=$avg_conf | min_confidence=$min_conf | max_confidence=$max_conf"
    else
        echo "Summary: ${#rows[@]} files found but no valid confidence values to summarize"
    fi
} | tee "$OUTPUT"

echo ""
echo "Full output written to: $OUTPUT"