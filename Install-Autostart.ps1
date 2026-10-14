#requires -version 5.1
<#
    安装开机自启：在「启动」文件夹里创建一个指向 Start-BalanceTray.vbs 的快捷方式。
    用法：powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Autostart.ps1')

try {
    $path = Install-BalanceAutostart -Root $PSScriptRoot
    Write-Host "已开启开机自启：" -ForegroundColor Green
    Write-Host "  $path"
    Write-Host "下次登录 Windows 时会自动启动托盘程序。"
} catch {
    Write-Host "设置失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
