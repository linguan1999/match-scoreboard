#!/bin/bash
# ecs_watchdog.sh — server.py 看门狗（部署在阿里云 ECS 上，配合 cron 每分钟执行）
# 逻辑：curl 本机 /state 探活，连续 2 次失败 → 杀掉 server.py 并用 nohup 重启。
#       server.py 自带 state.json 快照，重启后当前比分与计时自动恢复，不丢数据。
#
# ========== 部署（一次性） ==========
#   1) 上传本脚本到 ECS：/root/ecs_watchdog.sh，然后 chmod +x /root/ecs_watchdog.sh
#   2) crontab -e 添加一行：
#        * * * * * /bin/bash /root/ecs_watchdog.sh >> /root/watchdog.log 2>&1
#   3) 手动跑一次确认：/bin/bash /root/ecs_watchdog.sh && cat /root/watchdog.log
# ====================================

PORT=8080
SECRET="CHANGE_ME_SECRET"
SERVER_DIR="/root"                 # server.py 所在目录
SERVER_LOG="/root/server.log"      # server.py 的 nohup 输出
FAIL_FILE="/tmp/.score_watchdog_fail"   # 失败计数落盘（cron 每次是新进程）
LOCK_DIR="/tmp/.score_watchdog.lock"

# ---- 防并发（上一轮还没跑完时直接退出） ----
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# ---- 探活 ----
if curl -s -m 5 "http://127.0.0.1:${PORT}/?key=${SECRET}" | grep -q '"ok"'; then
    rm -f "$FAIL_FILE"
    exit 0
fi

# ---- 失败计数 ----
FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
FAILS=$((FAILS + 1))
echo "$FAILS" > "$FAIL_FILE"

if [ "$FAILS" -lt 2 ]; then
    echo "[$(date '+%F %T')] 探活失败第 ${FAILS} 次，下轮再确认"
    exit 0
fi

# ---- 连续 2 次失败 → 重启 ----
echo "[$(date '+%F %T')] 探活连续 ${FAILS} 次失败，重启 server.py..."
pkill -f "python3 ${SERVER_DIR}/server.py" 2>/dev/null
pkill -f "python3 server.py" 2>/dev/null
sleep 1
cd "$SERVER_DIR" || exit 1
nohup python3 "$SERVER_DIR/server.py" >> "$SERVER_LOG" 2>&1 &
sleep 2

if curl -s -m 5 "http://127.0.0.1:${PORT}/?key=${SECRET}" | grep -q '"ok"'; then
    echo "[$(date '+%F %T')] 重启成功，比分状态已从 state.json 恢复"
else
    echo "[$(date '+%F %T')] 重启后探活仍失败，请手动检查：tail -50 $SERVER_LOG"
fi
rm -f "$FAIL_FILE"
