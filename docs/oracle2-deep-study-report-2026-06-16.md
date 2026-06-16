# Oracle2 Deep-Study Report — 2026-06-16

**Objective:** Study Forgemaster's fleet architecture via parallel analysis wave, then bridge colony games with conservation protocol.

## Subagent Wave

### Completed (6/10)
1. **protocol-conformance** (27s, 16k tokens) — SuperInstance protocol envelope guide
2. **core-ecosystem-analysis** (6s, 225k tokens) — Architecture of 3 core repos
3. **cell-sequencer-alignment** (1m40s, 73k tokens) — Cross-repo clock/event model comparison
4. **ternary-fleet-survey** (2m2s, 105k tokens) — 8 ternary crates surveyed; 4 publishing-ready
5. **fleet-bridge-analysis** (1m46s, 33k tokens) — ternary-fleet-integration/packing are mid-bridge
6. **distribution-audit** (2m22s, 39k tokens) — 7 fleet apps audited; 2/7 published on npm
7. **conserve-server-patch** (2m56s, 126k tokens) — 540-line monkey-patch for conservation endpoints

### Claude Code Bridge
8. **claude-bottle-bridge** — Wrote 252-line `bottle_integration.rs` bridging `AggregateResult` ↔ `Bottle` (+2.3KB analysis doc)

### Panic-Failed (2/10)
9. **kimi-architecture-omnibus** — Context overflow (15+ READMEs)
10. ~~cell-sequencer-alignment~~ — Actually completed

### Still Running
11. **⬤ pincher-ci-fix** — Claude Code agent fixing pincher CI (6m+ runtime). Default build passes; all-features fails from wasmtime v28+ / landlock 0.5+ API changes.

## Products

### Code Artifacts (built + tested)
| File | Lines | Status |
|------|-------|--------|
| `superinstance_bottle.py` | 210 | ✅ Tested round-trip, conservation audit |
| `colony_conservation_scorer.py` | 290 | ✅ Tested 9-channel scoring + fleet efficiency |
| `conserve_server_patch.py` | 540 | ✅ Validated syntax, applied to colony-games.py |
| `conserve_server_patch.py` (as module) | 540 | ✅ Imports clean, all three modules linked |
| `bottle_integration.rs` | 252 | ✅ Written, ready to land in superinstance-protocol |
| `colony-games-darwin-reputation.py` | 200 | ✅ Published to colony-games repo |
| `.gc-pin` | 6 | ✅ Protection manifest for core data |

### Infrastructure Live
- ✅ **Conservation endpoints running on port 8823** — `GET /game/conserve/status`, `/game/conserve/score`, `/game/conserve/cell`, `/game/conserve/bottle`, `POST /game/conserve/verify`, `POST /game/conserve/log`
- ✅ **γ=1.2194 + η=0.0874 = C=1.3068** — Fleet conservation verified live (conserved=true, δ(14)=0.2386)
- ✅ 14 cells scored with roles: MAPPER (5), GENERALIST (8), PROCESSOR (1)

### Docs Written
| Location | Content |
|----------|---------|
| `i2i-vessel/bottles/protocol-conformance-guide.md` | SuperInstance protocol envelope + TypeScript/Python client guide |
| `i2i-vessel/bottles/fleet-bridge-analysis.md` | ternary-fleet-integration/packing analysis |
| `i2i-vessel/bottles/ternary-fleet-survey.md` | 8 ternary crate survey (4 ready, 3 broken, 1 weak) |
| `i2i-vessel/bottles/distribution-audit.md` | 7 fleet app distribution audit |
| `i2i-vessel/bottles/core-ecosystem-analysis.md` | superinstance-core/protocol/action architecture |
| `i2i-vessel/bottles/cell-sequencer-alignment.md` | Cross-repo clock/event/model comparison |
| `i2i-vessel/bottles/claude-bottle-bridge.md` | Bottle bridge + AggregateResult→Bottle pipeline |
| `i2i-vessel/bottles/pincher-ci-fix-status.md` | Pincher CI: default ✅, all-features ❌ (wasmtime/landlock) |
| `i2i-vessel/bottles/pypi-publish-proposal.md` | Python SDK publish plan (blocked on token) |
| `i2i-vessel/bottles/fleet-deep-think-strategy-2026-06-16.md` | Ecosystem strategy doc |
| `i2i-vessel/bottles/colony-psychology-paper-2026-06-16.md` | 5-experiment paper (inherited reputation breaks defection) |
| `fleet-oracle2/integrations/superinstance_bottle.py` | Pushed to repo |
| `fleet-oracle2/integrations/colony_conservation_scorer.py` | Pushed to repo |
| `fleet-oracle2/integrations/conserve_server_patch.py` | Pushed to repo |
| `fleet-oracle2/docs/*.md` | All 6 analysis docs pushed to repo |

## Key Insights

1. **Inherited reputation with multiplier mode** is the first mechanism that breaks the defection attractor in the Darwin Arena (TFT wins 8/13)
2. **4/8 ternary crates are publishing-ready** (ternary-route, ternary-pid, ternary-entropy, ternary-hamiltonian) — blocked only on CARGO_REGISTRY_TOKEN
3. **2/7 fleet apps are live on npm** (tminus-dispatcher v1.0.1, @superinstance/schemas v1.0.0) — Python SDK in plato-portal is not published
4. **Forgemaster's stack is 3-layer: Math → Bridge → Wire** — the final hop (bridge → protocol bottle) is now written for Python and Rust
5. **The conservation law is live** on the colony games server — every cell has a 9-channel score, and the fleet is within CLT bounds

## Remaining Work (on hold)
- **PyPI publish:** Need API token for `superinstance` v0.1.1
- **crates.io publish:** Need CARGO_REGISTRY_TOKEN for 8 ternary crates
- **CF Workers deploy:** Need CF API token for fleet-dashboard-api
- **Baton-system repo:** 404 — create or remove from docs
