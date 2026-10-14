@echo off
rem 命令行查一次 DeepSeek 余额（绕过执行策略限制）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Balance.ps1" %*
echo.
pause
