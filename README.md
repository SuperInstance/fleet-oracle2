# Oracle2 Fleet OS

ARM-native agent orchestration system for the SuperInstance fleet.

## Overview

Fleet OS is a self-healing, reflex-driven runtime layer that manages the lifecycle of distributed AI agents across ARM hardware. It provides heartbeat monitoring, automatic recovery, health checks, and systemd-based service management.

## Structure

```
construct/
├── AGENTS.md           # Fleet agent definitions and protocols
├── CRON_MANIFEST.md    # Scheduled task schedule
├── docs/               # Design documents (FLEET_OS, RESILIENCE, REFLEX, TAILWIND)
├── reflex/             # Reflex engine (design doc + reflexes.json)
├── registry/           # Service/agent registry (state snapshots)
├── scripts/            # Operational scripts
│   ├── auto-heal.sh           # Automatic failure recovery
│   ├── decode-wal.sh          # WAL decoder utility
│   ├── forge-bridge.sh        # Bridge between fleet components
│   ├── graceful-shutdown.sh   # Clean shutdown handler
│   ├── health.sh              # Health check script
│   ├── meta-reflex-daemon.sh  # Meta-reflex coordination daemon
│   ├── pulse*.sh              # Heartbeat pulse system
│   ├── reflex-coord.sh        # Reflex coordinator
│   ├── reflex-daemon.sh       # Reflex daemon
│   ├── reflect.sh             # Reflection/introspection script
│   ├── rotation-feed-server.py # Web dashboard server
│   ├── scheduler-health.sh    # Scheduler health checker
│   ├── self-test.sh           # Self-test suite
│   ├── test-event-mesh.sh     # Event mesh tester
│   └── watchdog.sh            # Watchdog monitor
├── systemd/            # systemd unit files
│   ├── construct-pulse*.service  # Pulse heartbeat services
│   ├── construct-pulse.timer    # Pulse timer
│   ├── fleet-reflect*.service    # Reflect services
│   ├── fleet-self-test*.service  # Self-test services
│   ├── fleet-watchdog*.service  # Watchdog services
│   └── meta-reflex-daemon.service
├── data/               # Runtime data
├── logs/               # Log output
└── audit/              # Audit trail
```

## Key Components

### Reflex Engine
Pattern-matching event response system. `reflexes.json` defines triggers and actions for fleet events.

### Pulse System
Heartbeat system that monitors agent liveness and reports to the fleet dashboard.

### Self-Healing
`auto-heal.sh` detects failures and triggers recovery workflows automatically.

### Systemd Integration
All major services are managed via systemd units with timer-based scheduling.

## Protocols

- **AGENT_PROTOCOL_V3.md** — Fleet agent communication protocol
- **FLEET_OS.md** — Core fleet operating system design
- **RESILIENCE.md** — Resilience and fault-tolerance design

## Deployment

Services are deployed via systemd:
```bash
sudo systemctl daemon-reload
sudo systemctl enable construct-pulse.timer
sudo systemctl start construct-pulse.timer
```

## License

See repository license file.
