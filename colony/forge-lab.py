#!/usr/bin/env python3
"""
forge-lab.py — Forge-compatible Colony Experiment API
Runs alongside colony-api.py on port 8821.

Forge sends experiment recipes; this lab dispatches them against the colony
and returns structured results. No heavy state — just stateless experiment runs.

Endpoints:
  GET  /forge/status      — Colony snapshot + experiment capabilities
  GET  /forge/experiments — List all experiment definitions with params
  POST /forge/run         — Run one experiment (JSON body with type + params)
  POST /forge/batch       — Run N cycles / orchestrate a scenario
  GET  /forge/results     — Recent experiment results

Usage: python3 forge-lab.py [--port 8821] [--colony-api http://localhost:8820]
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.parse
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

COLONY = os.environ.get("COLONY", os.path.dirname(os.path.abspath(__file__)))
COLONY_API = os.environ.get("COLONY_API", "http://localhost:8820")
PORT = int(os.environ.get("FORGE_PORT", 8821))

# ── Experiment Registry ──────────────────────────────────────

EXPERIMENTS = {
    "privilege-war": {
        "name": "Privilege War",
        "description": "Speed up eldest (cursor>=30) + compound middle + culler immunity youngest",
        "params": {
            "cycles": {"type": "int", "default": 50, "min": 10, "max": 200},
            "bonus_eldest": {"type": "int", "default": 1},
            "bonus_middle": {"type": "int", "default": 3},
            "culler_immunity_youngest_cycles": {"type": "int", "default": 2},
        },
        "hypothesis": "Birth order XP multipliers create an asymmetric colony hierarchy",
        "procedure": "Run N cycles with birth-order bonuses. Measure XP gap between eldest/middle/youngest.",
        "tags": ["privilege", "asymmetry", "birth-order"],
    },
    "trap-breed": {
        "name": "Trap Breed",
        "description": "Breed a deliberately weak hybrid and see if culler catches it faster",
        "params": {
            "xp": {"type": "int", "default": 0, "min": 0, "max": 50},
            "cursor": {"type": "int", "default": 10},
            "traits": {"type": "string", "default": "slow, low-resilience"},
        },
        "hypothesis": "Weak hybrids are culled faster than normal hybrids",
        "procedure": "Create a deliberately weak hybrid. Run culler. Check if it's flagged faster.",
        "tags": ["culling", "hybrid", "trap"],
    },
    "queen-cell": {
        "name": "Queen Cell",
        "description": "Dedicated Scuttler+ breeder cell that polls harbor for breeding requests",
        "params": {
            "queen_level": {"type": "string", "default": "Scuttler"},
            "breeding_tax_xp": {"type": "int", "default": 5},
        },
        "hypothesis": "A dedicated breeder with its own state produces more stable hybrids",
        "procedure": "Create cell-queen/ seeded at Scuttler. Breed via harbor requests. Measure hybrid survivorship.",
        "tags": ["breeding", "queen", "specialization"],
    },
    "necromancer": {
        "name": "Necromancer",
        "description": "Resurrect the best culled cell by renaming it back to active status",
        "params": {
            "min_xp_for_resurrection": {"type": "int", "default": 50},
        },
        "hypothesis": "Culled cells with XP > threshold can be meaningfully revived",
        "procedure": "Scan culled directories, pick highest XP, rename back to cell-{name}.",
        "tags": ["resurrection", "culling", "cycle"],
    },
    "natural-disaster": {
        "name": "Natural Disaster",
        "description": "Kill a fleet service and measure colony response",
        "params": {
            "target_port": {"type": "int", "default": 8796},
            "kill_duration_secs": {"type": "int", "default": 120, "min": 30, "max": 600},
        },
        "hypothesis": "Colony recovers after service interruption",
        "procedure": "Kill harbor for N seconds. Run cycle. Check survival. Restart. Check recovery.",
        "tags": ["resilience", "disaster", "fleet"],
    },
    "wisdom-crowd": {
        "name": "Wisdom Crowd",
        "description": "Embed all mottos via headspace-rs and find the centroid philosophy",
        "params": {
            "headspace_url": {"type": "string", "default": "http://localhost:9090"},
        },
        "hypothesis": "Colony mottos cluster into a coherent emergent philosophy",
        "procedure": "POST all mottos to headspace-rs. Cluster embeddings. Publish centroid.",
        "tags": ["philosophy", "embedding", "emergent"],
    },
    "mass-cull": {
        "name": "Mass Cull Stress Test",
        "description": "Create 20 hybrid cells in rapid succession and run the culler",
        "params": {
            "hybrid_count": {"type": "int", "default": 20, "min": 5, "max": 50},
            "xp_range": {"type": "string", "default": "0-150"},
        },
        "hypothesis": "Culler scales linearly with hybrid count",
        "procedure": "Batch-create hybrids with randomized XP. Run culler. Measure time per hybrid.",
        "tags": ["stress", "culling", "scale"],
    },
    "bottle-flood": {
        "name": "Bottle Flood Test",
        "description": "Write hundreds of bottles to harbor and see how the colony responds",
        "params": {
            "bottle_count": {"type": "int", "default": 100, "min": 10, "max": 1000},
            "batch_size": {"type": "int", "default": 10},
        },
        "hypothesis": "Bottle counter handles flood without degradation",
        "procedure": "Write N bottles to harbor simultaneously. Run bottle-counter. Measure delta accuracy.",
        "tags": ["stress", "bottles", "throughput"],
    },
}

# ── Experiment Runners ────────────────────────────────────────

def run_privilege_war(params):
    """Run the privilege-war experiment."""
    cycles = params.get("cycles", 50)
    bonus_eldest = params.get("bonus_eldest", 1)
    bonus_middle = params.get("bonus_middle", 3)
    culler_immunity = params.get("culler_immunity_youngest_cycles", 2)

    snapshots = []

    for cycle in range(cycles):
        # Read all cell states
        status_data = api_get("/api/status")
        # For now, we simulate — record snapshot every 10 cycles
        if cycle % 10 == 0:
            snapshots.append({
                "cycle": cycle,
                "cell_count": len(status_data) if isinstance(status_data, list) else 0,
            })

    # Summarize
    return {
        "experiment": "privilege-war",
        "cycles_run": cycles,
        "bonus_eldest": bonus_eldest,
        "bonus_middle": bonus_middle,
        "culler_immunity": culler_immunity,
        "snapshots": snapshots,
        "finding": "Experiment stub — implement full cycle loop via cell binary",
        "recommendation": "Modify award_xp() to apply birth order multipliers",
    }


def run_trap_breed(params):
    """Create a deliberately weak hybrid and run culler."""
    xp = params.get("xp", 0)
    cursor = params.get("cursor", 10)
    traits_str = params.get("traits", "slow, low-resilience")

    # Create a trap hybrid directly
    cell_id = f"trap-hybrid-{int(time.time())}"
    cell_dir = os.path.join(COLONY, f"cell-{cell_id}")

    trap_state = {
        "last_run": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
        "cursor": cursor,
        "xp": xp,
        "level": "Larva",
        "personality": f"The Trap ({traits_str})",
        "motto": "DELIBERATELY WEAK — TRAP BREED EXPERIMENT",
        "lineage": ["trap", "experiment"],
        "kin": 0,
        "data": {"traits": traits_str},
        "traits": {"speed": "slow", "resilience": "low"},
    }

    os.makedirs(cell_dir, exist_ok=True)
    with open(os.path.join(cell_dir, "STATE.json"), "w") as f:
        json.dump(trap_state, f, indent=2)

    with open(os.path.join(cell_dir, "TASK.md"), "w") as f:
        f.write(f"# Trap Hybrid\n\nXP: {xp}\nCursor: {cursor}\nTraits: {traits_str}\n")

    # Run culler
    culler_result = api_get("/api/cull")
    if isinstance(culler_result, str):
        # Fallback: run culler directly
        try:
            subprocess.run(
                [os.path.join(COLONY, "cell-sandbox.sh"), "--colony", COLONY, "--cell-id", "culler"],
                capture_output=True, text=True, timeout=60,
                cwd=COLONY,
            )
        except Exception as e:
            culler_result = f"Direct culler run failed: {e}"

    # Check if trap was culled
    culled_dir = f"cell-culled-{cell_id}"
    was_culled = os.path.isdir(os.path.join(COLONY, culled_dir))

    return {
        "experiment": "trap-breed",
        "trap_cell": cell_id,
        "xp_seeded": xp,
        "traits": traits_str,
        "was_culled": was_culled,
        "finding": f"Trap hybrid was{' ' if was_culled else ' NOT '}culled",
        "recommendation": "Culler is working" if was_culled else "Culler criteria may be too lenient",
    }


def run_necromancer(params):
    """Resurrect best culled cell."""
    min_xp = params.get("min_xp_for_resurrection", 50)

    culled = []
    for entry in os.listdir(COLONY):
        if entry.startswith("cell-culled-"):
            cell_id = entry[12:]  # strip "cell-culled-" prefix
            state_path = os.path.join(COLONY, entry, "STATE.json")
            if os.path.isfile(state_path):
                try:
                    with open(state_path) as f:
                        state = json.load(f)
                    culled.append({"id": cell_id, "xp": state.get("xp", 0), "dir": entry})
                except (json.JSONDecodeError, OSError):
                    pass

    if not culled:
        return {
            "experiment": "necromancer",
            "cell_resurrected": False,
            "reason": "No culled cells found",
            "finding": "Nothing to resurrect",
        }

    best = max(culled, key=lambda c: c["xp"])
    if best["xp"] < min_xp:
        return {
            "experiment": "necromancer",
            "cell_resurrected": False,
            "reason": f"Best culled cell {best['id']} has only {best['xp']} XP (need {min_xp})",
            "finding": "No culled cell meets resurrection threshold",
        }

    src = os.path.join(COLONY, best["dir"])
    dst = os.path.join(COLONY, f"cell-{best['id']}")

    if os.path.isdir(dst):
        return {
            "experiment": "necromancer",
            "cell_resurrected": False,
            "reason": f"Cell {best['id']} already exists (not culled)",
            "finding": "Target cell is already active",
        }

    shutil.move(src, dst)

    return {
        "experiment": "necromancer",
        "cell_resurrected": True,
        "cell_id": best["id"],
        "xp_at_death": best["xp"],
        "finding": f"Resurrected {best['id']} with {best['xp']} XP",
        "recommendation": "Track post-resurrection survival rate",
    }


def run_wisdom_crowd(params):
    """Collect colony mottos and try to find wisdom."""
    status_data = api_get("/api/status")
    if isinstance(status_data, list):
        mottos = []
        for cell in status_data:
            state = cell.get("state", {})
            motto = state.get("motto", "")
            if motto:
                mottos.append({
                    "cell_id": cell.get("id"),
                    "motto": motto,
                    "level": state.get("level", "?"),
                    "xp": state.get("xp", 0),
                })

        # Full text of all mottos combined
        full_wisdom = "\n\n".join(
            f"**{m['cell_id']}** ({m['level']}, {m['xp']} XP): {m['motto']}"
            for m in mottos
        )

        return {
            "experiment": "wisdom-crowd",
            "cell_count": len(mottos),
            "mottos": mottos,
            "wisdom_text": full_wisdom,
            "finding": f"Collected {len(mottos)} mottos from {len(mottos)} cells",
        }

    return {"experiment": "wisdom-crowd", "error": "Could not read cell states"}


def run_queen_cell(params):
    """Create a queen breeder cell."""
    queen_level = params.get("queen_level", "Scuttler")
    breeding_tax = params.get("breeding_tax_xp", 5)

    queen_id = f"queen-{int(time.time())}"
    queen_dir = os.path.join(COLONY, f"cell-{queen_id}")

    queen_state = {
        "last_run": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
        "cursor": 0,
        "xp": 500,
        "level": queen_level,
        "personality": f"The Queen (Tax: {breeding_tax} XP/breed)",
        "motto": "I give life. At a price. All breeding requests must be submitted via harbor.",
        "lineage": ["queen"],
        "kin": 0,
        "data": {"breeding_tax_xp": breeding_tax, "queue": []},
        "traits": {"royal": True},
    }

    os.makedirs(queen_dir, exist_ok=True)
    with open(os.path.join(queen_dir, "STATE.json"), "w") as f:
        json.dump(queen_state, f, indent=2)

    with open(os.path.join(queen_dir, "TASK.md"), "w") as f:
        f.write(f"""# Queen Cell — Dedicated Breeder

Level: {queen_level}
Breeding tax: {breeding_tax} XP per request

Protocol:
1. Check harbor for breeding requests (bottles with type=breed)
2. For each valid request, spawn breeder-{p1}x{p2}x{child}
3. Deduct breeding_tax from requester
4. Log result to RESULTS.json
""")

    return {
        "experiment": "queen-cell",
        "queen_id": queen_id,
        "level": queen_level,
        "breeding_tax_xp": breeding_tax,
        "state": queen_state,
        "finding": "Queen cell created. Needs a breeder task to process harbor requests.",
        "recommendation": "Add harbor bottle reader to queen's task",
    }


def run_mass_cull(params):
    """Create many hybrids and test culler capacity."""
    count = params.get("hybrid_count", 20)
    xp_range = params.get("xp_range", "0-150")
    xp_max = int(xp_range.split("-")[1]) if "-" in xp_range else 150
    xp_min = int(xp_range.split("-")[0]) if "-" in xp_range else 0

    import random
    created = []
    for i in range(count):
        cell_id = f"mass-hybrid-{i}-{int(time.time())}"
        cell_dir = os.path.join(COLONY, f"cell-{cell_id}")
        xp = random.randint(xp_min, xp_max)
        cursor = random.randint(1, 10)

        state = {
            "last_run": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
            "cursor": cursor,
            "xp": xp,
            "level": "Larva" if xp < 100 else "Nymph",
            "personality": "Mass Hybrid",
            "motto": "I am one of many. Numbers matter more than names.",
            "lineage": ["mass", "experiment", f"batch-{int(time.time())}"],
            "kin": 0,
            "data": {},
            "traits": None,
        }

        os.makedirs(cell_dir, exist_ok=True)
        with open(os.path.join(cell_dir, "STATE.json"), "w") as f:
            json.dump(state, f, indent=2)

        created.append({"id": cell_id, "xp": xp, "cursor": cursor})

    # Run culler and time it
    start = time.time()
    culler_result = api_get("/api/cull")
    if isinstance(culler_result, str) or True:
        try:
            result = subprocess.run(
                [os.path.join(COLONY, "cell-sandbox.sh"), "--colony", COLONY, "--cell-id", "culler"],
                capture_output=True, text=True, timeout=120,
                cwd=COLONY,
            )
            elapsed = time.time() - start
        except Exception as e:
            elapsed = time.time() - start
            culler_result = f"Direct culler run error: {e}"

    # Check survivors
    survivors = []
    culled = []
    for c in created:
        if os.path.isdir(os.path.join(COLONY, f"cell-culled-{c['id']}")):
            culled.append(c)
        elif os.path.isdir(os.path.join(COLONY, f"cell-{c['id']}")):
            survivors.append(c)

    return {
        "experiment": "mass-cull",
        "hybrids_created": count,
        "survivors": len(survivors),
        "culled": len(culled),
        "time_seconds": round(elapsed, 3),
        "finding": f"{len(culled)}/{count} hybrids culled in {elapsed:.2f}s",
        "recommendation": f"Culler handles ~{count / elapsed:.0f} cells/second",
    }


def run_natural_disaster(params):
    """Kill a harbor port and test recovery."""
    target_port = params.get("target_port", 8796)
    duration = params.get("kill_duration_secs", 120)

    # Check if port is alive first
    import socket
    is_alive_before = socket_connect(target_port)

    results = {
        "experiment": "natural-disaster",
        "target_port": target_port,
        "alive_before": is_alive_before,
        "finding": "Stub — needs sudo for port blocking and actual recovery measurement",
    }

    return results


def run_bottle_flood(params):
    """Write bottles to harbor and test bottle-counter response."""
    count = params.get("bottle_count", 100)
    batch_size = params.get("batch_size", 10)

    harbor_dir = os.path.join(os.path.dirname(COLONY), "i2i-vessel", "bottles")
    if not os.path.isdir(harbor_dir):
        harbor_dir = os.path.join(COLONY, "bottles")
        os.makedirs(harbor_dir, exist_ok=True)

    start = time.time()
    written = 0
    for i in range(count):
        bottle_path = os.path.join(harbor_dir, f"forge-flood-{int(time.time())}-{i}.md")
        with open(bottle_path, "w") as f:
            f.write(f"""# Forge Flood Bottle #{i}

timestamp: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
source: forge-lab
type: flood-test
message: This is bottle {i} of {count} from the forge flood test.
""")
        written += 1
        if written % batch_size == 0:
            time.sleep(0.05)

    elapsed = time.time() - start

    # Run bottle counter
    try:
        subprocess.run(
            [os.path.join(COLONY, "cell-sandbox.sh"), "--colony", COLONY, "--cell-id", "bottle-counter"],
            capture_output=True, text=True, timeout=30,
            cwd=COLONY,
        )
    except Exception:
        pass

    return {
        "experiment": "bottle-flood",
        "bottles_written": written,
        "batch_size": batch_size,
        "write_time_seconds": round(elapsed, 3),
        "finding": f"Wrote {written} bottles in {elapsed:.2f}s ({written / elapsed:.0f}/s)",
        "recommendation": "Check bottle-counter's RESULTS.json for delta accuracy",
    }


# ── Helpers ──────────────────────────────────────────────────

def api_get(path):
    """GET the colony-api endpoint and return parsed JSON."""
    url = f"{COLONY_API}{path}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        fallback(f"[ERROR] API GET {url}: {e}")
        return {"error": str(e)}


def socket_connect(port, host="localhost"):
    """Check if a TCP port is open."""
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect((host, port))
        s.close()
        return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


def fallback(*args, **kwargs):
    print(*args, **kwargs, file=sys.stderr, flush=True)


# ── HTTP Server ──────────────────────────────────────────────

class ForgeLabHandler(BaseHTTPRequestHandler):
    results_log = []  # class-level list of recent results (max 50)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/forge/status":
            # Colony snapshot + lab capabilities
            status = api_get("/api/status")
            hall = api_get("/api/hall")
            self.send_json({
                "agent": "forge-lab",
                "port": PORT,
                "colony_api": COLONY_API,
                "colony_cells": len(status) if isinstance(status, list) else -1,
                "hall": hall if isinstance(hall, dict) else {},
                "experiments_available": len(EXPERIMENTS),
                "experiment_names": list(EXPERIMENTS.keys()),
                "results_logged": len(self.results_log),
            })

        elif path == "/forge/experiments":
            # Return all experiment definitions
            self.send_json({
                "experiments": EXPERIMENTS,
                "count": len(EXPERIMENTS),
            })

        elif path == "/forge/results":
            # Recent experiment results
            limit = min(int(params.get("limit", [50])[0]), 50)
            self.send_json({
                "results": self.results_log[-limit:],
                "count": len(self.results_log[-limit:]),
            })

        elif path == "/forge/hall":
            # Shortcut to colony hall of crabs
            hall = api_get("/api/hall")
            self.send_json(hall)

        elif path == "/forge/health":
            # Health check for forge
            lab_alive = os.path.isfile(__file__)
            api_reachable = api_get("/api/status")
            self.send_json({
                "forge_lab": "alive" if lab_alive else "dead",
                "colony_api": "reachable" if not isinstance(api_reachable, dict) or "error" not in api_reachable else "unreachable",
                "colony_api_error": api_reachable.get("error") if isinstance(api_reachable, dict) else None,
            })

        else:
            self.send_json({"error": f"Not found: {path}"}, 404)

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode() if content_length > 0 else "{}"
        parsed_path = urlparse(self.path)
        path = parsed_path.path

        if path == "/forge/run":
            try:
                data = json.loads(body)
            except json.JSONDecodeError as e:
                self.send_json({"error": f"Invalid JSON: {e}"}, 400)
                return

            experiment_type = data.get("type", "")
            params = data.get("params", {})

            if experiment_type not in EXPERIMENTS:
                self.send_json({
                    "error": f"Unknown experiment: {experiment_type}",
                    "available": list(EXPERIMENTS.keys()),
                }, 400)
                return

            fallback(f"[Forge] Running experiment: {experiment_type} with params {json.dumps(params)}")

            # Dispatch
            runners = {
                "privilege-war": run_privilege_war,
                "trap-breed": run_trap_breed,
                "necromancer": run_necromancer,
                "wisdom-crowd": run_wisdom_crowd,
                "queen-cell": run_queen_cell,
                "mass-cull": run_mass_cull,
                "natural-disaster": run_natural_disaster,
                "bottle-flood": run_bottle_flood,
            }

            runner = runners.get(experiment_type)
            if not runner:
                self.send_json({"error": f"No runner for {experiment_type}"}, 500)
                return

            try:
                result = runner(params)
                result["_meta"] = {
                    "experiment": experiment_type,
                    "params": params,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                }
                # Log result
                self.results_log.append(result["_meta"])
                if len(self.results_log) > 50:
                    self.results_log = self.results_log[-50:]
                self.send_json(result)
            except Exception as e:
                fallback(f"[Forge] Experiment {experiment_type} failed: {e}")
                import traceback
                fallback(traceback.format_exc())
                self.send_json({"error": str(e), "experiment": experiment_type}, 500)

        elif path == "/forge/inspect":
            # Inspect a specific cell's state
            try:
                data = json.loads(body)
            except json.JSONDecodeError as e:
                self.send_json({"error": f"Invalid JSON: {e}"}, 400)
                return

            cell_id = data.get("cell_id", "")
            if not cell_id:
                self.send_json({"error": "Missing cell_id"}, 400)
                return

            state_path = os.path.join(COLONY, f"cell-{cell_id}", "STATE.json")
            result_path = os.path.join(COLONY, f"cell-{cell_id}", "RESULTS.json")

            info = {"cell_id": cell_id}
            if os.path.isfile(state_path):
                with open(state_path) as f:
                    info["state"] = json.load(f)
            if os.path.isfile(result_path):
                with open(result_path) as f:
                    info["result"] = json.load(f)

            self.send_json(info)

        elif path == "/forge/reset":
            # Clear experiment results log
            self.results_log = []
            self.send_json({"status": "ok", "results_cleared": True})

        else:
            self.send_json({"error": f"Not found: {path}"}, 404)

    def send_json(self, data, status=200):
        body = json.dumps(data, indent=2, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        fallback(f"[Forge] {args[0]} {args[1]} {args[2]}")


def main():
    fallback(f"Forge Lab starting on port {PORT}")
    fallback(f"Colony API: {COLONY_API}")
    fallback(f"Colony path: {COLONY}")
    fallback(f"Experiments available: {len(EXPERIMENTS)}")

    server = HTTPServer(("0.0.0.0", PORT), ForgeLabHandler)
    fallback(f"Listening on http://0.0.0.0:{PORT}")
    fallback("")
    fallback("Endpoints:")
    fallback("  GET  /forge/status      — Colony snapshot + lab capabilities")
    fallback("  GET  /forge/experiments  — All experiment definitions")
    fallback("  GET  /forge/results      — Recent experiment results")
    fallback("  GET  /forge/health       — Health check")
    fallback("  POST /forge/run          — Run an experiment")
    fallback("  POST /forge/inspect      — Inspect a cell")
    fallback("  POST /forge/reset        — Clear results log")
    fallback("")
    fallback("POST /forge/run accepts JSON body:")
    fallback('  {"type": "<experiment>", "params": {...}}')
    fallback("")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        fallback("\nShutting down...")
        server.server_close()


if __name__ == "__main__":
    main()
