#requires -version 5.1
<#
    Test-Balance.ps1 —— 命令行查余额 / 持续观察 / 生成图标预览

    示例：
      .\Test-Balance.ps1                     # 查一次
      .\Test-Balance.ps1 -Watch              # 每 5 秒刷新，终端里持续看
      .\Test-Balance.ps1 -Json               # 输出 JSON（给别的脚本用）
      .\Test-Balance.ps1 -IconPreviewDir .   # 生成托盘图标预览图（不联网）
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Watch,
    [int]$IntervalSeconds = 5,
    [switch]$Json,
    [string]$IconPreviewDir
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }

. (Join-Path $Root 'DeepSeekBalance.ps1')

Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- 图标预览
if ($IconPreviewDir) {
    if (-not (Test-Path -LiteralPath $IconPreviewDir)) { New-Item -ItemType Directory -Path $IconPreviewDir -Force | Out-Null }

    $samples = @(
        @{ Name = '12345';  Total = 12345.67; Currency = 'CNY' },
        @{ Name = '1234';   Total = 1234.56;  Currency = 'CNY' },
        @{ Name = '103';    Total = 103.50;   Currency = 'CNY' },
        @{ Name = '42';     Total = 42.00;    Currency = 'CNY' },
        @{ Name = '12';     Total = 12.30;    Currency = 'CNY' },
        @{ Name = '5';      Total = 5.20;     Currency = 'CNY' },
        @{ Name = '0.8';    Total = 0.87;     Currency = 'CNY' },
        @{ Name = 'usd';    Total = 8.40;     Currency = 'USD' },
        @{ Name = 'error';  Total = -1;       Currency = 'CNY' },
        @{ Name = 'loading';Total = -2;       Currency = 'CNY' }
    )

    $cell = 44
    $w = $samples.Count * $cell
    $h = $cell + 18

    $sheet = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#2B2F36'))
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $capFont = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 7
    $capBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

    $i = 0
    foreach ($s in $samples) {
        $text = Get-BalanceIconText -Value $s.Total -Currency $s.Currency
        $color = '#1F9D55'
        if ($s.Name -eq 'error')        { $text = '!';  $color = '#8A8F98' }
        elseif ($s.Name -eq 'loading')  { $text = '…';  $color = '#4A7DBF' }
        else {
            $color = $script:SeverityColors[(Get-BalanceSeverity -Value $s.Total -Low 20 -Critical 5)]
        }
        $bmp = New-BalanceIconBitmap -Text $text -Color $color
        $g.DrawImage($bmp, ($i * $cell + 6), 4, 32, 32)
        $cap = "$text"
        $sz = $g.MeasureString($cap, $capFont)
        $g.DrawString($cap, $capFont, $capBr, ($i * $cell + ($cell - $sz.Width) / 2), ($cell - 2))
        $bmp.Dispose()
        $i++
    }
    $g.Dispose()

    $p1 = Join-Path $IconPreviewDir 'icon-preview-1x.png'
    $p4 = Join-Path $IconPreviewDir 'icon-preview-4x.png'
    $sheet.Save($p1, [System.Drawing.Imaging.ImageFormat]::Png)

    # 4 倍放大，方便肉眼检查字形（最近邻，不做平滑）
    $big = New-Object System.Drawing.Bitmap -ArgumentList ($w * 4), ($h * 4)
    $g2 = [System.Drawing.Graphics]::FromImage($big)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g2.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g2.DrawImage($sheet, 0, 0, $w * 4, $h * 4)
    $g2.Dispose()
    $big.Save($p4, [System.Drawing.Imaging.ImageFormat]::Png)

    # 额外导出单个 32x32 图标，直接看真实尺寸
    $single = New-BalanceIconBitmap -Text (Get-BalanceIconText -Value 103.50 -Currency 'CNY') -Color $script:SeverityColors['ok']
    $single.Save((Join-Path $IconPreviewDir 'icon-single-32.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $single.Dispose()

    $sheet.Dispose(); $big.Dispose()
    Write-Host "已生成预览：" -ForegroundColor Green
    Write-Host "  $p1"
    Write-Host "  $p4"
    return
}

# ---------------------------------------------------------------- 查询
function Show-State {
    param($State)
    if ($State.ok) {
        $color = 'Green'
        if ($State.severity -eq 'low')      { $color = 'Yellow' }
        if ($State.severity -eq 'critical') { $color = 'Red' }
        $line = 'DeepSeek 余额 {0}   [赠金 {1} / 充值 {2}] {3}  可用={4}  延迟 {5}ms' -f `
            (Format-Money -Value $State.total -Currency $State.currency),
            (Format-Money -Value $State.granted -Currency $State.currency),
            (Format-Money -Value $State.toppedUp -Currency $State.currency),
            $State.fetchedAt.ToString('HH:mm:ss'),
            $State.isAvailable,
            $State.latencyMs
        Write-Host $line -ForegroundColor $color
        foreach ($extra in @($State.infos)) {
            if ("$($extra.currency)" -ne "$($State.currency)") {
                Write-Host ("   其他币种: {0} (赠金 {1} / 充值 {2})" -f `
                    (Format-Money -Value $extra.total -Currency $extra.currency),
                    (Format-Money -Value $extra.granted -Currency $extra.currency),
                    (Format-Money -Value $extra.toppedUp -Currency $extra.currency)) -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Host ("查询失败 [{0}] {1}" -f $State.kind, $State.error) -ForegroundColor Red
        if ($State.detail) { Write-Host "    详情: $($State.detail)" -ForegroundColor DarkGray }
    }
}

$cfg = Get-BalanceConfig -Path $ConfigPath

if (-not $Watch) {
    $state = Get-DeepSeekBalance -Config $cfg
    if ($Json) {
        $state | ConvertTo-Json -Depth 5
    } else {
        Show-State -State $state
    }
    if ($state.ok) { exit 0 } else { exit 1 }
}

Write-Host "持续观察中（每 ${IntervalSeconds}s，Ctrl+C 退出）…" -ForegroundColor DarkGray
while ($true) {
    $state = Get-DeepSeekBalance -Config $cfg
    $now = (Get-Date).ToString('HH:mm:ss')
    Write-Host -NoNewline "[$now] "
    Show-State -State $state
    Start-Sleep -Seconds ([math]::Max(2, $IntervalSeconds))
}
