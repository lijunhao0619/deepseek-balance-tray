@echo off
rem Render the details window to a PNG without leaving the tray running.
rem Useful for eyeballing the layout, or for sending me a screenshot.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0BalanceTray.ps1" -CaptureUi "%~dp0ui-preview.png"
echo.
echo Done: %~dp0ui-preview.png
pause
