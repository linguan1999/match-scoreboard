$ErrorActionPreference = "Stop"
$PROJ  = "c:\Users\七月光影直播工作站\Documents\trae_projects\feipan\android-build"
$SDK   = "$PROJ\sdk"
$BT    = "$SDK\build-tools\34.0.0"
$WORK  = "C:\feipan-apk-build"
$APP   = "$WORK\app"
$OUT   = "$APP\out"
$env:JAVA_HOME = "C:\Program Files\Android\openjdk\jdk-21.0.8"
$JAVAC = "$env:JAVA_HOME\bin\javac.exe"
$KEYTOOL = "$env:JAVA_HOME\bin\keytool.exe"

# 0. stage into ASCII-only workspace (aapt2 cannot handle non-ASCII paths)
Write-Host "== stage workspace =="
if (Test-Path $WORK) { Remove-Item $WORK -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$OUT\classes", "$APP\assets" | Out-Null
Copy-Item "$PROJ\app\src"     "$APP\src"     -Recurse
Copy-Item "$PROJ\app\res"     "$APP\res"     -Recurse
Copy-Item "$PROJ\app\AndroidManifest.xml" "$APP\"
Copy-Item "c:\Users\七月光影直播工作站\Documents\trae_projects\feipan\referee.html" "$APP\assets\referee.html" -Force
# 复用持久化签名密钥，保证历次 APK 签名一致（可直接覆盖安装）
if (Test-Path "$PROJ\feipan.keystore") { Copy-Item "$PROJ\feipan.keystore" "$WORK\feipan.keystore" -Force }

# SDK also lives under a Chinese path -> make a junction in ASCII space
$SDKLINK = "C:\feipan-apk-build\sdk"
if (-not (Test-Path $SDKLINK)) {
    cmd /c mklink /J "C:\feipan-apk-build\sdk" "$SDK" | Out-Null
}
$BTL = "$SDKLINK\build-tools\34.0.0"

# 1. aapt2 compile
Write-Host "== aapt2 compile =="
& "$BTL\aapt2.exe" compile --dir "$APP\res" -o "$OUT\res.zip"
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed" }

# 2. aapt2 link
Write-Host "== aapt2 link =="
& "$BTL\aapt2.exe" link -o "$OUT\app-unsigned.apk" `
    -I "$SDKLINK\platforms\android-34\android.jar" `
    --manifest "$APP\AndroidManifest.xml" `
    --java "$OUT\gen" `
    -A "$APP\assets" `
    --min-sdk-version 24 --target-sdk-version 34 `
    "$OUT\res.zip"
if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed" }

# 3. javac
Write-Host "== javac =="
& $JAVAC -source 8 -target 8 -encoding UTF-8 `
    -cp "$SDKLINK\platforms\android-34\android.jar" `
    -d "$OUT\classes" `
    "$APP\src\com\feipan\referee\MainActivity.java" `
    "$APP\src\com\feipan\referee\KeepAliveService.java" `
    "$OUT\gen\com\feipan\referee\R.java"
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

# 4. d8（收集全部 .class，含 MainActivity$Bridge 等内部类）
Write-Host "== d8 =="
New-Item -ItemType Directory -Force -Path "$OUT\dex" | Out-Null
$classes = Get-ChildItem "$OUT\classes" -Recurse -Filter *.class | ForEach-Object { $_.FullName }
& "$BTL\d8.bat" --lib "$SDKLINK\platforms\android-34\android.jar" `
    --min-api 24 --output "$OUT\dex" `
    $classes
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

# 5. add classes.dex into apk
Write-Host "== package dex =="
Copy-Item "$OUT\app-unsigned.apk" "$OUT\app-dex.apk" -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open("$OUT\app-dex.apk", "Update")
$entry = $zip.CreateEntry("classes.dex", [System.IO.Compression.CompressionLevel]::Optimal)
$stream = $entry.Open()
$bytes = [System.IO.File]::ReadAllBytes("$OUT\dex\classes.dex")
$stream.Write($bytes, 0, $bytes.Length)
$stream.Close()
$zip.Dispose()

# 6. zipalign
Write-Host "== zipalign =="
& "$BTL\zipalign.exe" -f 4 "$OUT\app-dex.apk" "$OUT\app-aligned.apk"
if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }

# 7. keystore + apksigner
if (-not (Test-Path "$WORK\feipan.keystore")) {
    Write-Host "== generate keystore =="
    & $KEYTOOL -genkeypair -v -keystore "$WORK\feipan.keystore" `
        -alias feipan -keyalg RSA -keysize 2048 -validity 10950 `
        -storepass feipan123 -keypass feipan123 `
        -dname "CN=Feipan Referee, OU=Feipan, O=Feipan, L=Hangzhou, ST=Zhejiang, C=CN"
    if ($LASTEXITCODE -ne 0) { throw "keytool failed" }
}
Write-Host "== apksigner =="
& "$BTL\apksigner.bat" sign --ks "$WORK\feipan.keystore" --ks-key-alias feipan `
    --ks-pass pass:feipan123 --key-pass pass:feipan123 `
    --out "$WORK\referee.apk" "$OUT\app-aligned.apk"
if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

& "$BTL\apksigner.bat" verify "$WORK\referee.apk"
if ($LASTEXITCODE -ne 0) { throw "verify failed" }

# 8. copy result back to project
Copy-Item "$WORK\referee.apk" "$PROJ\referee.apk" -Force
Copy-Item "$WORK\feipan.keystore" "$PROJ\feipan.keystore" -Force -ErrorAction SilentlyContinue
Write-Host "BUILD OK -> $PROJ\referee.apk"
