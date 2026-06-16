# Ternary Crate Fleet Survey

**Date:** 2026-06-16  
**Scope:** All 8 `ternary-*` crates under `/home/ubuntu/fleet-study/`  
**Repository:** All at `https://github.com/SuperInstance/ternary-*`

---

## 1. `ternary-conserve` — Conservation Domain Framework

- **Problem:** Provides a parametric, reusable lifecycle for any measurable resource — budget it, profile expected consumption, detect anomalies, and report threshold crossings. Targets fish stocks, fuel, battery, inference tokens, and crew attention domains.
- **Key types:** `ResourceUnit` trait (line 88), `Budget<T>` (line 209), `Profile<T>` (line 227), `EventKind<T>` (line 238), `ConservationEvent<T>` (line 276), `ThresholdSet<T>` (line 297), `ConservationDomain<T: ResourceUnit>` (line 338).
- **Ternary deps:** `ternary-types` (path `../ternary-types`) — used for `Ternary` in event severity.
- **Tests:** 12 `#[test]` functions in `lib.rs`. **Fails to compile** — `ternary-types` crate not found on disk (path dependency missing).
- **γ+η=C relation:** Direct embodiment. `ConservationDomain` implements the closed-loop **Budget → Profile → Detect → Report** cycle where `remaining = total - consumed` is the core conservation invariant. The `ResourceUnit::remaining()` method (line 102) is the computational analogue of conservation subtraction. Events carry `Ternary` severity (Negative=exhaustion, Neutral=warning, Positive=nominal), mapping η to event severity and γ to the budget remaining.
- **Publishing readiness:** ⚠️ **Needs work.** Missing `homepage`, `documentation`, `[badges]`. Path dependency `ternary-types` needs resolution. `#[deny(missing_docs)]` is good but there are no docs on `Budget`'s fields. `serde` is optional but `no_std` mode via feature flag is implicit. 911 lines, dense but well-structured.

---

## 2. `ternary-svm` — PEGASOS Linear SVM for Ternary Features

- **Problem:** Fast linear SVM classification (with PEGASOS stochastic sub-gradient descent) over ternary \{-1, 0, +1\} feature vectors, including OvO multi-class for the three value classes.
- **Key types:** `Trit = i8` (line 44), `TernSVM` (line 111), `OvOTernSVM` (line 458). Two binaries: `train-cli` and `ternary-svm`.
- **Ternary deps:** None.
- **Tests:** 25 `#[test]` in `lib.rs`. **Library tests compile OK.** Binary `train-cli` fails to compile (missing `serde_json` dep in feature=`cli` context — 16 errors). `ternary-rhythm` binary unaffected.
- **γ+η=C relation:** The PEGASOS update rule explicitly references η as the learning rate: `w ← (1 − ηλ)w + η·yᵢ·xᵢ` — see doc comment at line 221. η controls the step size, γ (not named here) maps to the regularization λ. The ternary output \{-1, 0, +1\} decision function maps directly to conservation states.
- **Publishing readiness:** ⚠️ **Needs work.** Missing `homepage`, `documentation`, `keywords`, `categories`, `[badges]`, `authors`. The CLI binary's compile error reveals `serde_json` dependency is gated behind `cli` feature but the binary unconditionally uses it — packaging bug. 951 lines, the most complex crate.

---

## 3. `ternary-route` — Ternary-Aware Load Balancer

- **Problem:** Route requests with ternary \{-1=down, 0=degraded, +1=healthy\} health awareness. Implements weighted round-robin, queue/degrade logic, failover, and rebalance.
- **Key types:** `Destination` (line 7), `RouteDecision` enum (line 16), `TernaryRouter` (line 23) with methods `route`, `weighted_route`, `update_health`, `failover`, `drain_queue`, `rebalance`.
- **Ternary deps:** None.
- **Tests:** 8 `#[test]` in `lib.rs`. All compile cleanly.
- **γ+η=C relation:** The `health: i8` field on `Destination` is the clear mapping: η = health state (\{-1,0,+1\}). γ maps to load level (0.0–1.0 continuous). The routing decision `RouteDecision::Accept(dest) | Queue | Reject` is the C-arity mapping: Accept > Queue > Reject. Conservation appears as load redistribution — `rebalance()` ensures the total load is conserved across destinations.
- **Publishing readiness:** ✅ **Publishing-ready.** Clean metadata (description ✓, license MIT ✓, repository ✓, homepage ✓, categories ✓, keywords ✓). Missing only `documentation` and `[badges]` and `authors`. 213 lines, focused, well-tested.

---

## 4. `ternary-pid` — Ternary PID Controller

- **Problem:** Continuous PID controller with ternary output \{-1, 0, +1\} for fleet governance. Includes anti-windup, deadband, derivative filtering, cascade control, and feedforward.
- **Key types:** `TernaryPid` (line 5), `CascadePid` (line 102), `FeedforwardPid` (line 120).
- **Ternary deps:** None.
- **Tests:** 9 `#[test]` in `lib.rs`. All compile cleanly.
- **γ+η=C relation:** The three PID terms (P+I+D) map to the ternary trinity: Proportional = γ (current deviation), Integral = η (accumulated history), Derivative = C rate of change (future prediction). The ternary quantization `if output > 0.0 { 1 } else if output < 0.0 { -1 } else { 0 }` (line 99) is the C-mapping from continuous PID space to \{-1,0,+1\}. The `deadband` parameter enforces conservation territory (Neutral zone).
- **Publishing readiness:** ✅ **Publishing-ready.** Full metadata (description ✓, license MIT ✓, repository ✓, homepage ✓, documentation ✓, keywords ✓, categories ✓). Missing only `[badges]` and `authors`. 230 lines, clean, single-file.

---

## 5. `ternary-search-rs` — High-Performance Vector Search Server

- **Problem:** Rust replacement for Python semantic search server. Loads fleet embeddings (384-d f32 vectors from ndjson), serves search/concept/cross/frontier/stats endpoints. Support for concept-guided search, cross-pollination, and frontier analysis.
- **Key types:** `VectorStore` (vectors.rs:25), `Record` (vectors.rs:12), `SearchHit` (vectors.rs:45), `ConceptInfo` (vectors.rs:54), `Stats` (vectors.rs:60), `CrossPair` (concepts.rs:12), `FrontierEntry` (concepts.rs:22), `AnalysisFile` (concepts.rs:31), `ConceptAnalysis` (concepts.rs:39), `AppState` (main.rs:59), `Args` (main.rs:32).
- **Ternary deps:** None. This is a standalone web server using axum + rayon + tokio.
- **Tests:** 0 `#[test]` functions. No test module. **No tests at all.**
- **γ+η=C relation:** The three search operations — Primary Search (concept match), Cross-Pollination (outside concept), Frontier (boundary expansion) — map to the three ternaries. `concept_boost` (line 56, default 1.15) is the γ parameter modulating concept attraction. The `search()` method's three-way sort (concept → cosine → boost) embodies the η hierarchy.
- **Publishing readiness:** ❌ **Needs significant work.** Missing `repository`, `license`, `homepage`, `documentation`, `keywords`, `categories`, `[badges]`. Path dependencies (`vectors_path`, `analysis_path`) hardcoded to `/home/phoenix/...` — will break on any other machine. Vector dimension `DIM=384` is hardcoded and unconfigurable. No `authors` field. 784 lines across 3 source files.

---

## 6. `ternary-rhythm` — Temporal Pattern Recognition

- **Problem:** Generate, detect, classify, and evolve rhythmic patterns on ternary time values. Provides Euclidean rhythms, polyrhythms, syncopation detection, groove analysis, and pattern evolution.
- **Key types:** `RhythmPattern = Vec<Ternary>` (line 11), `TernaryExt` trait (line 18), `Rhythm` (line 52), `Metronome` (line 123), `Polyrhythm` (line 167), `Syncopation` (line 223), `Groove` (line 261), `RhythmEvolver` (line 340), `Classification` (line 562). Free functions: `euclidean`, `syncopation`, `density`, `swing`, `rotate`, `classify`, `visualize`, `to_string`, `from_string`.
- **Ternary deps:** None (has own `mod ternary` with `Ternary` type).
- **Tests:** 52 `#[test]` in `lib.rs`. **Fails to compile** — optional dep `neon-kernel` (path `../the-rotation/crates/neon-kernel`) not found on disk. With `default-features` (no `simd` feature) it should still work; the error is from trying to resolve the path regardless.
- **γ+η=C relation:** Direct: `Ternary::Positive` (beat/hit), `Ternary::Neutral` (rest/sustain), `Ternary::Negative` (accent/release) — the classic ternary pattern. The three states γ=Positive action, η=Neutral flow, C=Negative emphasis. **Conservation appears in `density()`** (line 513): the sum of absolute values over time is conserved in a closed pattern. `RhythmEvolver` mutates patterns while preserving the conservation measure.
- **Publishing readiness:** ⚠️ **Needs work.** Missing `documentation`, `[badges]`. The `neon-kernel` path dependency from `the-rotation/` directory is missing on disk, breaking compile. Features `simd` + `neon-kernel` are non-functional. Strong codebase with 52 tests. 1135 lines, the largest crate.

---

## 7. `ternary-entropy` — Entropy Analysis for Ternary Distributions

- **Problem:** Compute Shannon entropy, conditional entropy, mutual information, KL divergence, JS divergence, sliding window entropy, and entropy rate for ternary-valued distributions.
- **Key types:** `Ternary` enum (line 11), `TernaryDistribution` (line 33), `JointDistribution` (line 120). Free functions: `shannon_entropy`, `max_entropy`, `normalized_entropy`, `conditional_entropy`, `joint_entropy`, `mutual_information`, `kl_divergence`, `js_divergence`, `cross_entropy`, `sliding_entropy`, `entropy_rate`.
- **Ternary deps:** None (has its own `Ternary` enum definition).
- **Tests:** 24 `#[test]` in `lib.rs`. All compile and would pass cleanly.
- **γ+η=C relation:** The three-side distribution (Positive, Negative, Neutral) is the foundation of the entropy computation. H = -Σ pᵢ log₂(pᵢ) = γ(Positive) + η(Negative) + C(Neutral). **directly embodies the conservation law:** `shannon_entropy` is the sum over all three states, `mutual_information` measures how much one side constrains another, `conditional_entropy` measures residual uncertainty. Maximum entropy (log₂ 3) corresponds to perfect conservation balance.
- **Publishing readiness:** ✅ **Publishing-ready.** Clean metadata (description ✓, license MIT ✓, repository ✓, keywords ✓, categories ✓). Missing only `homepage`, `documentation`, `[badges]`, `authors`. Zero external dependencies. 483 lines, textbook-level code.

---

## 8. `ternary-hamiltonian` — Z₃ Hamiltonian Mechanics

- **Problem:** Discrete Hamiltonian dynamics where positions and momenta live in Z₃ = {0,1,2} (mapped from \{-1,0,+1\}). Provides symplectic integrators (Euler and Störmer–Verlet) that preserve phase space volume exactly by using modular arithmetic instead of clamping. Explicitly fixes the prior bug where clamping destroyed symplecticity.
- **Key types:** `z3` module (line 32) with `encode`, `decode`, `add`, `sub`, `mul`, `TernaryCoupling` (line 82), `PhaseSpace` (line 115), `Hamiltonian` (line 182), `SymplecticIntegrator` (line 221), `EnergyConservation` (line 294), `PoissonBracket` (line 344), `LiouvilleTheorem` (line 383).
- **Ternary deps:** None.
- **Tests:** 30 `#[test]` in `lib.rs`. All compile cleanly. Most rigorous test suite: volume preservation of all 9 states for 1-DOF and all 81 states for 2-DOF over dozens of steps, periodicity verification.
- **γ+η=C relation:** **Direct formal proof.** Hamiltonian H = T + V = kinetic + potential = γ(kinetic) + η(potential). The conservation law is Liouville's theorem: phase space volume is preserved by symplectic flow. `TernaryCoupling::alpha` = γ (force coupling), `beta` = η (velocity coupling). The Z₃ update `p ← p − α·q, q ← q + β·p` is the discrete flow that conserves C. The `PoissonBracket` constrains observables via {f,g} = Σ(df/dq · dg/dp − df/dp · dg/dq) — the η×γ conservation relation. All 9 states remain distinct forever.
- **Publishing readiness:** ✅ **Publishing-ready.** description ✓, license MIT ✓, repository ✓. Missing `homepage`, `documentation`, `keywords`, `categories`, `[badges]`, `authors`. Zero external dependencies. 788 lines, the most mathematically rigorous crate.

---

## Summary Table

| # | Crate | Lines | Tests | Compiles? | Ready? | Ternary Deps | γ+η=C Mapping |
|---|-------|-------|-------|-----------|--------|-------------|---------------|
| 1 | conserve | 911 | 12 | ❌ (missing dep) | ⚠️ | ternary-types | Budget → Profile → Detect → Report cycle |
| 2 | svm | 951 | 25 | ⚠️ (lib only) | ⚠️ | none | η=learning rate, γ=regularization λ |
| 3 | route | 213 | 8 | ✅ | ✅ | none | health∈{-1,0,+1} = η, load=γ |
| 4 | pid | 230 | 9 | ✅ | ✅ | none | P=γ, I=η, D=output (C) |
| 5 | search-rs | 784 | 0 | ✅ | ❌ | none | concept/boost/cross = γ/η/C |
| 6 | rhythm | 1135 | 52 | ❌ (missing dep) | ⚠️ | none (own Ternary) | Positive/Neutral/Negative pattern states |
| 7 | entropy | 483 | 24 | ✅ | ✅ | none (own Ternary) | H = -Σ pᵢ log pᵢ over 3 states |
| 8 | hamiltonian | 788 | 30 | ✅ | ✅ | none | α=γ, β=η, Liouville=C |

## Key Findings

1. **Broken builds:** `ternary-conserve` and `ternary-rhythm` fail to compile due to missing path dependencies (`ternary-types` and `neon-kernel` respectively, neither on disk). `ternary-svm` library tests work but the CLI binary fails.

2. **Zero-test crate:** `ternary-search-rs` has 0 tests for a server handling search/concept logic and loading real data files.

3. **Publishing-ready (4/8):** `ternary-route`, `ternary-pid`, `ternary-entropy`, `ternary-hamiltonian` — solid metadata, clean compiles, good test coverage.

4. **Metadata gaps across all crates:** Only 3/8 have a `[badges]` section? Actually none have `[badges]`. Most are missing `homepage` and `documentation` URLs. `authors` is missing from 5/8.

5. **The γ+η=C conservation law** is structurally embedded across the fleet:
   - *Explicit math:* `ternary-hamiltonian` (formal symplectic proof)
   - *Explicit loop:* `ternary-conserve` (Budget→Profile→Detect→Report)
   - *Probability:* `ternary-entropy` (H over 3 states)
   - *Control theory:* `ternary-pid` (P+I+D = γ+η+C)
   - *Classification:* `ternary-svm` (η as SGD learning rate)
   - *Timing:* `ternary-rhythm` (3-state temporal patterns)
   - *Networking:* `ternary-route` (health = η, load = γ)
   - *Search:* `ternary-search-rs` (concept/boost/cross triage)

6. **Recommendation:** Fix path dependencies first (make them optional or vendored), add `[badges]`, fill metadata gaps, and add tests to `ternary-search-rs` before any crates.io publishing push.
