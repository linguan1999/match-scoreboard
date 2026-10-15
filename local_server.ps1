# local_server.ps1 — 本地模式：在 vMix 电脑上运行，手机经同一 WiFi 直连推送，收到即写 CSV
# 冗余能力：超过 15 秒没收到手机直推（手机断 WiFi 转推云端）时，自动从云端拉取兜底，
#           数据源与云端趋同，避免与 sync_score.ps1 双开时 CSV 打架；计时偏差 >3 秒自动重锚。
# 首次运行建议"以管理员身份运行"（自动注册端口与防火墙规则）；之后普通权限即可
# 用法：powershell -ExecutionPolicy Bypass -File local_server.ps1

# ========== 配置（口令与 referee.html 设置里保持一致） ==========
$Port      = 8080
$CsvPath   = "D:\vmix\score.csv"     # vMix Data Sources 读取的实时比分 CSV
$ResultsPath = "D:\vmix\results.csv" # 历史成绩 CSV（独立文件，vMix 赛后读）
$SECRET    = "CHANGE_ME_SECRET"
$CloudUrl  = "http://YOUR_SERVER_IP:8080"   # 云端兜底地址（直推断供时从这里拉）
# ==============================================================

$CloudStateUrl = "$CloudUrl/state?key=$SECRET"

$STATUS_TEXT = @{ idle = "未开始"; ready = "待启动"; running = "进行中"; paused = "已暂停" }
$CONFLICT_WINDOW = 10    # 10 秒内有别的 session 推过就算冲突
$SESSION_TTL     = 60    # 60 秒不推 → 视为不活跃
$HOLD_CAP_MS     = 300000   # 冻结补算上限 5 分钟：防手机/电脑时钟偏差导致时间暴涨
$script:held     = $false   # 本次断连是否已冻结过（收到新推送后复位）

# ---- 本机计时 ----
$script:timers = @{}

# ts 自适应：云端 server.py 是秒，本地推送是毫秒
function Convert-TsToMs($v) {
    $d = [double]$v
    if ($d -gt 1e11) { return [long]$d }
    return [long]($d * 1000)
}

function Update-Timers {
    if ($null -eq $script:lastData) { return }
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    # 计时锚点：用数据的产生时刻（云端兜底数据较旧时保持时间连续）
    $anchor = $script:recvMs
    if ($anchor -le 0 -or $now -lt $anchor -or $now - $anchor -gt 60000) { $anchor = $now }
    $idx = 0
    foreach ($c in $script:lastData.courts) {
        $t = $script:timers[$idx]
        if ($null -eq $t) {
            $t = @{ status = "idle"; baseMs = [long]0; runStartMs = $null }
            $script:timers[$idx] = $t
        }
        $newStatus = [string]$c.status
        if ($newStatus -eq "running") {
            if ($t.status -ne "running") {
                # 启动/继续命令：以推送的累计值为底，本机时钟起走
                $t.baseMs = [long]$c.elapsedMs
                $t.runStartMs = $anchor
            } elseif ($null -ne $t.runStartMs) {
                # 软校正：本机推算值与手机权威值偏差 >3 秒 → 重锚（自愈断续分叉/暂停事件丢失）
                $localEst = [long]$t.baseMs + ($now - [long]$t.runStartMs)
                if ([math]::Abs($localEst - [long]$c.elapsedMs) -gt 3000) {
                    $t.baseMs = [long]$c.elapsedMs
                    $t.runStartMs = $anchor
                }
            }
        } else {
            # 暂停/结束/新建：定格为推送的累计值
            $t.baseMs = [long]$c.elapsedMs
            $t.runStartMs = $null
        }
        $t.status = $newStatus
        $idx++
    }
}

function Get-Elapsed([int]$i, [long]$fallback) {
    $t = $script:timers[$i]
    if ($null -eq $t) { return $fallback }
    if ($t.status -eq "running" -and $null -ne $t.runStartMs) {
        return [long]$t.baseMs + ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - [long]$t.runStartMs)
    }
    return [long]$t.baseMs
}

function Format-Time([long]$ms) {
    $s = [math]::Floor($ms / 1000)
    "{0:00}:{1:00}" -f [math]::Floor($s / 60), ($s % 60)
}

function Csv-Cell([string]$v) {
    if ($v -match '[",\r\n]') { '"' + ($v -replace '"', '""') + '"' } else { $v }
}

# ---- CSV 写文件 ----
function Write-Csv {
    if ($null -eq $script:lastData) { return }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("场地,A队伍,A队得分,B队伍,B队得分,比赛时间,状态")
    $idx = 0
    foreach ($c in $script:lastData.courts) {
        $elapsed = Get-Elapsed $idx ([long]$c.elapsedMs)
        $idx++
        $statusText = $STATUS_TEXT[[string]$c.status]
        if (-not $statusText) { $statusText = [string]$c.status }
        $scoreA = ""; $scoreB = ""
        if ($c.status -ne "idle") { $scoreA = [string]$c.scoreA; $scoreB = [string]$c.scoreB }
        $cells = @("场地$idx", [string]$c.teamA, $scoreA, [string]$c.teamB, $scoreB, (Format-Time $elapsed), $statusText)
        $lines.Add((($cells | ForEach-Object { Csv-Cell $_ }) -join ","))
    }
    try {
        [System.IO.File]::WriteAllText($CsvPath, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        Write-Host "CSV 写入失败：$($_.Exception.Message)" -ForegroundColor Red
    }
}

function Ensure-ResultsFile {
    if (-not (Test-Path $ResultsPath)) {
        [System.IO.File]::WriteAllText(
            $ResultsPath,
            "ended_at,court,team_a,score_a,team_b,score_b,duration_ms,winner`r`n",
            (New-Object System.Text.UTF8Encoding($true))
        )
    } elseif ((Get-Item $ResultsPath).Length -eq 0) {
        [System.IO.File]::WriteAllText(
            $ResultsPath,
            "ended_at,court,team_a,score_a,team_b,score_b,duration_ms,winner`r`n",
            (New-Object System.Text.UTF8Encoding($true))
        )
    }
}

function Append-ResultsRow($match) {
    Ensure-ResultsFile
    $row = "{0},{1},{2},{3},{4},{5},{6},{7}`r`n" -f (
        [string]$match.endedAt,
        [int]$match.court,
        (Csv-Cell ([string]$match.teamA)),
        [int]$match.scoreA,
        (Csv-Cell ([string]$match.teamB)),
        [int]$match.scoreB,
        [int]$match.durationMs,
        [string]$match.winner
    )
    # 追加时带 BOM 会导致中间行有 BOM —— 所以 append 直接 UTF-8 无 BOM，
    # 第一行写表头时已经带 BOM 了，整个文件仍可正常被 Excel/vMix 识别
    [System.IO.File]::AppendAllText($ResultsPath, $row, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-ResultsCsv {
    Ensure-ResultsFile
    $content = [System.IO.File]::ReadAllText($ResultsPath, [System.Text.Encoding]::UTF8)
    if (-not $content.StartsWith([char]0xFEFF)) {
        $content = [char]0xFEFF + $content
    }
    return $content
}

# ---- 会话追踪（冲突检测） ----
$script:ownerSession   = $null
$script:ownerLastPush  = [double]0
$script:knownSessions  = @{}   # {sessionId: unixEpoch}

function Check-Conflict([string]$sid, [bool]$takeover) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # 清理过期
    $expire = $script:knownSessions.Keys | Where-Object { ($now - [double]$script:knownSessions[$_]) -gt $SESSION_TTL }
    foreach ($k in $expire) { $script:knownSessions.Remove($k) }

    $script:knownSessions[$sid] = $now

    if ($takeover) {
        # 强制接管
        $script:ownerSession  = $sid
        $script:ownerLastPush = $now
        return $null
    } elseif ($null -eq $script:ownerSession -or ($now - $script:ownerLastPush) -gt $SESSION_TTL) {
        # 没人或过期 → 新的接管
        $script:ownerSession  = $sid
        $script:ownerLastPush = $now
        return $null
    } elseif ($sid -eq $script:ownerSession) {
        # 同一个继续推
        $script:ownerLastPush = $now
        return $null
    } else {
        # 不同 session 且 owner 还活着 → 冲突
        return $script:ownerSession
    }
}

# ---- 断连保数据：owner 超时未推送 → 冻结 running 场地 ----
# 时间结算到"最后一次推送"时刻并改为已暂停，本机计时器同步定格，CSV 不再走表。
# 收到新推送后整个 lastData 被替换、$script:held 复位，一切继续。
function Test-HoldOwner {
    if ($null -eq $script:lastData -or $script:held) { return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($null -ne $script:ownerSession -and ($now - $script:ownerLastPush) -le $SESSION_TTL) { return }
    $changed = $false
    foreach ($c in $script:lastData.courts) {
        if ($c.status -eq "running") {
            $adv = [long]$script:recvMs - [long]$c.lastTick
            if ($adv -lt 0) { $adv = [long]0 }
            if ($adv -gt $HOLD_CAP_MS) { $adv = [long]$HOLD_CAP_MS }
            $c.elapsedMs = [long]$c.elapsedMs + $adv
            $c.lastTick  = [long]$script:recvMs
            $c.status    = "paused"
            $changed = $true
        }
    }
    if ($changed) {
        $script:held = $true
        Update-Timers   # 本机计时器按冻结后的状态定格
        Write-Host "owner 超时，已冻结进行中场地的计时（数据保留，可从手机端复位恢复）" -ForegroundColor Yellow
    }
}

# ---- 云端兜底自愈：直推断供（手机转走云端）时从云端拉取，保证 CSV 数据不僵死 ----
# 采纳云端数据时同步刷新 owner 会话与冻结标记，避免 Test-HoldOwner 误冻结。
function Test-CloudFallback {
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    if ($now - $script:lastPushMs -lt 15000) { return }        # 直推还活着，不需要兜底
    if ($now - $script:lastCloudTryMs -lt 2000) { return }     # 限频：每 2 秒试一次
    $script:lastCloudTryMs = $now
    try {
        $resp = Invoke-RestMethod -Uri $CloudStateUrl -TimeoutSec 3
        if ($null -ne $resp.data -and $null -ne $resp.data.courts) {
            $cloudTs = Convert-TsToMs $resp.ts
            # 云端比本地新 3 秒以上、且云端数据本身是近 2 分钟内的（防止捡到陈旧场次）
            if ($cloudTs - $script:recvMs -gt 3000 -and $cloudTs -gt ($now - 120000)) {
                $script:lastData = $resp.data
                $script:recvMs = $cloudTs
                $script:held = $false
                # 同步 owner 会话：云端数据就是手机推的，视为其延续，避免 60 秒后被误冻结
                $newSid = [string]$resp.data.sessionId
                if ($newSid) {
                    $script:ownerSession = $newSid
                    $script:ownerLastPush = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                }
                Update-Timers
                Write-Host "直推断供，已从云端兜底拉取最新比分（恢复直推后自动切回）" -ForegroundColor DarkCyan
            }
        }
    } catch {
        # 云端也不可达：保留本地推算/冻结状态，等待直推恢复
    }
}

function Send-Json($ctx, [int]$code, [string]$json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $resp = $ctx.Response
    $resp.StatusCode = $code
    $resp.ContentType = "application/json; charset=utf-8"
    $resp.Headers.Add("Access-Control-Allow-Origin", "*")
    $resp.Headers.Add("Access-Control-Allow-Headers", "*")
    $resp.Headers.Add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Send-Text($ctx, [int]$code, [string]$content, [string]$ctype) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $resp = $ctx.Response
    $resp.StatusCode = $code
    $resp.ContentType = $ctype
    $resp.Headers.Add("Access-Control-Allow-Origin", "*")
    $resp.Headers.Add("Access-Control-Allow-Headers", "*")
    $resp.Headers.Add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

# ---- 首次运行：注册端口与防火墙（需管理员） ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    netsh http add urlacl url="http://+:$Port/" user=Everyone 2>$null | Out-Null
    if (-not (Get-NetFirewallRule -DisplayName "ScoreServer-$Port" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "ScoreServer-$Port" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
    }
}

Ensure-ResultsFile

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try {
    $listener.Start()
} catch {
    Write-Host "端口 $Port 监听失败（权限不足）。请右键 PowerShell → 以管理员身份运行本脚本一次，之后即可正常使用。" -ForegroundColor Red
    exit 1
}

# 显示本机局域网 IP
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
       Select-Object -ExpandProperty IPAddress
Write-Host "本地计分服务已启动，端口 $Port" -ForegroundColor Green
Write-Host "手机端 ⚙ 设置里的『本地服务器地址』填以下任一地址：" -ForegroundColor Green
foreach ($ip in $ips) { Write-Host "  http://${ip}:$Port" -ForegroundColor Cyan }
Write-Host "实时 CSV：$CsvPath" -ForegroundColor Green
Write-Host "历史成绩：$ResultsPath" -ForegroundColor Green
Write-Host "（按 Ctrl+C 停止）" -ForegroundColor Green

$script:lastData = $null
$script:recvMs   = [long]0
$script:lastPushMs      = [long]0   # 最后一次收到手机直推的时刻（驱动云端兜底）
$script:lastCloudTryMs  = [long]0   # 上次尝试云端兜底的时刻（限频）
$async = $listener.BeginGetContext($null, $null)

while ($listener.IsListening) {
    while (-not $async.AsyncWaitHandle.WaitOne(1000)) {
        Test-CloudFallback
        Test-HoldOwner
        Write-Csv
    }
    try {
        $ctx = $listener.EndGetContext($async)
    } catch { break }
    $async = $listener.BeginGetContext($null, $null)

    try {
        $req = $ctx.Request
        $path = $req.Url.LocalPath
        $keyOk = $req.Url.Query -match ("key=" + [regex]::Escape($SECRET))

        if ($req.HttpMethod -eq "OPTIONS") {
            Send-Json $ctx 200 "{}"
        } elseif (-not $keyOk) {
            Send-Json $ctx 403 '{"err":"forbidden"}'
        } elseif ($req.HttpMethod -eq "POST" -and $path -eq "/update") {
            $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
            $payload = $body | ConvertFrom-Json

            # ---- 乱序保护：同一 session 且 pushEpoch 明显小于已存 → 丢弃迟到的旧包 ----
            $sid = [string]$payload.sessionId
            $isStale = $false
            if ($sid -and $null -ne $script:lastData) {
                $oldEp = $script:lastData.pushEpoch
                $newEp = $payload.pushEpoch
                if ($null -ne $oldEp -and $null -ne $newEp -and
                    [string]$script:lastData.sessionId -eq $sid -and
                    [long]$newEp -lt ([long]$oldEp - 2000)) {
                    $isStale = $true
                }
            }

            if ($isStale) {
                # 旧包直接丢弃，仍返回 ok（客户端无需感知，新的心跳会覆盖回来）
                Send-Json $ctx 200 '{"ok":true,"stale":true}'
            } else {
                $script:lastData = $payload
                $script:held = $false   # 新推送到达，解除冻结标记
                $script:recvMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
                $script:lastPushMs = $script:recvMs
                Update-Timers

                # 会话冲突检测
                $takeover = [bool]$payload.takeover
                $conflictOwner = $null
                if ($sid) {
                    $conflictOwner = Check-Conflict $sid $takeover
                }

                if ($conflictOwner) {
                    Send-Json $ctx 200 ('{"ok":true,"conflict":true,"owner":"' + $conflictOwner + '"}')
                } else {
                    Send-Json $ctx 200 '{"ok":true}'
                }
                Write-Csv
            }
        } elseif ($req.HttpMethod -eq "POST" -and $path -eq "/record") {
            $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
            $match = $body | ConvertFrom-Json
            Append-ResultsRow $match
            Send-Json $ctx 200 '{"ok":true}'
        } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/state") {
            $json = if ($script:lastData) { @{ data = $script:lastData; ts = $script:recvMs; now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() } | ConvertTo-Json -Depth 5 -Compress } else { '{"data":null}' }
            Send-Json $ctx 200 $json
        } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/results") {
            $csv = Read-ResultsCsv
            Send-Text $ctx 200 $csv "text/csv; charset=utf-8"
        } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/") {
            Send-Json $ctx 200 '{"name":"scoreboard-local-server","ok":true}'
        } else {
            Send-Json $ctx 404 '{"err":"not found"}'
        }
    } catch {
        Write-Host "请求处理出错：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$listener.Stop()
