# _preview_server.py — 临时预览服务：用它给 scorebug.html 喂一份模拟比分，方便看效果
# 端口 8099，同源提供 /scorebug.html 和 /state
import http.server
import json
import os
import random
import threading
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
PORT = 8099

MOCK = {
    "data": {
        "courts": [
            {"status": "running", "teamA": "蓝鲸队", "teamB": "飞盘先锋",
             "scoreA": 13, "scoreB": 9, "elapsedMs": 754000, "lastTick": 0},
            {"status": "idle", "teamA": "", "teamB": "",
             "scoreA": 0, "scoreB": 0, "elapsedMs": 0, "lastTick": 0},
        ],
        "sessionId": "preview",
    },
    "ts": time.time(),
}

LOCK = threading.Lock()


def bump():
    """每 3 秒随机给一方加 1 分，用来观察得分变化动效"""
    while True:
        time.sleep(3)
        with LOCK:
            c = MOCK["data"]["courts"][0]
            if random.random() < 0.5:
                c["scoreA"] += 1
            else:
                c["scoreB"] += 1
            c["elapsedMs"] += 3000
            MOCK["ts"] = time.time()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def do_GET(self):
        if self.path.split("?")[0] == "/state":
            with LOCK:
                body = json.dumps(MOCK, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, *a):
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


threading.Thread(target=bump, daemon=True).start()
print(f"预览服务已启动: http://127.0.0.1:{PORT}/scorebug.html?court=1")
Server(("127.0.0.1", PORT), Handler).serve_forever()
