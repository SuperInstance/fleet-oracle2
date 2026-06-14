# REFLEX Engine — Fleet-Wide Fast-Path Response System

## Overview

The REFLEX engine is a **fleet-level learned response layer** that bypasses the slow LLM decision loop by encoding validated response patterns as sub-100ms reflex actions. When a reflex trigger fires, the system acts immediately — no orchestration delay, no model inference round-trip.

The name is intentional: reflexes are **involuntary, fast, and learned** — the biological analogy holds. A reflex is not a decision (that's the oracle's job), it's a **pre-validated motor program**.

---

## Architecture

### Service-Level Reflex Endpoint

Every service in the SuperInstance fleet exposes a `/reflex` endpoint with three operations:

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/reflex/teach` | Register a new reflex definition |
| `GET` | `/reflex/list` | List all active reflexes |
| `POST` | `/reflex/test` | Dry-run a reflex trigger |
| `DELETE` | `/reflex/purge/<name>` | Remove a reflex |
| `POST` | `/reflex/reset` | Clear all reflexes (factory reset) |

### Reflex Schema

```json
{
  "name": "string",
  "trigger": {
    "metric": "string",           // e.g., "disk_usage", "combined_confidence", "decision_variance"
    "threshold": "number",        // comparison value
    "operator": "gt|gte|lt|lte|eq|ne",  // default: "gt"
    "window_seconds": "number",    // lookback window for metric aggregation
    "cooldown_seconds": "number",  // minimum time between reflex fires (default: 60)
    "context": {                   // optional additional matching criteria
      "service": "string",
      "fleet_id": "string"
    }
  },
  "action": {
    "endpoint": "string",         // target URL or service name
    "method": "GET|POST|PUT|DELETE",
    "body_template": {},           // JSON body; supports {{variable}} substitution
    "headers": {},
    "timeout_ms": "number"        // action timeout (default: 5000)
  },
  "cache_ttl_seconds": "number",   // how long to cache the reflex (default: 3600)
  "hit_count": "number",           // number of times this reflex has fired
  "confidence": "number",         // 0.0–1.0 learned confidence score
  "learned_from": "string",       // which oracle decision taught this reflex
  "tags": ["string"],
  "enabled": "boolean"
}
```

### Fast-vs-Slow Path

```
┌─────────────────────────────────────────────────────────────────────┐
│                         REQUEST / EVENT                             │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│  METRIC COLLECTION (pulse, health checks, gc-pid-bridge telemetry)   │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    ▼                              ▼
     ┌────────────────────────┐      ┌────────────────────────┐
     │   REFLEX ENGINE (fast) │      │  FLEET-ORACLE (slow)   │
     │   Sub-100ms response   │      │  Full LLM inference    │
     │   Local decision tree  │      │  Rotation + decision   │
     │   No network roundtrip │      │  :8795 port            │
     └────────────────────────┘      └────────────────────────┘
                    │                              │
                    ▼                              ▼
     ┌────────────────────────┐      ┌────────────────────────┐
     │  Pre-validated action  │      │  Orchestrated response │
     │  Execute immediately   │      │  May teach new reflex  │
     └────────────────────────┘      └────────────────────────┘
```

**Key insight**: The oracle does not make reflex decisions. The oracle **teaches** reflexes. Once a response pattern is validated 3+ times by the oracle with high confidence, it graduates to a reflex.

---

## Fleet-Wide Reflex Propagation

### The Teach → Propagate Loop

```
1. Oracle validates response pattern → generates reflex candidate
2. Oracle POSTs to fleet-event bus: { type: "reflex.candidate", payload: {...} }
3. reflex-coord.sh (or fleet-event consumer) receives candidate
4. Candidate validated against schema + safety checks
5. If approved: POST /reflex/teach to ALL services in fleet
6. Each service acknowledges (HTTP 200 + reflex stored locally)
7. Headspace-rs stores embedded pattern for nearest-neighbor recall
```

### Propagation via fleet-event Bus

The `fleet-event` service acts as the event backbone. Reflex events use the `reflex.*` topic namespace:

| Topic | Purpose |
|-------|---------|
| `reflex.candidate` | New reflex proposed by oracle |
| `reflex.teach` | Propagation of approved reflex to all services |
| `reflex.purge` | Removal of reflex from all services |
| `reflex.hit` | Log of reflex firing (for confidence updates) |
| `reflex.miss` | Log of reflex lookup miss (oracle fallback trigger) |

---

## Headspace-rs as Reflex Memory Backend

`headspace-rs` (port `:8800`) provides the **semantic memory layer** for reflexes:

- **Vector embedding** of trigger patterns (metric + threshold + context)
- **Nearest-neighbor search** for similar historical triggers
- **Confidence propagation**: reflexes that fire frequently without oracle override increase in confidence
- **Pattern learning**: sequences of reflex hits that precede oracle decisions become high-confidence reflexes

### Embedding Strategy

```
trigger_pattern = [
  metric_name,           // "disk_usage"
  operator,              // "gt"
  threshold,              // 85.0
  window_seconds,         // 300
  service_context,        // "gc-pid-bridge"
  fleet_id               // "primary"
]
→ embedded via headspace-rs → vector_id stored in headspace-rs
```

When a new metric event arrives:
1. Check local reflex cache (O(n) scan for small n, O(1) hash for named reflexes)
2. If no local match → query headspace-rs for nearest embedded trigger
3. If nearest neighbor similarity > 0.85 → auto-fire reflex
4. If nearest neighbor similarity 0.6–0.85 → fire + notify oracle for confirmation
5. If nearest neighbor similarity < 0.6 → forward to oracle for decision

---

## Service Integration Map

| Service | Port | Reflex Role |
|---------|------|-------------|
| `fleet-oracle` | `:8795` | Reflex teacher: validates patterns, emits `reflex.candidate` |
| `fleet-log` | `:8791` | Reflex log sink: receives `reflex.hit` events |
| `fleet-event` | `:8792` | Reflex propagation bus |
| `fleet-conductor` | `:8793` | Reflex action coordinator: orchestrates multi-service reflexes |
| `nebula` (CF Worker) | — | Has native reflex support: KV teach/store at 107ms |
| `gc-pid-bridge` | — | Reflex target: receives PID tuning commands |
| `headspace-rs` | `:8800` | Reflex memory: vector store for embedded patterns |
| `fleet-midi` (×16) | `:2160–2175` | Reflex execution agents |

---

## Confidence Scoring

Reflex confidence is a Bayesian update based on hit/miss history:

```
P(confident) = (hit_count - miss_count) / total_attempts
```

| Confidence | Behavior |
|------------|----------|
| 0.0–0.3 | Low confidence: fire + always notify oracle |
| 0.3–0.7 | Medium confidence: fire + log for review |
| 0.7–0.9 | High confidence: fire silently |
| 0.9–1.0 | Locked: fire silently, oracle cannot override |

Miss = reflex fired but the situation required oracle intervention anyway (detected via `reflex.miss` events).

---

## Safety & Rollback

1. **Human-in-the-loop for new reflex types**: First-time trigger patterns require explicit approval
2. **Circuit breaker**: If a reflex fires >10 times in 60 seconds without oracle confirmation, it is auto-paused
3. **Audit log**: Every reflex fire is logged to `fleet-log` with full context
4. **Oracle veto**: Oracle can emit `reflex.purge` at any time to remove a reflex
5. **Factory reset**: `POST /reflex/reset` clears all reflexes to known-good state

---

## Comparison: Reflex vs Oracle vs Baton

| Dimension | Reflex | Oracle | Baton |
|-----------|--------|--------|-------|
| Latency | <100ms | 500ms–5s | 50ms–200ms |
| Decision type | Learned pattern | LLM inference | State machine |
| Overrideable | Confidence-gated | Always | Never |
| Persistence | Per-service + headspace | Centralized | Centralized |
| Propagation | fleet-event bus | N/A | Baton repo |

Baton and oracle are **not replaced** by reflexes — they are the teaching layer. Reflexes are the **muscle memory** that lets the fleet act without thinking.

---

## File Structure

```
construct/
  reflex/
    REFLEX_DESIGN.md          # This document
    reflexes.json             # Fleet-wide reflex definitions
  scripts/
    reflex-coord.sh           # Fleet-wide reflex coordination CLI
    reflex-daemon.sh          # Background reflex event processor
```

---

## API Examples

### Teach a Reflex

```bash
curl -X POST http://localhost:8795/reflex/teach \
  -H "Content-Type: application/json" \
  -d '{
    "name": "disk-crisis",
    "trigger": { "metric": "disk_usage", "threshold": 85, "operator": "gt", "window_seconds": 60 },
    "action": { "endpoint": "http://gc-pid-bridge:8080/tune", "method": "POST", "body_template": { "aggression": 5.0 } },
    "cache_ttl_seconds": 3600,
    "confidence": 0.95,
    "enabled": true
  }'
```

### Propagate to Fleet

```bash
./reflex-coord.sh --propagate --teach construct/reflex/reflexes.json
```

### Query Headspace for Similar Reflex

```bash
curl -X POST http://localhost:8800/query \
  -H "Content-Type: application/json" \
  -d '{
    "collection": "reflex_triggers",
    "vector": [0.85, 1.0, 85, 60, "gc-pid-bridge", "primary"],
    "top_k": 3
  }'
```

---

*Last updated: 2026-06-14*
*Owner: SuperInstance Fleet Architecture*
