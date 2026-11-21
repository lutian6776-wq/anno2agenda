@echo off
setlocal
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package_android_release.ps1" %*
exit /b %ERRORLEVEL%
