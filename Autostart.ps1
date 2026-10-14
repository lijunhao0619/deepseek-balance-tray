#requires -version 5.1
<#
    Autostart.ps1 —— 开机自启的安装/卸载/检测（托盘菜单和独立脚本共用）
#>

function Get-BalanceAutostartShortcutPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return (Join-Path $startup 'DeepSeek余额托盘.lnk')
}

function Test-BalanceAutostart {
    return (Test-Path -LiteralPath (Get-BalanceAutostartShortcutPath))
}

function Install-BalanceAutostart {
    [CmdletBinding()]
    param([string]$Root)
    if (-not $Root) { $Root = $PSScriptRoot }

    # 开机自启走「静默」路径：直接调 powershell 跑主程序、不带 -ShowPanel，
    # 免得到时候每次开机都弹一个详情窗口出来。
    $ps1 = Join-Path $Root 'BalanceTray.ps1'
    if (-not (Test-Path -LiteralPath $ps1)) { throw "找不到主程序: $ps1" }

    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Get-BalanceAutostartShortcutPath))
    $lnk.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments        = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"'
    $lnk.WorkingDirectory = $Root
    $lnk.Description      = 'DeepSeek 用量托盘（开机自启，静默）'
    $ico = Join-Path $Root 'tray.ico'
    if (Test-Path -LiteralPath $ico) {
        $lnk.IconLocation = "$ico,0"
    } else {
        $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',167'
    }
    $lnk.Save()
    return (Get-BalanceAutostartShortcutPath)
}

function Uninstall-BalanceAutostart {
    $p = Get-BalanceAutostartShortcutPath
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
        return $true
    }
    return $false
}
