' DeepSeek usage tray -- silent launcher (no console window)
' Double-click this file to keep the usage widget in the system tray.
' It also pops the details window once, so you can SEE that it started
' (the tray icon itself may be hidden in the Windows 11 "^" overflow menu).
' NOTE: keep this file ASCII-only. Windows Script Host reads .vbs as ANSI.
Option Explicit

Dim sh, fso, scriptDir, ps1, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\BalanceTray.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "BalanceTray.ps1 not found:" & vbCrLf & ps1, 16, "DeepSeek Usage Tray"
    WScript.Quit 1
End If

sh.CurrentDirectory = scriptDir

' -WindowStyle Hidden keeps the console window from flashing; 0 = hidden window
' -ShowPanel pops the details window once after the first successful read
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """ -ShowPanel"
sh.Run cmd, 0, False
