# PyPI Publish Fix — superinstance Python SDK

**Status:** Ready, blocked on PyPI API token  
**Source:** `plato-portal/superinstance/` (v0.1.1)  
**Gap:** pyproject.toml exists, SDK is mature, but never published to PyPI  

## What's Ready

- `pyproject.toml` — All metadata correct (name, version, license, classifiers, deps)
- `hatchling` build backend — cargo-adjacent, minimal configuration
- 8 modules: `agent.py`, `fleet.py`, `memory.py`, `exceptions.py`, `agent_cache.py`, `__init__.py`, plus artifacts `prompt.txt`, `roundtable-prompt.txt`
- Line count: ~400 lines across all modules

## What's Missing

1. **PyPI API token** — `pypi-AgEIcHlwaS5vcmc...` in CI or local
2. **GitHub release workflow** — no `.github/workflows/publish.yml` (but plato-portal doesn't have .github dir at all)
3. **SDK is in plato-portal repo** — wrong home. It should be in `SuperInstance/superinstance` (the meta-repo) or its own repo

## The Fix (ready to apply when token arrives)

```bash
# One-time:
# pypi token in CI secret or local ~/.pypirc

# Build:
cd plato-portal
pip install build
python -m build

# Publish:
pip install twine
twine upload dist/superinstance-0.1.1*

# Verify:
pip install superinstance
python -c "import superinstance; print(superinstance.__version__)"
```

## Proposed Repo Move

The SDK lives in `plato-portal/superinstance/` but its pyproject.toml says `Homepage = "https://github.com/SuperInstance/superinstance"`. It should live at:

```
github.com/SuperInstance/superinstance-python
```

Reason: `superinstance` meta-repo has 1,200+ repos in its README — not an SDK home. A dedicated Python repo gets:
- PyPI via GitHub Actions on tag
- CI per PR
- Issue tracker for SDK bugs
- Clean `pip install` workflow

**Move plan:**
1. `git subtree` or `git filter-branch` to extract `superinstance/` from plato-portal
2. Push to `SuperInstance/superinstance-python`
3. Add GitHub Actions publish workflow (trigger: tag push `v*`)
4. Delete from plato-portal (or leave as a shim that says "moved to superinstance-python")
