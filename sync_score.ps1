# sync_score.ps1 — 在 vMix 电脑上运行：每秒从云端拉取比分状态，实时覆写本地 CSV
# 注意：本脚本与 local_server.ps1 二选一运行（两者都写同一个 score.csv，双开会交替覆写）。
#       启动时会自动检测：发现本机已在跑 local_server.ps1 则拒绝启动。
#       local_server.ps1 自带云端兜底自愈，功能已覆盖本脚本，优先用它。
# 用法：右键"使用 PowerShell 运行"；若被策略拦截，用以下命令启动：
#   powershell -ExecutionPolicy Bypass -File sync_score.ps1

# ========== 配置（部署后填写，与 fc_index.py / referee.html 保持一致） ==========
$ApiUrl     = "http://YOUR_SERVER_IP:8080/state?key=CHANGE_ME_SECRET"
$ResultsUrl = "http://YOUR_SERVER_IP:8080/results?key=CHANGE_ME_SECRET"
$LocalProbeUrl = "http://127.0.0.1:8080/?key=CHANGE_ME_SECRET"   # 双开检测用
$CsvPath    = "D:\vmix\score.csv"    # vMix Data Sources 读取的实时比分 CSV
$ResultsCsv = "D:\vmix\results.csv"  # 历史成绩 CSV（赛后用）
# ============================================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- 双开检测：本机已有 local_server.ps1 在跑 → 拒绝启动，防止交替覆写同一 CSV ----
try {
    $probe = Invoke-RestMethod -Uri $LocalProbeUrl -TimeoutSec 2
    if ($probe.name -eq "scoreboard-local-server") {
        Write-Host "检测到本机正在运行 local_server.ps1（自带云端兜底自愈，功能已覆盖本脚本）。" -ForegroundColor Red
        Write-Host "两者同时运行会交替覆写同一个 CSV，导致 vMix 比分/时间闪烁。请二选一。" -ForegroundColor Red
        exit 1
    }
} catch {
    # 本地 8080 没有服务（或被其他程序占用）→ 正常继续
}

$STATUS_TEXT = @{ idle = "未开始"; ready = "待启动"; running = "进行中"; paused = "已暂停" }

function Format-Time([long]$ms) {
    $s = [math]::Floor($ms / 1000)
    "{0:00}:{1:00}" -f [math]::Floor($s / 60), ($s % 60)
}

function Csv-Cell([string]$v) {
    if ($v -match '[",\r\n]') { '"' + ($v -replace '"', '""') + '"' } else { $v }
}

Write-Host "比分同步运行中：$ApiUrl" -ForegroundColor Cyan
Write-Host "CSV 输出：$CsvPath （按 Ctrl+C 停止）" -ForegroundColor Cyan
Write-Host "历史成绩：$ResultsCsv" -ForegroundColor Cyan

$lastData = $null
$recvMs   = [long]0
$failCount = 0
$lastResultsPull = 0   # Unix 秒戳

# ---- 本机计时：只响应命令（状态跳变），时间在本机跑，不跟随每次快照重锚 ----
$timers = @{}   # 每场地：status / baseMs / runStartMs

function Update-Timers {
    if ($null -eq $script:lastData) { return }
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
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
                # 软校正：本机推算值与手机权威值偏差 >3 秒 → 重锚（自愈拉取断续分叉）
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

while ($true) {
    try {
        $resp = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 5
        if ($null -ne $resp.data -and $null -ne $resp.data.courts) {
            $script:lastData = $resp.data
            $script:recvMs   = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            Update-Timers
            $failCount = 0
        }
    } catch {
        $failCount++
        if ($failCount % 10 -eq 1) { Write-Host "拉取失败（自动重试中）：$($_.Exception.Message)" -ForegroundColor Yellow }
    }

    if ($null -ne $lastData) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("场地,A队伍,A队得分,B队伍,B队得分,比赛时间,状态")
        $idx = 0
        foreach ($c in $lastData.courts) {
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
            # UTF-8 带 BOM，保证 vMix 中文不乱码
            [System.IO.File]::WriteAllText($CsvPath, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        } catch {
            Write-Host "CSV 写入失败：$($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # 历史成绩：每 30 秒拉一次（服务器已累积全部记录，直接整体覆盖即可）
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($nowSec - $lastResultsPull -ge 30) {
        try {
            $csvText = Invoke-RestMethod -Uri $ResultsUrl -TimeoutSec 5
            if ($csvText -and $csvText.Length -gt 0) {
                [System.IO.File]::WriteAllText($ResultsCsv, [string]$csvText, (New-Object System.Text.UTF8Encoding($true)))
            }
            $lastResultsPull = $nowSec
        } catch {
            # results 拉取失败静默重试，不影响实时比分
        }
    }

    Start-Sleep -Milliseconds 1000
}
