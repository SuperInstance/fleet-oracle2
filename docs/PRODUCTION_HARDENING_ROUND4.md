# Production Hardening — Round 4 (2026-07-11)

Branch: `production-round4-2026-07-11` (off `main`).

This document tracks concrete production-readiness fixes found by reading the
actual source, scripts, tests, and configs. Each entry is verified before push.

## Audit method

- Read every shell script in `scripts/`, all four Rust crates, and the Python
  source + the one integration test.
- Cross-checked README/config claims against what the code actually does.
- Verified each fix with the language-appropriate build/test/lint before push.

## Findings & status

Status legend: ✅ fixed · 🔧 in progress · ⏳ queued

| # | Area | Finding | Status |
|---|------|---------|--------|
| F1 | Rust `conservation-meter` | `detect_burn()` treats *flat* γ as "rising" (`>=`) → false burn alarm on a stable box | ⏳ |
| F2 | Shell `pulse-webhook.sh` | Telegram alert override + `send_telegram` defined **after** `main "$@"` runs → dead code; `TELEGRAM_ENABLED` default contradicts README; bot token hardcoded in repo | ⏳ |
| F3 | Shell `self-test.sh` | Conductor health check is fake-green (`jq '… // true'` always truthy); `headspace`/`gc-pid` point at wrong ports | ⏳ |
| F4 | Shell `gc-intelligent.sh` | Redundant if/else — both branches call `phase_evict` identically | ⏳ |
| F5 | Shell `gc-auto-evict.sh` | `freed_kb` parser strips the unit suffix (1.2G → "1.2" reported as KB) | ⏳ |
| F6 | Py `bottle_integration_test.py` | Conservation assertions structurally cannot fail (fake-green) | ⏳ |
| F7 | Rust `colony/cell` | `--colony`/`--cell-id` arg parse panics (index OOB); `harbor-tcp` health probes a TCP port over HTTP; base-XP doc off by 2× | ⏳ |
| F8 | Docs `README.md` | References missing `ternary-gc-advisor.py`; headspace port ambiguity; honest status markers for stubs | ⏳ |

Verification commands used per fix are recorded in each commit message and the
final report.
