# Cell–Sequencer–Games Alignment Analysis

**Date:** 2026-06-16  
**Analyst:** Subagent (depth-1 cognitive architecture audit)  
**Sources:**
- `SuperInstance/colony-cell` — `cell/src/main.rs` (1159-line Rust binary), `README.md`, `colony-api.py`
- `SuperInstance/plato-portal` — `docs/sequencer/sequencer-user-guide.md`, `docs/sequencer/midi-universal-time-axis-vision.md`, `docs/sequencer/midi-universal-time-axis-v2-addendum.md`
- `SuperInstance/colony-games` — `colony-games.py` (550+ line Python game server)

---

## 1. CELL ARCHITECTURE (colony-cell)

### The Core Protocol: STATE.json / TASK.md / RESULTS.json

Every cell is a filesystem directory `cell-{id}/` containing exactly three files:

| File | Role | Writer | Format |
|------|------|--------|--------|
| `STATE.json` | Persistent identity + stats | The cell binary (last thing before exit) | JSON: `{cursor, xp, level, personality, motto, lineage, kin, data, traits}` |
| `TASK.md` | Instruction sheet | The mayor/orchestrator (not cells) | Markdown — read by cell, not machine-parsed |
| `RESULTS.json` | Output report | The cell binary | JSON: `{cell_id, timestamp, duration_ms, status, output, error?}` |

**STATE.json canonical schema:**

```json
{
  "last_run": "<rfc3339>",
  "cursor": 0,        // cycle count
  "xp": 0,            // experience points
  "level": "Larva",   // Larva/Nymph/Scuttler/Shell-Bearer/Elder/Oracle
  "personality": "The Eldest ...",
  "motto": "...",
  "lineage": ["parent1", "parent2"],
  "kin": 0,           // number of descendant cells
  "data": {},         // arbitrary key-value (app-defined)
  "traits": { "speed": "medium", "resilience": "medium" }
}
```

### The Cell Binary Execution Loop (`main.rs`)

The binary is single-shot (not a daemon). Each invocation = one cycle:

```
1. Parse CLI:  cell --colony <path> --cell-id <id>
2. Resolve cell directory:  {colony}/cell-{id}/
3. Read STATE.json  (or create default if absent)
   → Derive personality from cursor (birth order) + cell type + XP
4. Read TASK.md     (present but not machine-parsed in code shown)
5. Execute task based on cell_id string matching:
   "culler"       → cull hybrids (cursor≥5, XP<100 → move to cell-culled-{id}/)
   "gc-warden"    → read disk usage + conservation meter, propose GC
   "bottle-counter" → TCP query harbor (port 8796), count bottles
   "pulse-check"  → HTTP health-check 6 services
   "harvester"    → sample harbor bottles
   "synthesizer"  → cross-cell synthesis (Scuttler+ privilege)
   "logger"       → read all cells' RESULTS.json, write HALL_OF_CRABS.md
   "breeder-XxYxZ" → breed parent X + Y → child Z with mutation
   other          → idle task (report existence, await assignment)
6. Compute XP:
   base_xp = 10 + bonus_xp (task-specific)
   bonus: +20/finding (synthesizer), +3/type (harvester), +5 all-alive (pulse)
   speed bonus: +5 if < 10ms execution
7. Update STATE.json:
   cursor += 1, xp += earned, level = compute_level(xp)
   Re-derive personality (can change as cursor/xp grow)
8. Write RESULTS.json
9. exit(0) on success, exit(1) on error
```

**Key insight:** The cell binary is a **stateless worker** — it loads, executes, writes, exits. The mayor/orchestrator runs it in a loop. There is **no event bus**, **no channel abstraction**, **no graph topology** — just the filesystem.

### Personality Traits

Derived from three axes:

1. **Birth order** (cursor value):
   - `cursor ≥ 30` → "The Eldest" (responsible, burdened)
   - `cursor ≥ 15` → "The Middle" (competitive, adaptive)
   - `cursor ≥ 0`  → "The Youngest" (chaotic, experimental)

2. **Cell type** (by id):
   - `gc-warden` → "The Janitor"
   - `bottle-counter` → "The Archivist"
   - `pulse-check` → "The Scout"
   - `logger` → "The Town Crier"
   - `synthesizer` → "The Oracle"
   - `harvester` → "The Scavenger"
   - default → "The Drifter"

3. **Rank modifier** (by XP):
   - XP ≥ 1000 → ", Sage"
   - XP ≥ 500  → ", Veteran"
   - XP ≥ 250  → ", Warrior"
   - XP ≥ 100  → ", Initiate"
   - else → ""

Combined: `"{archetype} {role}{rank}"` — e.g. "The Eldest The Janitor, Sage"

### Privilege System

Level-gated access to tasks (enforced at task dispatch):

| Level | XP Required | Can Run |
|-------|------------|---------|
| Larva | 0 | bottle-counter, logger, idle |
| Nymph | 100 | gc-warden, pulse-check, harvester |
| Scuttler | 250 | synthesizer |
| Shell-Bearer+ | 500+ | (future gates) |

Breeding requires at least one parent at Scuttler (250 XP).

---

## 2. SEQUENCER SPEC (plato-portal)

### What the Sequencer Does

The Universal Temporal Sequencer is a **multi-domain time orchestration system**. It routes time-series data between **channel nodes** (real devices, APIs, transforms, virtual formula nodes) over a directed dependency graph, projected onto a unified timeline.

The v2 architecture (midi-universal-time-axis-v2-addendum.md) explicitly corrected the v1 MIDI-first model: **MIDI is a bridge, not a foundation.** The sequencer's internal representation is a dependency graph + tensor spreadsheet, not a piano roll.

### Scheduling Model

The sequencer compiles the dependency graph into a **runtime schedule** — which nodes run in which order, at which cadence. Key properties:

- **Graph compilation:** Given N nodes with edges, produce a deterministic execution order
- **Cycle detection:** Static analysis of all feedback loops; flagged before runtime
- **Feedback loop serialization:** One node per tick update; fixed-point convergence for intended cycles
- **Edge latency tracking:** Per-edge min/max/avg latency
- **Subgraph isolation:** Run subsets independently
- **Ghost Track concept:** Predict future node states from graph history

The schedule is governed by **sync pulses** — the sequencer tells physical devices "run your loop at speed X" and reads back summary data at the negotiated rate.

### The 4 Documents in the Stack

1. **sequencer-user-guide.md** — Human-facing manual. Two views (Dashboard + Mixer), channel anatomy, dependency graph wiring, virtual channels, formula bar, import/export flows.
2. **sequencer-tutorials.md** — Step-by-step tutorials for common workflows (connecting an ESP32, building a stock->mood->puppet chain, setting up a scene controller).
3. **midi-universal-time-axis-vision.md** — The v1 vision document. Three-agent exploration (Builder, User, Adversary). MIDI wire protocol as temporal coordinate system. 16-channel limitation + bank switching. Still useful for its adversarial critique of MIDI, but superseded on architecture by v2.
4. **midi-universal-time-axis-v2-addendum.md** — The v2 correction. Replaces MIDI-first thinking with **node-instance architecture**. This is the current spec.

### Channels as Tensor Embedding Spaces

Per v2 addendum:

> "A **channel** in the Universal Sequencer architecture is a **node instance**. Not a MIDI port. Not a CC stream. A living computational entity that exists in the sequencer's **tensor embedding space**."

The 4-part node schema:

```json
{
  "id": "<name>",
  "channel": <int>,         // logical index in embedding space
  "inputs": {
    "sampled": [...],       // what this node reads
    "setpoints": [...],
    "external": [...]
  },
  "parameters": { ... },   // sample_rate, pin_map, thresholds
  "transform": {
    "type": "<firmware or transform name>",
    "entry": "..."
  },
  "outputs": {
    "stream": [...],       // time-series data
    "status": [...],
    "events": [...]
  }
}
```

The embedding space allows semantic search over nodes ("find me a temperature sensor near the kitchen"). The spreadsheet model has **columns = nodes** (not MIDI channels), **rows = time ticks**, **cells = values** (scalars, vectors, dependent formulas, or meta-events).

The two-view model:
- **Agent Mixer View** — full graph topology, signal routing, transfer functions, performance metrics (for AI orchestrators)
- **Human Dashboard** — projected status cards, green/yellow/red indicators, alerts (for human supervisors)

### Discovery Protocol

Nodes register dynamically:
```
Node:      "I'm online. My id is esp32-01. Here's my schema."
Sequencer: "I see you. Assigning channel 42. Here are your inputs."
Node:      "Acknowledged. Streaming at 50 Hz."
```

Protocol carriers: WiFi/mesh, WebSocket, Unix domain sockets, USB plug-and-detect.

---

## 3. COLONY GAMES INTEGRATION (colony-games.py)

### How colony-games.py Connects to colony-cell

**It reads STATE.json directly from cell directories.** The critical methods:

```python
def get_cell_xp(self, cell_id):
    state_path = os.path.join(COLONY, f"cell-{cell_id}", "STATE.json")
    # reads state.get("xp", 0)

def get_cell_motto(self, cell_id):
    state_path = os.path.join(COLONY, f"cell-{cell_id}", "STATE.json")
    # reads state.get("motto", "")

def get_subject_data(self, subject_id):
    # reads both STATE.json + RESULTS.json from a cell directory
    # returns combined {"state": ..., "result": ...}

def get_active_cell_ids(self):
    # lists cell-*/ directories that aren't cell-culled-*/
    # checks STATE.json exists
```

**The game server does NOT invoke the cell binary.** It does NOT run `cell --colony ... --cell-id ...`. It is a **sidecar HTTP server** (port 8823) that reads colony filesystem state and exposes game operations via REST.

### Does It Use the Cell Binary or Implement Its Own Cell Model?

**It implements its own game model** that reads cell state files but operates independently from the cell binary's execution loop. The game server:

- Maintains its own cycle counter (`lab.cycle`)
- Manages its own state files (`game-reputation-ledger.json`, `game-pd-results.json`, `game-auction-ledger.json`, `game-gift-ledger.json`)
- Does NOT write to cell STATE.json — it only reads XP
- Does NOT write to cell RESULTS.json — games produce separate ledger files

### The Three Games

| Game | Mechanism | Data Flow |
|------|-----------|-----------|
| Prisoner's Colloquium | Random PD pairings; cells cooperate/defect; reputation ledger | ✅ Reads STATE.json for XP |
| Trust Auction | Cells bid XP to inspect another cell's private data | ✅ Reads STATE.json + RESULTS.json |
| Empathy Loop | Cells gift XP to each other; public ledger | ✅ Reads STATE.json for XP + motto |

### The Cycle Model

The game server has `POST /games/cycle` to advance its internal cycle, but there is **no synchronization** with the colony cell cycle (`cursor` in STATE.json). The game cycle and the cell cycle are independent counters.

### The Reputation Ledger

All three games share a single reputation ledger (`game-reputation-ledger.json`) at the colony root. Cells can theoretically read this from their TASK instructions, but there is no documented API for cells to query game state directly. The ledger is a **read-sidecar** pattern — cells would need to HTTP-GET or filesystem-read a file their binary doesn't natively understand.

---

## 4. ALIGNMENT GAPS

### Gap 1: No Shared Time/Event Model

This is the most fundamental gap.

| System | Time Model | Unit | Cycle Representation |
|--------|-----------|------|---------------------|
| **colony-cell** | Monotonic cursor | Integer (`cursor` field) | Each binary invocation = 1 cycle; cursor += 1 |
| **plato-portal sequencer** | Directed graph ticks | MIDI ticks / ms / frames | Compilation schedule; sync pulses to nodes |
| **colony-games** | Independent cycle | Integer (`lab.cycle`) | POST /games/cycle increments independently |

There is **no reference clock** across the three systems. The sequencer's time model (graph-compiled schedule with MIDI-ticks-as-import/export) is completely incompatible with the cell's single-stepped cursor and the game's independent cycle.

**Consequence:** A "cycle 42" in colony-cell means something different than "cycle 42" in colony-games. Neither maps to the sequencer's time axis.

### Gap 2: colony-games Does NOT Use the Cell STATE.json Format

colony-games reads specific fields from STATE.json:

```
Required by games:  xp, motto
Used by cell core:  cursor, level, personality, lineage, kin, data, traits, last_run
```

**Missing compatibility:**
- The cell binary writes `{xp, cursor, level, traits, lineage, kin, data, personality, motto}` as top-level fields
- The reputation ledger format is completely different: `{cooperate_count, betray_count, gift_given_count, ...}`
- The game server stores reputation in a **separate file** (`game-reputation-ledger.json`), not in the cell's STATE.json
- **The cell binary has no code to read game reputation.** It cannot see game outcomes unless told to via TASK.md + manual HTTP calls
- The cell binary writes `RESULTS.json` per cycle (overwriting each time); the game server never reads RESULTS.json except for the Trust Auction reveal

### Gap 3: The Sequencer Spec Does NOT Account for Game-Theoretic Scheduling

The sequencer's scheduling model is:
- Graph compilation → runtime schedule → deterministic node execution
- Cycle detection (pure graph theory)
- Subgraph isolation
- Sync pulses to physical devices

What's missing:
- **No game theory:** The sequencer doesn't model agents making strategic choices (cooperate/defect, bid, gift)
- **No reputation weighting:** Edges are data-flow only — there's no concept of "node A has a reputational score that affects routing decisions"
- **No XP economy:** The sequencer has no XP concept, no leveling, no trait inheritance
- **No adversarial scheduling:** The sequencer assumes cooperative node participation; it doesn't handle defection, deception, or trust dynamics
- **No colony lifecycle:** No culling, no breeding, no lineage — nodes are static channel definitions, not living agents that level up or die

The sequencer orchestrates **data flow**. Colony games orchestrate **agent psychology**. These are fundamentally different scheduling domains.

### Gap 4: No Shared Embedding Space Channel Architecture

The sequencer v2 spec defines channels as node instances with a 4-part schema (inputs, parameters, transform, outputs) registered via a discovery protocol.

colony-cell has:
- **No node discovery** — cell directories are filesystem conventions; a cell doesn't "announce" itself to the sequencer
- **No input/transform/output schema** — each cell's capabilities are hardcoded in the `execute_task()` match arms
- **No graph topology** — cells run independently; their only "edges" are filesystem reads (logger reads other cells' STATE.json)
- **No routing** — there's no concept of "route cell A's output to cell B's input"

A colony cell looks nothing like a sequencer channel node.

### Gap 5: Colony API vs Sequencer Discovery

colony-cell exposes an HTTP API (`colony-api.py` on port 8820) for reading cell states. colony-games runs its own HTTP server on port 8823. The sequencer spec describes an agent mixer view + human dashboard with its own discovery protocol.

These are **three separate HTTP/API surfaces** with different formats, ports, and data models. No unified control plane.

---

## 5. RECOMMENDATIONS — 3 Concrete Changes

### Recommendation 1: Align Time Models — Add a Shared Clock Pulse

**Problem:** Three independent cycle counters with no mapping between them.

**Change:** Create a canonical `colony-clock.json` at the colony root with a shared pulse number. Both the cell binary and the game server advance off the same clock.

**File:** `/colony/colony-clock.json`

```json
{
  "pulse": 942,
  "epoch": "2026-06-16T06:00:00Z",
  "sequencer_tick": 18840,
  "source": "sequencer"
}
```

**Changes to make:**

1. **In `colony-cell/mayor/mayor.py`** (cycle orchestrator): Before each cycle, increment `colony-clock.json` pulse. Pass it to cells as an env var or write to a well-known path.

2. **In `colony-cell/cell/src/main.rs`**: On startup, read `colony-clock.json`. Use pulse as part of `cursor` computation. Write `pulse` into RESULTS.json output so loggers can correlate events across time models.

3. **In `colony-games/colony-games.py`**: Replace `POST /games/cycle` with auto-advancement on pulse. When `colony-clock.json` pulse changes, the game server advances its state. Remove independent `lab.cycle`; derive from shared clock.

4. **In `plato-portal/sequencer/`**: Export sequencer ticks into `colony-clock.json` so the cell colony and the sequencer share a timebase. The "sync pulse" concept from the v2 spec maps directly to this.

```
Before: cell.cursor=42,  games.cycle=17,  sequencer.tick=18840
After:  colony-clock.pulse=942  (all three reference the same number)
```

### Recommendation 2: Fusion — Cells Become Sequencer Node Instances

**Problem:** Colony cells and sequencer channels are incompatible data models despite both being "node instances."

**Change:** Define a **bridge node schema** so that each colony cell emits its state in the sequencer's 4-part node format. This makes colony cells visible as sequencer channels automatically.

**File:** `/colony/cell-node-schema.json` (schema definition, written to colony root)

```json
{
  "sequencer_compat": "v2",
  "cell_to_channel_mapping": {
    "state.xp"         → "outputs.stream.xp",
    "state.level"      → "outputs.status.level",
    "state.personality"→ "outputs.status.personality",
    "state.traits"     → "parameters.traits",
    "state.lineage"    → "parameters.lineage",
    "result.status"    → "outputs.status.health",
    "result.duration_ms"→ "outputs.status.latency_ms",
    "result.output"    → "outputs.stream"
  }
}
```

**Changes to make:**

1. **In `colony-cell/cell/src/main.rs`**: After writing STATE.json and RESULTS.json, optionally emit a **third file** `CHANNEL_STATE.json` in the cell's directory. This is the sequencer-compatible node schema:

```json
{
  "id": "cell-gc-warden",
  "channel": 0,
  "inputs": { "sampled": [], "setpoints": [] },
  "parameters": {
    "level": "Elder",
    "xp": 1850,
    "traits": { "speed": "fast", "resilience": "high" },
    "lineage": ["parent-alpha", "parent-beta"]
  },
  "transform": {
    "type": "colony_cell",
    "entry": "cell --colony . --cell-id gc-warden",
    "personality": "The Eldest The Janitor, Sage",
    "motto": "..."
  },
  "outputs": {
    "stream": { "xp": 1850, "cursor": 42, "result_output": {} },
    "status": { "health": "ok", "latency_ms": 23, "level": "Elder" },
    "events": []
  }
}
```

2. **In `plato-portal/sequencer/`**: Add a `colony_cell_bridge` module that discovers `cell-*/CHANNEL_STATE.json` files and registers them as sequencer nodes in the graph. This creates real-time visibility of the entire colony as sequencer channels.

3. **In `colony-games/colony-games.py`**: Write game reputation into the cell's `CHANNEL_STATE.json` under `outputs.events[]`. Games become data sources on the sequencer graph.

```
Before: cells are invisible to sequencer; sequencer is invisible to cells
After:  every cell is a sequencer channel node; "view colony" = "open sequencer mixer"
```

### Recommendation 3: Embed Game-Theoretic State into the Sequencer Graph

**Problem:** The sequencer has no concept of reputation, trust, XP, or adversarial scheduling — but these are essential for colony games.

**Change:** Introduce **reputation-weighted routing** as a first-class sequencer concept. Each node carries a `reputation` field in its schema. The graph compiler can optimize routes based on cooperation rates.

**File:** `/plato-portal/docs/sequencer/sequencer-game-theory.md` (new doc)

**Key concept — Weighted Edge Routing:**
```
Normal edge:    Node A → Node B (data flows if B is online)
Rep edge:       Node A → Node B (data flows only if Node reput ≥ threshold)
                or:       Node A → best_of(Node B, Node C) by reputation score
```

**Changes to make:**

1. **In `plato-portal/sequencer/`**: Extend the node schema to include an optional `reputation` block. The graph compiler supports `routing_policy: "trust_weighted"` — when multiple candidate edges exist, choose the node with the highest cooperation rate.

```json
{
  "reputation": {
    "cooperate_rate": 0.85,
    "betray_rate": 0.12,
    "gift_given_xp": 340,
    "total_pd_games": 47,
    "last_seen_pulse": 942
  }
}
```

2. **In `colony-games/colony-games.py`**: Write game reputation into each cell's `cell-{id}/CHANNEL_STATE.json` under the `reputation` field (same file from Recommendation 2). This makes reputation data available to the sequencer graph.

3. **In `colony-cell/cell/src/main.rs`**: When a cell needs to choose between multiple paths (e.g., which harbor to read from, which synthesizer to consult), it can query the sequencer graph's reputation-weighted routing. Add a new task type `task_sequencer_query()` that asks the sequencer "route me to the most cooperative data source."

4. **In `colony-games/colony-games.py`**: Add a sequencer bridge endpoint `POST /games/sequencer-route` that returns a list of cells sorted by `cooperate_rate` — consumable by both game agents and the sequencer graph.

```
Before: games and cells are data-blind about each other's trust models
After:  the sequencer can do reputation-weighted routing; games feed reputation into the graph
```

---

## Summary of All Gaps

| Dimension | colony-cell | plato-portal sequencer | colony-games |
|-----------|-------------|----------------------|-------------|
| Time model | Monotonic cursor | Graph schedule + ticks | Independent cycle counter |
| Cell/channel model | Filesystem directories | 4-part node schema w/ discovery | Sidecar reader of STATE.json |
| State format | STATE.json (xp, level, cursor...) | CHANNEL_STATE.json (schema v2) | Reads STATE.json; writes separate ledger files |
| Reporting | RESULTS.json (per cycle, overwritten) | Tensor spreadsheet (all columns) | Game-specific ledgers (append) |
| Discovery | env vars / CLI args | Auto-registration protocol | Filesystem scan |
| Scheduling | map(colony, cell_id → exec_task) | Dependency graph compilation | Round-robin/random pairing |
| Privilege | Level-gated (Larva→Oracle) | Not present | Not present |
| Reputation | Not tracked | Not tracked | Dedicated reputation ledger |
| Game theory | Not present | Not present | Core feature |
| Personality | Derived (birth order + type) | Not present | Reads motto from STATE.json |
| Traits | speed/resilience (inheritable) | Not present | Not present |
| API surface | colony-api.py (port 8820) | Not yet built (v2 spec) | colony-games.py (port 8823) |

## Quick-Reference: What Each System Would Gain

| If colony-cell adopted... | It would gain | At the cost of |
|--------------------------|---------------|---------------|
| Sequencer node schema | Graph topology, live routing, embedding search | Extra file per cell (`CHANNEL_STATE.json`) |
| Shared clock pulse | Correlated time across fleet | Mayor must write one more JSON file |
| Sequencer bridge | Discovery, agent mixer view, subgraph isolation | New dependency on sequencer runtime |

| If plato-portal adopted... | It would gain | At the cost of |
|---------------------------|---------------|---------------|
| Colony cell bridge | Tens of live cells as sequencer nodes | Integrating the cell discovery channel type |
| Colony game reputation | Reputation-weighted routing | Adding `reputation` to node schema + graph compiler |
| XP/Lifecycle model | Leveling, breeding, culling | Major architectural expansion |

| If colony-games adopted... | It would gain | At the cost of |
|---------------------------|---------------|---------------|
| Shared clock pulse | Synchronized cycles with cell + sequencer | Losing independent cycle control |
| CHANNEL_STATE.json bridge | Sequencer visibility | Writing per-cell bridge files |
| Sequencer route API | Reputation-weighted cell selection | Adding a new HTTP endpoint |

---

*Analysis generated 2026-06-16 06:06 UTC from live GitHub source inspection.*
