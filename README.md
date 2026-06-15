# fleet-oracle2 — Construct Stack

A self-aware agent orchestration OS running on **Oracle Cloud ARM64 free tier**.
Every 5 minutes, the construct measures itself, computes a conservation metric,
embeds its state into a semantic vector store, detects anomalies, tunes its own
GC aggressiveness, and optionally auto-evicts dead weight — all without human
intervention.

> "A garbage collector that cannot examine its own past mistakes
>  is doomed to repeat them."

---

## Architecture

```
                          ┌──────────────────────────────────────────┐
                          │           9-Step Pulse Pipeline          │
                          │         (cron: every 5 minutes)          │
                          └──────────────────────────────────────────┘
                                       │ 1. collect_metrics
                                       │ 2. compute γ, η
                                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐              │
│  │harbor-da.│◄──│pulse-    │   │conserva- │◄──│pulse-    │   ┌───────┐ │
│  │:8797/TCP │   │metric.sh │──►│tion-meter│   │metric.sh │   │head-  │ │
│  │:8796/TCP │   │          │   │:8798     │   │          │   │space  │ │
│  └─────────┘   └────┬─────┘   └──────────┘   └────┬─────┘   │:9090  │ │
│       ▲             │                              │         └───┬───┘ │
│       │      ┌──────▼─────┐               ┌───────▼─────┐       │     │
│       │      │pulse-      │               │pulse-       │  ┌────▼───┐ │
│       │◄─────│webhook.sh  │               │embed.sh     │  │pulse-  │ │
│       │      │: Telegram  │               │: 384-dim    │  │anomaly │ │
│       │      └────────────┘               │embedding    │  │.sh     │ │
│       │                                   └─────────────┘  └────────┘ │
│  ┌────┴─────────┐    ┌──────────────┐     ┌──────────────────┐        │
│  │pulse-self-   │    │gc-auto-evict │     │rotation-feed     │        │
│  │tune.sh       │───►│.sh           │     │:8799 (HTTP)      │        │
│  │(metabolic    │    │→ gc-intelli- │     │data/rotation-    │        │
│  │feedback)     │    │  gent.sh     │     │feed.json (JSONL) │        │
│  └──────────────┘    └──────────────┘     └──────────────────┘        │
│                                                                         │
│  ┌────────────┐  ┌─────────────┐  ┌────────────┐  ┌────────────────┐  │
│  │gc-pid-     │  │gc-pid-bridge│  │fleet-sync  │  │construct-      │  │
│  │server.py   │  │(Rust binary)│  │→ baton     │  │dashboard       │  │
│  │:8785       │  │(controller) │  │system      │  │:8800           │  │
│  └────────────┘  └─────────────┘  └────────────┘  └────────────────┘  │
│                                                                         │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐  ┌──────────────────┐     │
│  │fleet-o.  │  │fleet-log │  │fleet-event │  │reflex-daemon     │     │
│  │:8795     │  │:8781     │  │:8782       │  │meta-reflex-daemon│     │
│  └──────────┘  └──────────┘  └────────────┘  └──────────────────┘     │
│                                                                         │
└─────────────────────────── Oracle2 (aarch64) ───────────────────────────┘
```

### Feedback Loops (closed)

1. **Metabolic** — `pulse-self-tune.sh` reads γ/η ratio, adjusts GC setpoint
2. **Auto-evict** — `gc-auto-evict.sh` triggers GC when setpoint ≤ 15%
3. **Anomaly** — `pulse-anomaly.sh` vs headspace-rs vector store (cosine sim < 0.85)
4. **Alert** — `pulse-webhook.sh` fires Telegram + harbor bottles on ratio ≥ 3.0/5.0
5. **Daily sync** — `fleet-sync-to-baton.sh` writes intelligence bottle to baton-system

---

## Services

| Port | Service | Type | Role |
|------|---------|------|------|
| 8785 | gc-pid-server.py | HTTP daemon | PID aggression queries wrapping gc-pid-bridge |
| 8795 | fleet-oracle | HTTP | Decision-making oracle (`/api/decide`) |
| 8781 | fleet-log | HTTP | Event log store |
| 8782 | fleet-event | HTTP | Event bus |
| 8796 | harbor-daemon | TCP | Bottle message queue (BOTTLE protocol, I2I v2) |
| 8797 | harbor-daemon (health) | HTTP | Harbor health endpoint |
| 8798 | conservation-meter | HTTP | γ/η tracking (`/api/report`, `/api/status`) |
| 8799 | rotation-feed-server.py | HTTP | Serves rotation-feed.json |
| 8800 | construct-dashboard | HTTP | Stack dashboard (`fleet-construct-dashboard.html`) |
| 9090 | headspace-rs | HTTP | 384-dim vector store (`/api/segment`, `/api/query`) |

Plus supporting daemons (log to `/tmp/`):
- `reflex-daemon.sh` — event-driven reflex processor
- `meta-reflex-daemon.sh` — meta-monitoring, watches the watcher
- `supervisor.sh` — exponential-backoff process supervisor

---

## Pipeline (9 Steps, every 5 min)

1. **Collect metrics** — disk%, free RAM, load, uptime, active services
2. **Compute γ (complexity)** = `disk_pct × 10 + load × 100`
3. **Compute η (efficiency)** = `services_active × 10`
4. **POST to conservation-meter** — `:8798/api/report` stores γ/η/timestamp
5. **Append to rotation-feed** — JSONL at `data/rotation-feed.json` (max 1000)
6. **Send harbor bottle** — TCP to `:8796`, TTL 1 hour
7. **Embed in headspace-rs** — deterministic 384-dim metric projection → `/api/segment`
8. **Check webhook thresholds** — `pulse-webhook.sh` evaluates γ/η ratio vs 3.0/5.0, fires Telegram + alert bottles
9. **Run anomaly detection** — `pulse-anomaly.sh` queries headspace for nearest neighbor; <0.85 similarity = CONCERN, >3 consecutive = DRIFT
10. **Self-tune** — `pulse-self-tune.sh` adjusts GC setpoint (10–40%) based on ratio + trend
11. **Auto-evict** — `gc-auto-evict.sh` triggers `gc-intelligent.sh --execute` if setpoint ≤ 15%

> Step numbering in code reflects the original 9-step design; the actual pipeline is 11 steps.

---

## Configuration

### Thresholds (pulse-webhook.sh)

| Env | Default | Meaning |
|-----|---------|---------|
| `RATIO_WARN` | 3.0 | γ/η ratio → WARNING bottle |
| `RATIO_CRIT` | 5.0 | γ/η ratio → ALARM bottle |
| `CONFIDENCE_LOW` | 0.3 | combined_confidence → LOW_CONFIDENCE bottle |
| `TELEGRAM_ENABLED` | `false` | opt-in Telegram alerts |
| `TELEGRAM_BOT_TOKEN` | (construct token) | Bot API token |
| `TELEGRAM_CHAT_ID` | 8709904335 | Operator chat |

### GC Setpoints (pulse-self-tune.sh)

| Env | Default | Range | Meaning |
|-----|---------|-------|---------|
| `MIN_SETPOINT` | 10 | — | Most aggressive (keep 10% free) |
| `MAX_SETPOINT` | 40 | — | Most relaxed (allow 40% free) |
| Default | 20 | — | Normal GC target |

### GC PID (gc-intelligent.sh)

| Env | Default | Meaning |
|-----|---------|---------|
| `PID_BRIDGE` | `gc-pid-bridge` | ARM-optimized Rust PID binary |
| Kp | 5.0 | Proportional gain |
| Ki | 0.5 | Integral gain |
| Kd | 0.2 | Derivative gain |

Calibrate automatically: `./scripts/gc-intelligent.sh --calibrate`

### Eviction (gc-auto-evict.sh)

| Threshold | Default | Action |
|-----------|---------|--------|
| Trigger setpoint | 15 | Fire `gc-intelligent.sh --execute` |
| — | ≤ 5% | Compost with 72h TTL |

---

## Metrics

### γ/η — Conservation Constraint

```
γ (gamma)  = disk_pct × 10 + load × 100   ← production effort / complexity
η (eta)    = services_active × 10           ← contextual overhead
C          = γ + η                           ← total conservation effort
ratio      = γ / η                            ← stress signal
```

- **ratio < 2**: cool — system relaxed
- **ratio 2-4**: nominal — keep current setpoint
- **ratio 4-6**: stressed — GC gets more aggressive
- **ratio > 6**: critical — minimum setpoint (max aggression)

### Read Live

```bash
# Conservation meter
curl http://localhost:8798/api/status | jq .

# GC PID aggression
curl http://localhost:8785/api/aggression?used_pct=63 | jq .

# Harbor bottle count
curl http://localhost:8797/health | jq .

# Rotation feed
curl http://localhost:8799/ | jq .

# Headspace segment count
curl http://localhost:9090/api/status | jq .

# Fleet health
./scripts/health.sh

# GC dry-run + prediction
./scripts/gc-intelligent.sh --status

# GC audit (deep pattern analysis)
./scripts/gc-intelligent.sh --audit
```

### Data Files

```
data/
├── rotation-feed.json        ← JSONL pulse history (max 1000)
├── gc-ledger/
│   ├── ledger.jsonl          ← GC decision history
│   ├── trend.json            ← Trend predictions
│   ├── patterns.json         ← Pattern DB
│   ├── pid-state.json        ← Calibration state
│   └── calibration.json      ← Auto-tuned PID constants
├── gc-compost/               ← Soft-deleted files (TTL-based)
├── pulse-self-tune-state.json ← Current setpoint
├── .anomaly-state.json       ← Consecutive anomaly counter
└── anomalies/
    └── pulse-anomalies.jsonl ← Anomaly event log
```

---

## Related

| System | Role |
|--------|------|
| [baton-system](https://github.com/SuperInstance/baton-system) | Fleet intelligence hub — receives daily construct sync bottles |
| pincher | Hot-tier workload agent |
| i2i-vessel | I2I protocol v2 — bottle transport layer |
| ternary-pid | Rust PID controller (gc-pid-bridge) compiled for Neoverse-N1 |
| fleet-conductor | Higher-level fleet orchestration |

---

## Quick Start

```bash
git clone https://github.com/SuperInstance/fleet-oracle2 construct
cd construct

# Full startup
./scripts/start-fleet.sh

# Or manual: start the pulse cron pipeline
./scripts/pulse-metric.sh    # one-shot 5-min cycle
```

The pipeline logs to `/tmp/pulse-metric.log` and the construct data dir.
For permanent install: `systemctl enable --now construct-pulse.timer` and friends
in `systemd/`.

---

*Built on Oracle Cloud ARM64 — 4 OCPUs, 24GB RAM, 200GB NVMe, $0/mo.*
