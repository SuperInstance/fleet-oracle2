# Fleet Resilience & Self-Healing

This document describes the resilience architecture for the construct fleet: known failure modes, degradation behavior, recovery procedures, and the limits of automation.

---

## Overview

The fleet is designed around a **crash-only** philosophy: services are expected to fail fast, restart cleanly, and degrade gracefully. The watchdog + auto-heal layer provides continuous health monitoring and automatic recovery for the common failure cases.

```
┌─────────────────────────────────────────────────────────────┐
│                   Fleet Watchdog (2min)                     │
│  health check → port/HTTP/binary → restart if down         │
│  summary POST → fleet-event :8782                          │
└────────────────────────┬────────────────────────────────────┘
                         │ alert conditions
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                    Auto-Heal Script                        │
│  headspace-rs down  → restart                              │
│  fleet-oracle down  → restart                              │
│  disk >90%          → force GC                             │
│  feed stale >10min  → cycle pulse                          │
│  flap >3 in 5min    → critical alert                       │
└─────────────────────────────────────────────────────────────┘
```

---

## Services

### Core Fleet Services

| Service | Port | HTTP Health | Binary | Systemd | Notes |
|---------|------|-------------|--------|---------|-------|
| fleet-oracle | 8795 | `/health` | — | fleet-oracle | Discovery / routing |
| fleet-log | 8781 | `/health` | — | fleet-log | Structured log ingestion |
| fleet-event | 8782 | `/health` | — | fleet-event | Event bus |
| fleet-conductor | 8769 | `/health` | — | fleet-conductor | Orchestration |
| headspace-rs | 8800 | `/health` | `~/.cargo/bin/headspace-rs` | headspace-rs | Rust memory service |
| rotation-feed-server | 8796 | `/health` | — | rotation-feed-server | Rotation feed |
| fleet-midi-N (×16) | 2160–2175 | `/health` | — | fleet-midi@N | MIDI agents |
| construct-pulse | — | — | `construct-pulse-daemon.sh` | construct-pulse | Daemon |
| reflex-daemon | — | — | `reflex-daemon.sh` | reflex-daemon | Daemon |
| meta-reflex-daemon | — | — | `meta-reflex-daemon.sh` | meta-reflex-daemon | Daemon |
| gc-pid-bridge | — | — | `~/.cargo/bin/gc-pid-bridge` | gc-pid-bridge | Rust GC bridge |

---

## Known Failure Modes

### fleet-oracle (port 8795)
- **Failure:** Routing queries return errors; fleet services can't find each other
- **Degradation:** Services fall back to cached endpoints; new service discovery halted
- **Auto-recover:** Watchdog detects port down → `systemctl --user try-restart fleet-oracle`
- **Manual recovery:** `systemctl --user restart fleet-oracle; journalctl --user -u fleet-oracle -n 50`

### fleet-log (port 8781)
- **Failure:** Logs queue up in memory; after ~5min buffer full, logs dropped
- **Degradation:** Reduced observability; events still flow through fleet-event
- **Auto-recover:** Watchdog → systemd restart
- **Manual recovery:** `systemctl --user restart fleet-log`

### fleet-event (port 8782)
- **Failure:** Event bus goes down; services lose pub/sub
- **Degradation:** Services operate in isolated mode; events buffered locally
- **Auto-recover:** Watchdog → systemd restart
- **Manual recovery:** `systemctl --user restart fleet-event`

### fleet-conductor (port 8769)
- **Failure:** Orchestration halted; new tasks queue but don't execute
- **Degradation:** Existing tasks continue; no new task dispatch
- **Auto-recover:** Watchdog → systemd restart
- **Manual recovery:** `systemctl --user restart fleet-conductor`

### headspace-rs (port 8800)
- **Failure:** Rust memory service crashes (OOM, panic, segfault)
- **Degradation:** In-memory state lost; headspace features unavailable
- **Auto-recover:** Watchdog detects binary missing → restart; if restart fails → `warn` alert
- **Manual recovery:** Check `~/.cargo/bin/headspace-rs` permissions; `journalctl` for panic logs

### rotation-feed-server (port 8796)
- **Failure:** Feed stops updating; clients serve stale data
- **Degradation:** Stale rotation data; pulse daemon may trigger re-cycle
- **Auto-recover:** Watchdog → systemd restart; auto-heal forces pulse cycle if feed >10min stale

### fleet-midi agents (ports 2160–2175)
- **Failure:** Individual MIDI agent goes down; others unaffected
- **Degradation:** That agent's slots are unavailable; others continue
- **Auto-recover:** Watchdog → `systemctl --user try-restart fleet-midi@N`

### construct-pulse daemon
- **Failure:** Pulse loop dies; rotation feed stops updating
- **Degradation:** Feed goes stale after ~10min; auto-heal triggers HUP signal
- **Auto-recover:** Watchdog detects binary down → restart
- **Manual recovery:** `construct-pulse-daemon.sh &` (foreground)

### reflex-daemon / meta-reflex-daemon
- **Failure:** Reflex engine stops; auto-heal not triggered on conditions
- **Degradation:** Conditions accumulate without response; watchdog still runs on timer
- **Auto-recover:** Watchdog → restart
- **Manual recovery:** Check pid files; restart via `reflex-daemon.sh &`

### gc-pid-bridge (Rust binary)
- **Failure:** Bridge process dies; GC coordination with headspace may break
- **Degradation:** GC still runs on schedule; coordination signals lost
- **Auto-recover:** Watchdog checks binary executable → restart

---

## Alert Levels

| Level | Meaning | Action |
|-------|---------|--------|
| `info` | Something was fixed automatically | Log only; notify if configured |
| `warn` | Auto-heal attempted but service still down; or degraded state | Post to fleet-event; notify configured channel |
| `critical` | Service has been restart-flapping (>3x in 5min); or data loss imminent | Immediate alert; disable auto-restart for that service |

---

## Data Durability Guarantees

### What survives restart

| Data | Survives restart? | Survives crash? | Notes |
|------|-------------------|------------------|-------|
| rotation-feed.json | ✅ | ✅ (on disk) | Checkpointed on graceful shutdown |
| fleet-oracle endpoint cache | ✅ | ✅ (on disk) | Persisted to disk |
| fleet-log buffer | ❌ | ❌ | In-memory only; buffer ~5min |
| fleet-event in-flight events | ❌ | ❌ | Not persisted |
| Construct memory (headspace-rs) | ❌ | ❌ | In-memory only |
| Checkpoint manifests | ✅ | ✅ | Written to `construct/data/` |

### Checkpoint on graceful shutdown

`graceful-shutdown.sh` creates:
- Copy of `rotation-feed.json` → `construct/data/rotation-feed-YYYYMMDD-HHMMSS.json`
- Last 500 lines of each log file → `*-snap-YYYYMMDD-HHMMSS.log`
- Manifest with decisions, services running, GC status, system state

### What does NOT survive

- In-memory queues (fleet-log, fleet-event) — events in flight are dropped on crash
- headspace-rs memory state — gone on crash; service must re-learn
- Per-service in-memory caches — all cleared on restart

---

## Crash-Only Philosophy (Rust Services)

Rust services in this fleet (headspace-rs, gc-pid-bridge) follow a **crash-only** contract:

### Required signals

| Signal | Behavior |
|--------|----------|
| `SIGTERM` | Graceful shutdown: flush buffers, finish in-flight requests, exit 0 |
| `SIGINT` | Same as SIGTERM |
| `SIGKILL` | Immediate termination; no flush; crash-only fallback |

### Implementation requirements

```rust
// Every Rust service MUST handle SIGTERM:
fn main() {
    // Set up signal handler
    tokio::spawn(async {
        tokio::signal::ctrl_c().await.unwrap();
        // flush_and_shutdown().await;
        std::process::exit(0);
    });

    // ... service logic
}
```

### Why crash-only?

1. **Simplicity:** No complex state machines for shutdown/startup transitions
2. **Reliability:** Each restart is a fresh start; no half-connected state
3. **Observability:** Crash = visible failure; no silent degradation
4. **Fast recovery:** Restart is faster than graceful teardown in most cases

### What crash-only does NOT mean

- It does NOT mean "ignore errors"
- It does NOT mean "no error handling"
- Rust services MUST still use `Result`, `?`, proper error logging, and `anyhow`/`thiserror` for meaningful errors
- It means: **when something unexpected goes wrong, crash and let the watchdog restart** rather than trying to limp along in a broken state

---

## What We CAN'T Auto-Recover From

### Data loss (irreversible)

- Events in fleet-event in-flight queue — lost on crash; no replay
- headspace-rs in-memory state — lost on crash; must re-learn
- fleet-log buffered events — lost on crash

**Mitigation:** Run graceful-shutdown before maintenance; checkpoint regularly

### Partition / network split

- If fleet-oracle goes down AND the watchdog can't reach it to POST events, the system operates in a degraded state with no visibility
- **Mitigation:** Fleet-oracle should be co-located with watchdog on same host; use local loopback

### Disk full (>95%)

- No service can write; even restart attempts may fail to write PID files
- **Mitigation:** Alert at 90% (auto-heal triggers GC); alert at 95% (human required)

### OOM kills (headspace-rs, gc-pid-bridge)

- Linux OOM killer may SIGKILL before watchdog can respond
- **Mitigation:** Set memory limits via systemd (`MemoryMax=`); monitor with watchdog binary check

### Corrupt state files

- If rotation-feed.json is corrupted, services may fail to start
- **Mitigation:** Checkpoint on graceful shutdown; keep last 2 rotation feeds

### Configuration drift

- If a service is misconfigured, auto-restart will just keep failing
- **Mitigation:** Flap detection (>3 restarts in 5min) escalates to `critical` alert and disables further auto-restart

### Cascading failures

- If fleet-event and fleet-log both go down simultaneously, the watchdog may not be able to POST its summary
- **Mitigation:** Watchdog logs locally to `/tmp/fleet-watchdog.log` even if POST fails; check logs manually

---

## Recovery Procedures

### Automatic (watchdog + auto-heal)

```
Every 2 minutes:
  watchdog.sh → checks all services
              → if DOWN → try-restart via systemd
              → POST summary to fleet-event
              → exit 0/1/2/3

On alert conditions:
  auto-heal.sh → headspace-rs down    → restart + warn alert
              → fleet-oracle down     → restart + warn alert
              → disk >90%            → force GC + info alert
              → feed stale >10min     → cycle pulse + warn alert
              → flap >3 in 5min      → critical alert (disable auto-restart)
```

### Manual: Single service down

```bash
# Check status
systemctl --user status fleet-oracle

# Restart
systemctl --user restart fleet-oracle

# Check logs
journalctl --user -u fleet-oracle -n 50 --no-pager
```

### Manual: All services down (cascade)

```bash
# Restart in dependency order
systemctl --user restart fleet-event
systemctl --user restart fleet-log
systemctl --user restart fleet-oracle
systemctl --user restart fleet-conductor
systemctl --user restart rotation-feed-server

# Restart daemons
/home/ubuntu/.openclaw/workspace/construct/scripts/construct-pulse-daemon.sh &
/home/ubuntu/.openclaw/workspace/construct/scripts/reflex-daemon.sh &

# Verify
/home/ubuntu/.openclaw/workspace/construct/scripts/watchdog.sh
```

### Manual: Disk full

```bash
# Check what's using space
du -sh /home/ubuntu/.openclaw/workspace/construct/data/*
du -sh /tmp/*.log

# Run GC manually
/home/ubuntu/.openclaw/workspace/construct/scripts/gc-intelligent.sh --execute

# Or force aggressive cleanup
/home/ubuntu/.openclaw/workspace/construct/scripts/gc-intelligent.sh --aggressive
```

### Manual: Checkpoint recovery

```bash
# List checkpoints
ls -lt /home/ubuntu/.openclaw/workspace/construct/data/checkpoint-*.json | head -5

# Read a checkpoint manifest
cat /home/ubuntu/.openclaw/workspace/construct/data/checkpoint-20250614-091500.json

# Restore rotation feed from checkpoint
cp /home/ubuntu/.openclaw/workspace/construct/data/rotation-feed-20250614-091500.json \
   /home/ubuntu/.openclaw/workspace/construct/data/rotation-feed.json
```

---

## Watchdog Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All services healthy |
| 1 | One or more services degraded (HTTP check failed but port open) |
| 2 | One or more services down |
| 3 | Errors encountered (POST failed, restart failures, etc.) |

---

## Files Reference

| File | Purpose |
|------|---------|
| `construct/scripts/watchdog.sh` | Main health check + auto-recovery |
| `construct/scripts/auto-heal.sh` | Condition-based healing (reflex triggers) |
| `construct/scripts/graceful-shutdown.sh` | Clean shutdown with checkpoint |
| `construct/systemd/fleet-watchdog.service` | Systemd oneshot service |
| `construct/systemd/fleet-watchdog.timer` | Systemd timer (every 2 min) |
| `construct/data/checkpoint-*.json` | Shutdown checkpoint manifests |
| `/tmp/fleet-watchdog.log` | Watchdog log |
| `/tmp/fleet-watchdog-summary.json` | Last watchdog JSON summary |
| `/tmp/fleet-restart-counts.json` | Restart flap counter |
| `/tmp/gc-last-run` | Unix timestamp of last GC run |
