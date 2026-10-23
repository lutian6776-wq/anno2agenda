# 知程 (Anno2Agenda) - Android Release APK 一键安全编译脚本 (PowerShell)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " 知程 (Anno2Agenda) - Android Release APK 一键安全编译" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# 1. 规避系统代理对本地 127.0.0.1 Gradle Daemon / Dart 回环 IPC 通信的拦截
$env:HTTP_PROXY = ""
$env:HTTPS_PROXY = ""
$env:ALL_PROXY = ""
$env:http_proxy = ""
$env:https_proxy = ""
$env:all_proxy = ""

# 2. 设置 Pub Cache 与 Flutter 环境
$env:PUB_CACHE = "D:\.pub-cache"

# 3. 停止可能残留卡死的 Gradle 后台守护进程
Write-Host "[1/3] 正在检查并释放后台 Gradle 守护进程..." -ForegroundColor Yellow
Push-Location "$PSScriptRoot\android"
try {
    .\gradlew.bat --stop | Out-Null
} catch {}
Pop-Location

# 4. 执行多架构分包编译
Write-Host "[2/3] 正在执行 Flutter AOT 与 Gradle Release 编译打包..." -ForegroundColor Yellow
& "D:\flutter\bin\flutter.bat" build apk --split-per-abi

if ($LASTEXITCODE -eq 0) {
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host " [3/3] 编译成功！最新 APK 安装包目录：" -ForegroundColor Green
    Write-Host " build\app\outputs\flutter-apk\" -ForegroundColor Green
    Write-Host "   - app-arm64-v8a-release.apk   (主流现代手机，推荐)" -ForegroundColor White
    Write-Host "   - app-armeabi-v7a-release.apk (老旧机型兼容包)" -ForegroundColor White
    Write-Host "   - app-x86_64-release.apk      (电脑端 Android 模拟器)" -ForegroundColor White
    Write-Host "========================================================" -ForegroundColor Green
} else {
    Write-Host "========================================================" -ForegroundColor Red
    Write-Host " [!] 编译失败，请检查控制台上方具体报错输出。" -ForegroundColor Red
    Write-Host "========================================================" -ForegroundColor Red
}
