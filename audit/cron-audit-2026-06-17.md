# Cron Audit — 2026-06-17

## OpenClaw Managed Cron Jobs (`openclaw cron list`)

| ID | Name | Schedule | Next | Last | Status | Target | Delivery | Agent | Model |
|----|------|----------|------|------|--------|--------|----------|-------|-------|
| fe77b807 | openclaw-watchdog | every 2m | in 2m | <1m ago | ok | isolated | not requested | main | - |
| 094a6f40 | fleet-sync-cycle | cron 48 * * * * (exact) | in 37m | 23m ago | ok | isolated | telegram:8709904335 | main | - |
| 53f3710f | gc-intelligent | every 4h | in 3h | 1h ago | error | isolated | telegram:8709904335 | main | - |
| 05581a00 | meta-gc-agent | cron 30 0,4,8,12,16,20 * * * | in 3h | 38m ago | ok | isolated | telegram:8709904335 | main | minimax/MiniMax-M3 |
| 619f9ac0 | gc-deep-weekly | cron 0 6 * * 0 @ UTC (exact) | in 7d | 3h ago | ok | isolated | telegram:8709904335 | main | - |

**Notable:** `gc-intelligent` is in ERROR state — needs attention.

---

## User Crontab (`crontab -l`)

```
# API Keys (inherited by all cron jobs)
DEEPINFRA_API_KEY=...
MINIMAX_API_KEY=...
ZAI_API_KEY=...

*/5 * * * * /home/ubuntu/.openclaw/workspace/scripts/fleet_workspace_sync.py >> /tmp/workspace_sync.log 2>&1
0 * * * * /home/ubuntu/lever-runner/.venv/bin/lever-runner-promote >> /home/ubuntu/lever-runner/logs/auto_promote.log 2>&1
0 3 * * * /home/ubuntu/bin/sync-lu-forks.sh >> /home/ubuntu/logs/sync-lu-forks.log 2>&1
0 3 * * 0 cd /home/ubuntu/.openclaw/workspace && python3 scripts/fleet-gc.py >> /home/ubuntu/.openclaw/workspace/data/gc-cron.log 2>&1
0 3 * * 0 mkdir -p /home/ubuntu/lever-runner/logs/snapshots && /home/ubuntu/lever-runner/.venv/bin/lever-runner-export --include-stats > /home/ubuntu/lever-runner/logs/snapshots/lever-runner-$(date +\%Y\%m\%d).jsonl 2>> /home/ubuntu/lever-runner/logs/auto_promote.log
43 3 * * * "/home/ubuntu/.acme.sh"/acme.sh --cron --home "/home/ubuntu/.acme.sh" > /dev/null
48 * * * * /home/ubuntu/.openclaw/workspace/scripts/fleet-check.sh >> /tmp/fleet-check.log 2>&1
0 4 * * * bash /tmp/zeroclaw-nightly.sh >> /home/ubuntu/.openclaw/workspace/zeroclaws/reports/cron.log 2>&1
*/15 * * * * /usr/local/bin/fleet-construct > /dev/null 2>&1
```

---

## Root Crontab (`sudo crontab -l`)

No crontab for root.

---

## Systemd Timers (`systemctl list-timers --all`)

| Next | Left | Last | Passed | Unit | Activates |
|------|------|------|--------|------|-----------|
| Sun 2026-06-14 09:39:00 UTC | 27min left | Sun 2026-06-14 09:09:00 UTC | 2min 12s ago | phpsessionclean.timer | phpsessionclean.service |
| Sun 2026-06-14 14:36:51 UTC | 5h 25min left | Sun 2026-06-14 05:02:26 UTC | 4h 8min ago | motd-news.timer | motd-news.service |
| Sun 2026-06-14 19:32:42 UTC | 10h left | Sun 2026-06-14 07:15:11 UTC | 1h 56min ago | fwupd-refresh.timer | fwupd-refresh.service |
| Sun 2026-06-14 19:46:52 UTC | 10h left | Sun 2026-06-14 06:17:35 UTC | 2h 53min ago | certbot.timer | certbot.service |
| Sun 2026-06-14 22:33:08 UTC | 13h left | Sun 2026-06-14 08:13:51 UTC | 57min ago | apt-daily.timer | apt-daily.service |
| Sun 2026-06-14 22:42:45 UTC | 13h left | Sat 2026-06-13 22:42:45 UTC | 10h ago | update-notifier-download.timer | update-notifier-download.service |
| Sun 2026-06-14 22:52:48 UTC | 13h left | Sat 2026-06-13 22:52:48 UTC | 10h ago | systemd-tmpfiles-clean.timer | systemd-tmpfiles-clean.service |
| Mon 2026-06-15 00:00:00 UTC | 14h left | Sun 2026-06-14 00:00:00 UTC | 9h ago | dpkg-db-backup.timer | dpkg-db-backup.service |
| Mon 2026-06-15 00:00:00 UTC | 14h left | Sun 2026-06-14 00:00:00 UTC | 9h ago | logrotate.timer | logrotate.service |
| Mon 2026-06-15 00:25:33 UTC | 15h left | Mon 2026-06-08 00:33:12 UTC | 6 days ago | fstrim.timer | fstrim.service |
| Mon 2026-06-15 00:28:46 UTC | 15h left | Sun 2026-06-14 04:55:10 UTC | 4h 16min ago | man-db.timer | man-db.timer |
| Mon 2026-06-15 06:27:12 UTC | 21h left | Sun 2026-06-14 06:52:56 UTC | 2h 18min ago | apt-daily-upgrade.timer | apt-daily-upgrade.service |
| Wed 2026-06-17 09:11:25 UTC | 3 days left | Sun 2026-06-07 15:48:47 UTC | 6 days ago | update-notifier-motd.timer | update-notifier-motd.service |
| Sun 2026-06-21 03:10:07 UTC | 6 days left | Sun 2026-06-14 03:10:36 UTC | 6h ago | e2scrub_all.timer | e2scrub_all.service |
| n/a | n/a | n/a | n/a | apport-autoreport.timer | apport-autoreport.service |
| n/a | n/a | n/a | n/a | snapd.snap-repair.timer | snapd.snap-repair.service |
| n/a | n/a | n/a | n/a | ua-timer.timer | ua-timer.service |

**Notable miss:** `fstrim.timer` last ran 6 days ago (expected weekly). `update-notifier-motd.timer` last ran 6 days ago.

---

## Construct- managed Systemd Units

| Unit | Type | Purpose |
|------|------|---------|
| construct-pulse.service | oneshot | Fleet pulse event emission |
| construct-pulse.timer | timer | Runs construct-pulse every 5 min |
| construct-pulse-loop.service | oneshot | Long-running pulse loop daemon |
| construct-pulse-webhook.service | oneshot | Webhook delivery for pulse events |

---

## New Units Added 2026-06-17 (this session)

| Unit | Type | Purpose |
|------|------|---------|
| meta-reflex-daemon.service | long-running | Self-observation daemon loop |
| fleet-reflect.service | oneshot | System self-assessment |
| fleet-reflect.timer | timer | Runs fleet-reflect every 6h (00,06,12,18 UTC) |
| fleet-self-test.service | oneshot | Daily self-test runner |
| fleet-self-test.timer | timer | Runs fleet-self-test daily at 03:00 UTC |
