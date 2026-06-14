#!/usr/bin/env python3
"""
rotation-feed-server.py
Serves rotation-feed.json as JSON via a simple HTTP server with CORS headers.
Runs on port 8796.
"""
import http.server
import json
import os
import socketserver
from pathlib import Path

PORT = 8796
SCRIPT_DIR = Path(__file__).parent.resolve()
FEED_FILE = (SCRIPT_DIR.parent / "data" / "rotation-feed.json").resolve()

# Fallback mock data if file doesn't exist yet
MOCK_DATA = [
    {
        "id": "mock-001",
        "timestamp": "2026-06-14T08:00:00Z",
        "rotation_cycle_error": 1.2,
        "rotation_cognitive": -1.0,
        "rotation_confidence": 0.95,
        "combined_confidence": 0.78,
        "needs_attention": False,
        "entropy_surprise": 0.15,
        "rhythm_anomaly": 0.03,
        "svm_prediction": 1.0,
        "svm_confidence": 0.45,
        "decision_count": 10,
        "rotation_total": 10,
        "disk_pct": 50,
        "ram_free_mb": 21000,
        "load": 1.5,
        "services_active": 35,
    },
    {
        "id": "mock-002",
        "timestamp": "2026-06-14T08:30:00Z",
        "rotation_cycle_error": 1.3,
        "rotation_cognitive": -1.0,
        "rotation_confidence": 0.97,
        "combined_confidence": 0.80,
        "needs_attention": False,
        "entropy_surprise": 0.18,
        "rhythm_anomaly": 0.04,
        "svm_prediction": 1.0,
        "svm_confidence": 0.48,
        "decision_count": 22,
        "rotation_total": 22,
        "disk_pct": 51,
        "ram_free_mb": 20800,
        "load": 2.1,
        "services_active": 36,
    },
    {
        "id": "mock-003",
        "timestamp": "2026-06-14T09:00:00Z",
        "rotation_cycle_error": 1.48,
        "rotation_cognitive": -1.0,
        "rotation_confidence": 1.0,
        "combined_confidence": 0.81,
        "needs_attention": False,
        "entropy_surprise": 0.12,
        "rhythm_anomaly": 0.03,
        "svm_prediction": 1.0,
        "svm_confidence": 0.45,
        "decision_count": 46,
        "rotation_total": 46,
        "disk_pct": 53,
        "ram_free_mb": 20711,
        "load": 1.97,
        "services_active": 37,
    },
]


class CORSRequestHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP handler that adds CORS headers to all responses."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SCRIPT_DIR.parent), **kwargs)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "86400")
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/rotation-feed" or self.path == "/rotation-feed":
            self._serve_rotation_feed()
        elif self.path == "/api/health":
            self._serve_health()
        else:
            super().do_GET()

    def _serve_rotation_feed(self):
        """Load rotation-feed.json (JSONL) and return as JSON array."""
        try:
            if FEED_FILE.exists():
                records = []
                with open(FEED_FILE, "r") as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            try:
                                records.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
                # If file is empty or only has one record, prepend mock data
                if len(records) < 3:
                    records = MOCK_DATA + records
            else:
                records = MOCK_DATA

            response = json.dumps({"records": records, "count": len(records)}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", len(response))
            self.end_headers()
            self.wfile.write(response)
        except Exception as e:
            self._error(500, f"Failed to serve rotation feed: {e}")

    def _serve_health(self):
        """Health check endpoint."""
        response = json.dumps({"status": "ok", "service": "rotation-feed-server"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", len(response))
        self.end_headers()
        self.wfile.write(response)

    def _error(self, code: int, message: str):
        body = json.dumps({"error": message}).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[rotation-feed-server] {args[0]}")


class ReuseAddrTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with ReuseAddrTCPServer(("", PORT), CORSRequestHandler) as httpd:
        print(f"[rotation-feed-server] Serving rotation feed on http://localhost:{PORT}")
        print(f"[rotation-feed-server] Feed file: {FEED_FILE}")
        print(f"[rotation-feed-server] Endpoints:")
        print(f"  GET /api/rotation-feed  → rotation feed JSON")
        print(f"  GET /api/health         → health check")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[rotation-feed-server] Shutting down.")
