#!/usr/bin/env python3
"""
conservation-runtime.py — HTTP daemon bridging colony games ↔ superinstance-protocol.
Runs on port 8797.

Endpoints:
  POST /conservation/score    — Score cells, wrap in Bottle, return enriched profile
  POST /conservation/verify   — Verify Σtrits conservation between two bottles
  POST /conservation/pulse    — Emit fleet pulse as Bottle
  GET  /conservation/health   — Runtime status + fleet efficiency metrics
  GET  /                      — HTML dashboard
"""

import http.server
import json
import sys
import os
import time
import uuid
from urllib.parse import urlparse, parse_qs

# Add workspace to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from superinstance_bottle import Bottle, BottleHeader, audit, audit_strict, ConservationError


PORT = int(os.environ.get("CONSERVATION_RUNTIME_PORT", "8794"))
COLONY_DATA = os.environ.get("COLONY_DATA", ".")

# Track pulse history
pulse_history = []
MAX_PULSES = 100


def log(msg: str):
    timestamp = time.strftime("%H:%M:%S", time.gmtime())
    print(f"[{timestamp}] {msg}", file=sys.stderr, flush=True)


class ConservationHandler(http.server.BaseHTTPRequestHandler):
    """HTTP handler for the conservation runtime."""

    def _send_json(self, data: dict, status: int = 200):
        body = json.dumps(data, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length > 0 else b""

    def _read_json(self) -> dict:
        body = self._read_body()
        return json.loads(body.decode("utf-8")) if body else {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            self._serve_dashboard()
        elif path == "/conservation/health":
            self._handle_health()
        else:
            self._send_json({"error": f"Not found: {path}"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/conservation/score":
            self._handle_score()
        elif path == "/conservation/verify":
            self._handle_verify()
        elif path == "/conservation/pulse":
            self._handle_pulse()
        else:
            self._send_json({"error": f"Not found: {path}"}, 404)

    # ─── Health ────────────────────────────────────────────────────────

    def _handle_health(self):
        """GET /conservation/health — runtime status."""
        try:
            from colony_conservation_scorer import compute_fleet_efficiency

            # Try to score cells from ledger if available
            ledger_path = os.path.join(COLONY_DATA, "game-reputation-ledger.json")
            fleet_metrics = {}
            if os.path.exists(ledger_path):
                from colony_conservation_scorer import score_cell_from_ledger
                profiles = score_cell_from_ledger(ledger_path)
                fleet_metrics = compute_fleet_efficiency(profiles)
        except ImportError:
            fleet_metrics = {"skip": "colony_conservation_scorer not available"}

        self._send_json({
            "status": "healthy",
            "service": "conservation-runtime",
            "version": 1,
            "port": PORT,
            "uptime_seconds": int(time.time() - start_time),
            "pulses_emitted": len(pulse_history),
            "fleet": fleet_metrics,
        })

    # ─── Score ─────────────────────────────────────────────────────────

    def _handle_score(self):
        """POST /conservation/score — Score cells and wrap in Bottle.

        Input: {"cells": [{...cell data...}]}
        Output: Bottle JSON with scored profiles as payload
        """
        data = self._read_json()
        cells = data.get("cells", data.get("ledger", []))

        if not cells:
            self._send_json({"error": "No cells or ledger data provided"}, 400)
            return

        try:
            from colony_conservation_scorer import score_cell, compute_fleet_efficiency

            profiles = {}
            for cell in cells:
                if isinstance(cell, str):
                    continue  # skip string IDs, need dict data
                p = score_cell(cell)
                profiles[cell.get("agent_id", cell.get("id", "unknown"))] = p

            # Determine trit charge from fleet efficiency
            efficiency = compute_fleet_efficiency(list(profiles.values()))
            gamma_sign = 1 if efficiency.get("gamma", 0) > 0.5 else -1
            eta_sign = 1 if efficiency.get("eta", 0) > 0.3 else -1
            trits = [gamma_sign, eta_sign, 1 if efficiency.get("C", 0) > 0.8 else 0]

            bottle = Bottle.new(
                src="conservation-runtime",
                tgt="fleet-pulse",
                act="conservation.score",
                trits=trits,
                payload={
                    "profiles": {pid: p.to_dict() for pid, p in profiles.items()},
                    "efficiency": efficiency,
                    "timestamp": time.time(),
                },
                ttl=30,
            )

            response_data = {
                "bottle_id": bottle.id,
                "trits": trits,
                "conservation_sum": bottle.trit_sum(),
                "efficiency": efficiency,
                "n_cells": len(profiles),
                "bottle_json": json.loads(bottle.encode().decode("utf-8")),
            }
            self._send_json(response_data)

        except ImportError as e:
            self._send_json({"error": f"Dependency not available: {e}"}, 500)

    # ─── Verify ────────────────────────────────────────────────────────

    def _handle_verify(self):
        """POST /conservation/verify — Verify Σtrits conservation.

        Input: {"input_bottle": {...}, "output_bottle": {...}}
        Or: raw bottle bytes (single bottle)
        """
        body = self._read_body()
        content_type = self.headers.get("Content-Type", "")

        if "application/octet-stream" in content_type:
            # Single bottle — just validate and return its conservation status
            bottle = Bottle.decode(body)
            bottle.validate()
            self._send_json({
                "bottle_id": bottle.id,
                "valid": True,
                "trit_sum": bottle.trit_sum(),
                "conserved": True,  # single bottle is always "conserved"
                "ttl_ok": True,
            })
            return

        # JSON mode with two bottles
        data = json.loads(body.decode("utf-8")) if body else {}
        in_bottle_data = data.get("input_bottle") or data.get("input")
        out_bottle_data = data.get("output_bottle") or data.get("output")

        if in_bottle_data and out_bottle_data:
            # Both bottles provided
            in_bottle = Bottle.from_dict(in_bottle_data)
            out_bottle = Bottle.from_dict(out_bottle_data)

            try:
                in_bottle.validate()
                out_bottle.validate()
                audit_strict(in_bottle, out_bottle)
                self._send_json({
                    "conserved": True,
                    "input_sum": in_bottle.trit_sum(),
                    "output_sum": out_bottle.trit_sum(),
                })
            except ConservationError as e:
                self._send_json({
                    "conserved": False,
                    "input_sum": in_bottle.trit_sum(),
                    "output_sum": out_bottle.trit_sum(),
                    "error": str(e),
                }, 409)
        else:
            self._send_json({"error": "Provide input_bottle and output_bottle"}, 400)

    # ─── Pulse ─────────────────────────────────────────────────────────

    def _handle_pulse(self):
        """POST /conservation/pulse — Emit fleet efficiency pulse as Bottle."""
        data = self._read_json()
        metrics = data.get("metrics", {})

        try:
            from colony_conservation_scorer import compute_fleet_efficiency

            ledger_path = os.path.join(COLONY_DATA, "game-reputation-ledger.json")
            if os.path.exists(ledger_path):
                from colony_conservation_scorer import score_cell_from_ledger
                profiles = score_cell_from_ledger(ledger_path)
                efficiency = compute_fleet_efficiency(profiles)
            else:
                efficiency = {
                    "n": 0, "gamma": 0, "eta": 0, "C": 0,
                    "delta": 0, "gamma_predicted": 0,
                }
        except ImportError:
            efficiency = {
                "n": metrics.get("n", 0),
                "gamma": metrics.get("gamma", 0),
                "eta": metrics.get("eta", 0),
                "C": metrics.get("gamma", 0) + metrics.get("eta", 0),
                "delta": metrics.get("delta", 0),
            }

        gamma_sign = 1 if efficiency.get("gamma", 0) > 0.3 else -1
        eta_sign = 1 if efficiency.get("eta", 0) > 0.3 else -1
        trits = [gamma_sign, eta_sign]

        bottle = Bottle.new(
            src="conservation-runtime",
            tgt="dash-relay",
            act="fleet.pulse",
            trits=trits,
            payload={
                "efficiency": efficiency,
                "timestamp": time.time(),
                "source": "colony",
            },
            ttl=60,
        )

        pulse_history.append({
            "time": time.time(),
            "bottle_id": bottle.id,
            "trits": trits,
        })
        if len(pulse_history) > MAX_PULSES:
            pulse_history.pop(0)

        self._send_json({
            "pulse_emitted": True,
            "bottle_id": bottle.id,
            "trits": trits,
            "conservation_sum": bottle.trit_sum(),
            "efficiency": efficiency,
        })

    # ─── Dashboard ─────────────────────────────────────────────────────

    def _serve_dashboard(self):
        """GET / — Minimal HTML dashboard."""
        html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Conservation Runtime Dashboard</title>
<style>
body{font-family:system-ui,sans-serif;max-width:900px;margin:2em auto;padding:0 1em}
h1{color:#333}
.status{background:#e8f5e9;padding:1em;border-radius:8px;border:1px solid #c8e6c9}
.metric{display:inline-block;margin:0.5em;padding:0.5em 1em;background:#f5f5f5;border-radius:4px}
.pulse{border-bottom:1px solid #eee;padding:0.5em 0}
pre{background:#f5f5f5;padding:1em;border-radius:4px;overflow-x:auto}
td,th{padding:0.3em 0.8em;text-align:left}
</style>
</head>
<body>
<h1>🔬 Conservation Runtime</h1>
<div class="status" id="health">Loading...</div>
<h2>📊 Fleet Efficiency</h2>
<pre id="metrics">Computing...</pre>
<h2>📡 Recent Pulses</h2>
<div id="pulses">None yet</div>

<script>
async function refresh(){
  const h=await fetch('/conservation/health').then(r=>r.json());
  document.getElementById('health').innerHTML=
    'Status: <strong>'+h.status+'</strong> | '+
    'Uptime: '+h.uptime_seconds+'s | '+
    'Pulses: '+h.pulses_emitted;
  if(h.fleet) document.getElementById('metrics').textContent=JSON.stringify(h.fleet,null,2);
}
refresh(); setInterval(refresh,15000);
</script>
</body>
</html>"""
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ─── Launcher ────────────────────────────────────────────────────────────────
start_time = time.time()


def main():
    server = http.server.HTTPServer(("0.0.0.0", PORT), ConservationHandler)
    log(f"🧪 Conservation runtime listening on port {PORT}")
    log(f"   Endpoints: POST /conservation/score, /conservation/verify,")
    log(f"              POST /conservation/pulse, GET /conservation/health")
    log(f"   Dashboard: http://localhost:{PORT}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down...")
        server.server_close()


if __name__ == "__main__":
    main()
