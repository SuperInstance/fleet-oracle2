# Production Hardening — Round 4 (2026-07-11)

Branch: `production-round4-2026-07-11` (off `main`).

This document tracks concrete production-readiness fixes found by reading the
actual source, scripts, tests, and configs. Each entry was verified before push.

## Audit method

- Read every shell script in `scripts/`, all four Rust crates, and the Python
  source + the one integration test.
- Cross-checked README/config claims against what the code actually does.
- Verified each fix with the language-appropriate build/test/lint before push.

## Findings & fixes

| # | Area | Finding | Fix | Verified by |
|---|------|---------|-----|-------------|
| F1 | Rust `conservation-meter` | `detect_burn()` treated *flat* γ as "rising" (`>=`) → false burn alarm on a stable box, forcing max GC aggression | `>=`→`>` (strict); added 7 unit tests | `cargo test` → 7 passed |
| F2 | Shell `pulse-webhook.sh` | Telegram override + `send_telegram` defined **after** `main "$@"` ran → dead code (alerts never sent); the wrapper would also infinite-recurse once reordered; `TELEGRAM_ENABLED` default contradicted README; live bot token hardcoded in repo | Folded Telegram fan-out into `send_harbor_bottle` before `main`; default `true`→`false`; removed token (env-only) | `bash -n`; behavioral test: pri≥4 fires (1 call), pri 3 does not (0) |
| F3 | Shell `self-test.sh` | Conductor health check was fake-green (`jq '… // true'` always truthy); `headspace`/`gc-pid` pointed at wrong ports | Require explicit healthy signal; headspace 8800→9090, gc-pid 8080→8785 | `bash -n`; cross-checked vs README/pulse-embed/gc-pid-server.py |
| F4 | Shell `gc-intelligent.sh` | Redundant if/else — both branches called `phase_evict` identically | Call once | `bash -n` |
| F5 | Shell `gc-auto-evict.sh` | `freed_kb` parser stripped the unit suffix (`1.2G`→`1.2` mislabeled KB, ~1,000,000× off) | Parse number+unit, convert to KB | `bash -n`; python check: 1.2G→1258291KB, 500M→512000KB |
| F6 | Py `bottle_integration_test.py` | Conservation assertions structurally could not fail (swallowed try/except; identical bottles; "chain" always "all same"); even printed `VIOLATED` yet exited 0 | `expect()` harness + exit code = failure count + **negative** tests that assert violations are detected | normal run exit 0 (11/11); sabotaging enforcement → exit 3 (3 negative checks fail) |
| F7 | Rust `colony/cell` | `--colony`/`--cell-id` arg parse panicked (index OOB); `harbor-tcp` health probed a TCP port over HTTP (always down); base-XP doc off by 2×; `&motto[..n]` panicked on multi-byte UTF-8 | Bounds-safe arg lookup; TCP connect probe for :8796; doc `/10`→`/20`; `safe_truncate()` char-boundary helper + 4 tests | `cargo build` OK; `cargo test` → 4 passed |
| F8 | Docs `README.md`/`AGENTS.md` | `ternary-gc-advisor.py` referenced as a live "Swarm advisor" but absent from repo; README said "9 Steps"/"11 steps" while code has 12 (incl. 7.5 half-step, 10→12→11 reorder) | Honest status markers (planned stub, graceful skip); corrected step count + interval note | doc diff review |

## Honest stubs left in place (not deleted)

- `ternary-gc-advisor.py` — referenced by `gc-intelligent.sh` (guarded by `[ -f ]`,
  degrades to local PID when absent). Marked as a planned stub in README + AGENTS.md.

## Verification commands

```bash
# Rust (conservation-meter + colony/cell)
cd conservation-meter && cargo test                     # 7 passed
cd colony/cell && OPENSSL_DIR=/usr OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu \
  OPENSSL_INCLUDE_DIR=/usr/include cargo test           # 4 passed

# Shell (no shellcheck in CI env; syntax-checked with bash -n)
bash -n scripts/pulse-webhook.sh scripts/self-test.sh \
      scripts/gc-intelligent.sh scripts/gc-auto-evict.sh

# Python
python3 -m py_compile integrations/bottle_integration_test.py
python3 integrations/bottle_integration_test.py          # exit 0 (11/11 checks)
```

## Notes / environment caveats

- `shellcheck` and `jq` are not installed in this environment; shell scripts were
  syntax-checked with `bash -n` and cross-referenced against the live config.
- `colony/cell` needs OpenSSL; built with `OPENSSL_DIR` env vars (no sudo needed
  since system OpenSSL headers + lib are present).
- The leaked Telegram bot token (removed in F2) remains in git history and must
  be rotated by the operator; it is now env-only (`TELEGRAM_BOT_TOKEN`).
