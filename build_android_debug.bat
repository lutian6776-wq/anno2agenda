@echo off
chcp 65001 >nul
echo ========================================================
echo  知程 (Anno2Agenda) - Android Debug APK (分ABI架构) 编译
echo ========================================================

:: 1. 规避系统代理对本地 127.0.0.1 Gradle Daemon / Dart 回环 IPC 通信的拦截
set HTTP_PROXY=
set HTTPS_PROXY=
set ALL_PROXY=
set http_proxy=
set https_proxy=
set all_proxy=

:: 2. 设置 Pub Cache 与 Flutter 环境
set PUB_CACHE=D:\.pub-cache

:: 3. 停止可能残留卡死的 Gradle 后台守护进程，并解除 Flutter SDK 全局死锁
echo [1/3] 正在检查并释放后台 Gradle 守护进程与 Flutter 锁文件...
if exist "D:\flutter\bin\cache\flutter.bat.lock" (
    del /f /q "D:\flutter\bin\cache\flutter.bat.lock" >nul 2>&1
)
cd /d "%~dp0android"
call gradlew.bat --stop >nul 2>&1
cd /d "%~dp0"

:: 4. 执行多架构分包调试版编译
echo [2/3] 正在编译 Debug 调试版分架构 APK...
call D:\flutter\bin\flutter.bat build apk --debug --split-per-abi

if %ERRORLEVEL% equ 0 (
    echo ========================================================
    echo  [3/3] Debug 调试包编译成功！产物目录：
    echo  build\app\outputs\flutter-apk\
    echo    - app-arm64-v8a-debug.apk   (主流现代手机，支持Logcat调试)
    echo    - app-armeabi-v7a-debug.apk (老旧机型调试包)
    echo    - app-x86_64-debug.apk      (电脑模拟器调试包)
    echo ========================================================
) else (
    echo ========================================================
    echo  [!] 编译失败，请检查控制台上方具体报错输出。
    echo ========================================================
)
pause
