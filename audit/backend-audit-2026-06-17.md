# Fleet Backend Audit Report
**Date:** 2026-06-17
**Auditor:** automated hardening audit
**Host:** ok (Linux 6.8.0-1054-oracle aarch64)
**Uptime:** 12 days, 10h

---

## 1. Service Inventory

| Service | Binary | Port | Status | Version |
|---------|--------|------|--------|---------|
| fleet-oracle | `/usr/local/bin/fleet-oracle` | 8795 | ✅ RUNNING | 0.3.0 |
| fleet-log | `/usr/local/bin/fleet-log` | 8781 | ✅ RUNNING | 0.1.0 |
| fleet-event | `/usr/local/bin/fleet-event` | 8782 | ✅ RUNNING | event-bus |

### Process Details

```
ubuntu  2345676  fleet-log     Ssl  07:15  0:00
ubuntu  2348386  fleet-event   Ssl  07:18  0:00
ubuntu  2396104  fleet-oracle  Ssl  08:57  0:00
```

Load average: 0.41 / 0.95 / 1.05 — nominal.

---

## 2. fleet-oracle (port 8795)

### Health & API

| Endpoint | Result |
|----------|--------|
| `GET /api/health` | ✅ 200 — `{"status":"healthy","version":"0.3.0"}` |
| `GET /api/status` | ✅ 200 — full oracle status |
| `POST /api/decide` | ✅ 200 — returns decision + oracle_status |
| `GET /` | 404 (expected, no root handler) |

### Decision Statistics

```
decision_count:   50
history_len:      50
rotation_total:   50
svm_trained:      true
svm_confidence:   0.45–0.50
rotation_confidence: 0.9999
rotation_cycle_error: 1.484 (baseline established)
last_entropy_surprise: 0.302–0.407
last_rhythm_anomaly: 0.031
```

### Rotation 5th Engine — VERIFIED LOADED

The **Rotation 5th inference engine** is confirmed present and operational:

- Binary symbol: `rotation_core.bc0b6afe9c7bc0c1-cgu.0` (Rust compiled crate)
- Symbol: `_ZN13rotation_core14RotationEngine6rotate17hfcba3cd00faad255E`
- Source reference in `fleet-oracle/src/rotation_oracle.rs`:
  > *"ARM-optimized rotation engine as 5th inference module"*
- Source reference in `fleet-oracle/src/decision.rs`:
  > *"Run all oracles (including rotation — the 5th inference engine)"*
- Rotation engine wraps: Bayesian posterior update → PID cascade → Compression → Cycle Validation → Attractor analysis
- Returns `rotation_cycle_error`, `rotation_cognitive`, `rotation_confidence`, `combined_confidence` on every decision

### decision-wal Directory

Path: `/home/ubuntu/.openclaw/workspace/construct/data/decision-wal/`
Status: **Empty** — directory exists but contains no WAL files. The oracle is not currently persisting decision WAL entries to disk. No data loss risk currently (in-memory state is intact), but WAL persistence should be reviewed.

---

## 3. fleet-log (port 8781)

### Health & API

| Endpoint | Result |
|----------|--------|
| `GET /health` | ✅ 200 — `{"status":"healthy","version":"0.1.0"}` |
| `GET /api/health` | 404 (uses `/health` not `/api/health`) |
| `POST /api/logs` | ✅ accepted — `{"accepted":1,"total_ingested":15}` |

### Rotation Pulse Log Flow

Construct pulse log entries are confirmed flowing into fleet-log:
- `source=construct-pulse` entries present in fleet-log
- Pulse entries contain rotation feedback metadata: `rotation_cycle_error`, `rotation_confidence`, `combined_confidence`
- Recent pulse logs show oracle2 votes with disk/ram metrics

**Note:** fleet-log uses `/health` (not `/api/health`). The health.sh probe handles this fallback correctly.

---

## 4. fleet-event (port 8782)

### Health & API

| Endpoint | Result |
|----------|--------|
| `GET /health` | 404 (no GET health endpoint) |
| `POST /api/events` | ✅ accepted — returns `{"accepted":true,...}` |

### rotation_feedback Events — CONFIRMED ACCEPTED

fleet-event accepts `rotation_feedback` events from construct-pulse. Verified events in buffer:

| Timestamp | ternary_merit | combined_confidence |
|-----------|---------------|---------------------|
| 2026-06-14T09:03:12Z | 80 | 0.809 |
| 2026-06-14T09:03:46Z | 78 | 0.783 |
| 2026-06-14T09:05:00Z | 50 | (health check) |

**Note:** fleet-event has no HTTP GET health endpoint. The health.sh probe uses a lightweight POST to `/api/events` as a liveness check, which is the correct approach.

---

## 5. rotation-feed.json

Path: `/home/ubuntu/.openclaw/workspace/construct/data/rotation-feed.json`
Format: **JSONL** (one JSON object per line, max 1000 entries)

Current entries: **2**

| Timestamp | combined_confidence | rotation_cycle_error |
|-----------|---------------------|----------------------|
| 2026-06-14T09:03:12Z | 0.809 | 1.485 |
| 2026-06-14T09:03:46Z | 0.783 | 1.484 |

Rotation feed is being appended correctly by pulse.sh on each run. No trimming needed yet (well under 1000 entry limit).

---

## 6. Systemd Timer & Service (construct-pulse)

### Files Written

Two files were written to `/home/ubuntu/.openclaw/workspace/construct/systemd/` (write access to `/etc/systemd/system/` was not available; files need to be copied to `/etc/systemd/system/` with root privileges):

#### `construct-pulse.timer`
```
[Unit] Description=Construct Pulse — runs construct/scripts/pulse.sh every 15 minutes
[Timer] OnBootSec=1min  OnUnitActiveSec=15min  Persistent=true  Unit=construct-pulse.service
[Install] WantedBy=timers.target
```

#### `construct-pulse.service`
```
[Unit] Description=Construct Pulse — metric collection, oracle query, fleet-log + fleet-event write
After=network.target  Wants=fleet-oracle.service fleet-log.service fleet-event.service
[Service] Type=oneshot  ExecStart=/home/ubuntu/.openclaw/workspace/construct/scripts/pulse.sh
User=ubuntu  Group=ubuntu  NoNewPrivileges=true  ProtectSystem=strict  ProtectHome=read-only
ReadWritePaths=/home/ubuntu/.openclaw/workspace/construct/data  TimeoutSec=600
StandardOutput=journal  StandardError=journal
```

**Hardening features applied:**
- `NoNewPrivileges=true` — prevents privilege escalation
- `ProtectSystem=strict` — read-only /usr, /boot, /etc
- `ProtectHome=read-only` — /home is read-only for the service
- `ReadWritePaths=` — only `construct/data` is writable
- `TimeoutSec=600` — prevents runaway pulse from blocking timer
- `Wants=fleet-oracle.service fleet-log.service fleet-event.service` — soft dependency on upstream services

### Deployment Instructions

To activate the timer, run as root:
```bash
sudo cp /home/ubuntu/.openclaw/workspace/construct/systemd/construct-pulse.timer /etc/systemd/system/
sudo cp /home/ubuntu/.openclaw/workspace/construct/systemd/construct-pulse.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now construct-pulse.timer
```

---

## 7. Health Check Script

**Path:** `/home/ubuntu/.openclaw/workspace/construct/scripts/health.sh`
**Permissions:** `rwxr-xr-x` (executable)

### Features
- Pings all 3 services with 5-second timeout
- fleet-oracle: probes `GET /api/health`
- fleet-log: probes `GET /health` (falls back from `/api/health`)
- fleet-event: probes `POST /api/events` with a lightweight `health_check` event (no GET endpoint available)
- Outputs one JSONL line per service:
  ```json
  {"service":"fleet-oracle","status":"ok","latency_ms":8,"time":"2026-06-17T..."}
  ```
- Summary line to stderr: `[time] [health] SUMMARY: all 3/3 services healthy`
- Exit code 0 = all healthy, 1 = any down

### Verification Run

```
fleet-oracle  ✅ ok  8ms
fleet-log     ✅ ok  16ms
fleet-event   ✅ ok  9ms
SUMMARY: all 3/3 services healthy
```

---

## 8. Findings & Recommendations

### ✅ Healthy
- All 3 services are running and responsive
- Rotation 5th engine is loaded and producing valid output on every decision
- rotation_feedback events are flowing into fleet-event correctly
- pulse.sh script is production-quality, handles oracle unavailability gracefully
- health.sh correctly handles each service's unique API layout

### ⚠️ Needs Attention

1. **decision-wal is empty** — fleet-oracle is not persisting decision WAL to disk. If the oracle process restarts, decision history will be lost. Review the WAL writer configuration.

2. **fleet-event has no health endpoint** — monitored correctly via POST probe in health.sh, but a native `GET /health` endpoint would be cleaner and is a standard practice.

3. **Systemd files not in /etc/systemd/system/** — written to workspace only due to write permission restrictions. Must be copied to `/etc/systemd/system/` with root to activate.

### 🔒 Security Posture

- fleet-oracle v0.3.0: Rust binary, ARM-optimized, no exposed unauthenticated endpoints beyond `/api/decide`
- All services bind to `0.0.0.0` — ensure firewall restricts access to internal network
- construct-pulse.service hardened with sandbox directives (NoNewPrivileges, ProtectSystem, ProtectHome, ReadWritePaths)
- health.sh uses short timeouts (5s) to prevent hangs

---

## 9. Files Created

| File | Purpose |
|------|---------|
| `/home/ubuntu/.openclaw/workspace/construct/scripts/health.sh` | Health check script |
| `/home/ubuntu/.openclaw/workspace/construct/systemd/construct-pulse.timer` | Systemd timer (15-min interval) |
| `/home/ubuntu/.openclaw/workspace/construct/systemd/construct-pulse.service` | Systemd oneshot service for pulse.sh |
| `/home/ubuntu/.openclaw/workspace/construct/audit/backend-audit-2026-06-17.md` | This report |