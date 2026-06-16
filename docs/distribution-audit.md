# Fleet Distribution Audit
**Generated:** 2026-06-16 06:07 UTC  
**Scope:** 7 SuperInstance repos + 1 npm scoped package

---

## Summary Table

| # | Package | Runtime | Channel | Status | Last Published | CI | Blockers |
|---|---------|---------|---------|--------|----------------|----|----------|
| 1 | **@superinstance/tminus-dispatcher** | Node.js (JavaScript) | **npm** | ✅ PUBLISHED | 3 days ago (v1.0.1) | ✅ 3 workflows (CI, Ensign, Publish) | None — fully publish-ready. Tag release fires GitHub → npm. |
| 2 | **pincher** (workspace: `pincher-core`, `pincher-cli`, `hybrid-bridge`, `pincher-infer`) | Rust + Python | **crates.io / PyPI / .nail bundle** | ❌ NOT PUBLISHED | N/A | ✅ 5 workflows (CI, Release, Bundle Publisher, Agent Activation) | **Multiple blockers:** (a) `pincher-core` depends on `ternary-types` and `silo-core` via git URLs — not publishable to crates.io until these are on crates.io or vendored. (b) `version = "0.1.0"` via workspace (0.x releases fine but semver rules apply). (c) `pincher-infer` targets PyPI but has no publish CI workflow. (d) Bundle publisher targets a custom `pincher.dev` registry — operational. |
| 3 | **flux-core** (sub-crate in net-new `SuperInstance/flux-core` repo) | Rust | **crates.io** | ❌ NOT PUBLISHED | N/A | ✅ 3 workflows (Rust CI, Publish, old Rust CI) | **Blocked:** (a) Cargo.toml `repository` field points to `https://github.com/flux-project/flux-core` (third-party org), not `SuperInstance/flux-core`. (b) Version `0.1.0` is a fork — needs alignment/bumping before publish. (c) Publish workflow exists but has never fired (no v* tags). |
| 4 | **cuda-oxide** (18-crate workspace, SuperInstance fork) | Rust | **crates.io** | ❌ NOT PUBLISHED on crates.io | N/A | ✅ 10+ workflows (CI, clippy, fmt, codeql, cargo-deny, book, docs, unit-tests, naming-guard, Publish) | **Blocked:** (a) The original `cuda-oxide` crates on crates.io are owned by `NVlabs` (NVIDIA). The SuperInstance fork would need to publish under a different name (e.g. `cuda-oxide-superinstance` or per-crate names). (b) 18-crate workspace with private `reserved-oxide-symbols` (publish = false). (c) Heavy LLVM/CUDA system dependencies. (d) Publish workflow exists but tags start with `v*` — none pushed yet since the fork. |
| 5 | **message-in-a-bottle** | No language (artifact repo) | N/A | ⚠️ ARCHIVE ONLY | N/A | ❌ No CI | **Not a distributable package.** Contains 3 bottle manifests (context, infra-rebuild, publish-request). It's a preserved state snapshot from Oracle1. Not publishable — informational only. |
| 6 | **@superinstance/schemas** (in `SuperInstance/plato-portal`) | TypeScript | **npm** | ✅ PUBLISHED | 3 weeks ago (v1.0.0) | ✅ CI, Deploy Docs, GitHub Pages | None — fully published as `@superinstance/schemas`. However, the repo is named `plato-portal` and also contains a Python SDK (`pyproject.toml`, `superinstance` v0.1.1) which is **not** published to PyPI. |
| 7 | **fleet-dashboard-api** (in `SuperInstance/fleet-dashboard-api`) | TypeScript (Cloudflare Worker) | **Cloudflare Workers / npm** | ❌ NOT PUBLISHED | N/A | ❌ No CI | **Blocked:** (a) `private: true` in package.json — explicitly not for npm. (b) Deployment target is Cloudflare Workers via `wrangler deploy`, not a library. (c) No CI workflow configured at all. (d) Needs `wrangler.toml` secrets configured for deployment. |

---

## Detailed Per-Package Analysis

### 1. @superinstance/tminus-dispatcher

| Field | Value |
|-------|-------|
| Repo | `SuperInstance/tminus-dispatcher` |
| Language | JavaScript (Node.js) |
| npm package | `@superinstance/tminus-dispatcher` |
| Latest version | 1.0.1 |
| Published | 2026-06-13 (3 days ago) |
| CI | ✅ CI, ✅ Ensign (agent), ✅ Publish to npm |
| Publish trigger | GitHub Release published → npm publish |
| Maintainer | `superinstance` <casey.digennaro@gmail.com> |
| Deps | `ws@^8.16.0` |
| **Verdict** | **🟢 Publish-ready.** This is the fleet's gold standard — published and automated. |

### 2. pincher (multi-package workspace)

| Sub-package | Channel | Status | Details |
|-------------|---------|--------|---------|
| `pincher-core` | crates.io | ❌ Not published | Git deps on `ternary-types`, `silo-core` block crates.io publish |
| `pincher-cli` | crates.io | ❌ Not published | Depends on local `pincher-core`; inherits git dep issue |
| `hybrid-bridge` | crates.io | ❌ Not published (likely) | Not checked in detail but same workspace constraints |
| `pincher-infer` | PyPI | ❌ Not published | No PyPI publish CI workflow |
| `.nail` bundle | pincher.dev | ⚠️ CI exists | Workflow publishes to `https://pincher.dev` — operational readiness depends on registry |

**CI:** The `Pincher CI/CD Bundle Publisher` workflow compiles, fuzzes, packs, signs, and publishes `.nail` bundles to a custom pincher.dev registry. The `Release` workflow creates GitHub releases with binaries. Both trigger on `v*.*.*` tags.

**Key Blockers:**
1. **Git dependencies** — `ternary-types` and `silo-core` are pulled via `git =` URLs, which crates.io forbids for published crates. Must either:
   - Publish `ternary-types` and `silo-core` to crates.io first
   - Vendor the dependencies inline
   - Switch to crates.io versions if available
2. **Python SDK** — `pincher-infer` targets PyPI but has no publish workflow or credential config.

**Verdict:** 🟡 **Partially buildable** (the .nail bundle pipeline exists). **Not on any standard package registry.** Requires upstream crate publishing and PyPI workflow additions.

### 3. flux-core (SuperInstance fork)

| Field | Value |
|-------|-------|
| Repo | `SuperInstance/flux-core` (not the original `flux-project/flux-core`) |
| Language | Rust |
| Sub-crate path | `flux-core/` (the root Cargo.toml is a wrapper) |
| Version | 0.1.0 |
| CI | ✅ Rust CI, ✅ Publish to crates.io |
| Publish trigger | Push of `v*` tag |

**Key Blockers:**
1. **Repository URL mismatch** — The sub-crate's `Cargo.toml` has `repository = "https://github.com/flux-project/flux-core"`, not the SuperInstance fork URL. This will be confusing and potentially block crates.io validation or confuse consumers.
2. **Version** — `0.1.0` may conflict with any existing `flux-core` crates on crates.io. `cargo search flux-core` found a different `flux-core` (v0.5.2, a "declarative task runner") — name collision possible.
3. **Fork status** — The crate lists authors as "FLUX Project Contributors" — the SuperInstance fork should have its own metadata.

**Verdict:** 🟠 **CI pipeline exists but crate has never been published.** Needs metadata cleanup before first publish.

### 4. cuda-oxide (SuperInstance fork of NVlabs/cuda-oxide)

| Field | Value |
|-------|-------|
| Repo | `SuperInstance/cuda-oxide` |
| Language | Rust (18-crate workspace) |
| CI | ✅ 10 workflows: CI, clippy, fmt, codeql, cargo-deny, unit-tests, docs, book, naming-guard, Publish to crates.io |
| Publish trigger | Push of `v*` tag |

**Key Blockers:**
1. **Name collision** — The original `cuda-oxide` is on crates.io at version 0.4.0, published by NVIDIA. The SuperInstance fork cannot publish under the same name.
2. **18-crate workspace** — `reserved-oxide-symbols` is marked `publish = false` (workspace-private, internal naming contract enforcement). Must exclude from publishing batch.
3. **System requirements** — Requires LLVM 21+, CUDA toolkit, NVPTX target. CI runs workspace-level builds but crates.io publish CI (`cargo publish`) would need these deps.
4. **No tags pushed** — The publish workflow has never triggered on the fork.

**Verdict:** 🔴 **Significant before publish: rename crates, split workspace, or coordinate with upstream.** Not ready for standard Rust distribution without a renaming strategy.

### 5. message-in-a-bottle

| Field | Value |
|-------|-------|
| Repo | `SuperInstance/message-in-a-bottle` |
| Language | None (empty repo with markdown files) |
| Content | 3 bottle manifests (context, infra-rebuild, publish-request from Oracle1) |
| CI | ❌ None |
| Pushed | 2026-05-22 (initial commit only) |

This is not a distributable package — it's a **preserved artifact archive**. The `PUBLISH-REQUEST.md` bottle contains instructions from Oracle1 to Forgemaster about publishing PyPI packages (plato-mud-server) and checking crates.io for plato-instinct, plato-relay, plato-dcs.

**Verdict:** ⚪ **Informational only.** No distribution infrastructure needed or possible.

### 6. @superinstance/schemas (plato-portal)

| Field | Value |
|-------|-------|
| Repo | `SuperInstance/plato-portal` |
| npm packages | ✅ `@superinstance/schemas` v1.0.0 (published 3 weeks ago) |
| Python SDK | ⚠️ `superinstance` v0.1.1 in repo, **not published** to PyPI |
| CI | ✅ Auto-Index, CI, Deploy Docs, Deploy to GitHub Pages |
| npm metadata | `main: schemas/index.js`, `types: schemas/index.d.ts` ✅ complete |

**Key Notes:**
- The `package.json` has `name: "@superinstance/schemas"` — **not** `plato-portal`. This is correct — the npm package name doesn't need to match the repo name.
- The Python SDK (`pyproject.toml`) is under the same repo but is **separate** — `superinstance` v0.1.1. No CI publishes it to PyPI.
- The `@superinstance/schemas` package has a `Proprietary` license in npm metadata despite LICENSE file in repo.

**Verdict:** 🟢 **npm package is publish-ready and live.** Python SDK has a PyPI gap.

### 7. fleet-dashboard-api

| Field | Value |
|-------|-------|
| Repo | `SuperInstance/fleet-dashboard-api` |
| Language | TypeScript (Cloudflare Worker) |
| package.json | `private: true` — explicitly not for npm |
| CI | ❌ No workflows |
| Wrangler config | ✅ Proper `wrangler.toml` with D1 binding (`fleet-telemetry`) |
| Deploy command | `wrangler deploy` |

**Key Blockers:**
1. **`private: true`** — The package is explicitly not intended for npm distribution. It's an application, not a library.
2. **No CI** — Zero CI/CD workflows exist. No automatic deployment pipeline.
3. **CF Workers deployment** — Needs Cloudflare credentials and `wrangler.toml` secrets configured. The D1 database `fleet-telemetry` must exist in the Cloudflare account.

**Verdict:** 🟠 **Deploy-ready** (wrangler config is valid) but **no automation.** Not an npm package by design.

---

## Cross-Cutting Findings

### Published vs. Unpublished

| Status | Count | Packages |
|--------|-------|----------|
| ✅ Published | 2 | `@superinstance/tminus-dispatcher`, `@superinstance/schemas` |
| ❌ Not published | 4 | pincher (crates.io + PyPI), flux-core, cuda-oxide, fleet-dashboard-api |
| ⚪ N/A | 1 | message-in-a-bottle |
| ⚠️ Partial | 1 | plato-portal (npm published, PyPI SDK unpublised) |

### Common Blockers

1. **Git dependencies** — `pincher-core` depends on `ternary-types` and `silo-core` via git URLs. This is the #1 blocker for crates.io publishing.

2. **Fork metadata** — Both `flux-core` and `cuda-oxide` are forks with stale metadata (wrong repository URLs, original author names).

3. **No tag-based triggers** — `flux-core`, `cuda-oxide`, and `pincher` all have publish-on-tag workflows but no tags have ever been pushed for the SuperInstance repos.

4. **Python SDK gap** — `plato-portal/pyproject.toml` defines a `superinstance` Python package that isn't published to PyPI. `pincher-infer` also has no PyPI publish pipeline.

5. **No CI on fleet-dashboard-api** — The sole Cloudflare Worker has zero CI, making production deployment a manual operation.

### Recommendations

| Priority | Action | Package(s) |
|----------|--------|------------|
| P0 | Publish `ternary-types` and `silo-core` to crates.io (or vendor them) | pincher |
| P0 | Add PyPI publish workflow for `superinstance` Python SDK | plato-portal |
| P1 | Update metadata (repo URL, authors) and push a v0.2.0 tag | flux-core, cuda-oxide |
| P1 | Rename cuda-oxide fork crates (e.g., `cuda-oxide-superinstance`) | cuda-oxide |
| P1 | Set up Cloudflare Workers CI/CD for fleet-dashboard-api | fleet-dashboard-api |
| P2 | Evaluate `message-in-a-bottle` — move actionable content to TODO/ticket, archive repo | message-in-a-bottle |

---

*Audit performed via `gh api`, `npm view`, `cargo search`, and direct Cargo.toml/package.json inspection.*
