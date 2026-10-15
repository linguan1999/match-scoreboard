# 一键构建/更新「比分接收端」Windows 桌面应用
# 用法：在 PowerShell 中运行 .\build.ps1
$ErrorActionPreference = "Stop"
$projDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $projDir

# 同步最新的 receiver.html 到工程内（用项目根目录那份为准）
$rootHtml = Join-Path (Split-Path $projDir -Parent) "receiver.html"
if (Test-Path $rootHtml) {
    Copy-Item $rootHtml (Join-Path $projDir "receiver.html") -Force
    Write-Host "已同步 receiver.html"
}

Write-Host "正在编译..."
dotnet publish -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=none `
    -p:PublishTrimmed=false `
    -o "publish"

if ($LASTEXITCODE -ne 0) { throw "编译失败" }

$exe = Join-Path $projDir "publish\比分接收端.exe"
Write-Host "构建完成：$exe"
Write-Host "产物："
Get-ChildItem (Join-Path $projDir "publish") | Select-Object Name, @{N='SizeMB';E={[math]::Round($_.Length/1MB,1)}}
