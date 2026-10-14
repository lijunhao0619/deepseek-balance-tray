#requires -version 5.1
<#
    取消开机自启。
    用法：powershell -ExecutionPolicy Bypass -File .\Uninstall-Autostart.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Autostart.ps1')

if (Uninstall-BalanceAutostart) {
    Write-Host "已取消开机自启。" -ForegroundColor Green
} else {
    Write-Host "本来就没有设置开机自启。" -ForegroundColor DarkGray
}
