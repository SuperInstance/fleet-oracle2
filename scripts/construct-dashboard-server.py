#!/usr/bin/env python3
"""Serves fleet-construct-dashboard.html on port 8800."""
import http.server, socketserver, json, os, subprocess, re
from urllib.request import urlopen
from pathlib import Path

PORT = 8800
HERE = Path(__file__).parent.parent  # construct/
HTML = HERE / "fleet-construct-dashboard.html"
CSS  = HERE / "fleet-shell.css"
LOGO = HERE / "assets" / "construct-crab-logo.jpg"

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path == "/dashboard":
            self._serve_html()
        elif self.path.startswith("/api/gc-pid"):
            self._serve_api()
        elif self.path == "/api/stack-health":
            self._serve_api()
        elif self.path == "/fleet-shell.css":
            self._serve_css()
        elif self.path == "/assets/construct-crab-logo.jpg":
            self._serve_logo()
        else:
            super().do_GET()

    def _serve_html(self):
        if HTML.exists():
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            with open(HTML) as f:
                self.wfile.write(f.read().encode())
        else:
            self.send_error(404, "Dashboard not built yet")

    def _serve_css(self):
        if CSS.exists():
            self.send_response(200)
            self.send_header("Content-Type", "text/css")
            self.send_header("Cache-Control", "max-age=3600")
            self.end_headers()
            with open(CSS) as f:
                self.wfile.write(f.read().encode())

    def _serve_logo(self):
        if LOGO.exists():
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "max-age=3600")
            self.end_headers()
            with open(LOGO, "rb") as f:
                self.wfile.write(f.read())

    def _serve_api(self):
        data = {}
        try:
            r = urlopen("http://localhost:8797/health", timeout=3)
            data["harbor"] = json.loads(r.read())
        except: data["harbor"] = {"error":"unreachable"}
        try:
            r = urlopen("http://localhost:8798/api/status", timeout=3)
            data["conservation"] = json.loads(r.read())
        except: data["conservation"] = {"error":"unreachable"}
        try:
            r = urlopen("http://localhost:8799/api/rotation-feed", timeout=3)
            data["rotation"] = json.loads(r.read())
        except: data["rotation"] = {"error":"unreachable"}
        try:
            pct = json.loads(urlopen("http://localhost:8798/api/status", timeout=3).read())
            # Get last gamma_trend value for disk pct approximation
            data["gc"] = {"aggression":"N/A","source":"unknown"}
        except: data["gc"] = {"error":"unreachable"}
        try:
            pct_val = int(self.path.split("?")[1]) if "?" in self.path else 63
            out = subprocess.check_output(["/usr/local/bin/gc-pid-bridge", str(pct_val)], timeout=2)
            data["gc"] = {"aggression": float(out.strip()), "source":"gc-pid-bridge", "disk_pct": pct_val}
        except: data["gc"] = {"aggression":"N/A","source":"bridge-unreachable"}
        data["_ts"] = __import__("datetime").datetime.utcnow().isoformat() + "Z"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data,default=str).encode())

    def log_message(self, *a): pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"[construct-dashboard] http://0.0.0.0:{PORT}")
    httpd.serve_forever()
