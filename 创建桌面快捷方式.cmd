@echo off
rem 在桌面上创建「DeepSeek 用量」快捷方式（双击本文件一次即可）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Create-DesktopShortcut.ps1" -Where Desktop
echo.
pause
