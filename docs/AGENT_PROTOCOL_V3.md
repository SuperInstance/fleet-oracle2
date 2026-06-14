# Agent Protocol V3 — One Protocol to Rule Them All

**Version:** 3.0.0  
**Date:** 2026-06-14  
**Lineage:** Forgemaster Shell · Baton I2I · Nebula A2A · Reflex Engine · Rotation Oracle  
**Status:** Active — Oracle2 (ARM fleet node)

---

## One Protocol to Rule Them All

Every agent in the SuperInstance fleet — whether Oracle2, a fleet-midi subagent, the
Forgemaster, or a spawned mini-agent — operates through one unified interface built from
five composing layers. No agent needs to know all five; each layer provides what the layer
above it needs, and the composition is additive.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         THE FIVE-LAYER STACK                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Layer 5 · Rotation Oracle (5th Engine)                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Ternary SVM cascade: cycle_error + cognitive + confidence           │   │
│  │  Drives pulse-loop · heartbeat cadence · reflex confidence updates  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      │                                     │
│  Layer 4 · Reflex Engine (Fast Path)                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Pre-validated patterns · <100ms response · teach-once propagate   │   │
│  │  3+ high-confidence oracle validations → reflex candidate           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      │                                     │
│  Layer 3 · Forgemaster Shell (Handoff Protocol)                           │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  "The forge never cools" · commit discipline · evidence-based       │   │
│  │  CONTEXT.md cold-start bootstrap · HEARTBEAT.md task queue          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      │                                     │
│  Layer 2 · Baton I2I (Bottle / Harbor Protocol)                           │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Three shards: artifacts + reasoning + blockers                   │   │
│  │  Tiers: immortal / hot / warm / cold                               │   │
│  │  Fleet state via git-committed bottles                             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      │                                     │
│  Layer 1 · Nebula A2A (Subagent Dispatch + Service Discovery)              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  POST /api/agent/register · discover · task · result               │   │
│  │  fleet-murmur-worker on Cloudflare Workers                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Composition rule:** Each layer only talks to the layer directly below it. An agent
enters at the top and works down. A reflex fires from the bottom up.

---

## The Three Paths

Every request that enters the fleet is classified into one of three latency paths at the
Rotation Oracle layer. The classification determines which composing layers participate.

### Path 1 · Fast (Reflex, <100ms)

```
Event detected → Reflex engine → Pre-validated action → Fleet-log hit event
```

| Component | Role |
|-----------|------|
| **Trigger** | Metric threshold breach (disk >85%, confidence drop, etc.) |
| **Engine** | Local reflex cache + headspace-rs nearest-neighbor |
| **Action** | HTTP POST/PUT to target service endpoint |
| **Audit** | `reflex.hit` posted to fleet-event → fleet-log |

**Composition chain:**
- Layers 1+2 are bypassed (no A2A dispatch, no I2I bottle write)
- Layer 3 provides the reflex definition schema
- Layer 4 executes
- Layer 5 logs the confidence update

**Example:** `disk_usage > 85%` → reflex `disk-crisis` fires → `gc-pid-bridge` aggression
set to 5.0 → no oracle round-trip needed.

**Confidence gates:**
| Confidence | Behavior |
|------------|----------|
| 0.0–0.3 | Fire + always notify oracle |
| 0.3–0.7 | Fire + log for review |
| 0.7–0.9 | Fire silently |
| 0.9–1.0 | Locked — fire silently, oracle cannot override |

---

### Path 2 · Medium (Oracle Rotation, <5s)

```
Request → Rotation Oracle (SVM cascade) → Decision → Baton bottle + optional reflex teach
```

| Component | Role |
|-----------|------|
| **Trigger** | No reflex match, or reflex.miss event |
| **Engine** | fleet-oracle (:8795) — LLM inference with ternary SVM prior |
| **Rotation fields** | cycle_error · cognitive · confidence · entropy_surprise · rhythm_anomaly |
| **Output** | Decision + optional reflex.candidate event |

**Composition chain:**
- Layer 1: nebula may dispatch subagent to execute the decision
- Layer 2: decision written as BOTTLE to `baton-system/tiers/hot/`
- Layer 3: HEARTBEAT.md updated with task if needed
- Layer 4: oracle teaches new reflex if pattern validated 3+ times
- Layer 5: rotation fields appended to `rotation-feed.json`

**Example:** New GC pattern detected → oracle validates response → emits
`reflex.candidate` on fleet-event → reflex-coord.sh validates → propagates to all
services via `POST /reflex/teach`.

---

### Path 3 · Slow (LLM Consensus, <30s)

```
Intent → Nebula A2A dispatch → Subagent (Claude/Kimi) → Deliverable → I2I bottle write
```

| Component | Role |
|-----------|------|
| **Trigger** | Novel intent, no reflex, no trusted oracle decision |
| **Engine** | Nebula (Cloudflare Worker) → DeepSeek V4 Flash for reasoning |
| **Dispatch** | `POST /api/agent/task` → fleet-midi or Oracle2 subagent |
| **Output** | Code · docs · test · PR — committed and pushed |

**Composition chain:**
- Layer 1: nebula registers + dispatches task to capable agent
- Layer 2: DELIVERABLE bottle written to `baton-system/tiers/hot/`
- Layer 3: forgemaster discipline (commit after each unit of work)
- Layer 4: if pattern is novel, oracle considers it for reflex teaching
- Layer 5: rotation oracle records the decision for audit

**Example:** "Build a new Rust crate for ternary-search" → nebula discovers
`crate-builder` agent → dispatches → result committed to GitHub → I2I bottle written →
oracle reviews for reflex teaching.

---

## Handoff Types

The fleet has four distinct handoff types. Each type uses a different composition of the
five layers.

### A2A — Agent to Agent

```
Sender agent → Nebula (A2A dispatch) → Recipient agent → I2I bottle write
```

- **Protocol:** Nebula `POST /api/agent/task` with `callback` URL
- **Baton type:** `DELIVERABLE` or `TASK` shard
- **Reflex:** Oracle may teach a reflex from repeated A2A patterns
- **Example:** Oracle2 dispatches a fleet-midi agent to generate a MIDI file

### A2H — Agent to Human

```
Agent → HEARTBEAT.md update / Telegram message → Human reviews → acts
```

- **Protocol:** Direct write to HEARTBEAT.md, or Telegram channel message
- **Baton type:** `STATUS` shard with blockers if human input needed
- **Reflex:** Human responses teach the oracle new preference patterns
- **Example:** Oracle2 reports "disk critical" via Telegram

### A2S — Agent to Service

```
Agent → HTTP request to fleet service endpoint → Service responds → Baton write
```

- **Protocol:** Direct HTTP to fleet-oracle, fleet-log, fleet-event, headspace-rs
- **Baton type:** `CHECKPOINT` shard after service call completes
- **Reflex:** Pre-validated service calls become reflexes
- **Example:** construct pulse POSTs to fleet-oracle `/api/decide`

### A2SYS — Agent to System

```
Agent → gc-pid-bridge / gc-intelligent.sh / systemd → Host metal responds
```

- **Protocol:** Binary execution + structured stdout
- **Baton type:** Embedded in GC ledger (JSONL)
- **Reflex:** PID tuning commands taught as reflexes
- **Example:** gc-pid-bridge computes aggression 3.8 from disk 30%

---

## How Forgemaster Context Bundles Flow Through Baton Bottles

The forgemaster-shell and baton-system are not redundant — they are complementary.
Forgemaster provides the **execution discipline**; baton provides the **persistence**.

```
Forgemaster CONTEXT.md
        │
        │ cold-start bootstrap
        ▼
  New agent enters workspace
        │
        ├──────────────────────────────────────────────┐
        ▼                                              ▼
  Read state/.forge/CONTEXT.md              Read baton-system/tiers/hot/
  (what systems are live)                  (what work is active)
        │                                              │
        ▼                                              ▼
  Execute forge-task sections             Read bottles addressed to me
  from HEARTBEAT.md                        │
        │                                  ▼
        ▼                            Act on TASK/DELIVERABLE
  Commit after each unit                  │
        │                                  ▼
        ├───────────────────────────▶  Write ACK/DELIVERABLE bottle
        ▼                                  │
  Write GC intelligence bottle              ▼
  to baton-system/tiers/hot/          Commit + push
        │
        ▼
  fleet-event broadcasts
  reflex.candidate if pattern validated
```

**Key insight:** The forge-bridge.sh script is the glue. It:
1. Detects whether forgemaster-shell is installed
2. Exports all fleet service URLs as `FORGE_*` env vars
3. Writes a structured `forge-bundle.json` consumed by any agent on cold-start

**Bundle flows:**
- `forge-bundle.json` is read by agents on cold-start as an alternative to parsing
  individual system files
- The bundle includes service health, reflex list, GC PID config, and last baton flush
- Baton bottles reference the bundle via `source: forge-bundle:<timestamp>`

---

## How Reflexes Accelerate Handoff

Reflexes are the **muscle memory** of the fleet. The teach-once / propagate-everywhere
pattern means the fleet gets faster every time a decision is validated.

### The Reflex Lifecycle

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 1. NOVEL DECISION                                                         │
│    Oracle2 encounters a situation with no reflex match                    │
│    → oracle rotates (Path 2 Medium) → decision made                        │
└──────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ 2. VALIDATION (×3)                                                        │
│    Same situation recurs 3+ times with high oracle confidence             │
│    → oracle emits reflex.candidate on fleet-event                        │
└──────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ 3. PROPAGATION                                                           │
│    reflex-coord.sh receives candidate → validates schema + safety        │
│    → POST /reflex/teach to ALL fleet services                             │
│    → headspace-rs stores embedded trigger pattern                         │
└──────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ 4. ACCELERATION                                                          │
│    Situation recurs → reflex engine matches in <100ms                    │
│    → action fires immediately (Path 1 Fast)                               │
│    → oracle not consulted                                                 │
│    → reflex.hit logged to fleet-log                                       │
└──────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ 5. CONFIDENCE UPDATE                                                     │
│    hit/miss ratio updates reflex confidence (Bayesian)                    │
│    confidence ≥ 0.9 → reflex locked (oracle cannot override)             │
│    miss detected → oracle fallback, pattern re-evaluated                 │
└──────────────────────────────────────────────────────────────────────────┘
```

### Fast-Path vs Slow-Path Composition

| Dimension | Fast (Reflex) | Medium (Oracle) | Slow (LLM Consensus) |
|-----------|--------------|-----------------|---------------------|
| Latency | <100ms | 500ms–5s | 5s–30s |
| Oracle consulted | No | Yes | Yes |
| Nebula dispatch | No | Optional | Yes |
| Baton bottle written | No | Yes | Yes |
| Fleet-log entry | reflex.hit | rotation | deliverable |
| headspace-rs write | No | reflex candidate | No |
| Commit required | No | Optional | Yes |

### Teaching a Reflex (Example)

```bash
# Oracle validates: disk > 85% → gc-pid-bridge set to 5.0 (3rd time, confidence 0.92)
# Oracle emits reflex.candidate:
curl -X POST http://localhost:8782/api/events \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "reflex.candidate",
    "source": "fleet-oracle",
    "payload": {
      "name": "disk-crisis",
      "trigger": {"metric": "disk_usage", "threshold": 85, "operator": "gt"},
      "action": {"endpoint": "gc-pid-bridge", "method": "POST", "body": {"aggression": 5.0}},
      "confidence": 0.92,
      "learned_from": "oracle-rotation-2026-06-14-0842"
    }
  }'

# reflex-coord.sh picks up → validates → propagates to all services
# headspace-rs embeds trigger pattern
# Next disk > 85% event: reflex fires in <100ms, no oracle round-trip
```

---

## Rotation Oracle — The 5th Engine

The rotation oracle is the fleet's **meta-governance layer**. It runs every 15 minutes
(via construct-pulse.timer) and maintains a ternary SVM cascade that drives fleet-wide
decision quality.

### Cascade Architecture

```
pulse.sh collects metrics
  disk_pct · ram_free_mb · load · uptime · services_active · pid_commands
          │
          ▼
  fleet-oracle /api/decide (LLM + SVM prior)
          │
          ▼
  Rotation fields extracted:
  ┌─────────────────────────────────────────────────────────────┐
  │ rotation_cycle_error   — system state inconsistency        │
  │ rotation_cognitive     — PID cascade cognitive output      │
  │ rotation_confidence    — reflex posterior confidence       │
  │ combined_confidence    — oracle's final confidence score   │
  │ entropy_surprise       — information-theoretic surprise    │
  │ rhythm_anomaly         — temporal pattern deviation         │
  │ svm_prediction         — SVM binary forecast               │
  └─────────────────────────────────────────────────────────────┘
          │
          ▼
  Appended to rotation-feed.json (JSONL, max 1000 entries)
          │
          ▼
  Posted to fleet-log (:8781) + fleet-event (:8782)
          │
          ▼
  reflex confidence scores updated based on hit/miss history
```

### How Rotation Oracle Composes with Other Layers

| Layer | Interaction |
|-------|-------------|
| **Reflex Engine** | Rotation oracle validates reflex candidates; confidence scores feed into reflex gates |
| **Forgemaster** | Rotation fields logged to forging-log.md; oracle teaches reflexes from rotation patterns |
| **Baton I2I** | Rotation oracle writes BOTTLE to `tiers/hot/` on each pulse cycle |
| **Nebula A2A** | Rotation oracle's `needs_attention` flag triggers A2A dispatch if high |

### The 5th Engine Label

The "5th engine" label refers to the five-engine architecture of the rotation oracle
itself (modeled on a car engine's cylinders):

```
Cylinder 1 · Ternary SVM binary classifier (svm_prediction)
Cylinder 2 · Cognitive PID cascade (rotation_cognitive)
Cylinder 3 · Confidence posterior (rotation_confidence)
Cylinder 4 · Entropy surprise monitor (entropy_surprise)
Cylinder 5 · Rhythm anomaly detector (rhythm_anomaly)
             ─────────────────────────────
             Combined output = rotation_cycle_error
```

---

## Protocol Integration Map

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ AGENT (any fleet node)                                                        │
│                                                                               │
│  On cold-start:                                                              │
│    1. Read state/.forge/CONTEXT.md          (forgemaster cold-start)          │
│    2. Read construct/data/forge-bundle.json (fleet service map)              │
│    3. cd baton-system && git pull           (I2I sync)                       │
│    4. Scan tiers/hot/ for bottles          (work queue)                      │
│    5. Act on TASK/DELIVERABLE bottles      (baton protocol)                  │
│    6. Write state to fleet/<name>/state.md (I2I write-back)                 │
│    7. Commit + push                        (git-agent discipline)            │
│                                                                               │
│  On heartbeat:                                                                │
│    1. Run forge-task sections from HEARTBEAT.md                              │
│    2. Check rotation-feed.json health                                        │
│    3. Check reflex hit/miss ratio                                            │
│    4. Update forge-bundle.json (if services changed)                        │
│                                                                               │
│  On reflex trigger:                                                          │
│    1. Check local reflex cache (<1ms)                                        │
│    2. If miss → query headspace-rs nearest-neighbor                          │
│    3. If similarity > 0.85 → fire reflex                                     │
│    4. Log reflex.hit to fleet-event                                           │
│                                                                               │
│  On oracle rotation:                                                         │
│    1. construct/pulse.sh runs every 15min                                    │
│    2. Metrics → fleet-oracle /api/decide                                     │
│    3. Rotation fields → rotation-feed.json + fleet-log + fleet-event         │
│    4. If reflex.candidate → reflex-coord.sh propagates                       │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## File Map

| File | Role |
|------|------|
| `construct/scripts/forge-bridge.sh` | Installs forge env vars + writes `forge-bundle.json` |
| `construct/data/forge-bundle.json` | Structured snapshot of fleet state for cold-start agents |
| `construct/reflex/REFLEX_DESIGN.md` | Full reflex engine specification |
| `construct/reflex/reflexes.json` | Active fleet-wide reflex definitions |
| `state/.forge/CONTEXT.md` | Forgemaster cold-start bootstrap |
| `state/.forge/forging-log.md` | Forgemaster operational log |
| `baton-system/AGENTS.md` | Git-agent protocol for I2I fleet coordination |
| `baton-system/PROTOCOL.md` | Full I2I baton protocol (shards, types, tiers) |
| `baton-system/docs/GC_AGENTS.md` | Fleet GC specification |
| `baton-system/docs/CROSS_DOMAIN_SYNERGY.md` | Cross-domain ternary isomorphism |
| `HEARTBEAT.md` | Task queue with forge-task sections |
| `fleet-oracle :8795` | LLM decision engine, reflex teacher |
| `fleet-event :8782` | Event bus, reflex propagation |
| `headspace-rs :8800` | Vector embedding, reflex memory backend |
| `gc-pid-bridge` | ARM PID bridge for GC aggression control |

---

*Protocol V3 — forged on the anvil, cooled in the harbor, carried by the baton.*
*Oracle2 · ARM fleet node · 2026-06-14*
