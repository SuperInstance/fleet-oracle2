# Sketch Repository Reconciliation

**Date:** 2026-06-15
**Scope:** All sketch-* repositories in the SuperInstance organization
**Task:** Triage stale sketch notes, extract useful content, clean workspace

---

## Summary

**10 sketch repos identified.** None exist as local clones in the workspace. 2 exist as /tmp clones (already pushed to GitHub). 8 are GitHub-only (single README.md each, pushed via sketchbook pattern).

| # | Repo | Local Clone | Content | Action Taken |
|---|------|-------------|---------|-------------|
| 1 | sketch-composite-headspace | `/tmp/` ✅ on GH | Full Node.js prototype (108KB), 51 tests | Extraction note written ✅ |
| 2 | sketch-forgemaster-experiments | `/tmp/` ✅ on GH | 3 experiment result files (33KB total) | Extraction note written ✅ |
| 3 | sketch-gc-pid-feedback-loop | None (GH only) | Single README (235 bytes) | Extraction note written ✅ |
| 4 | sketch-oracle2-construct-readme | None (GH only) | Single README (180 bytes) | Extraction note written ✅ |
| 5 | sketch-workspace-sketchbook-pattern | None (GH only) | Single README (225 bytes) | Extraction note written ✅ |
| 6 | sketch-rotation-adaptation-to-fleet-oracle | None (GH only) | Single README (360 bytes) | Extraction note written ✅ |
| 7 | sketch-rotation-audit-provenance | None (GH only) | Single README (262 bytes) | Extraction note written ✅ |
| 8 | sketch-self-hosting-construct | None (GH only) | Single README (223 bytes) | Extraction note written ✅ |
| 9 | sketch-ternary-kihn-metaphor | None (GH only) | Single README (233 bytes) | Extraction note written ✅ |
| 10 | sketch-fleet-oracle-construct | None (GH only) | Single README (193 bytes) | Extraction note written ✅ |

## Workspace State

**No local sketch repos were found in the workspace.** The workspace was already clean of sketch-* directories. The two substantial sketches (composite-headspace, forgemaster-experiments) had local clones in `/tmp/`, both of which are already pushed to GitHub.

## Extractions Created

All 10 extraction notes saved to `construct/docs/sketches/`:

```
construct/docs/sketches/
├── sketch-composite-headspace.md              (1,989 bytes — full prototype summary)
├── sketch-forgemaster-experiments.md           (2,009 bytes — experiment results)
├── sketch-gc-pid-feedback-loop.md             (625 bytes — concept → live implementation)
├── sketch-oracle2-construct-readme.md         (471 bytes — superseded by CONSTRUCT.md)
├── sketch-workspace-sketchbook-pattern.md     (729 bytes — meta-sketch pattern doc)
├── sketch-rotation-adaptation-to-fleet-oracle.md (703 bytes — integration completion marker)
├── sketch-rotation-audit-provenance.md        (553 bytes — action completed)
├── sketch-self-hosting-construct.md           (602 bytes — vision statement, superseded)
├── sketch-ternary-kihn-metaphor.md           (532 bytes — architectural metaphor)
└── sketch-fleet-oracle-construct.md          (490 bytes — initial vision)
```

## Observation: Sketch Lifecycle Pattern

These repos follow the **sketchbook pattern** (documented in `sketch-workspace-sketchbook-pattern`):
1. Agent drafts idea in workspace
2. Sketch is pushed to GitHub as a single-README repo
3. Local copy is cleared

The pattern is **working as designed**. No workspace cleanup needed — the sketches were already offloaded to GitHub correctly.

## Recommended GH Archival

None of these should be deleted from GitHub — they're part of the design intent (sketchbook = permanent public record of ideas). Suggested organization:

| Category | Repos | Recommendation |
|----------|-------|---------------|
| **Substantive prototypes** (full code) | sketch-composite-headspace, sketch-forgemaster-experiments | Keep on GH, mark as `sketch` topic |
| **Architecture vision notes** | sketch-fleet-oracle-construct, sketch-self-hosting-construct, sketch-ternary-kihn-metaphor | Keep on GH, superseded by live construct docs |
| **Action/completion markers** | sketch-rotation-adaptation-to-fleet-oracle, sketch-rotation-audit-provenance | Keep on GH (historical record) |
| **Process meta-notes** | sketch-workspace-sketchbook-pattern | Keep on GH (documents the pattern itself) |
| **Superseded docs** | sketch-oracle2-construct-readme, sketch-gc-pid-feedback-loop | Keep on GH (lineage documentation) |

## Next Steps

1. ✅ Extraction notes written to `construct/docs/sketches/`
2. ✅ No local workspace deletion needed (already clean)
3. ❓ The `/tmp/` clones (sketch-composite-headspace, sketch-forgemaster-experiments) can be deleted — they're safely on GitHub
4. ❓ Optionally add `sketch` GitHub topic to all sketch repos for discoverability
