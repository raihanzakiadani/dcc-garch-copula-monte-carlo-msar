import os, socket, subprocess, threading, time, http.server
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "wait_flaresolverr.sh"


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"msg":"FlareSolverr is ready!"}')
    def log_message(self, *a): pass


def run(port, wait):
    return subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, timeout=60,
                          env={**os.environ, "FLARESOLVERR_URL": f"http://127.0.0.1:{port}/v1", "FLARE_WAIT_SECONDS": str(wait)})


def test_waits_through_connection_refused_until_service_starts():
    port = free_port()
    def late():
        time.sleep(5); s = http.server.HTTPServer(("127.0.0.1", port), H); s.timeout = 30
        for _ in range(10): s.handle_request()
    threading.Thread(target=late, daemon=True).start()
    r = run(port, 30)
    assert r.returncode == 0 and "FlareSolverr ready after" in r.stdout and "ready!" in r.stdout


def test_gives_up_with_warning_but_does_not_fail_the_job():
    r = run(free_port(), 6)
    assert r.returncode == 0 and "::warning::FlareSolverr not reachable after 6s" in r.stdout
