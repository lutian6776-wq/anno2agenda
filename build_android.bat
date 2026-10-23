@echo off
chcp 65001 >nul
echo ========================================================
echo  知程 (Anno2Agenda) - Android Release APK 一键安全编译
echo ========================================================

:: 1. 规避代理对本地 Gradle Daemon 回环通讯的拦截
set HTTP_PROXY=
set HTTPS_PROXY=
set ALL_PROXY=
set http_proxy=
set https_proxy=
set all_proxy=

:: 2. 设置 Pub Cache 与 Flutter 环境
set PUB_CACHE=D:\.pub-cache

:: 3. 停止可能残留卡死的 Gradle 后台僵尸进程
echo [1/3] 正在检查并释放后台 Gradle 守护进程...
cd /d "%~dp0android"
call gradlew.bat --stop >nul 2>&1
cd /d "%~dp0"

:: 4. 执行多架构分包编译
echo [2/3] 正在执行 Flutter AOT 与 Gradle Release 编译打包...
call D:\flutter\bin\flutter.bat build apk --split-per-abi

if %ERRORLEVEL% equ 0 (
    echo ========================================================
    echo  [3/3] 编译成功！最新 APK 安装包目录：
    echo  build\app\outputs\flutter-apk\
    echo    - app-arm64-v8a-release.apk   (主流现代手机，体积最小性能最强)
    echo    - app-armeabi-v7a-release.apk (老旧机型兼容包)
    echo    - app-x86_64-release.apk      (电脑端 Android 模拟器)
    echo ========================================================
) else (
    echo ========================================================
    echo  [!] 编译失败，请检查控制台上方具体报错输出。
    echo ========================================================
)
pause
