# -*- coding: utf-8 -*-
# _test_mock_server.py — 冗余方案验证用临时 mock（验证完删除）
# 用法：python _test_mock_server.py <port> <mode>
#   mode=always  /state 永远成功（供 local_server 兜底自愈测试）
#   mode=fail8   /state 前 8 次成功、第 9~25 次失败、之后恢复（供 scorebug 容灾/告警测试）
#   mode=name    GET / 返回 {"name":"scoreboard-local-server"}（供 sync_score 双开检测测试）
import json
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

PORT = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else "always"
ROOT = os.path.dirname(os.path.abspath(__file__))

state = {"req": 0}
LOCK = threading.Lock()

COURT_RUN = {"status": "running", "teamA": "Mock Team A", "teamB": "Mock Team B",
             "scoreA": 13, "scoreB": 9, "elapsedMs": 754000, "lastTick": 0}
COURT_IDLE = {"status": "idle", "teamA": "", "teamB": "", "scoreA": 0, "scoreB": 0, "elapsedMs": 0, "lastTick": 0}


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204, b"")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        print("[%d] POST %s" % (PORT, self.path.split("?")[0]), flush=True)
        self._send(200, b'{"ok":true}')

    def do_GET(self):
        path = self.path.split("?")[0]
        with LOCK:
            state["req"] += 1
            n = state["req"]

        if path == "/state":
            ok = True
            if MODE == "fail8":
                ok = n <= 8 or n > 25   # 9~25 次失败模拟断供，之后恢复
            if not ok:
                print("[%d] /state #%d -> 500" % (PORT, n), flush=True)
                self._send(500, b'{"err":"mock fail"}')
                return
            print("[%d] /state #%d -> ok" % (PORT, n), flush=True)
            body = json.dumps({
                "data": {"courts": [dict(COURT_RUN), dict(COURT_IDLE)], "sessionId": "mock-sid"},
                "ts": time.time(), "now": time.time(),
            }).encode("utf-8")
            self._send(200, body)
        elif path == "/":
            if MODE == "name":
                self._send(200, b'{"name":"scoreboard-local-server","ok":true}')
            else:
                self._send(200, b'{"name":"mock","ok":true}')
        elif path.endswith(".html"):
            try:
                with open(os.path.join(ROOT, path.lstrip("/")), "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except Exception:
                self._send(404, b"not found", "text/plain")
        else:
            self._send(404, b"not found")

    def log_message(self, *a):
        pass


print("mock on %d mode=%s" % (PORT, MODE), flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
