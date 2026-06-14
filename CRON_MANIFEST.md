# Fleet Cron Manifest

Centralized record of every scheduled job in the fleet — cron, systemd timers, and OpenClaw-managed jobs.

---

## openclaw-watchdog
- **Type:** openclaw-cron
- **Runs:** every 2 minutes
- **Script:** internal (OpenClaw managed)
- **Log:** OpenClaw internal state
- **Deps:** openclaw service running
- **On failure:** watchdog misses trigger agent restart; check `openclaw gateway status`

---

## fleet-sync-cycle
- **Type:** openclaw-cron
- **Runs:** cron `48 * * * *` (hourly, on the 48th minute)
- **Script:** internal OpenClaw cycle
- **Log:** OpenClaw session log
- **Deps:** openclaw service running, telegram bot up
- **On failure:** Alert via telegram:8709904335; check openclaw logs for cycle errors

---

## gc-intelligent
- **Type:** openclaw-cron
- **Runs:** every 4 hours
- **Script:** internal GC cycle
- **Log:** OpenClaw session log
- **Deps:** openclaw service running
- **On failure:** **ERROR state observed 2026-06-14.** Check `openclaw cron list`; inspect agent logs; may need manual GC retry or agent restart

---

## meta-gc-agent
- **Type:** openclaw-cron
- **Runs:** cron `30 0,4,8,12,16,20 * * *` (every 4h at half-past: 00:30, 04:30, 08:30, 12:30, 16:30, 20:30 UTC)
- **Script:** internal meta-GC agent
- **Log:** OpenClaw session log
- **Deps:** openclaw service running, minimax/MiniMax-M3 model available
- **On failure:** Alert via telegram; check model availability and agent state

---

## gc-deep-weekly
- **Type:** openclaw-cron
- **Runs:** cron `0 6 * * 0` (06:00 UTC every Sunday)
- **Script:** internal deep GC cycle
- **Log:** OpenClaw session log
- **Deps:** openclaw service running
- **On failure:** Alert via telegram; check that Sunday run completed; retry manually if missed

---

## workspace-sync
- **Type:** system-crontab
- **Runs:** cron `*/5 * * * *` (every 5 minutes)
- **Script:** `/home/ubuntu/.openclaw/workspace/scripts/fleet_workspace_sync.py`
- **Log:** `/tmp/workspace_sync.log`
- **Deps:** python3, openclaw workspace accessible
- **On failure:** Log file grows stale; check python path and workspace integrity

---

## lever-runner-promote
- **Type:** system-crontab
- **Runs:** cron `0 * * * *` (hourly, on the hour)
- **Script:** `/home/ubuntu/lever-runner/.venv/bin/lever-runner-promote`
- **Log:** `/home/ubuntu/lever-runner/logs/auto_promote.log`
- **Deps:** lever-runner venv active, lever-runner service up
- **On failure:** Promote cycle missed; check venv and lever-runner daemon health

---

## sync-lu-forks
- **Type:** system-crontab
- **Runs:** cron `0 3 * * *` (03:00 UTC daily)
- **Script:** `/home/ubuntu/bin/sync-lu-forks.sh`
- **Log:** `/home/ubuntu/logs/sync-lu-forks.log`
- **Deps:** git remotes reachable
- **On failure:** Fork sync skipped for the day; check git connectivity and remote URLs

---

## fleet-gc-weekly
- **Type:** system-crontab
- **Runs:** cron `0 3 * * 0` (03:00 UTC every Sunday)
- **Script:** `cd /home/ubuntu/.openclaw/workspace && python3 scripts/fleet-gc.py`
- **Log:** `/home/ubuntu/.openclaw/workspace/data/gc-cron.log`
- **Deps:** python3, openclaw workspace, scripts/fleet-gc.py present
- **On failure:** GC skipped; check python path, script existence, and workspace disk space

---

## lever-runner-export-snapshot
- **Type:** system-crontab
- **Runs:** cron `0 3 * * 0` (03:00 UTC every Sunday, same window as fleet-gc)
- **Script:** `mkdir -p /home/ubuntu/lever-runner/logs/snapshots && /home/ubuntu/lever-runner/.venv/bin/lever-runner-export --include-stats > /home/ubuntu/lever-runner/logs/snapshots/lever-runner-$(date +\%Y\%m\%d).jsonl`
- **Log:** appended to `/home/ubuntu/lever-runner/logs/auto_promote.log`
- **Deps:** lever-runner venv, snapshots directory writable
- **On failure:** Snapshot missed; check disk space and lever-runner-export binary

---

## acme-sh-cert-renewal
- **Type:** system-crontab
- **Runs:** cron `43 3 * * *` (03:43 UTC daily)
- **Script:** `/home/ubuntu/.acme.sh/acme.sh --cron --home /home/ubuntu/.acme.sh`
- **Log:** ACME cron output (suppressed to /dev/null); check `/home/ubuntu/.acme.sh/` for logs
- **Deps:** acme.sh installed, valid certificates or pending challenges
- **On failure:** Certificate renewal may be missed; check acme.sh logs manually if SSL certs appear stale

---

## fleet-check
- **Type:** system-crontab
- **Runs:** cron `48 * * * *` (hourly, on the 48th minute)
- **Script:** `/home/ubuntu/.openclaw/workspace/scripts/fleet-check.sh`
- **Log:** `/tmp/fleet-check.log`
- **Deps:** fleet-check.sh present, construct coordination accessible
- **On failure:** Forgemaster bottle checks missed; check script and construct API connectivity

---

## zeroclaw-nightly
- **Type:** system-crontab
- **Runs:** cron `0 4 * * *` (04:00 UTC daily)
- **Script:** `bash /tmp/zeroclaw-nightly.sh`
- **Log:** `/home/ubuntu/.openclaw/workspace/zeroclaws/reports/cron.log`
- **Deps:** `/tmp/zeroclaw-nightly.sh` present, zeroclaw workspace
- **On failure:** Nightly zeroclaw run skipped; check script presence and zeroclaw workspace

---

## fleet-construct-15min
- **Type:** system-crontab
- **Runs:** cron `*/15 * * * *` (every 15 minutes)
- **Script:** `/usr/local/bin/fleet-construct`
- **Log:** stdout to /dev/null (no log file)
- **Deps:** fleet-construct binary at /usr/local/bin
- **On failure:** Construct coordination pulses missed; check binary exists and construct service health

---

## construct-pulse
- **Type:** systemd-timer
- **Runs:** every 5 minutes (via construct-pulse.timer)
- **Script:** construct-pulse.service → pulse.sh
- **Log:** managed by pulse.sh output
- **Deps:** network reachable, construct workspace intact
- **On failure:** Pulse events missed; check construct-pulse.service state and pulse.sh logs

---

## phpsessionclean
- **Type:** systemd-timer
- **Runs:** systemd timer (system-managed)
- **Script:** phpsessionclean.service
- **Log:** systemd journal
- **Deps:** php sessions directory
- **On failure:** PHP session files accumulate; harmless, cosmetic

---

## certbot
- **Type:** systemd-timer
- **Runs:** systemd timer (system-managed)
- **Script:** certbot.service
- **Log:** systemd journal, certbot logs
- **Deps:** network, certbot installed, domain validation reachable
- **On failure:** SSL certificates may not renew; check certbot logs and domain DNS

---

## logrotate
- **Type:** systemd-timer
- **Runs:** systemd timer (system-managed, 00:00 daily)
- **Script:** logrotate.service
- **Log:** systemd journal
- **Deps:** logrotate config, logs writable
- **On failure:** Log files grow beyond configured max; check logrotate.conf

---

## apt-daily
- **Type:** systemd-timer
- **Runs:** systemd timer (system-managed)
- **Script:** apt-daily.service
- **Log:** systemd journal, /var/log/apt/history.log
- **Deps:** network (for apt update)
- **On failure:** Security patches delayed; check network and disk space

---

## fstrim
- **Type:** systemd-timer
- **Runs:** systemd timer (weekly, expected Mon ~00:25 UTC)
- **Script:** fstrim.service
- **Log:** systemd journal
- **Deps:** SSD with TRIM support
- **On failure:** **Missed — last ran 6 days ago.** Check fstrim.timer state; SSDs may accumulate unwritten blocks

---

## e2scrub_all
- **Type:** systemd-timer
- **Runs:** systemd timer (weekly, Sun 2026-06-21 03:10 UTC)
- **Script:** e2scrub_all.service
- **Log:** systemd journal
- **Deps:** ext4 filesystems
- **On failure:** Filesystem consistency check skipped; check e2scrub_all.timer

---

## meta-reflex-daemon
- **Type:** systemd-service (long-running)
- **Runs:** continuous (Restart=on-failure)
- **Script:** `/home/ubuntu/.openclaw/workspace/construct/scripts/meta-reflex-daemon.sh`
- **Log:** script-managed; check process output
- **Deps:** network, construct workspace
- **On failure:** Daemon restarts after 10s; persistent failures indicate script or environment issue

---

## fleet-reflect
- **Type:** systemd-timer
- **Runs:** `OnCalendar=*-*-* 00,06,12,18:00:00` (every 6h: 00:00, 06:00, 12:00, 18:00 UTC)
- **Script:** `/home/ubuntu/.openclaw/workspace/construct/scripts/reflect.sh`
- **Log:** `/home/ubuntu/.openclaw/workspace/construct/logs/reflect-YYYYMMDD-HHMMSS.log`
- **Deps:** network, construct workspace
- **On failure:** Reflection skipped; logs indicate cause; next run proceeds normally

---

## fleet-self-test
- **Type:** systemd-timer
- **Runs:** `OnCalendar=*-*-* 03:00:00` (daily at 03:00 UTC)
- **Script:** `/home/ubuntu/.openclaw/workspace/construct/scripts/self-test.sh`
- **Log:** `/home/ubuntu/.openclaw/workspace/construct/logs/self-test-YYYYMMDD.log`
- **Deps:** construct workspace, all fleet services
- **On failure:** Self-test skipped; check logs; alert if consecutive failures

---

## Scheduler Health Check

A health checker runs independently and writes to `/tmp/scheduler-health.json`. See `scheduler-health.sh`.

To run manually:
```bash
bash /home/ubuntu/.openclaw/workspace/construct/scripts/scheduler-health.sh
cat /tmp/scheduler-health.json
```
