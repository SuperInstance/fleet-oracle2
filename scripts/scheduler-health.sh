#!/usr/bin/env bash
# scheduler-health.sh — Fleet scheduler health checker
# Writes output to /tmp/scheduler-health.json
# Checks: systemd timer last/next run, missed timers, dead fleet processes, large log files

set -euo pipefail

OUTPUT="/tmp/scheduler-health.json"

FLEET_PATTERNS=(
    "meta-reflex-daemon"
    "meta-reflex"
    "construct-pulse"
    "reflex-daemon"
    "reflex-coord"
    "pulse-loop"
    "fleet-construct"
)

LOG_DIRS=(
    "/home/ubuntu/.openclaw/workspace/construct/logs"
    "/home/ubuntu/.openclaw/workspace/zeroclaws/reports"
    "/home/ubuntu/lever-runner/logs"
    "/tmp"
    "/home/ubuntu/logs"
)

LOG_SIZE_LIMIT=104857600
MISSED_TIMER_THRESHOLD=7200

# Inline Python health-checker
python3 - << 'PYEOF'
import subprocess
import re
import json
import sys

FLEET_PATTERNS = [
    "meta-reflex-daemon", "meta-reflex", "construct-pulse",
    "reflex-daemon", "reflex-coord", "pulse-loop", "fleet-construct"
]
LOG_DIRS = [
    "/home/ubuntu/.openclaw/workspace/construct/logs",
    "/home/ubuntu/.openclaw/workspace/zeroclaws/reports",
    "/home/ubuntu/lever-runner/logs",
    "/tmp",
    "/home/ubuntu/logs"
]
MISSED_THRESHOLD = 7200

def parse_timers():
    result = subprocess.run(['systemctl', 'list-timers', '--all'], capture_output=True, text=True)
    lines = result.stdout.strip().split('\n')
    data_lines = lines[3:-2] if len(lines) > 5 else []
    timers = []

    for line in data_lines:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 6:
            continue

        if parts[0] == 'n/a':
            unit = parts[4] if len(parts) > 4 else ''
            timers.append({
                'unit': unit.replace('.timer', ''),
                'next': 'n/a', 'last': 'n/a',
                'passed': 'n/a', 'seconds_since': 0
            })
            continue

        nf = len(parts)
        unit = parts[nf - 2]
        next_dow, next_date, next_time = parts[1], parts[2], parts[3]
        last_dow, last_date, last_time = parts[7], parts[8], parts[9]
        passed_parts = parts[11:nf - 2]
        passed_str = ' '.join(passed_parts)

        total = 0
        days_m = re.search(r'(\d+)\s*days?', passed_str)
        hours_m = re.search(r'(\d+)\s*h(?![a-z])', passed_str)
        mins_m = re.search(r'(\d+)\s*min', passed_str)
        secs_m = re.search(r'(\d+)\s*s(?![a-z])', passed_str)
        if days_m: total += int(days_m.group(1)) * 86400
        if hours_m: total += int(hours_m.group(1)) * 3600
        if mins_m: total += int(mins_m.group(1)) * 60
        if secs_m: total += int(secs_m.group(1))

        timers.append({
            'unit': unit.replace('.timer', ''),
            'next': f"{next_dow} {next_date} {next_time}",
            'last': f"{last_dow} {last_date} {last_time}",
            'passed': passed_str,
            'seconds_since': total
        })
    return timers

def find_dead_processes(patterns):
    result = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
    lines = result.stdout.split('\n')
    dead = []
    for line in lines:
        for pat in patterns:
            if pat.lower() in line.lower() and 'grep' not in line and 'scheduler-health' not in line:
                dead.append(line.strip())
                break
    return dead

def find_large_logs(log_dirs):
    large = []
    for d in log_dirs:
        try:
            result = subprocess.run(
                ['find', d, '-type', 'f', '-size', '+100M', '-printf', '%s %p\n'],
                capture_output=True, text=True
            )
            for line in result.stdout.strip().split('\n'):
                if not line:
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2:
                    size = int(parts[0])
                    path = parts[1]
                    size_mb = size // (1024 * 1024)
                    large.append(f"{path} ({size_mb}MB)")
        except Exception:
            pass
    return large

def main():
    timers = parse_timers()
    dead = find_dead_processes(FLEET_PATTERNS)
    large = find_large_logs(LOG_DIRS)

    fleet_pattern = re.compile(
        r'fleet|meta-reflex|reflect|self-test|construct-pulse|'
        r'gc-intelligent|gc-deep|meta-gc|openclaw-watchdog|fleet-sync',
        re.IGNORECASE
    )
    missed = []
    for t in timers:
        if fleet_pattern.search(t['unit']) and t['seconds_since'] > MISSED_THRESHOLD:
            missed.append(f"Timer \"{t['unit']}\" missed — {t['seconds_since']}s since last run")

    healthy = len(missed) == 0 and len(dead) == 0

    alerts = []
    for m in missed:
        alerts.append({"severity": "critical", "message": f"Timer missed: {m}"})
    for l in large:
        alerts.append({"severity": "warning", "message": f"Large log file: {l}"})

    result = subprocess.run(['date', '-u', '+%Y-%m-%dT%H:%M:%SZ'], capture_output=True, text=True)
    ts = result.stdout.strip()

    output = {
        "generated_at": ts,
        "timers": timers,
        "missed_timers": missed,
        "dead_processes": dead,
        "large_logs": large,
        "healthy": healthy,
        "alerts": alerts
    }

    with open('/tmp/scheduler-health.json', 'w') as f:
        json.dump(output, f, indent=2)

    print(json.dumps(output, indent=2))

if __name__ == '__main__':
    main()
PYEOF
