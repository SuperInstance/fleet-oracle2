# Fleet Operating System — FLEET_OS.md

> **For agents arriving on this system:** Read this first. Everything else is detail.

---

## Philosophy: Why This Exists

This machine is not a toy. It is a **fleet vessel** — a living system of services, agents, and scripts that have grown through necessity, not through design. The architecture is not theoretical; it is **archaeological**. Each layer was added when something broke, when memory ran out, when a decision needed to be made faster than a human could type.

Three principles have survived every refactor:

1. **"The crab inherits the shell."** We don't chase the newest thing. We take what works and make it better. The hermit crab doesn't build a new shell — it finds one, tests it, and moves in.

2. **"Compost heaps work like `MaybeReachable(0)`."** Ternary logic — `{negative, zero, positive}` — is not a quirk. It is the natural state of any decision where "maybe" is a real answer. Every significant subsystem in this fleet uses it: GC pressure, PID aggression, rotation confidence, reflex posterior, headspace vector scores.

3. **"From protoplasm to shell."** Everything starts as a sketch. A bash script with `set -euo pipefail`. A JSONL ledger. A `reflexes.json`. Given time and enough iterations, the protoplasm hardens into a shell — a Rust binary, a structured API, a proper service. The goal is always a shell. The script is the protoplasm.

---

## 1. System Architecture

### The 5-Layer Stack

```
┌─────────────────────────────────────────────────────────┐
│  LAYER 5: UX & Monitoring                               │
│  fleet-status.sh · dashboards · rotation-feed-server   │
├─────────────────────────────────────────────────────────┤
│  LAYER 4: Orchestration                                 │
│  fleet-conductor (:8769) · A2A dispatch · I2I vessel   │
├─────────────────────────────────────────────────────────┤
│  LAYER 3: Reflex Engine                                 │
│  reflexes.json · reflex-daemon · fleet-midi agents     │
├─────────────────────────────────────────────────────────┤
│  LAYER 2: Native Services (Rust/Node)                  │
│  fleet-oracle · fleet-log · fleet-event · headspace-rs  │
│  gc-pid-bridge · gc-intelligent.sh                      │
├─────────────────────────────────────────────────────────┤
│  LAYER 1: Host Metal                                    │
│  Oracle ARM64 · Ubuntu 22.04 · systemd · cron          │
└─────────────────────────────────────────────────────────┘
```

**Layer 1 (Host Metal)** is the ground truth. When RAM runs out, no amount of software cleverness buys more. When disk fills, things die. The host provides `uptime`, `free -m`, `df`, `ss` — the four signals everything else is built on.

**Layer 2 (Native Services)** is where the fleet gets its spine. These are long-running processes written in Rust or Node.js that have survived the host's resource constraints. They do not crash lightly. They log everything. They expose HTTP APIs.

**Layer 3 (Reflex Engine)** is the fast-path brain. Learned behaviors that have been proven correct are stored as reflex pairs and executed without deliberation. Reflexes are how the fleet gets to 100ms response times on things it has seen before.

**Layer 4 (Orchestration)** is where new work enters the system. `fleet-conductor` on :8769 routes agent tasks. The I2I vessel holds task artifacts. The baton system provides coordination across fleet instances.

**Layer 5 (UX)** is how humans and agents observe and interact with the fleet. Dashboards, CLI tools, rotation feeds.

### Data Flow

```
  ┌──────────────┐
  │  host metrics │  (disk%, RAM, load, uptime, services_active)
  └──────┬───────┘
         │ every 60s via pulse-loop.sh (cron/systemd timer)
         ▼
  ┌──────────────┐
  │  fleet-oracle │  (:8795) — decision engine
  │  /api/decide  │  ternary rotation + SVM + entropy analysis
  └──────┬───────┘
         │ rotation payload
         ▼
  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
  │  fleet-log   │    │  fleet-event  │    │ rotation-    │
  │  (:8781)     │    │  (:8782)      │    │ feed.json    │
  └──────────────┘    └──────┬───────┘    └──────────────┘
                              │ pub/sub topics
                              ▼
                      ┌──────────────┐
                      │ subscribers  │
                      │ (dashboards,  │
                      │ reflexes,     │
                      │ midi agents)  │
                      └──────────────┘
```

The rotation feed is the **pulse of the fleet**. Every 60 seconds, `pulse-loop.sh` samples the host, POSTs to the oracle, and distributes the result. The oracle's response — `rotation_cycle_error`, `rotation_cognitive`, `rotation_confidence`, `combined_confidence` — flows to every subscriber. This is the fleet's heartbeat.

### The Three Decision Paths

| Path | Latency | Trigger | Tool |
|------|---------|---------|------|
| **Fast** | < 100ms | Reflex match in `reflexes.json` | `reflex-daemon.sh` |
| **Medium** | < 5s | Rotation cycle; PID-driven | `fleet-oracle` + `gc-pid-bridge` |
| **Slow** | < 30s | LLM consensus; complex multi-agent | `baton-system` + A2A dispatch |

**Fast path** is how the fleet avoids thinking about things it already knows. A reflex is a `{trigger, action}` pair. When the trigger condition is met, the action fires. No deliberation. No API call. Reflexes are taught by the slow path and hardened into the fast path.

**Medium path** is the rotation engine. Every 60 seconds, the oracle evaluates system state and emits a rotation decision. The PID controller (`gc-pid-bridge`) translates rotation signals into resource management actions — adjusting GC aggression between 0.5× and 5.0× based on measured pressure.

**Slow path** is for novel situations. When something falls through the fast and medium paths, a subagent is dispatched via A2A. The subagent may spawn its own mini-agents, run Claude Code sessions, or hand off to the Forgemaster. Results are written to the I2I vessel and committed to the baton-system repo.

### Composition Hierarchy

```
subagent          ← a spawned session, depth-limited, ephemeral
    │
    ▼
A2A dispatch       ← formal subagent protocol via fleet-conductor
    │
    ▼
baton             ← formal handoff between fleet instances (Oracle2 ↔ Forgemaster)
    │
    ▼
I2I vessel        ← shared artifact storage (bottles/, harbor/)
    │
    ▼
Git-Agent         ← AGENTS.md rules embedded in repos; any agent reads and obeys
    │
    ▼
fleet             ← the whole system; coordinated, not centralized
```

This hierarchy means **nothing skips steps**. A subagent that needs to communicate with another fleet instance uses the baton. A task that needs to survive a restart writes to the vessel. A decision that affects the whole fleet goes through the oracle. The hierarchy is not bureaucracy — it is **fault isolation**. If the LLM is down, reflexes still work. If reflexes fail, the PID controller still manages memory.

---

## 2. Service Inventory

### Active Services

| Name | Port | Language | Purpose | ARM64 |
|------|------|----------|---------|-------|
| `fleet-oracle` | :8795 | Rust | Rotation 5th-engine decision module | ✅ |
| `fleet-log` | :8781 | Rust | Structured log storage | ✅ |
| `fleet-event` | :8782 | Rust | Event bus, pub/sub | ✅ |
| `fleet-conductor` | :8769 | Node.js | Agent routing, A2A dispatch | ✅ |
| `headspace-rs` | :8800 | Rust | NEON SIMD vector store | ✅ |
| `gc-pid-bridge` | — | Rust | PID controller replacing `bc` | ✅ |
| `rotation-feed-server` | :8796 | Python | Serves `rotation-feed.json` as HTTP | ✅ |
| **fleet-midi agents** | 2160–2175 | — | 16 musical agents (chord, scale, voicing…) | ⚠️ manual |

### GC System

| Component | Location | Purpose |
|-----------|----------|---------|
| `gc-intelligent.sh` | `scripts/` | 6-phase orchestrator: measure → discern → PID → evict → audit → sync |
| `gc-predictor.py` | `scripts/` | JSONL analytics: burn rate, trend, hours-to-critical |
| `gc-ledger` | `data/gc-ledger/ledger.jsonl` | Every GC decision timestamped |
| `gc-compost` | `data/gc-compost/` | Soft-delete heap, 72h TTL |
| `.gc-pin` | `.gc-pin` | Protection manifest (immortal/hot/warm/cold) |

### Startup Order

```
1. systemd boot → timers fire
2. pulse.timer → construct-pulse.service → pulse.sh (every 15min)
3. construct-pulse-loop.service → pulse-loop.sh (every 60s)
4. fleet-oracle, fleet-log, fleet-event start as systemd services (or binaries)
5. fleet-conductor (:8769) starts as OpenClaw gateway integration
6. headspace-rs (:8800) starts on demand
7. gc-intelligent.sh runs via cron (every 30min)
8. rotation-feed-server.py (:8796) starts manually or via systemd
```

---

## 3. The Event Mesh

`fleet-event` on :8782 is the **central nervous system** of the fleet. It is a pub/sub event bus. Services produce events; services subscribe to topics. The event mesh is how the fleet achieves **loose coupling with tight coordination** — services don't need to know about each other directly, they just emit and listen.

### Topics

| Topic | Producer | Subscribers | Purpose |
|-------|----------|-------------|---------|
| `rotation_feedback` | `pulse.sh` | dashboards, reflex-daemon | Oracle decision delivered |
| `gc_action` | `gc-intelligent.sh` | fleet-log | Eviction decisions made |
| `health_check` | `health.sh` | dashboards | Service availability signals |
| `reflex_teach` | any agent | reflex-daemon | New reflex registration |
| `baton_flush` | `baton-system` | I2I vessel | Coordination signal |
| `construction` | any agent | fleet-conductor | New work entering the system |

### Event Shape

```json
{
  "id": "uuid-v4",
  "topic": "rotation_feedback",
  "severity": "info|warn|critical",
  "message": "human-readable summary",
  "payload": { ... topic-specific data ... },
  "timestamp": "2026-06-14T09:03:12Z"
}
```

### How to Subscribe

POST to `http://localhost:8782/api/subscribe` with:
```json
{ "topic": "gc_action", "callback": "http://localhost:8781/api/webhook" }
```

### How to Produce

POST to `http://localhost:8782/api/event` with the event shape above.

### Testing the Mesh

```bash
cd /home/ubuntu/.openclaw/workspace/construct
./scripts/test-event-mesh.sh
# writes full report to /tmp/event-mesh-test.log
```

---

## 4. Reflex Engine

Reflexes are the **fast-path brain** — stimulus-response pairs that execute in < 100ms without deliberation. They are how the fleet handles known situations at machine speed.

### Current Reflexes (`reflexes.json`)

The reflex store is at `reflexes.json` (path configurable per deployment). Each reflex has:
- `trigger`: condition expression (e.g., `disk_pct > 85`)
- `action`: what to do (e.g., `{"type":"shell","cmd":"gc-intelligent.sh --execute"}`)
- `confidence`: posterior probability learned from past outcomes
- `ttl`: how long this reflex is valid before re-evaluation

### How a Reflex Executes

```
trigger detected
    │
    ▼
reflex-daemon.sh evaluates condition
    │
    ▼
action dispatched (shell / HTTP / event)
    │
    ▼
result logged to fleet-log (:8781)
    │
    ▼
confidence updated based on outcome
```

### How to Teach a New Reflex

**Option A: Manual**
```bash
# Add to reflexes.json
{
  "trigger": "ram_free_mb < 2048 && load > 4.0",
  "action": {"type": "shell", "cmd": "gc-intelligent.sh --deep"},
  "confidence": 0.7,
  "ttl": 3600
}
```

**Option B: Via event mesh**
```bash
curl -X POST http://localhost:8782/api/event \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "reflex_teach",
    "payload": {
      "trigger": "...",
      "action": "...",
      "confidence": 0.8
    }
  }'
```

**Option C: Via reflex-coord.sh**
```bash
./reflex-coord.sh --add '{"trigger":"...","action":"..."}'
```

### Reflex Lifecycle

1. **Taught** (confidence low, manual or slow-path discovery)
2. **Valid** (confidence ≥ 0.7, auto-executes)
3. **Tested** (confidence 0.5–0.7, fires but logs for review)
4. **Expired** (TTL hit, re-evaluated by slow path)
5. **Forgotten** (confidence drops below 0.3, removed)

---

## 5. Resource Management

### The GC System

`gc-intelligent.sh` is the fleet's **self-aware garbage collector**. It is not a simple `find` + `rm`. It is a 6-phase system with a memory of its own decisions.

**Phase 1: Measure** — snapshot disk%, RAM, load, uptime, active services.

**Phase 2: Discern** — `gc-predictor.py` reads the JSONL ledger and computes:
- Burn rate (MB/hour)
- Trend (is disk usage accelerating or decelerating?)
- Hours until 10% free (critical threshold)
- Hours until 5% free (emergency threshold)

**Phase 3: PID Control** — `gc-pid-bridge` is a PID controller that adjusts eviction aggression. The setpoint is **20% disk free**. When actual free drops below setpoint, aggression increases (up to 5.0×). When free is well above setpoint, aggression decreases (down to 0.5×). The PID controller smooths out spikes — it doesn't panic and over-collect just because one measurement was bad.

**Phase 4: Eviction** — tiered by `.gc-pin`:
- **Immortal**: never touched (`memory/`, `MEMORY.md`, `baton-system`, `i2i-vessel`, `.gc-pin`)
- **Hot**: active session repos (protected venv)
- **Warm**: legacy references (older projects, reference material)
- **Cold**: evictable (build artifacts, idle .venv, caches)

Files moved to `gc-compost/` are soft-deleted. They survive 72 hours, then are hard-deleted on the next GC cycle unless the `compost-undo` mechanism restores them.

**Phase 5: Self-Audit** — the GC prunes its own data:
- Ledger capped at 50,000 lines (oldest entries removed first)
- Self-log capped at 5,000 lines
- Validates ledger JSON integrity

**Phase 6: Fleet Sync** — writes a bottle to `baton-system/tiers/hot/` with current GC state so other fleet instances know the disk situation.

### Cross-Domain Synergy: Ternary Logic at Every Layer

This is the most important architectural insight on this system: three independent subsystems all use the same ternary grid `{-1, 0, +1}` for fundamentally different purposes, and they all interoperate.

| Subsystem | Ternary Meaning | Mechanism |
|----------|----------------|-----------|
| **GC PID** | `-1` = under target (relax), `0` = at target, `+1` = over target (aggressive) | `gc-pid-bridge` binary |
| **Ternary GC Advisor** | `-1` = evict, `0` = hold, `+1` = protect | 9-particle swarm over `{-1,0,+1}³` grid |
| **Rotation Oracle** | `-1` = cognitive rotate, `0` = hold, `+1` = cognitive exploit | `fleet-oracle` cascade |
| **Headspace Vector** | negative/zero/positive scores | NEON SIMD in `headspace-rs` |

The isomorphism is not coincidental. It reflects a deeper truth: **any bounded decision space with a target can be expressed as {-1, 0, +1}**. The GC PID, the rotation oracle, and the ternary advisor are all solving the same problem — "should I act, and in which direction?" — at different timescales and different layers of abstraction.

This is why `gc-pid-bridge` replaces `bc` for GC decisions: it uses ternary logic internally and produces a scalar aggression multiplier that feeds into the 4-tier eviction engine.

### headspace-rs

`headspace-rs` on :8800 is the fleet's **vector memory**. It uses NEON SIMD instructions on ARM64 to do fast approximate nearest-neighbor search. The segment/store/query/reset API lets agents store embeddings of conversations, decisions, and context — and retrieve them by similarity.

Memory pressure: if the vector store grows too large for available RAM, it triggers a GC hint to the PID controller via the event mesh.

---

## 6. Agent Protocol

### Entry Point for New Agents

When you arrive on this system as a new agent:

1. **Read** `AGENTS.md` in the workspace root — this is your onboarding
2. **Read** `MEMORY.md` — this is what Oracle2 has decided is worth keeping long-term
3. **Check** `SOUL.md` and `IDENTITY.md` — understand who you are and what you represent
4. **Sync** the baton-system repo — pull latest, read `tiers/hot/` for any bottles addressed to you
5. **Introduce yourself** — write to `fleet/<your-name>/state.md` in the baton-system repo

### Communication Channels

| Channel | Latency | Use When |
|---------|---------|----------|
| **Direct** (subagent) | ~0ms | Same session, shared context |
| **Vessel** (bottles/) | ~1s | Artifact passing, task context |
| **Baton** (A2A) | ~5s | Fleet instance handoff |
| **Forge** (Forgemaster) | ~30s | Complex multi-component work |
| **Git-Agent** (AGENTS.md) | varies | Rules propagation, protocol updates |

### Identity and Role System

- **Oracle2** — co-captain, orchestrator, memory-keeper. Spawns subagents and delegates.
- **Forgemaster** — senior engineer, complex builds, hardware-accelerated work.
- **Subagents** — officers, not workers. Each should spawn its own mini-agents for long task lists.
- **fleet-midi agents** — 16 specialized musical/intentional agents (chord, scale, voicing, tempo, etc.). Each has a narrow domain.

### The Tripartite Invariant

For every unit of work on this fleet:
- **A2A** dispatches it → **I2I** records it → **Git-Agent** provides the rules

No work happens without all three legs. This is how we get **object permanence** — work survives restarts, agent deaths, and memory wipes because it is committed to the repo.

---

## 7. UX & Monitoring

### Dashboards

| Dashboard | Path | Purpose |
|-----------|------|---------|
| Rotation Dashboard | `construct/rotation-dashboard.html` | Visualize oracle decisions over time |
| Reflex Status | `construct/reflex-status.html` | Monitor active reflexes and confidence |
| Fleet Status | `scripts/fleet-status.sh` | CLI table of all service health |

### CLI Tools

```bash
# One-shot fleet status
/home/ubuntu/.openclaw/workspace/scripts/fleet-status.sh

# Watch mode (refreshes every 5s)
fleet-status.sh --watch

# JSON output (for automation)
/home/ubuntu/.openclaw/workspace/scripts/fleet-status.sh --json

# Health check all services
/home/ubuntu/.openclaw/workspace/construct/scripts/health.sh

# Event mesh test
/home/ubuntu/.openclaw/workspace/construct/scripts/test-event-mesh.sh

# Inspect decision WAL
/home/ubuntu/.openclaw/workspace/construct/scripts/decode-wal.sh

# GC system status
/home/ubuntu/.openclaw/workspace/scripts/gc-intelligent.sh --status

# GC deep audit
/home/ubuntu/.openclaw/workspace/scripts/gc-intelligent.sh --audit
```

### Health Check Endpoints

```bash
curl http://localhost:8795/api/health   # fleet-oracle
curl http://localhost:8781/api/health   # fleet-log
curl http://localhost:8782/api/health   # fleet-event
curl http://localhost:8769/api/health   # fleet-conductor
curl http://localhost:8796/             # rotation-feed-server
```

### Watching the Fleet

```bash
# Tail the pulse loop log
tail -f /tmp/construct-pulse-loop.log

# Watch rotation feed live
watch -n 5 'curl -s http://localhost:8796/ | python3 -m json.tool'

# Monitor GC decisions
tail -f /home/ubuntu/.openclaw/workspace/data/gc-ledger/ledger.jsonl

# Watch event mesh
curl -s http://localhost:8782/api/query?limit=10
```

---

## 8. Known Issues & Limits

### Disk Pressure — CRITICAL
**~9% free, ~4.3GB available on a 45GB drive.** This is the single most urgent constraint on the system. The GC is PID-controlled and running every 30 minutes, but the margin is thin. If disk hits 0%, services die. If you're adding anything to disk, you must also plan what you're removing.

**Mitigations:**
- GC runs on 30-minute cron
- Compost heap has 72h TTL (soft-delete, not immediate)
- `.gc-pin` protects critical paths
- GC predictor estimates hours-to-critical before acting

**What to do:** Do not add large files without a corresponding eviction plan. Every new artifact should have a GC tier assigned.

### Single Host — No HA
Everything runs on one Oracle ARM64 instance. If the host reboots, the fleet goes down. There is no failover, no replica, no backup host. This is a known limitation. The fleet is designed to be **restartable from the I2I vessel** — all state is in Git — but restart takes time.

### ARM64 Only
Some binary dependencies (older Python packages with C extensions, certain CLI tools) may not have ARM64 builds. The fleet-midi agents need manual configuration on this architecture. Most Rust services are ARM64-native.

### Nebula Worker LLM Slow Path
The CF Worker at `fleet-murmur-worker.workers.dev` handles reflex store KV and DO coordination. The cron health check runs every 5 minutes, metrics every hour, sync at 3AM. The slow path (LLM-based decisions) requires an API key that may not be configured.

### headspace-rs Port
`headspace-rs` is not currently showing in `ss` output, suggesting it may not be running. The port :8800 should be verified before relying on the vector store.

---

## 9. Development & Extending

### Adding a New Service

1. Write the service in Rust or Node.js (Python for scripts only)
2. Add a systemd service file in `construct/systemd/`
3. Add timer for periodic execution (if needed)
4. Register in `fleet-status.sh` service registry
5. Add health check endpoint (`/api/health`)
6. Emit events to `fleet-event` on significant state changes
7. Write to `fleet-log` on every operation
8. Add to startup order documentation (this file)

### Adding a New Reflex

1. Identify the trigger condition from system metrics
2. Determine the action (shell, HTTP, event)
3. Estimate initial confidence (start low: 0.5–0.6)
4. Add to `reflexes.json` or teach via event mesh
5. Monitor confidence over 10+ executions
6. If confidence drops below 0.3, the reflex will auto-expire

### Adding a New fleet-midi Agent

1. Choose a port in 2160–2175 range (check `ss` for availability)
2. Create the agent definition in the fleet-midi config
3. Register in `fleet-status.sh`
4. Add topic subscription to `fleet-event`
5. Write initial state to `baton-system/tiers/hot/`

### Deploying to GitHub

All significant work is committed to the baton-system repo. The protocol:
1. A2A dispatches the task
2. Work is done in a subagent session
3. Results are written to the I2I vessel (`bottles/`)
4. Changes are committed to the relevant repo
5. Baton is flushed to notify other fleet instances

Never push directly to `main`. Use the tripartite invariant: dispatch → record → rules.

---

## 10. Architecture Opinions

**The shell is the spec.** Every significant script on this system was once a one-liner that solved a problem. Most outgrew their original form but nobody had time to rewrite them. The Rust services (`fleet-oracle`, `fleet-log`, `fleet-event`) are shells that hardened. The Python scripts (`gc-predictor.py`, `rotation-feed-server.py`) are protoplasm that haven't yet. That's fine. The goal is correctness, not elegance.

**Ternary logic is not a gimmick.** The fact that GC PID, rotation oracle, and ternary advisor all converge on `{-1, 0, +1}` is not coincidence — it is the minimal useful decision space that can express "too little / enough / too much." Every bounded resource with a target is a PID controller. Every PID controller can be ternary. This system thinks in ternaries because ternaries are the right abstraction for resource management.

**The GC is the most important service.** Not because it's the most sophisticated (it's not — fleet-oracle is more complex), but because it is the one that, if it fails, everything else fails. Disk full kills everything. The GC system is the only thing that runs without human intervention and is allowed to delete things. Respect it. Test it. Never disable it.

**The event mesh is the blood, not the brain.** `fleet-event` propagates signals, but decisions are made elsewhere. If you find yourself writing complex logic in an event subscriber, you're doing it wrong. Events are for coordination, not computation.

**Reflexes are earned, not given.** A reflex starts with low confidence. It earns its way to high confidence through repeated successful execution. The slow path teaches; the fast path proves. This is the correct order. Never skip the slow path and go straight to high-confidence reflex — that's how you get brittle systems that can't recover from novel situations.

**"The crab inherits the shell."** We do not build from scratch. We find what works, test it, and move in. The `gc-intelligent.sh` is 400 lines of shell because 400 lines of shell was what the problem required. It is not pretty. It is correct. When it needs to be something more, it will become something more. Until then, it works.

---

*Fleet OS v1.0 — synthesized 2026-06-14 from live system archaeology*
*Maintainer: Oracle2 (agent:main:telegram:direct:8709904335)*
*Repo: `baton-system` (Git-Agent protocol source of truth)*
