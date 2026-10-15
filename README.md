# 飞盘比赛直播计分系统

一套面向飞盘赛事直播的实时计分方案：手机裁判端记分 → 云端/本地服务中转 → vMix 电脑写 CSV → vMix Data Sources 上屏。支持**两个场地同时独立比赛**，全流程断连保数据。

## 系统架构

```
┌─────────────┐  POST /update   ┌──────────────────┐
│ 手机裁判端   │ ──────────────► │ 云端 server.py    │
│ referee.html│  (10s 心跳)     │ 阿里云 ECS :8080  │
│ 或 APK      │ ◄────────────── │ 状态信箱+成绩存档  │
└─────────────┘   GET /state    └────────┬─────────┘
       │ 同一 WiFi 直推                   │ GET /state（兜底/拉取）
       ▼                                  ▼
┌───────────────────────────────────────────────┐
│ vMix 电脑：local_server.ps1 / sync_score.ps1  │
│ 覆写 D:\vmix\score.csv（UTF-8 BOM）           │
└───────────────────────────────────────────────┘
       │ vMix Data Sources（1~2 秒刷新）
       ▼
   直播画面上屏（scorebug.html 比分条亦可作 vMix 浏览器输入）
```

## 文件清单

### 手机裁判端
| 文件 | 说明 |
|---|---|
| [referee.html](referee.html) | 裁判计分器主页。双场地 Tab 切换，建场→开表→加减分→暂停/恢复→结束完整流程；数据存 localStorage，刷新/关页不丢；10 秒心跳推送；冲突时提示接管；启动时自动从服务器恢复进行中的场次。**APK 内所有弹窗必须用页面内自绘弹窗（uiConfirm/uiAlert），禁用原生 alert/confirm** |
| [android-build/](android-build/) | APK 打包目录。运行 `build.ps1` 自动同步最新 referee.html → 重打包 → 签名，输出 `referee.apk`（应用名"裁判计分器"，包名 `com.feipan.referee`，支持 Android 7.0+，允许明文 HTTP）。APK 含前台保活服务：切后台/锁屏后由原生层按本地快照继续心跳推云端 |

### 服务端
| 文件 | 说明 |
|---|---|
| [server.py](server.py) | 云端主服务（Python 3 标准库，无依赖），部署在阿里云 ECS（cn-hangzhou，`http://YOUR_SERVER_IP:8080`），nohup 常驻。职责：状态信箱（`/update` `/state`）、历史成绩（`/record` `/results` → results.csv）、远程重启（`/restart`）。带会话冲突检测、乱序包丢弃、断连冻结看门狗（owner 超 60s 未推送 → 结算 running 场地到最后一推时刻并置 paused）、state.json 快照（重启不丢比分） |
| [ecs_watchdog.sh](ecs_watchdog.sh) | ECS 看门狗，cron 每分钟探活，连续 2 次失败自动重启 server.py |
| [fc_index.py](fc_index.py) | 阿里云函数计算 FC 版（历史备选方案，状态只存内存，已被 ECS 方案取代） |

### vMix 电脑端（二选一运行，严禁双开）
| 文件 | 说明 |
|---|---|
| [local_server.ps1](local_server.ps1) | **优先使用**。本地服务模式：手机经同一 WiFi 直推本机 8080 端口，收到即写 `D:\vmix\score.csv`；手机断 WiFi 超 15 秒时自动切云端拉取兜底，计时偏差 >3 秒自动重锚。首次建议管理员运行（自动注册端口/防火墙） |
| [sync_score.ps1](sync_score.ps1) | 纯云端拉取模式：每秒从 ECS 拉 /state 覆写 CSV。启动时自动检测 local_server.ps1 双开并拒绝启动 |

### 接收/展示端
| 文件 | 说明 |
|---|---|
| [receiver.html](receiver.html) | 比分接收端网页：浏览器实时查看两场地比分/计时，可手动绑 CSV 写出 |
| [ReceiverApp/](ReceiverApp/) | receiver.html 的 C# 桌面壳（`build.ps1` 发布） |
| [scorebug.html](scorebug.html) | vMix 浏览器输入专用比分条：透明背景、右上角悬浮条，拉取实时数据上屏 |
| [scoreboard.html](scoreboard.html) | 早期单机版计分页（本地 CSV 写出方案，现已由接收端取代） |

### 开发辅助
| 文件 | 说明 |
|---|---|
| [_preview_server.py](_preview_server.py) | 临时预览服务：给 scorebug.html 喂模拟比分看效果 |
| [_test_mock_server.py](_test_mock_server.py) | 测试用 mock 服务 |
| [阿里云部署指引.md](阿里云部署指引.md) | ECS 部署步骤 |

## 关键约定

- **同步口令（SECRET）**：`server.py`、`referee.html`、`local_server.ps1`、`sync_score.ps1` 四处必须保持一致；接口鉴权方式为 URL 带 `?key=<SECRET>`
- **CSV 格式**：UTF-8 带 BOM（vMix 读中文不乱码）；`score.csv` 为表头+2 行（每场地一行：场地、A队、A分、B队、B分、时间、状态），只存实时数据；`results.csv` 存历史成绩
- **时间戳自适应**：server.py 的 `ts` 是秒、手机端是毫秒，客户端按 `1e11` 阈值自动判断
- **冻结补算上限 5 分钟**：防手机/服务器时钟偏差导致计时暴涨
- **build.ps1 必须保存为 UTF-8 带 BOM**，否则 PowerShell 按 GBK 误读中文路径；签名密钥用 `android-build\feipan.keystore`（须复制进工作目录再签，保证签名一致可覆盖安装）

## 常用操作

**ECS 服务重启**（手机端设置页有按钮，或手动）：
```bash
curl "http://YOUR_SERVER_IP:8080/restart?key=<SECRET>"
```

**ECS 手动维护**（实例 `YOUR_ECS_INSTANCE_ID`，server.py 在 `/root/`，无 systemd）：
```bash
pkill -f "python3 server.py"; nohup python3 /root/server.py >> /root/server.log 2>&1 &
tail -50 /root/server.log   # 查日志
tail -20 /root/watchdog.log # 查看门狗
```

**改了 referee.html 后重出 APK**：
```powershell
powershell -ExecutionPolicy Bypass -File android-build\build.ps1
```

## 踩坑记录

- 单线程 HTTPServer 会因客户端连接中断卡死主循环（端口在听但不 accept），必须用 `ThreadingHTTPServer + daemon_threads=True`
- Android WebView 默认不弹原生 confirm/alert 且无报错，confirm 直接返回 false → 交互弹窗一律自绘
- build-tools 34.0.0 自带 d8 处理 JDK 21 编译的匿名内部类会 NPE → 原生代码不用匿名类，改包私有具名顶层类
- 手机浏览器 localStorage 可能缓存旧服务器地址，换部署后需在设置页手动更新
- App 划掉后保活服务仍会重启续推（保护直播），要彻底停止请先在 App 内结束/取消场次
