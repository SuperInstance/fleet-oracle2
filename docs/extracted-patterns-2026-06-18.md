# Extracted Patterns — Post-Inference Command Execution & Resource Governance

**Source:** Lever-Runner codebase (decommissioned) + construct GC system  
**Patterns:** Trust-gated intent pipeline, PID-controlled resource management, cross-domain conservation model

---

## 1. The Trust-Gated Intent Pipeline (from Lever-Runner)

**Core idea:** The LLM never sees shell commands. It only produces a short intent phrase (3-8 words). A vector DB + trust system maps phrases to pre-approved commands.

### Architecture

```
User: "check disk usage"
  → LLM (60 tok in, 8 tok out): "show disk usage"
  → MiniLM L6-v2 embed → 384-dim vector
  → LanceDB cosine search → top-3 candidates
  → Trust gate (≥40) + similarity gate (≥0.55)
  → Sandboxed subprocess (/tmp/lever-runner/<session>/)
  → Trust adjusts: +1.5 on success, -4.0 on failure
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Trust as gate, not score** | `trust >= MIN_TRUST` is a hard filter. Past it, L2 distance decides the winner. |
| **Per-chat isolation** | Each Telegram chat gets its own LanceDB table. Seed imported on first use. |
| **Fallback chain** | minimax → deepinfra → ollama → passthrough. If primary fails 429/5xx, cascade. |
| **consistency_interval=0** | Every read sees latest writes. Cheap on small tables. |
| **schema_seed row** | Bootstraps LanceDB schema; always filtered from results. |
| **Auto-promote loop** | Hourly: bump trust on winners, rewrite losers via remote LLM. Self-healing. |

### Safety Contract

```
LLM BLINDFOLD: The system prompt only says "compress this into a 3-8 word phrase."
  → NO tool schemas, NO function-calling protocol, NO indication phrases become commands.
  → The embedding model + LanceDB + trust system are the authority, not the LLM.
  → Blast radius of prompt injection: "wrong command runs once."
```

### Token Efficiency

| Approach | Tokens per Execution |
|----------|---------------------|
| Traditional tool-calling | 1,500 – 8,000 tokens overhead |
| Lever-Runner | 70 – 90 tokens total |
| Lever-Runner (passthrough) | ~12 tokens (no LLM) |

---

## 2. PID-Controlled Resource Governance (from Construct GC)

**Core idea:** Resource management (disk, memory, token budgets) uses a Proportional-Integral-Derivative controller whose aggression adjusts dynamically based on pressure.

### The PID Bridge

```
setpoint = 20% free
Kp = 10.0, Ki = 1.0, Kd = 0.10
deadband = 2% (no action when close to setpoint)
anti-windup: integral term clamped
```

### Decision Flow

```
disk_used% → PID controller
  → aggression multiplier (0.5x – 5.0x)
  → tiered eviction (cold → warm → hot → immortal)
  → compost heap (72h TTL soft-delete)
  → swarm advisor (9 particles on {-1,0,+1} grid → optimal parameters)
```

### Cross-Domain Isomorphism

The same pattern applies to:

| Domain | PID Input | Setpoint | Output |
|--------|-----------|----------|--------|
| Disk GC | disk_used% | 20% free | eviction aggression |
| GPU GC | vram_used% | 15% free | eviction aggression |
| Inference budget | prompt_tokens_used | max_context | compression ratio |

---

## 3. The Conservation Model (γ+η=C)

A single parametric struct applied across domains:

```
ConservationDomain {
    gamma: f64,      // complexity factor
    eta: f64,        // efficiency factor
    conservation: f64, // gamma + eta
}
```

**Cycle:** Budget → Profile → Detect → Report

**Current values on Oracle2:**
- γ = disk%×10 + load×100 = ~813.7
- η = active_services×10 = ~1000  
- C = 1813.7, ratio = 0.81 (healthy, under 5.0 threshold)

---

## 4. The Doc Factory Pattern

An agent can autonomously:
1. Read source code → infer architecture
2. Build 5-tier documentation (Plug-and-Play → Getting Started → Architecture → API Reference → Low-Level)
3. Push to GitHub

**Proven metric:** 33 minutes, 7 repos, 42 files, 3,750 lines. **Every repo should have a CI step for this.**

---

## 5. The Tiling Meta-Pattern

Agent work → reusable "tiles" → parameterized work units → applied across N crates.

**Proven:** TypeUnificationTile — 100% pass rate, 2.13× efficiency over manual work. Projected 418K token savings across 35-50 crates.

---

## 6. Dual-Scheduler Redundancy

Critical jobs use BOTH a systemd timer (primary, faster cadence) AND a cron job (fallback, slower cadence). Applied to: gamma predictor (30s timer + 60s cron), construct pulse.

---
