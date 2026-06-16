# Fleet Bridge Analysis

**Date:** 2026-06-16  
**Author:** Subagent (code integration specialist)  
**Scope:** `ternary-fleet-integration` & `ternary-fleet-packing`

---

## 1. `ternary-fleet-integration` — The γ Verifier

### What it actually integrates

`ternary-fleet-integration` is **not** integrating external systems. It is a **bridge crate** that wires abstract ternary math primitives (voting, telemetry, consensus) into concrete fleet infrastructure patterns that Forgemaster-style services can consume. Specifically:

| Module | Bridges Ternary Math → | Fleet Infrastructure |
|--------|------------------------|---------------------|
| `fleet_types` | Defines `FleetNode`, `FleetEvent`, `TernaryVote`, `MetricSample` — all with a `ternary_vote: i8` (-1/0/+1) field | Common data types the fleet API endpoints can serialize/deserialize via Serde |
| `ternary_aggregator` | `aggregate_votes()` / `weighted_consensus()` raw ternary consensus math | Outputs `AggregateResult` — deployment-ready consensus state |
| `dash_emitter` | Formats votes/metrics into ternary-annotated JSON | JSON pulses suitable for a fleet-dashboard backend or event-bus |
| `health_report` | Maps net ternary sentiment to health status (green/yellow/red) | Produces `FleetHealth` struct compatible with an api-gateway `/health` endpoint |
| `rate_limiter_bridge` | Maps {-1,0,+1} votes → token budgets (1.0/0.5/0.1) and priority levels (240/128/16) | `fleet_rate_limit()` computes a soft throttle from collective ternary state |
| `bin/dash_relay.rs` **(binary)** | Wires all of the above into a live **axum HTTP server** on port 8790 | Exposes `/api/pulse` (POST/GET), `/api/health`, `/api/votes` |

**Bottom line:** It integrates ternary math into **simulated fleet infrastructure**. There is no production integration with real Kubernetes, Prometheus, or any actual runtime — it provides the *types and patterns* that a real fleet gateway would consume.

### CI/CD Workflow

**No CI/CD workflow exists.** Neither `.github/workflows/` nor any `.yml`/`.yaml` CI config files are present. The git history contains only one commit: the CROSS-POLLINATION.md file. The repo references `conservation-action` from its CROSS-POLLINATION.md, but does not include it or wire it in.

### Dependency Publication Status

All four dependencies are **published on crates.io**:

| Dependency | Version | Status |
|------------|---------|--------|
| `serde` | 1 (feature: derive) | Published ✅ |
| `serde_json` | 1 | Published ✅ |
| `chrono` | 0.4 (feature: serde) | Published ✅ |
| `tokio` | 1 (feature: full) | Published ✅ |
| `axum` | 0.8 | Published ✅ |

No unpublished or git-only dependencies.

---

## 2. `ternary-fleet-packing` — The η Optimizer

### What it optimizes

`ternary-fleet-packing` is a **standalone packing/encoding library** for ternary values (trits = {-1, 0, +1}). It has **nothing to do with fleet deployment packing** (binary size, cold start, etc.) despite its name and CROSS-POLLINATION.md suggesting otherwise. The actual content is a pure-data compression library with four packing schemes:

| Scheme | Bits/Trit | Description | Best For |
|--------|-----------|-------------|----------|
| `Trit2` | 2 | Naive: -1→00, 0→01, +1→10 | Simplicity, fast encoding |
| `TritBinary` | 2 | {sign, nonzero} bits | XNOR-style dot products |
| `TritOptimal` | ~1.6 | Base-3 packing (5 trits/byte) | Shannon-optimal density |
| `RLE` | variable | Run-length encoding | Sparse ternary vectors |

### Gap: The CROSS-POLLINATION.md narrative

The CROSS-POLLINATION.md describes this as "optimizing how fleet components are packed into deployable binaries" — but the actual code has **zero deployment logic**. It doesn't pack binaries, link artifacts, or compute deployment density. The name "packing" is used in the *data compression* sense (packing trits into bytes), not the *binary deployment* sense.

### Dependency Publication Status

All three dependencies are **unpublished git dependencies**:

| Dependency | Source | Status |
|------------|--------|--------|
| `ternary-types` | `https://github.com/SuperInstance/ternary-types.git` | **Git-only, not on crates.io** ⚠️ |
| `ternary-matmul` (optional) | `https://github.com/SuperInstance/ternary-matmul.git` | **Git-only, not on crates.io** ⚠️ |
| `ternary-quantize` (optional) | `https://github.com/SuperInstance/ternary-quantize.git` | **Git-only, not on crates.io** ⚠️ |

These are fetched via `[dependencies]` with `git =` URLs. While this works for local builds (we confirmed it), it means:
- No version pinning via semver (only commit hashes in Cargo.lock)
- Builds will fail without access to those private repos
- Cannot be published to crates.io until they are

Note: In the actual build, `ternary-types` and `ternary-matmul` were compiled, but `ternary-fleet-packing`'s `lib.rs` does not appear to import from any of them directly. The dependency edges exist but the core packing algorithms in `lib.rs` are self-contained with no import from these git crates.

### CI/CD Workflow

**No CI/CD workflow exists.** Same situation as integration — one commit in `.git`, no `.github/` directory.

---

## 3. Connection to Conservation Action and SuperInstance Protocol

### Conservation Action

Both repos claim connection to `conservation-action` (a GitHub Action that enforces γ + η ≤ C in CI):

- **`ternary-fleet-integration`** — The CROSS-POLLINATION.md explicitly says it should be the test phase that `conservation-action` gates against. But there is **no actual CI job** consuming this crate, and no integration between the two. The conservation-action repo exists on disk but isn't wired into either repo's CI (there is no CI at all).

- **`ternary-fleet-packing`** — Described as "the η optimizer" where packing density directly affects η (overhead). This is a **narrative connection only** — the actual crate doesn't measure, compute, or report η values.

### SuperInstance Protocol

The protocol (`superinstance-protocol`) defines the **Bottle** format:

```
Bottle {
    id: Uuid (uuidv7),
    ver: u32,
    src: String,
    tgt: String,
    act: String,
    trits: Vec<i8>,       // ← ternary values as fleet event signal
    enc: "msgpack",
    pay: String,          // ← base64(msgpack(payload))
    ttl: u32,
}
```

**Are these crates producing objects the protocol can transport?**

- **`ternary-fleet-integration`** — YES, partially. The `FleetEvent`, `FleetPulse`, and `MetricSample` types are all Serde-serializable structs. They could be embedded as the msgpack `payload` inside a Bottle. The `trits` field in the protocol maps perfectly to the ternary vote values. However, there is **no code** that actually wraps integration output into Bottles — the bridge is conceptual, not coded.

- **`ternary-fleet-packing`** — YES, partially. The packed byte arrays produced by `trit2_pack()` / `trit_optimal_pack()` could be carried as the opaque `pay` payload. The `-1, 0, +1` trits it encodes are protocol-identical to `superinstance-protocol::Trit`. However, packing currently works on raw `[i8]` slices, not on Bottles — no direct integration.

---

## 4. Missing Features & Gaps

### `ternary-fleet-integration`

| Issue | Severity | Detail |
|-------|----------|--------|
| **No CI/CD** | High | Zero workflows. No automated testing in CI. No `conservation-action` integration despite claiming it. |
| **No authentication** | Medium | The axum relay at port 8790 has no auth, rate-limiting (despite having a `rate_limiter_bridge` module) or TLS. |
| **No persistence** | Medium | Fleet state is in-memory `RwLock<Vec<FleetNode>>`. Restart = data loss. |
| **No Bottle serialization** | Medium | Despite the protocol existing in the same repo fleet, no code wraps output into `superinstance-protocol::Bottle` format. |
| **No η accounting** | Low | The CROSS-POLLINATION.md describes γ verification, but no code actually computes γ quality or compares it against δ(n) thresholds from delta-clt. |
| **`rate_limiter_bridge` unused** | Low | The rate limiter module is compiled but never called by `dash_relay.rs` — it's an orphan module. |

### `ternary-fleet-packing`

| Issue | Severity | Detail |
|-------|----------|--------|
| **Mismatched narrative vs code** | High | CROSS-POLLINATION.md describes binary deployment optimization. The actual crate is a pure data-compression library. The term "packing" is correct but misleading in context. |
| **Unpublished git dependencies** | High | All three deps are git-only. `cargo publish` is impossible. `ternary-matmul` and `ternary-quantize` are optional but `ternary-types` is required (though unused). |
| **No CI/CD** | Medium | Zero workflows. |
| **No `ternary-types` import** | Medium | The `lib.rs` defines its own `Trit` enum rather than importing from `ternary-types`. This means two separate Trit definitions exist in the ecosystem. |
| **No Bottle integration** | Medium | Packed trit data isn't wrapped in `superinstance-protocol::Bottle` format even though the protocol defines `trits: Vec<i8>`. |
| **No η measurement** | Low | Despite being called "The η Optimizer," no code measures packing density, overhead, or compression ratio against the η budget. |
| **`TritOptimal` group-size artifact** | Low | Packs in groups of 5. The unpack assumes group size matches; a N=7 unpack on group-of-5 data would misalign. Works for current tests but fragile. |
| **Python backup artifacts** | Low | `/__pycache__/` and `/python_backup/` exist in the repo root — stale artifacts from a Python prototyping phase. |

### Cross-Cutting Gaps

1. **No real γ measurement** — Neither crate actually computes γ (quality metric) or η (overhead). The conservation law (γ + η ≤ C) is described but not instrumented.

2. **No Bottle production** — The protocol crate exists and is healthy, but neither integration nor packing produces `superinstance::Bottle` objects. The pipeline is:  
   `ternary math → integration/packing → [GAP: no Bottle wrapping] → transport`

3. **No conservation-action CI gate** — The `conservation-action` GitHub Action exists on disk but neither repo consumes it.

4. **No observability** — No metrics export (Prometheus, OpenTelemetry), no logging framework beyond `println!`.

5. **Single commit history** — Both repos have exactly one commit ("Add CROSS-POLLINATION.md"), suggesting they were created in a batch and have never been iterated or had their source evolve after the initial structure.

---

## 5. Summary

| Crate | Actual Function | Narrative Function | Gap |
|-------|----------------|--------------------|-----|
| `ternary-fleet-integration` | Types + an axum HTTP relay for ternary-annotated fleet state | Verifier of γ (quality) across fleet components | No γ computation, no CI, no Bottle wrapping |
| `ternary-fleet-packing` | Ternary bit-packing library (data compression) | Optimizer of η (deployment overhead/binary packing) | Is a data compression lib, not a deployment packer; git-only deps; no η measurement |

**The two crates are bridges in different directions:**
- `integration` bridges ternary concepts **outward** to fleet infrastructure patterns
- `packing` bridges raw ternary data **inward** to efficient byte representation

Neither bridges **into** the SuperInstance Protocol Bottle transport — that connecting layer is the missing piece.
