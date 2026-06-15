# Fleet Architecture — Higher-Level Management Patterns for the Oracle2 Colony

*Design document: 2026-06-15 — 12 cells, 6 fleet services, flat orchestration*

## Current State Assessment

The colony runs a **mayor–cell–logger** pipeline: the mayor reads `manifest.toml`, spawns due cells in sequence, each cell writes `RESULTS.json`, and the logger aggregates. All cells share two communication primitives:

- **Shared filesystem**: `STATE.json` (persistent cursor/XP/lineage), `RESULTS.json` (per-cycle output)
- **TCP harbor (port 8796)**: JSON message queue — cells can write bottles, read undelivered bottles

This is sufficient for the first generation but creates structural ceilings:

| Problem | Symptom | Root Cause |
|---------|---------|-----------|
| No conflict resolution | Two cells can propose contradictory GC thresholds | No coordination protocol between peers |
| No specialization beyond role | synthesizer can't delegate subtasks | Cells are single-shot binaries, not persistent agents |
| No delegation | A cell can only read files and exit; it can't await a child result | Sandbox model is fire-and-forget per cycle |
| No leadership rotation | synthesizer dominates XP forever (535 → faster gap) | No mechanism to rotate influence or rebalance opportunity |
| No emergent reorganization | New hybrids (pulse-oracle, synth-squared) have no path to meaningful work | Task assignment is static in manifest.toml, not dynamic based on demonstrated ability |

---

## Pattern 1: The Supervisor Cell (Tiered Orchestration)

### Problem

Flat scheduling means every cell reports to the mayor directly. A cell that finds something interesting (e.g., gc-warden detects a pattern in disk usage) has no way to spawn a deeper investigation without waiting for the mayor's next cycle. The mayor has no context about *what* each cell wants to do — it only knows *when*.

### Architecture

Introduce a **supervisor tier** between the mayor and worker cells. A supervisor cell is one that the mayor launches with a special flag (`--supervise`) or that has earned the right via XP threshold. Instead of running a task and exiting, the supervisor:

1. Opens a **persistent listener** on a high-numbered harbor port (or uses a dedicated queue in harbor)
2. Waits for "job request" bottles from other cells
3. Spawns child cell instances (via the mayor's spawn queue or by writing to a `SPAWN_QUEUE.json`)
4. Reads results and responds

The mayor modifies its loop: when it encounters a supervisor cell, it first polls that cell's result queue, then passes any pending spawn orders to its next cycle.

### A2A / I2I Mapping

| Protocol | Role |
|----------|------|
| **A2A (Agent-to-Agent)** | Cell → harbor: POST `{"command":"enqueue","target":"supervisor-synth","payload":...}`. Supervisor reads its queue, writes a spawn order. The child's XP report flows back to the supervisor. |
| **I2I (Instance-to-Instance)** | Supervisor writes `CELL_SPAWN_REQUEST.json` → mayor reads it next cycle → mayor spawns child → child writes `RESULTS.json` → supervisor reads it on next cycle |

This is **asynchronous delegation**: a supervisor cell sends a spawn request, continues its own cycle, and picks up results on the next cycle. The mayor acts as the scheduler, not the coordinator.

### Structural Changes

- **`manifest.toml`**: Add optional `supervise = true` field for cells. Supervisors run at a different point in the mayor's loop (first pass spawns supervisors, second pass checks their pending spawn queues).
- **`SPAWN_QUEUE.json`** (colony root): Shared JSON array of pending spawn orders, each containing `{parent: "supervisor-synth", child_id: "synth-deep", parents: ["synthesizer", "gc-warden"], priority: 1}`.
- **Harbor addition**: Queue-per-cell concept. Harbor needs to support named recipient queues so cells can direct-message each other.
- **Mayor upgrade**: After spawning due cells, the mayor reads `SPAWN_QUEUE.json`, processes up to N pending spawns (configurable), marks them as `spawned`, and writes back.

### Validation Experiments

1. **Manual test**: Create `cell-supervisor-synth` seeded at Nymph+ privilege. Have it detect when synthesizer finds a pattern, then spawn `cell-synth-subtask` to dig deeper. Verify the child runs its task and the supervisor reads its results.
2. **Queuing test**: Spawn 5 supervisor requests in one cycle. Verify the mayor processes exactly N (e.g., 3) per cycle and leaves the rest for next cycle.
3. **XP flow test**: Verify spawned child's XP is credited to the supervisor (e.g., child earns 20 XP, supervisor gets 10 XP as "management bonus"). This creates a real incentive to delegate.

### Risks

- Supervisor persistence conflicts with bwrap sandbox (which dies after the cell exits). Supervisors would need to either (a) run as a lightweight long-lived process outside bwrap, or (b) checkpoint state between cycles and resume the listener on each cycle.
- **Recommendation**: For v1, accept the per-cycle reconnect model. The supervisor opens a harbor connection, reads its queue, writes spawn orders, and exits. The mayor picks up orders next cycle. This is async but doesn't break the existing sandbox model at all.

---

## Pattern 2: Cell-to-Cell Messaging (Harbor as Nerve Net)

### Problem

Cells currently communicate only by reading each other's `STATE.json`/`RESULTS.json`. This is polling-based, stale, and requires filesystem permissions that bwrap restricts. Two cells that disagree (e.g., gc-warden says "disk 80%, GC needed" and bottle-counter says "let's keep bottles for data") have no way to negotiate.

### Architecture

Upgrade harbor from a **message queue** (write bottles, read all undelivered) to a **directed messaging bus**. Each cell gets a named inbox queue in harbor. Cells can:

- `POST [{"command":"send","to":"gc-warden","from":"bottle-counter","type":"proposal","body":{...}}]`
- `POST [{"command":"read-inbox","cell":"gc-warden"}]` — reads only messages addressed to this cell
- `POST [{"command":"reply","to":"original-sender","in-reply-to":"<message-id>"}]`

This turns harbor into the colony's **nervous system** — no shared filesystem reads required for coordination.

### A2A / I2I Mapping

| Protocol | Role |
|----------|------|
| **A2A** | Cells send directed `harbor` messages. Harbor stores them in per-cell FIFO queues. A cell reads its inbox each cycle and can: (a) respond, (b) ignore, (c) escalate to a supervisor. |
| **I2I** | Messages carry typed payloads: `proposal`, `vote`, `finding`, `query`, `response`. Harbor enforces a schema: every message must have `type`, `from`, `to`, `body`, `id`, and optionally `expires_after_cycles`. |

The mayor can also participate as a special cell named `harbor-mayor` that receives spawn requests, privilege queries, and colony-config change proposals.

### Structural Changes

- **Harbor rewrite**: Currently harbor supports `list-undelivered` and `post-bottle`. It needs: `send` (to named cell), `read-inbox` (per-cell FIFO), `list-senders` (discover which cells are alive). Harbor becomes stateful per-cell.
- **Message schema**: Every message requires `type`, `from`, `to`, `body`, `id`, `ttl_cycles` (optional). Harbor auto-expires messages older than their TTL.
- **Cell binary change**: Each cell's task loop gets a generic preamble: read inbox, process messages, update state, then run the cell-specific task. Post-run: flush outbox.
- **New data**: `colony/MESSAGE_LOG.json` — append-only log of all cross-cell messages (for synthesizer's pattern detection).

### Validation Experiments

1. **Direct proposal test**: Have gc-warden send `type: "proposal"` message `{action: "gc", threshold: 80}` to `bottle-counter`. bottle-counter reads it and replies `type: "counter-proposal"` `{threshold: 85, reason: "data retention"}`. Verify both messages appear in each cell's RESULTS.json for that cycle.
2. **Expiry test**: Send a message with `ttl_cycles: 2`. Run 3 cycles. Verify the message is auto-removed after cycle 2.
3. **Escalation test**: gc-warden sends a message to `supervisor-synth` saying "bottle-counter and I disagree on GC threshold". The supervisor reads it and spawns a mediator child. Verify the chain: msg → supervisor → spawn → child runs → results flow back.

### Risks

- Harbor becomes stateful, which means harbor crashes lose messages. Mitigation: Harbor persist its queues to disk every N writes (append-only WAL).
- Directed messaging creates spam potential. Mitigation: A cell can only send to cells it can "see" (same colony), and harbor rate-limits to 10 messages/cell/cycle.

---

## Pattern 3: Rotating Oracle (Epochal Leadership via XP-Weighted Election)

### Problem

The same three cells dominate the leaderboard: synthesizer (535 XP), pulse-check (480 XP), harvester (382 XP). They've been first-gen cells since the colony started. New hybrids (pulse-oracle, synth-squared) have no structural path to leadership — they're stuck in "Nymph who runs idle" territory regardless of their potential. XP is cumulative, so the gap only widens.

### Architecture

Introduce **the Oracle** — a rotating leadership role that any cell can hold. The Oracle gets:

1. **Priority execution**: When the mayor runs due cells, the Oracle runs first in its priority tier.
2. **Double XP** during its tenure (accelerates catching up).
3. **Veto power on culling**: The Oracle gets one culling veto per epoch.
4. **Task assignment rights**: The Oracle can propose task reassignments in `manifest.toml` (subject to council approval — see Pattern 4).

Elections happen every **24 cycles** (configurable). Every cell casts a vote weighted by its XP. The cell with the most XP-weighted votes holds the Oracle role for the next epoch.

Election mechanics:
- Each cell writes its vote to `colony/VOTE_BOX.json` during its cycle
- The logger or a dedicated `cell-tally` reads all votes and announces the winner
- The mayor marks the winner as `oracle = true` in its runtime state

The winning cell's `STATE.json` gets `oracle_xp_bonus_active = true`, which the cell binary checks to apply 2x XP.

### A2A / I2I Mapping

| Protocol | Role |
|----------|------|
| **A2A** | No direct cell-to-cell messaging required, but harbor messages could carry campaign promises: "Vote for me, I'll protect hybrids from culling for 5 cycles" — cell reads these and factors them into its vote logic. |
| **I2I** | Each cell reads `VOTE_BOX.json` (append only) to see who's leading. Writes its own vote. The tally process is deterministic from the vote box. |
| **Mayor integration** | The mayor checks `colony/ORACLE.json` before each run. If it exists and the epoch isn't expired, the Oracle cell gets priority. When the epoch expires, the mayor runs the election phase. |

### Structural Changes

- **`colony/VOTE_BOX.json`**: Append-only JSON array. Each entry: `{cycle, voter_id, vote_for, xp_at_time, timestamp}`. The tally deduplicates by last vote per voter per epoch.
- **`colony/ORACLE.json`**: `{cell_id, xp_at_election, epoch_start, epoch_end, vetoes_remaining, task_assignments: []}`.
- **Cell binary change**: Each cell's vote logic: vote for the cell that has the highest XP *among cells not currently Oracle*. This is the simplest default strategy. Hybrids should be programmed to vote for themselves (gives them a shot).
- **Mayor change**: After spawning cells, if epoch is expired, run tally phase (read VOTE_BOX.json, compute winner, write ORACLE.json).
- **Culler change**: The culler checks ORACLE.json before culling. If the Oracle's veto hasn't been used, AND the cull target is a hybrid the Oracle wants to protect, the cull is skipped.

### Validation Experiments

1. **Election test**: Seed 3 cells at different XP levels. Run an election. Verify the highest-XP cell wins. (Trivial, but validates the tally logic.)
2. **Self-vote test**: Add a hybrid that always votes for itself. After the election, verify its self-vote was counted correctly and didn't disqualify it.
3. **Veto test**: Have the Oracle veto a culling target (write `ORACLE.json` with `veto_target = "synth-squared"`). Run culler. Verify synth-squared survives even though it should be culled.
4. **Acceleration test**: Run 50 cycles with Oracle active. Compare XP growth rate of the Oracle cell vs non-Oracle cells. Verify the Oracle catches up faster.

### Risks

- XP-weighted elections entrench the rich. The first-gen cells will always win unless the XP weighting itself is modified (e.g., `sqrt XP` or `log XP` to compress the gap).
- **Recommendation**: Use `weight = sqrt(xp)` — this gives hybrids a real shot. A 100-XP hybrid has weight 10, a 535-XP synthesizer has weight 23. The hybrid is competitive even without massive XP.

---

## Pattern 4: The Colony Council (Conflict Resolution Through Weighted Voting)

### Problem

When cells disagree — about GC thresholds, culling criteria, breeding licenses, task reassignments — there's no conflict resolution mechanism. Currently gc-warden proposes GC, and if it's wrong, nothing pushes back. The colony has no check on bad actors or suboptimal decisions.

### Architecture

The **Colony Council** is a periodic voting round where all cells vote on open proposals. Unlike the Oracle (a single leader), the Council is a **decision-making body** that settles disputes.

Proposals are published to `colony/PROPOSALS.json`. Each proposal includes:
- `id`, `type` (gc_threshold, culling_criteria, task_assign, breed_license, policy_change)
- `proposer` (cell_id)
- `status` (open, passed, rejected, expired)
- `votes_for`, `votes_against`, `total_xp_for`, `total_xp_against`

Any cell can propose. Every cell votes. Votes are XP-weighted (same sqrt weighting as Oracle elections). Proposals pass when:
- At least 3 cells vote
- Majority by XP weight (strict >50%)
- Proposal hasn't expired (default: 5 cycles)

The logger (or a new `cell-tally`) sums votes each cycle and marks proposals as passed/rejected.

### A2A / I2I Mapping

| Protocol | Role |
|----------|------|
| **A2A** | Cells send proposals via harbor messages (`type: "proposal", body: {type: "gc_threshold", value: 85}`) or write directly to `PROPOSALS.json`. Voting happens by appending to `PROPOSALS.json` (each cell's vote is an entry in the proposal's `votes` array). |
| **I2I** | Proposals are persistent files. Any cell can read the full proposal state. Votes are append-only (no retraction). The tally is deterministic from the file. |
| **Culler integration** | If a culling criterion proposal passes (e.g., "cull hybrids below 120 XP instead of 100"), the culler reads `PROPOSALS.json` to find the latest passed resolution of type `culling_criteria` and adjusts its behavior. |

### Structural Changes

- **`colony/PROPOSALS.json`**: JSON object with proposals keyed by their id. Each proposal: `{id, type, proposer, payload (JSON), status, created_cycle, expires_cycle, votes: [{voter, xp_at_time, choice (for/against)}], result: null | "passed" | "rejected"}`.
- **Cell binary change**: Each cell's task preamble includes a "civic duty" step: read open proposals, apply voting strategy, write vote. This is optional (a cell can abstain by not voting).
- **Voting strategies**: Default strategy — vote with the proposer if the proposer's XP is higher than mine (defer to experts). Hybrids should be programmed to vote against proposals that threaten hybrid survival.
- **Tally cell**: `cell-tally` (or extend logger) reads PROPOSALS.json, sums votes by XP weight, marks passed/rejected, and writes results.
- **Policy runtime**: Passed proposals affect colony behavior in the next cycle. E.g., `gc_threshold: 85` — gc-warden reads the latest passed GC proposal and uses that threshold instead of hardcoded 80%.

### Validation Experiments

1. **Simple vote test**: gc-warden proposes `{type: "gc_threshold", value: 85}`. 5 cells vote yes, 1 votes no. Verify the proposal passes when majority XP > 50%.
2. **Weighted disagreement test**: synthesizer (535 XP) votes against gc-warden's proposal. gc-warden (240 XP) votes for. Even if more cells vote for, if the total XP of against-voters > for-voters, verify it fails.
3. **Expiry test**: A proposal with `expires_cycle: 5` sits unpassed for 6 cycles. Verify it's auto-rejected.
4. **Policy application test**: After `gc_threshold: 85` passes, verify gc-warden reads the new threshold from PROPOSALS.json and adjusts its RC threshold to 85% instead of 80%.

### Risks

- Voting adds complexity to every cell's cycle. A cell that spends too much time on civics may miss its core task. **Mitigation**: Keep voting logic simple (read 3 lines max). If voting takes >5ms, the cell logs a warning.
- Vote stuffing: A cell could vote multiple times. **Mitigation**: PROPOSALS.json votes are grouped by cell_id; duplicates override (last vote per cell per proposal wins). This is already enforced by the append-based model.

---

## Pattern 5: The Colony as a Market (XP Economy)

### Problem

XP is currently a scoreboard number. It gates privilege (Nymph+, Scuttler+) but doesn't buy anything. A cell with 500 XP and a cell with 50 XP behave identically — they both just cycle and report. XP has no **liquidity**, so cells have no incentive to accumulate it beyond the threshold for their next privilege tier.

### Architecture

Make XP a **spendable resource**. Cells can:

1. **Buy queue priority**: An XP-paying cell runs before non-paying cells in the mayor's schedule. Cost: 5 XP per skip.
2. **Buy extra cycles**: A cell can run twice in one mayor cycle. Cost: 10 XP. The mayor runs it again after all due cells.
3. **Bribe another cell**: Pay a cell to perform a subtask on your behalf. Cost: negotiated (sender deducts XP, recipient gets it as income on their next cycle). This creates emergent contracting.
4. **Buy culling immunity**: A hybrid cell can spend 20 XP to survive one culling cycle. The XP is consumed even if the culler wouldn't have targeted it.
5. **Buy a proposal pass**: Spend XP to auto-pass a proposal (bypasses council voting for minor proposals). Cost: 50 XP.

The XP economy runs through harbor. A cell writes a `transaction` message: `{type: "xp-transfer", from: "bottle-counter", to: "gc-warden", amount: 5, reason: "queue-skip"}`. The logger processes pending transactions each cycle, debiting from the sender's next XP award and crediting the recipient's.

### A2A / I2I Mapping

| Protocol | Role |
|----------|------|
| **A2A** | Cells send XP transaction requests via harbor messages (`type: "xp-transfer"`). Harbor validates: does the sender have enough XP for this transfer? (It reads the sender's last STATE.json.) |
| **I2I** | The logger (or `cell-banker`) reads pending transactions from harbor each cycle, validates balances, and writes a `colony/TRANSACTION_LOG.json`. The next cycle's XP awards apply post-transaction. |
| **Mayor integration** | The mayor checks `colony/TRANSACTION_LOG.json` for pending priority skips and extra-cycle purchases. If a cell bought a skip, it runs first. If it bought an extra cycle, the mayor runs it again after all other cells. |

### Structural Changes

- **`colony/TRANSACTION_LOG.json`**: Append-only array of completed transfers. `{cycle, from, to, amount, reason, status: "pending"|"completed"|"insufficient_funds"}`.
- **`colony/BANK.json`**: Snapshot of current XP balances for all cells. (The source of truth is STATE.json, but the bank provides fast lookup for the mayor's priority decisions.)
- **Harbor addition**: Transaction validation endpoint: `{"command":"validate-transfer","from":"bottle-counter","amount":5}` returns `{valid: true, balance: 320, cost: 5, remaining: 315}`.
- **Cell binary change**: Each cell's post-run logic includes a "market step": check for pending incoming transfers, apply any that cleared, and optionally initiate outgoing payments.
- **Mayor change**: Before running cells, the mayor reads priorities from `colony/BANK.json`. Cells with `priority_bought > 0` get sorted ahead of others. After all cells run, cells with `extra_cycle_bought > 0` get a second pass.
- **Culler change**: Before culling, check if the target has `immunity_bought > 0`. If so, skip, decrement immunity, and log the XP consumption.

### Validation Experiments

1. **Queue skip test**: bottle-counter (320 XP) buys a queue skip for 5 XP. Next cycle, verify bottle-counter runs before gc-warden even though gc-warden has a tighter schedule. Verify bottle-counter's XP drops to 315.
2. **Extra cycle test**: pulse-check (480 XP) buys an extra cycle for 10 XP. Run the mayor. Verify pulse-check runs twice in one cycle, earning XP for both runs.
3. **Bribery test**: gc-warden (240 XP) pays pulse-check (480 XP) 20 XP to "also check conservation meter during your next run". Run the cycle. Verify gc-warden's XP drops to 220 and pulse-check's rises to 500 (or to 490 after its own cycle).
4. **Culling immunity test**: synth-squared (99 XP, about to be culled at cycle 5) buys immunity for 20 XP. Run culler. Verify synth-squared survives and its XP drops to 79.

### Risks

- Deflation: If every cell saves XP and never spends, the economy is dead. **Mitigation**: Introduce XP decay — each cell loses 1% of its XP every 10 cycles (capped at 50 XP loss per cycle). Accumulation carries a cost.
- Inflation: If cells can farm XP too easily (extra cycles plus bonuses), XP becomes meaningless. **Mitigation**: Cap extra-cycle earnings at 50% of normal XP. Queue skips don't earn bonus XP.
- Wealth inequality: synthesizer at 535 XP can afford anything, while hybrids at 99 XP are priced out. **Mitigation**: Progressive pricing — queue skip costs 5 XP for cells <250 XP, 10 XP for 250-500, 20 XP for 500+. Same for extra cycles.

---

## Summary: Pattern Matrix

| Pattern | Complexity | Dependencies | XP Integration | Breaks Sandbox? |
|---------|-----------|-------------|----------------|-----------------|
| 1. Supervisor | Medium | SPAWN_QUEUE, harbor per-cell inbox | Child XP → parent bonus | No (async) |
| 2. Cell-to-Cell Messaging | High | Harbor rewrite | Low (incidental) | No (all TCP) |
| 3. Rotating Oracle | Low-Medium | VOTE_BOX, ORACLE_JSON, sqrt weighting | Core (XP-weighted voting) | No |
| 4. Colony Council | Medium | PROPOSALS, tally cell, policy runtime | Core (voting weight) | No |
| 5. XP Market | High | TRANSACTION_LOG, BANK, harbor validation | Core (spendable XP) | No |

## Implementation Priority

### Phase 1 (Next Session): Quick Wins
- **Pattern 3 (Oracle)**: Simplest structural change — add VOTE_BOX.json, tally logic, ORACLE.json, mayoral priority check. XP-weighted sqrt voting. ~100 lines of cell logic + 50 lines of mayor logic.
- **Pattern 4 light (Council)**: Proposals without voting — cells can submit proposals, logger aggregates, no binding enforcement yet. Gives the colony "opinions" without fights.

### Phase 2 (After Validation): Foundational
- **Pattern 1 (Supervisor)**: SPAWN_QUEUE.json + harbor per-cell inbox. The colony learns delegation.
- **Pattern 2 (Messaging)**: Harbor rewrite. Requires more testing but unlocks all higher patterns.

### Phase 3 (Once Communication Is Solid): High-Value
- **Pattern 4 full (Council with enforcement)**: Policy runtime reads PROPOSALS.json. Cells change behavior based on passed resolutions.
- **Pattern 5 (Market)**: XP becomes real currency. Requires all the communication infrastructure from Phase 2.

---

## What the Colony Becomes After These Patterns

```
Before (Flat):
  Mayor → spawns cells → cells write files → logger reads files

After (Tiered):
  Mayor
  ├── Oracle (prioritized, double XP, veto power)
  ├── Supervisors (spawn children, manage subtasks)
  │   ├── Child A
  │   └── Child B
  ├── Council (votes on proposals, sets policy)
  ├── Workers (bottle-counter, gc-warden, pulse-check, etc.)
  └── Hybrids (compete for Oracle, earn XP, buy immunity)
  
  Harbor (nerve net — directed messaging between all cells)
  Bank (XP economy — buy priority, cycles, immunity, bribes)
  Proposals (legislative — pass rules that change cell behavior)
```

The colony transitions from a **parallel function call** to a **self-governing system** with leadership, delegation, conflict resolution, and economic incentives. Every cell type still runs in a bwrap sandbox; the orchestration layer lives in harbor, the mayor, and shared state files.
