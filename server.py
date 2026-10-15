# -*- coding: utf-8 -*-
# ECS 独立服务端 · Python 3 标准库（无需 pip 安装任何依赖）
# 作用：比分"状态信箱"。手机端 POST /update 推全量状态，vMix 电脑 GET /state 拉取。
#       另外 /record 追加每场成绩到 results.csv，/results 拉历史。

import csv
import io
import json
import os
import time
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

SECRET = "CHANGE_ME_SECRET"   # 同步口令，与 referee.html / sync_score.ps1 保持一致
PORT = 8080

# ---- 状态 ----
STATE = {"data": None, "ts": 0}
STATE_LOCK = threading.Lock()

# ---- 重启请求（手机端/接收端 /restart 触发，主循环据此原地重启） ----
RESTART_REQUESTED = threading.Event()

# ---- 会话追踪（冲突检测） ----
# owner_session_id: 当前主裁判端 session
# owner_last_push:  owner 最后一次 /update 时间戳
# known_sessions:    活跃 session → 最后 push 时间
# 判定：不同 session 在 owner 活跃期内推 → 冲突
SESSION_LOCK = threading.Lock()
owner_session_id = None
owner_last_push = 0.0
known_sessions = {}    # {sessionId: lastPushEpoch}
SESSION_TTL = 60.0       # 60 秒不推 → 视为不活跃
HOLD_CAP_MS = 300_000    # 冻结补算上限 5 分钟：防手机/服务器时钟偏差导致时间暴涨

# ---- 历史成绩 ----
RESULTS_CSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.csv")
RESULTS_LOCK = threading.Lock()
RESULTS_HEADER = ["ended_at", "court", "team_a", "score_a", "team_b", "score_b", "duration_ms", "winner"]

def _ensure_results_file():
    """首次启动或被删后重建 CSV 并写表头"""
    if not os.path.exists(RESULTS_CSV) or os.path.getsize(RESULTS_CSV) == 0:
        with open(RESULTS_CSV, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(RESULTS_HEADER)
_ensure_results_file()

# ---- 比分快照（重启服务时当前比分不丢） ----
STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.json")

def _save_state_snapshot(data, ts):
    tmp = STATE_FILE + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"data": data, "ts": ts}, f, ensure_ascii=False)
        os.replace(tmp, STATE_FILE)      # 原子替换，避免读到写一半的文件
    except Exception as e:
        print("[warn] 比分快照写入失败：%s" % e)

def _load_state_snapshot():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            snap = json.load(f)
        if isinstance(snap, dict) and snap.get("data"):
            return snap
    except Exception:
        pass
    return None


def _hold_watchdog():
    """手机端断连保数据：owner 超过 SESSION_TTL 没推送时，把 running 场地的
    计时结算到"最后一次推送"时刻并冻结为 paused，打 heldAt 标记、落盘。
    接收端/CSV 拉到 paused 后时间即定格；手机恢复推送后整个 payload 被替换，
    heldAt 自然清除，一切继续。"""
    while True:
        time.sleep(5)
        try:
            with SESSION_LOCK:
                owner_gone = owner_session_id is None or time.time() - owner_last_push > SESSION_TTL
            if not owner_gone:
                continue
            with STATE_LOCK:
                data = STATE["data"]
                if not data or data.get("heldAt"):
                    continue
                ts_ms = int(STATE["ts"] * 1000) if STATE["ts"] else int(time.time() * 1000)
                changed = False
                for c in data.get("courts") or []:
                    if isinstance(c, dict) and c.get("status") == "running":
                        adv = min(max(ts_ms - int(c.get("lastTick") or 0), 0), HOLD_CAP_MS)
                        c["elapsedMs"] = int(c.get("elapsedMs") or 0) + adv
                        c["lastTick"] = ts_ms
                        c["status"] = "paused"
                        changed = True
                if changed:
                    data["heldAt"] = int(time.time() * 1000)
                    _save_state_snapshot(data, STATE["ts"])
                    print("[hold] owner 超时，已冻结进行中场地的计时（数据已保留，可从手机端复位恢复）")
        except Exception as e:
            print("[warn] 冻结看门狗异常：%s" % e)


class Handler(BaseHTTPRequestHandler):
    timeout = 10

    def _send(self, code, body=b"", ctype="application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _key_ok(self):
        return ("key=" + SECRET) in self.path

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def do_OPTIONS(self):
        self._send(204)

    # ---------- POST ----------
    def do_POST(self):
        if not self._key_ok():
            self._send(403, b'{"err":"forbidden"}')
            return
        path = self.path.split("?")[0]
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length > 0 else b"{}"
            payload = json.loads(body.decode("utf-8"))
        except Exception as e:
            self._send(400, json.dumps({"err": str(e)}).encode("utf-8"))
            return

        if path.endswith("/update"):
            self._handle_update(payload)
        elif path.endswith("/record"):
            self._handle_record(payload)
        elif path.endswith("/restart"):
            self._handle_restart()
        else:
            self._send(404, b'{"err":"not found"}')

    def _handle_update(self, payload):
        global owner_session_id, owner_last_push
        now = time.time()
        sid = payload.get("sessionId")
        takeover = bool(payload.get("takeover"))

        # 记录会话
        with SESSION_LOCK:
            # 清理过期会话
            stale = [k for k, v in known_sessions.items() if now - v > SESSION_TTL]
            for k in stale:
                del known_sessions[k]

            conflict = False
            conflict_owner = None
            if sid:
                known_sessions[sid] = now
                # 判定 owner：
                # - 没人当过 owner → 来的第一个就是
                # - 当前 owner 过期了 → 新的来的接管
                # - 同一个 sid 继续推 → 保持
                # - takeover=true → 强制接管（用户主动点"接管"按钮）
                # - 另一个 sid 在 CONFLICT_WINDOW 内也推过 → 冲突！
                if takeover:
                    owner_session_id = sid
                    owner_last_push = now
                elif owner_session_id is None or now - owner_last_push > SESSION_TTL:
                    owner_session_id = sid
                    owner_last_push = now
                elif sid == owner_session_id:
                    owner_last_push = now
                else:
                    # 有新的 sid 推，且旧 owner 还活着 → 冲突
                    conflict = True
                    conflict_owner = owner_session_id

        # 更新比分状态（含乱序保护：同 session 且 pushEpoch 明显小于已存 → 丢弃迟到的旧包，
        # 防止网络抖动时旧请求后到覆盖新比分；容差 2 秒，客户端 JS/原生心跳均带 pushEpoch）
        stale = False
        with STATE_LOCK:
            old = STATE["data"]
            if isinstance(old, dict) and old.get("sessionId") and old.get("sessionId") == payload.get("sessionId"):
                old_ep = old.get("pushEpoch")
                new_ep = payload.get("pushEpoch")
                if isinstance(old_ep, int) and isinstance(new_ep, int) and new_ep < old_ep - 2000:
                    stale = True
            if not stale:
                STATE["data"] = payload
                STATE["ts"] = now
        if stale:
            self._json({"ok": True, "stale": True})
            return
        _save_state_snapshot(payload, now)   # 落盘，重启后不丢

        if conflict:
            self._json({"ok": True, "conflict": True, "owner": conflict_owner})
        else:
            self._json({"ok": True})

    def _handle_record(self, payload):
        """追加一场比赛成绩到 results.csv"""
        ended_at = str(payload.get("ended_at") or time.strftime("%Y-%m-%d %H:%M:%S"))
        court = int(payload.get("court") or 0)
        team_a = str(payload.get("teamA") or "")
        score_a = int(payload.get("scoreA") or 0)
        team_b = str(payload.get("teamB") or "")
        score_b = int(payload.get("scoreB") or 0)
        duration_ms = int(payload.get("durationMs") or 0)
        winner = str(payload.get("winner") or "")

        with RESULTS_LOCK:
            _ensure_results_file()
            with open(RESULTS_CSV, "a", newline="", encoding="utf-8-sig") as f:
                w = csv.writer(f)
                w.writerow([ended_at, court, team_a, score_a, team_b, score_b, duration_ms, winner])

        self._json({"ok": True})

    def _handle_restart(self):
        """重启服务端程序：先把响应发出去，再让主循环重新起一个干净的监听"""
        self._json({"ok": True, "msg": "服务端正在重启"})
        server = self.server

        def _later():
            time.sleep(0.3)              # 留时间让响应写入客户端
            RESTART_REQUESTED.set()
            try:
                server.shutdown()        # 让 serve_forever 返回，主循环接着重启
            except Exception:
                pass

        threading.Thread(target=_later, daemon=True).start()

    # ---------- GET ----------
    def do_GET(self):
        if not self._key_ok():
            self._send(403, b'{"err":"forbidden"}')
            return
        path = self.path.split("?")[0]
        if path.endswith("/state"):
            with STATE_LOCK:
                self._json({"data": STATE["data"], "ts": STATE["ts"], "now": time.time()})
        elif path.endswith("/results"):
            self._handle_results()
        elif path.endswith("/restart"):
            self._handle_restart()
        elif path == "/":
            self._send(200, b'{"name":"scoreboard-ecs-server","ok":true}')
        else:
            self._send(404, b'{"err":"not found"}')

    def _handle_results(self):
        """返回 results.csv 全部内容（带 UTF-8 BOM，方便 vMix 直接读）"""
        with RESULTS_LOCK:
            _ensure_results_file()
            try:
                with open(RESULTS_CSV, "r", encoding="utf-8-sig") as f:
                    content = f.read()
            except Exception as e:
                self._json({"err": str(e)}, 500)
                return
        # 加 BOM（如果文件本身已有 utf-8-sig 会自动带上，但保险起见再加一次头）
        if not content.startswith("\ufeff"):
            content = "\ufeff" + content
        self._send(200, content.encode("utf-8"), "text/csv; charset=utf-8")

    def log_message(self, fmt, *args):
        print("[%s] %s" % (time.strftime("%H:%M:%S"), fmt % args))


if __name__ == "__main__":
    snap = _load_state_snapshot()
    if snap:
        with STATE_LOCK:
            STATE["data"] = snap.get("data")
            STATE["ts"] = snap.get("ts") or 0
        print("已从 state.json 恢复上次比分状态")

    threading.Thread(target=_hold_watchdog, daemon=True).start()

    while True:
        server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
        server.daemon_threads = True
        print("比分服务已启动，监听 0.0.0.0:%d" % PORT)
        print("口令：%s" % SECRET)
        print("手机端 referee.html 设置里『云端地址』填：http://<ECS公网IP>:8080")
        print("历史成绩 CSV：%s" % RESULTS_CSV)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")
            server.server_close()
            break
        server.server_close()
        # serve_forever 正常返回：只有收到 /restart 才重启，否则退出
        if not RESTART_REQUESTED.is_set():
            break
        RESTART_REQUESTED.clear()
        print("收到重启指令，正在重启服务…")
        time.sleep(0.5)
