# Sketch: Composite Headspace

**Status:** Archived on GitHub (`SuperInstance/sketch-composite-headspace`), local clone in /tmp.
**Date:** 2026-06-08 (prototype), README last updated 2026-06-14

## Intent

Cognitive orchestration framework running two parallel reasoning shells (bass/treble) coordinated through t-minus cueing protocol. Prototype for the "Symphony of Shells" / Forgemaster cognitive architecture.

## Key Ideas Extracted

- **Two-shell stereoscopic reasoning**: one shell for slow deep architectural analysis (bass, ~0.01–0.1 Hz, 128K token budget), one for fast pattern matching (treble, ~1–10 Hz, 32K token budget)
- **T-Minus Cueing Protocol**: `t-minus(shell, n)` signals act in n cognitive beats before alignment point P. Coordinates shells with different latency profiles to converge at the same alignment point.
- **Symmetry-Dissonance Loop**: 4-phase analysis — DETECT divergence → ISOLATE dissonance → CORRECT via complementary reasoning → RESOLVE into synthetic insight
- **Cognitive Parallax**: Disparity between two reasoning perspectives creates depth perception (analogous to binocular vision)
- **Frequency Band Model**: Sub-bass (0.001–0.01 Hz, ~3000ms) → Bass (0.01–0.1) → Mid (0.1–1) → Treble (1–10) → Ultrasonic (10–100)

## Preserved Code

Full source tree preserved on GitHub at `SuperInstance/sketch-composite-headspace`:
- `cli.js` — CLI entry point
- `src/coordinator.js` — T-minus dispatcher + CompositeHeadspace class
- `src/shell-agent.js` — ShellAgent with frequency bands, timbres, a-boxes
- `src/symmetry-detector.js` — Symmetry-Dissonance Loop analysis engine
- `src/reasoning-task.js` — ReasoningTask definition + sample problems
- `test/integration.test.js` — 51 integration tests
- `examples/basic-symmetry.js` — Runnable example

## Relevance

This sketch concept was matured into the broader Forgemaster/Symphony of Shells project. The local clone at `/tmp/sketch-composite-headspace/` can be removed after verifying GitHub has latest.
