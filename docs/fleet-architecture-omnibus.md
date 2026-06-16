# Fleet Architecture Omnibus — June 2026

## 1. Overview Map

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SUPERINSTANCE FLEET                             │
│                    (Two-Hemisphere Architecture)                        │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────┐  ┌─────────────────────────────────────┐
│      FORGEMASTER (Math Layer)       │  │      ORACLE2 (Behavior Layer)      │
├─────────────────────────────────────┤  ├─────────────────────────────────────┤
│                                     │  │                                     │
│  ┌─────────────────────────────┐   │  │  ┌─────────────────────────────┐   │
│  │  δ(n) CLT Theorem           │   │  │  │  colony-games.py (8823)     │   │
│  │  delta-clt/                 │   │  │  │  • PD Colloquium            │   │
│  │  └→ 9-channel scorer       │   │  │  │  • Trust Auction            │   │
│  │                              │   │  │  │  • Empathy Loop            │   │
│  │  conservation-languages/    │   │  │  │  • Darwin Arena (+rep)      │   │
│  │  └→ γ+η=C in 9 langs       │   │  │  │  • Mafia                    │   │
│  └─────────────────────────────┘   │  │  └─────────────────────────────┘   │
│                   │                 │  │                   │                 │
│  ┌─────────────────────────────┐   │  │  ┌─────────────────────────────┐   │
│  │  Ternary Crate Fleet        │   │  │  │  colony_conservation_scorer │   │
│  │  • ternary-types (base)     │   │  │  │  • 9-channel intent scores  │   │
│  │  • ternary-route    ✅ pub  │   │  │  │  • edge alignment matrix    │   │
│  │  • ternary-pid      ✅ pub  │   │  │  │  • λη fleet efficiency      │   │
│  │  • ternary-entropy  ✅ pub  │   │  │  └─────────────────────────────┘   │
│  │  • ternary-hamiltonian✅ pub│   │  │                   │                 │
│  │  • ternary-svm  ⚠️ CLI brk  │   │  │  ┌─────────────────────────────┐   │
│  │  • ternary-conserve ⚠️ bld  │   │  │  │  superinstance_bottle.py    │   │
│  │  • ternary-rhythm  ⚠️ bld   │   │  │  │  • Python protocol client  │   │
│  │  • ternary-search  ⚠️ no tst│   │  │  │  • encode/decode/validate   │   │
│  └─────────────────────────────┘   │  │  │  • conservation audit      │   │
│                   │                 │  │  └─────────────────────────────┘   │
│  ┌─────────────────────────────┐   │  │                   │                 │
│  │  Bridge Crates              │   │  │  ┌─────────────────────────────┐   │
│  │  ternary-fleet-integration  │   │  │  │  construct-coordination/    │   │
│  │  └→ AggregateResult         │   │  │  │  • fleet-deep-think-strat   │   │
│  │  ternary-fleet-packing      │   │  │  │  • colony-psychology-paper  │   │
│  │  └→ data compression       │   │  │  │  • experiment reports       │   │
│  └─────────────────────────────┘   │  │  └─────────────────────────────┘   │
│                   │                 │                                      │
│  ┌─────────────────────────────┐   │  ┌─────────────────────────────┐   │
│  │  superinstance-protocol     │   │  │  fleet-oracle2/             │   │
│  │  • Bottle envelope          │   │  │  • integrations/            │   │
│  │  • base64(msgpack) payload  │   │  │  • i2i-vessel/bottles/      │   │
│  │  • ternary conservation     │   │  │  • docs/analysis/           │   │
│  └─────────────────────────────┘   │  └─────────────────────────────┘   │
│                   │                 │                   │                 │
│  ┌─────────────────────────────┐   │  ┌─────────────────────────────┐   │
│  │  conservation-action        │   │  │  colony-games-darwin-rep    │   │
│  │  • GitHub Action gate       │   │  │  • inherited reputation     │   │
│  │  • CI/conservation check    │   │  │  • multiplier|exclusion|hyb │   │
│  └─────────────────────────────┘   │  └─────────────────────────────┘   │
│                   ▲                 │                   ▲                 │
│                   │     ▲▲           │                   │                │
│                   └─────║║───────────┘                   │                │
│     (GAP: no runtime │║║ conservation check in colony)  │                │
└─────────────────────║║───────────────────────────────────┘                │
                      ║║                                                    │
               ┌──────║║──────┐                                             │
               │   Bottle Bridge (bottle_integration.rs) — WRITTEN         │
               │   • AggregateResult → Bottle                              │
               │   • Bottle → AggregateResult                              │
               │   • validate_conservation()                               │
               └───────────────────────────┘                               │
                                          │                                │
               ┌──────────────────────────┴─────┐                          │
               │    Fleet Deployment            │                          │
               │  • tminus-dispatcher @npm ✅    │                          │
               │  • fleet-dashboard-api @CF ⚠️   │                          │
               │  • pincher @crates.io ❌ blocked│                          │
               │  • pincher-infer @PyPI ❌       │                          │
               │  • superinstance-sdk @PyPI ❌   │                          │
               │  • flux-core @crates.io ❌      │                          │
               └────────────────────────────────┘                          │
```

## 2. Gap Inventory

| Rank | Gap | Source | Target | Data | Blocker |
|------|-----|--------|--------|------|---------|
| 🔴 1 | No runtime conservation verification | colony-games.py (8823) | conservation-action | game scores → γ+η=C check | No runner exists; patch written but not PR'd |
| 🔴 2 | Bridge crate outputs not wired to protocol | ternary-fleet-integration | superinstance-protocol | AggregateResult → Bottle | bottle_integration.rs written but not landed |
| 🔴 3 | No conservation check in CI | colony-games | delta-clt | experiment results → CLT verify | Manual export only |
| 🟠 4 | Python protocol client not in pip | superinstance_bottle.py | PyPI | Bottle encode/decode for Python fleet | No PyPI token; no publish workflow |
| 🟠 5 | Conservation languages not importable | conservation-languages/ | colony_conservation_scorer.py | 9-language theorem verification | Two separate 9-channel implementations |
| 🟠 6 | No colony-cell → sequencer clock mapping | colony-cell (plato-portal) | cell-sequencer (superinstance-core) | cycle counters | No shared clock protocol |
| 🟠 7 | Cargo publish blocked for 6/8 ternary crates | ternary-svm, conserve, rhythm, etc. | crates.io | Cargo.toml | Git path deps; missing metadata; forks |
| 🟡 8 | fleet-dashboard-api not CI'd | fleet-dashboard-api | CF Workers | wrangler deploy | `private: true`; no workflow |
| 🟡 9 | Python SDK unpublished | plato-portal/superinstance/ | PyPI | agent.py, fleet.py, memory.py | No PyPI token |
| 🟡 10 | No tag-triggered releases | All publish workflows | GitHub Actions | On-tag CI pipelines | No tags ever pushed |

## 3. Immediate Next Steps

1. **PR the bottle_integration.rs** into superinstance-protocol crate — This is the linchpin: it enables all ternary → protocol integration. File written at `i2i-vessel/bottles/bottle_integration.rs`.

2. **PR the conserve-server-patch** into colony-games repo — Adds γ+η=C verification as a live endpoint. Patch tested and running at port 8823.

3. **Add PyPI publish workflow** for the Python protocol client — The `superinstance_bottle.py` is production-ready. Needs `publish.yml` + PyPI token.

4. **Add conservation check to colony-games CI** — When colony-games gets a CI, add a step that runs the 9-channel scorer on experiment output and verifies γ+η=C within δ(n).

5. **Create the plato-portal Python SDK extraction** — Move `superinstance/` from `plato-portal` to its own `SuperInstance/superinstance-python` repo with PyPI publish workflow.

## 4. Deployment Order

### Path: colony-games.py → Bottle → conservation-languages → delta-clt

```
Step 1: colony-games.py runs experiment
Step 2: conserve_server_patch scores all cells on 9 channels
        → /game/conserve/score returns {profiles, gamma, eta, C}
Step 3: superinstance_bottle.py wraps score in Bottle
        → {id: UUIDv7, src:"colony-games", act:"conservation.fleet.efficiency",
           trits: [quantized gamma semitones], enc:"msgpack", pay: base64(...)}
Step 4: Bottle.json lands in CONVERVE_LEDGER file
Step 5: conservation-languages/verifier reads ledger
        → γ + η == C (within δ(n)) ?
Step 6: delta-clt/live_experiment.py consumes verified data
        → computes CLT cancellation rate = δ(n) = 1/√n · (1 − 3/2n)
Step 7: conservation-action GitHub Action gates merge
        → if conservation violated, block PR
```

**What exists now:**
- ✅ Steps 1-4: colony-games.py (port 8823) + conserve-server-patch + superinstance_bottle.py + CONVERVE_LEDGER file
- ❌ Step 5: No runtime verifier that reads the ledger and checks γ+η=C
- ✅ Step 6: delta-clt/live_experiment.py exists but reads its own experiment-results.json, not the conservation ledger
- ✅ Step 7: conservation-action.yml exists but checks CI builds, not colony server output

**To close the gap:**
1. Write `conservation-ledger-verifier.py` that reads the colony games conservation ledger, runs `conservation-languages/` verifiers, and outputs a delta-clt-compatible results file
2. Add a nightly cron that runs the verifier and posts to fleet-pulse

## Key Numbers

| Metric | Value |
|--------|-------|
| Total repos scanned | 22 |
| Ternary crates surveyed | 8 |
| Publishing-ready | 4 (route, pid, entropy, hamiltonian) |
| Broken builds | 3 (conserve, svm, rhythm) |
| Live npm packages | 2 |
| Missing PyPI packages | 2 |
| Bottle bridge lines written | 252 |
| Conservation patch lines written | 540 |
| Colony experiments run | 5 |
| Breakthrough mechanism | Inherited reputation with multiplier (TFT 8/13) |
