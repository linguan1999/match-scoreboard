# -*- coding: utf-8 -*-
# 阿里云函数计算 FC · Web 函数（Python 3.10，入口 index.handler，纯 WSGI 无第三方依赖）
# 作用：比分"状态信箱"。手机端 POST /update 推全量状态，本地同步脚本 GET /state 拉取。
# 说明：状态只存内存，FC 冷启动会丢——手机端持有真值并每 10 秒心跳重推，丢失后自动恢复。

import json
import time

SECRET = "CHANGE_ME_SECRET"   # 同步口令，与 referee.html / sync_score.ps1 / local_server.ps1 保持一致

STATE = {"data": None, "ts": 0}


def handler(environ, start_response):
    headers = [
        ("Content-Type", "application/json; charset=utf-8"),
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Headers", "*"),
        ("Access-Control-Allow-Methods", "GET,POST,OPTIONS"),
    ]

    method = environ.get("REQUEST_METHOD", "GET")
    path = environ.get("PATH_INFO", "/")
    query = environ.get("QUERY_STRING", "")

    if method == "OPTIONS":
        start_response("204 No Content", headers)
        return [b""]

    if ("key=" + SECRET) not in query:
        start_response("403 Forbidden", headers)
        return [json.dumps({"err": "forbidden"}).encode("utf-8")]

    if method == "POST" and path.endswith("/update"):
        try:
            length = int(environ.get("CONTENT_LENGTH") or 0)
            body = environ["wsgi.input"].read(length) if length > 0 else b"{}"
            STATE["data"] = json.loads(body.decode("utf-8"))
            STATE["ts"] = time.time()
            start_response("200 OK", headers)
            return [b'{"ok":true}']
        except Exception as e:
            start_response("400 Bad Request", headers)
            return [json.dumps({"err": str(e)}).encode("utf-8")]

    if method == "GET" and path.endswith("/state"):
        start_response("200 OK", headers)
        return [json.dumps({"data": STATE["data"], "ts": STATE["ts"], "now": time.time()}).encode("utf-8")]

    start_response("404 Not Found", headers)
    return [b'{"err":"not found"}']
