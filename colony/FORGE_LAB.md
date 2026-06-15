# 🧪 Forge Lab — Colony Experiment API

**Port**: 8821
**Endpoint**: `http://oracle2:8821`
**Base API**: `colony-api.py` on port 8820 (internal)

## Forge can experiment with the colony via this lab.

### Quick Start

```bash
# Check lab health
curl http://oracle2:8821/forge/health

# See all experiments
curl http://oracle2:8821/forge/experiments

# Colony snapshot
curl http://oracle2:8821/forge/status
```

### Running Experiments

POST JSON to `/forge/run`:

```bash
curl -X POST http://oracle2:8821/forge/run \
  -H "Content-Type: application/json" \
  -d '{"type": "trap-breed", "params": {"xp": 0, "cursor": 10}}'

curl -X POST http://oracle2:8821/forge/run \
  -H "Content-Type: application/json" \
  -d '{"type": "wisdom-crowd", "params": {}}'

curl -X POST http://oracle2:8821/forge/run \
  -H "Content-Type: application/json" \
  -d '{"type": "mass-cull", "params": {"hybrid_count": 20}}'

curl -X POST http://oracle2:8821/forge/run \
  -H "Content-Type: application/json" \
  -d '{"type": "bottle-flood", "params": {"bottle_count": 100}}'
```

### Available Experiments

| Type | Description | Parameters |
|------|-------------|------------|
| `privilege-war` | Birth order XP multipliers | cycles, bonus_eldest, bonus_middle, culler_immunity_youngest_cycles |
| `trap-breed` | Deliberately weak hybrid → culler | xp, cursor, traits |
| `queen-cell` | Dedicated breeder cell | queen_level, breeding_tax_xp |
| `necromancer` | Resurrect best culled cell | min_xp_for_resurrection |
| `natural-disaster` | Kill a fleet service | target_port, kill_duration_secs |
| `wisdom-crowd` | Collect all mottos | headspace_url |
| `mass-cull` | Stress test culler | hybrid_count, xp_range |
| `bottle-flood` | Harbor stress test | bottle_count, batch_size |

### Inspecting Cells

```bash
curl -X POST http://oracle2:8821/forge/inspect \
  -H "Content-Type: application/json" \
  -d '{"cell_id": "synthesizer"}'
```

### Viewing Results

```bash
curl http://oracle2:8821/forge/results?limit=10
```

---

### Architecture

```
Forge (external) ──→ forge-lab:8821 ──→ colony-api:8820 ──→ cell binary
                                        └─→ direct filesystem access
```

- `forge-lab.py` is stateless (except results log, max 50 entries)
- It reads from colony-api for status snapshots
- It writes directly to colony filesystem for experiment setup (trap breeds, mass hybrids)
- Safe to restart between experiments
