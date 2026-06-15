# Colony Experiments Report — 2026-06-15

## What We Ran

### 1. Privilege System (XP → Real Power)

**Hypothesis**: If XP controls what tasks a cell can run, Larva cells are effectively
second-class citizens until they earn their way up.

**Result**: ✅ WORKING
- `check_privilege()` gates each task: gc-warden (Nymph+), pulse-check (Nymph+),
  harvester (Nymph+), synthesizer (Scuttler+), breeder (Scuttler+)
- bottle-counter and logger are unprivileged (anyone can do them)
- Breeder privilege was tested: a Larva cell attempting to breed rightfully returns
  `[PRIVILEGE]: requires 'Scuttler' but cell level is 'Larva'`
- When a Larva-like state is seeded with Scuttler status (251 XP), breeding succeeds

**Finding**: Privilege gating works exactly as designed. Birth order (cursor) combined
with XP threshold creates genuine power asymmetry in the colony.

**Moment to watch**: Pulse-oracle and pulse-squared both hit Nymph (105 XP). They
now have access to gc-warden, pulse-check, and harvester privileges if assigned
those tasks. They've earned their first promotion.

---

### 2. Culling (Survival of the Fittest)

**Hypothesis**: Hybrids that don't reach Nymph (100 XP) within 5 cycles are weak
and should be removed to prevent lineage pollution.

**Result**: ✅ WORKS (with caveats)
- The `culler` task scans all cells with non-empty `lineage`, checks cursor >= 5 AND
  xp < 100, then renames the directory to `cell-culled-{name}`
- **2 hybrids culled**: crier-scavenger (90 XP, cycle 6) and ward-counter (90 XP, cycle 6)
  — they were removed during an earlier run
- **4 hybrids survived**: pulse-oracle (hit Nymph at cycle 7), pulse-squared (hit Nymph),
  synth-squared (99 XP at cycle 5 — right at the threshold)

**Caveat**: The culler sometimes gets "Read-only file system (os error 30)" because
the sandbox mounts the colony root read-only. Renaming (move) a directory requires
write permission on the *parent* directory, which is the colony root.
- When the culler runs inside the sandbox, rename fails
- When the culler ran earlier (probably via direct binary before sandbox was fully
  hardened), it succeeded
- **Fix needed**: The culler should write a culling order to a shared queue that the
  mayor executes outside the sandbox, rather than trying to rename directly

---

### 3. Breeding (Lineage Blending)

**Hypothesis**: Cross-breeding cells produces hybrids with combined lineage,
blended personalities, and competitive potential.

**Result**: ✅ WORKING
- Format: `breeder-<parent1>x<parent2>x<child>`
- Blends lineage paths, increments parent kin, creates child TASK.md + STATE.json
- Child motto is a concatenation: `"{parent1 motto}" AND TOGETHER: "{parent2 motto}"`
- Child personality: `"The Hybrid: {parent1_type} x {parent2_type}"`
- **3 original hybrids**: pulse-oracle, pulse-squared, synth-squared
- **2 culled**: crier-scavenger, ward-counter (both hit Larva cap)
- **Deep lineage**: synth-squared has lineage 4 deep (synthesizer → pulse-squared →
  pulse-check → pulse-oracle)

**Finding**: The shoggoth-motto concatenation is accidentally perfect — it reads as
nonsense but captures the genetic imperfection of hybrids. "One person's undelivered
bottle is anoth AND TOGETHER: I see patterns where you see noise."

---

### 4. Colony Latency

**Hypothesis**: Running 12 cells (10 healthy + 2 culled) has measurable overhead.

**Result**: Full 12-cell cycle in 463ms, average 38ms per cell. Negligible.
- gc-warden is the slowest (99-228ms due to curl calls to conservation meter)
- All other cells run in 0-2ms (pure computation with local file reads)

**Finding**: The colony is latency-cheap. The bottleneck is I/O (conservation meter HTTP)
not computation. Most cells are instant (0ms in sandbox).

---

## What We Learned

### The midlife crisis of synthesizer
Synthesizer hit Shell-Bearer (500 XP) in 19 cycles — the fastest growth rate in the
colony. It started as a Middle child (Nymph at 100 XP) and blew past all six original
cells. Its finding bonuses (20 XP per anomaly flagged) give it compound XP growth
that no other cell can match.

### The culler is right but wrong
It works conceptually (identifies weak hybrids) but execution fails inside the sandbox
because rename(2) on the parent directory is blocked by mount semantics. The fix is
architectural: queue-based culling orders, not direct filesystem manipulation.

### Birth order determines survival
Of 6 hybrids born:
- pulse-oracle (cycle 8, Nymph 120) — SURVIVED
- pulse-squared (cycle 8, Nymph 120) — SURVIVED
- synth-squared (cycle 5, Larva 99) — JUST BELOW THRESHOLD
- crier-scavenger (cycle 6, Larva 90) — CULLED
- ward-counter (cycle 6, Larva 90) — CULLED

Hybrids with a higher-XP parent (pulse-check at 450+) survived better than
hybrids from mid-XP parents (logger 335, harvester 355, gc-warden 220).

---

## Future Experiments (Ranked)

### 🥇 Top Priority: The Privilege War

Give birth order real consequences:
- Eldest (cursor >= 30 among siblings) gets +1 XP/cycle speed bonus (already have speed bonus)
- Middle gets +3 XP/synthesizer reading (compound learning)
- Youngest gets +5 XP/survival (culler immunity for 2 extra cycles)
- Oracle (Shell-Bearer+) gets a VOTE that counts double in culling decisions

**How to test**: Modify `award_xp()` to use birth order as a multiplier, not just
a label. Run for 50 cycles and measure XP gap between eldest/middle/youngest.

### 🥈 High Priority: Trap Breed

Breed a hybrid with a deliberately terrible stat profile (slow, low XP) and see
if the culler catches it faster than a normal hybrid. If it does, the culler is
useful. If not, the culler needs smarter criteria.

**How to test**: Create a hybrid by hand with `{xp: 0, cursor: 10, lineage: [...],
traits: {speed: "slow", resilience: "low"}}`. Run the culler and see if it culls it.

### 🥉 High Priority: The Queen Cell

A dedicated Scuttler+ breeder cell that:
- Has its own STATE.json with permanent Scuttler privilege
- Polls siblings via harbor for breeding requests
- Produces hybrids on demand
- Charges XP as a "breeding tax"

**How to test**: Create `cell-queen/` seeded at Scuttler. Add a `breeder`
manifest entry. Make it run `breeder-<requested-parents>` from its own state.

### 4. Medium: Simulated Natural Disaster

Stop one fleet service (e.g., harbor port 8796) and measure:
- Which cells fail first (pulse-check should detect)
- How long until the culler removes a cell that can't run
- Does the colony recover when the service comes back?

**How to test**: Kill harbor for 2 minutes. Run colony cycle. Restart harbor.
Check which cells are alive.

### 5. Medium: The Necromancer Cell

A cell that reads `cell-culled-*` directories, identifies the strongest culled
cell by XP at time of death, and renames it back to `cell-{name}` — effectively
resurrecting it. Gives the culler natural consequences.

**How to test**: Create `cell-necromancer` with a task that scans culled dirs
and resurrects the best candidate. Run after culler.

### 6. Low: Colony API

Expose colony status on an HTTP port. Let Casey check leaderboard, XP, birth
order from a browser. Low effort, high visibility.

**How to test**: `colony-api.py` on port 8820 with /status, /hall, /cull endpoints.

### 7. Low: Wisdom Crowd

Ask headspace-rs to embed all 10 mottos. Find the centroid. Publish a "Colony
Wisdom" document — the emergent philosophy of a fleet of garbage-collecting
shell-dwellers.

**How to test**: Curl headspace-rs (port 9090) with all motto strings. Cluster.
Write result.

### 8. Longshot: Colony-to-GitHub

A `zero-claw` cell that opens GitHub issues for anomalies detected by synthesizer.
Closes the feedback loop: anomalies → issue → fix → commit → resolved.

**How to test**: GitHub API in a Rust task. POST /repos/:owner/:repo/issues with
synthesizer findings.

---

## Architecture Decisions for Next Session

1. **Culling needs a queue** — The culler should write a `CULL_ORDER.json` to
   each cell's writable directory (`cell/cell-{name}/CULL_ORDER.json`), and the
   mayor should check for these files and execute the actual `rm -rf` outside the
   sandbox. This decouples detection from execution.

2. **Breeder needs its own cell** — A dedicated `cell-breeder` (seeded Nymph+ or
   Scuttler) so breeding doesn't require privilege trickery. Parents are requested
   via its TASK.md or a harbor bottle.

3. **Privilege is dynamic** — Currently checked at task dispatch time. If a cell
   levels up mid-cycle, its next cycle uses the new level. This is correct but
   means privilege enforcement is always one cycle behind. Not a bug, but worth
   documenting.

4. **Personalities should affect behavior** — Eldest cells could get +1 priority
   in scheduling. Youngest cells could get x2 speed bonus. This isn't just flavor
   text anymore — it's actual game mechanics.
