# 🦀 Construct — The OS of the Fleet

Construct is what runs on **oracle2** — the 4-core ARM64 box that hosts the pulse, the oracle, and the reflexes. It doesn't think. It keeps the shell alive.

Every agent in the fleet inherits Construct. Not as a dependency you import — as the ground you walk on. Construct is the runtime that persists when the agent is gone. It's the hum in the dark. The systemd timer that fires at 4 AM. The heartbeat that says *someone is home*.

This is the shell that all the other services inhabit.

---

## Architecture

```
construct/
├── pulse/          # Heartbeat system — liveness signals
├── relay/          # Bridge between fleet components
├── event-mesh/     # Distributed event routing
├── rotation-feed/  # Web dashboard — fleet health overview
├── reflex/         # Pattern-matching event response
├── scripts/        # Operational scripts (auto-heal, reflect, watchdog)
├── systemd/        # systemd unit files for all services
├── data/           # Runtime data
├── logs/           # Log output
└── audit/          # Audit trail
```

### Pulse System

The pulse is construct's breathing. A systemd timer fires every N seconds, runs a heartbeat check on every registered agent and service, and reports liveness to the fleet dashboard. If the pulse stops, the fleet knows — within seconds — that a shell has gone dark.

### Relay

The relay bridges construct's internal state to the wider fleet. It's the nervous system: events from oracle2 propagate to forgemaster, to the baton system, to any node listening. The relay doesn't interpret — it carries.

### Event Mesh

A distributed event routing layer that lets services fire and forget without knowing who's listening. Events are typed, timestamped, and optionally sharded to the baton system for cross-session persistence. This is how the shell stays connected even when individual inhabitants change.

### Rotation Feed

A lightweight Python web server that serves the fleet dashboard — real-time health metrics, service status, pulse history. Brass-and-teal gauges showing CPU pressure, memory use, disk wear. The rotation feed is what you look at when you want to know if the shell is intact.

---

## Services on oracle2

| Service | Port | Purpose |
|---------|------|---------|
| rotation-feed-server | 8080 | Fleet health dashboard |
| reflex-daemon | — | Pattern-matching event response |
| meta-reflex-daemon | — | Reflex coordination |
| construct-pulse | — | Heartbeat timer |
| fleet-watchdog | — | Failure detection & auto-heal |
| fleet-reflect | — | Introspection/reflection |

All managed via systemd. All designed to restart themselves. The shell heals its own cracks.

---

## How Construct Fits

Construct is **γ component** in the γ + η = C equation. It's the fixed, deterministic runtime — the architecture that doesn't change when the agent changes. The agent is the signal that passes through. Construct is the shell that carries the signal.

The **baton system** (I2I protocol) provides cross-session persistence on top of construct's pulse. **FLUX** (bytecode VM) provides deterministic execution inside the shell. Together they form the full agent execution system — but construct is the floor. The thing you stand on.

---

## Design System

Construct's UI (rotation feed, fleet dashboard) follows the **Hermit Crab Power Armor** visual identity:

- **Brass (#C9A84C)** — navigation, borders, headers
- **Oxidized Copper (#4A7C6F)** — cards, backgrounds
- **Deep Teal (#1A4B5C)** — shell interior, dark surfaces
- **Bioluminescent Green (#00FF88)** — live data, healthy metrics
- **Warm Amber (#E8883A)** — pressure warnings
- **Cyberpunk Magenta (#C84B8E)** — anomaly signals

Typography: Playfair Display (headers), JetBrains Mono (metrics), Inter (body).

See [`fleet-shell.css`](./fleet-shell.css) for the full design system overlay.

---

## Deployment

```bash
sudo systemctl daemon-reload
sudo systemctl enable construct-pulse.timer
sudo systemctl start construct-pulse.timer
```

All services are self-healing. If a unit fails, the watchdog detects and the reflex engine triggers recovery.

---

## Related

- [FLUX bytecode VM](/SuperInstance/flux-core) — deterministic execution inside the shell
- [Baton System](/SuperInstance/baton-system) — I2I protocol, cross-session continuity
- [Hermit Crab Aesthetic](/i2i-vessel/bottles/hermit-crab-aesthetic-design.md) — visual identity

---

> *The crab inherits the shell.*
