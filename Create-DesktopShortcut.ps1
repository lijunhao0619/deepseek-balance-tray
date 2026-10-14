#requires -version 5.1
<#
    Create-DesktopShortcut.ps1 —— 生成快捷方式 + 图标

    会先用托盘图标渲染器画一个 256x256 的 .ico，再建快捷方式指向 Start-BalanceTray.vbs，
    所以双击快捷方式 = 静默启动托盘程序（不会闪黑窗口）。

    用法：
      .\Create-DesktopShortcut.ps1                  # 建到桌面
      .\Create-DesktopShortcut.ps1 -Where Startup   # 建到「启动」文件夹（= 开机自启）
      .\Create-DesktopShortcut.ps1 -Where Here      # 就建在本文件夹里，方便自己拖走
#>
[CmdletBinding()]
param(
    [ValidateSet('Desktop', 'Startup', 'Here')]
    [string]$Where = 'Desktop'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

. (Join-Path $Root 'DeepSeekBalance.ps1')
Add-Type -AssemblyName System.Drawing

$vbs = Join-Path $Root 'Start-BalanceTray.vbs'
if (-not (Test-Path -LiteralPath $vbs)) { throw "找不到启动器: $vbs" }

# ------------------------------------------------------------------ 1. 生成图标

$icoPath = Join-Path $Root 'tray.ico'
$needIcon = $true
if (Test-Path -LiteralPath $icoPath) {
    # 已有图标就复用，除非脚本比它新
    if ((Get-Item $icoPath).LastWriteTime -ge (Get-Item (Join-Path $Root 'DeepSeekBalance.ps1')).LastWriteTime) {
        $needIcon = $false
        Write-Host "复用已有图标: $icoPath" -ForegroundColor DarkGray
    }
}

if ($needIcon) {
    try {
        # 256x256 画一次，Windows 会自己缩放到 16/32/48
        $bmp  = New-BalanceIconBitmap -Text '¥' -Color $script:SeverityColors['ok'] -Size 256
        $h    = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($h)
        $fs   = [System.IO.File]::Create($icoPath)
        $icon.Save($fs)
        $fs.Close()
        # 顺手导一张 PNG 方便预览
        $bmp.Save((Join-Path $Root 'app-icon-preview.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $fs.Dispose(); $icon.Dispose(); $bmp.Dispose()
        Write-Host "已生成图标: $icoPath" -ForegroundColor Green
    } catch {
        Write-Host "图标生成失败（改用系统图标）: $($_.Exception.Message)" -ForegroundColor Yellow
        $icoPath = ''
    }
}

# ------------------------------------------------------------------ 2. 目标文件夹

switch ($Where) {
    'Desktop' { $targetDir = [Environment]::GetFolderPath('Desktop') }
    'Startup' { $targetDir = [Environment]::GetFolderPath('Startup') }
    'Here'    { $targetDir = $Root }
    default   { $targetDir = [Environment]::GetFolderPath('Desktop') }
}

$lnkPath = Join-Path $targetDir 'DeepSeek 用量.lnk'

# ------------------------------------------------------------------ 3. 建快捷方式

try {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk.Arguments        = '"' + $vbs + '"'
    $lnk.WorkingDirectory = $Root
    $lnk.Description      = 'DeepSeek 用量托盘 —— 常驻显示今日折算花费'
    if ($icoPath) { $lnk.IconLocation = "$icoPath,0" }
    $lnk.WindowStyle      = 7
    $lnk.Save()

    Write-Host ''
    Write-Host '快捷方式已创建：' -ForegroundColor Green
    Write-Host "  $lnkPath"
    Write-Host ''
    Write-Host '双击它就会静默启动托盘程序（不会出现黑窗口）。' -ForegroundColor DarkGray
} catch {
    Write-Host "创建快捷方式失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "目标目录: $targetDir" -ForegroundColor DarkGray
    exit 1
}
