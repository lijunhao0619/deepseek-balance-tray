@echo off
rem 命令行查看本地用量统计（不需要 API Key）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Usage.ps1" %*
echo.
pause
