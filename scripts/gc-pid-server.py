#!/usr/bin/env python3
"""
gc-pid-server.py — HTTP daemon wrapping gc-pid-bridge

Listens on port 8785.  Any process can query GC aggression over HTTP
instead of spawning a subprocess per call.

Endpoints:
  GET /api/aggression?used_pct=<float>   → PID aggression from gc-pid-bridge
  GET /api/health                         → service + binary health
  GET /api/setpoint                       → current self-tune setpoint

Integration notes:
  - gc-intelligent.sh sets PID_BRIDGE to /usr/local/bin/gc-pid-bridge
  - pulse-self-tune.sh maintains the self-tune state file
  - All scripts that need aggression can now do curl localhost:8785/api/aggression?used_pct=63
"""

import json
import os
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ── Configuration ────────────────────────────────────────────────────────────
HOST = "127.0.0.1"
PORT = 8785
PID_BINARY = "/usr/local/bin/gc-pid-bridge"
DEFAULT_SETPOINT = 20
MIN_SETPOINT = 10
MAX_SETPOINT = 40

# Self-tune state path (written by pulse-self-tune.sh)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONSTRUCT_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))
STATE_FILE = os.path.join(CONSTRUCT_DIR, "data", "pulse-self-tune-state.json")


# ── Helpers ──────────────────────────────────────────────────────────────────
def read_setpoint() -> int:
    """Read the current setpoint from self-tune state, or return default."""
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
        sp = int(state.get("setpoint", DEFAULT_SETPOINT))
        return max(MIN_SETPOINT, min(MAX_SETPOINT, sp))
    except (FileNotFoundError, json.JSONDecodeError, ValueError, TypeError):
        return DEFAULT_SETPOINT


def call_pid_bridge(used_pct: float) -> dict:
    """Call gc-pid-bridge <used_pct> and return parsed result."""
    pct_str = f"{used_pct:.2f}"
    try:
        result = subprocess.run(
            [PID_BINARY, pct_str],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return {
                "error": f"gc-pid-bridge exited {result.returncode}",
                "stderr": result.stderr.strip(),
            }
        try:
            aggression = float(result.stdout.strip())
            return {"aggression": aggression}
        except ValueError:
            return {"error": f"non-numeric output: {result.stdout.strip()}"}
    except FileNotFoundError:
        return {"error": f"binary not found: {PID_BINARY}"}
    except subprocess.TimeoutExpired:
        return {"error": "gc-pid-bridge timed out after 5s"}
    except Exception as exc:
        return {"error": str(exc)}


def binary_available() -> bool:
    """Check whether the PID binary exists and is executable."""
    return os.path.isfile(PID_BINARY) and os.access(PID_BINARY, os.X_OK)


def json_response(handler, status: int, body: dict):
    """Send a JSON response with CORS headers."""
    payload = json.dumps(body, indent=2) + "\n"
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    handler.wfile.write(payload.encode())


# ── HTTP Handler ─────────────────────────────────────────────────────────────
class GCPIDHandler(BaseHTTPRequestHandler):
    """Lightweight HTTP handler for gc-pid queries."""

    def log_message(self, fmt, *args):
        """Structured JSON logging to stderr."""
        ts = self.log_date_time_string()
        msg = {
            "ts": ts,
            "client": self.client_address[0],
            "method": self.command,
            "path": self.path,
            "proto": self.request_version,
        }
        print(json.dumps(msg), file=sys.stderr, flush=True)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/api/health":
            self._handle_health()
        elif path == "/api/setpoint":
            self._handle_setpoint()
        elif path == "/api/aggression":
            self._handle_aggression(params)
        else:
            json_response(self, 404, {
                "error": "not_found",
                "available": ["/api/aggression", "/api/health", "/api/setpoint"],
            })

    def _handle_health(self):
        """GET /api/health → service + binary status."""
        ok = binary_available()
        json_response(self, 200, {
            "status": "ok",
            "binary": PID_BINARY,
            "binary_available": ok,
            "setpoint": read_setpoint(),
        })

    def _handle_setpoint(self):
        """GET /api/setpoint → current setpoint."""
        sp = read_setpoint()
        json_response(self, 200, {
            "setpoint": sp,
            "file": STATE_FILE,
        })

    def _handle_aggression(self, params):
        """GET /api/aggression?used_pct=<float> → aggression result."""
        # Extract and validate used_pct
        raw = params.get("used_pct", [None])[0]
        if raw is None:
            json_response(self, 400, {
                "error": "missing required query parameter: used_pct",
                "usage": "GET /api/aggression?used_pct=63",
            })
            return
        try:
            used_pct = float(raw)
        except (ValueError, TypeError):
            json_response(self, 400, {
                "error": f"invalid used_pct value: {raw!r}",
                "expected": "a floating-point number",
            })
            return

        # Clamp to reasonable range
        if used_pct < 0 or used_pct > 100:
            json_response(self, 400, {
                "error": f"used_pct out of range [0, 100]: {used_pct}",
            })
            return

        # Call the bridge
        result = call_pid_bridge(used_pct)

        if "error" in result:
            json_response(self, 502, {
                "status": "error",
                "error": result["error"],
                "stderr": result.get("stderr", ""),
                "source": "gc-pid-server",
            })
            return

        setpoint = read_setpoint()
        json_response(self, 200, {
            "aggression": result["aggression"],
            "setpoint": setpoint,
            "used_pct": used_pct,
            "source": "gc-pid-bridge",
        })

    # Suppress default HTTP server stderr noise
    def version_string(self):
        return "gc-pid-server/1.0"

    # Handle graceful shutdown signals for keep-alive clients
    def handle_one_request(self):
        try:
            return super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            pass


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    server = HTTPServer((HOST, PORT), GCPIDHandler)
    print(
        json.dumps({
            "event": "start",
            "host": HOST,
            "port": PORT,
            "binary": PID_BINARY,
            "binary_available": binary_available(),
            "setpoint": read_setpoint(),
            "state_file": STATE_FILE,
        }),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(json.dumps({"event": "shutdown"}), flush=True)
        server.server_close()


if __name__ == "__main__":
    main()
