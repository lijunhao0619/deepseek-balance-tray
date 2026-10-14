#requires -version 5.1
<#
    DetailsWindow.ps1 —— 详情窗口：无边框自绘卡片（浅色主题）

    设计要点：
      · 浅色主题：白卡片 + 极浅分区底 + 1px 淡边框，靠留白和细线分层，不用重阴影
      · DPI 感知：所有尺寸乘 $script:UiScale（由 BalanceTray.ps1 按 GetDpiForSystem 设定）。
        150% 缩放下窗口不再被系统位图拉伸，因此文字是原生渲染的，清晰不糊。
      · 1px 边框用「填充圆环」画（外圈填边框色 + 内圈填底色），避开 GDI+ Pen 居中导致的半像素灰边
      · 不用任何 WinForms 子控件，整卡 GDI+ 手绘，配合圆角与悬停反馈

    对外：Show-BalanceDetails / Update-DetailsWindow / Draw-DetailsUi
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not $script:UiScale) { $script:UiScale = 1.0 }

# ------------------------------------------------------------------ 配色（浅色）

$script:UiPalette = @{
    bg          = '#FFFFFF'   # 卡片底
    subtle      = '#F7F8FA'   # 图表/分区底
    hover       = '#F2F4F7'   # 悬停底
    border      = '#E4E7EC'   # 卡片外框
    borderHard  = '#D0D7DE'   # 按钮描边（浅底上要更清楚一点）
    grid        = '#E9ECF1'   # 走势图网格
    text        = '#1F2328'   # 主数字、标题
    textDim     = '#5B6470'   # 次级
    textLabel   = '#6B7280'   # 标签
    textMute    = '#9AA1AC'   # 空态提示
    accent      = '#2563EB'   # 强调色（主按钮、走势线）
    accentHover = '#1D4ED8'
}

# 浅色主题的语义色：填充用亮档，文字用深档（直接搬深色主题的荧光色会刺眼）
$script:UiAccent = @{
    ok       = @{ fill = '#16A34A'; text = '#15803D' }
    low      = @{ fill = '#F59E0B'; text = '#B45309' }
    critical = @{ fill = '#EF4444'; text = '#B91C1C' }
    error    = @{ fill = '#9AA1AC'; text = '#6B7280' }
    loading  = @{ fill = '#2563EB'; text = '#2563EB' }
}
$script:UiStatusText = @{
    ok = '正常'; low = '偏低'; critical = '告急'; error = '离线'; loading = '加载中'
}

$script:UiFontCache = @{}
$script:UiButtons   = @()
$script:UiHover     = $null

# ------------------------------------------------------------------ 布局
# 逻辑单位（96dpi 下的 px），绘制时统一乘 $script:UiScale
$script:UiLayout = @{
    W = 340; H = 208; Pad = 12
    TitleY = 10; PillH = 20; PillY = 9; CloseSize = 20; CloseY = 9
    HeroY = 32; HeroSize = 26
    MetaY = 64
    StatsY = 82; StatsH = 34
    ChartY = 122; ChartH = 40
    BtnY = 170; BtnH = 28
    RefreshW = 88; CopyW = 52; OpenW = 80
}

function Get-UiWindowSize {
    $L = $script:UiLayout
    return @{ W = [int][math]::Round($L.W * $script:UiScale); H = [int][math]::Round($L.H * $script:UiScale) }
}

function Get-UiFont {
    param([string]$Family, [single]$Size, [string]$Style = 'Regular')
    $key = "$Family|$Size|$Style"
    if ($script:UiFontCache.ContainsKey($key)) { return $script:UiFontCache[$key] }
    $fs = [System.Drawing.FontStyle]::Regular
    if ($Style -eq 'Bold') { $fs = [System.Drawing.FontStyle]::Bold }
    $font = $null
    foreach ($fam in @($Family, 'Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI')) {
        try {
            $font = New-Object System.Drawing.Font -ArgumentList $fam, $Size, $fs, ([System.Drawing.GraphicsUnit]::Pixel)
            break
        } catch { $font = $null }
    }
    if (-not $font) { $font = New-Object System.Drawing.Font -ArgumentList 'Arial', $Size, $fs, ([System.Drawing.GraphicsUnit]::Pixel) }
    $script:UiFontCache[$key] = $font
    return $font
}

function Get-UiSeverity {
    $sev = 'loading'
    if ($script:State) { $sev = [string]$script:State.severity; if (-not $sev) { $sev = 'error' } }
    if (-not $script:UiAccent.ContainsKey($sev)) { $sev = 'error' }
    return $sev
}

function Get-UiCloseRect {
    param([int]$W)
    $S = $script:UiScale
    $L = $script:UiLayout
    return (New-Object System.Drawing.Rectangle `
        -ArgumentList ([int]($W - ($L.Pad + $L.CloseSize) * $S)), ([int]($L.CloseY * $S)), `
                      ([int]($L.CloseSize * $S)), ([int]($L.CloseSize * $S)))
}

# 1px 描边的清晰画法：外圈填描边色，内圈填底色，避开 GDI+ Pen 居中造成的半像素灰边
function Fill-UiRing {
    param($G, [single]$X, [single]$Y, [single]$W, [single]$H, [single]$R, $FillBrush, $EdgeBrush, [single]$Bw)
    $G.FillPath($EdgeBrush, (New-RoundRectPath $X $Y $W $H $R))
    if ($W -gt 2 * $Bw -and $H -gt 2 * $Bw) {
        $inset = [math]::Max(0, $R - $Bw)
        $G.FillPath($FillBrush, (New-RoundRectPath ($X + $Bw) ($Y + $Bw) ($W - 2 * $Bw) ($H - 2 * $Bw) $inset))
    }
}

# ------------------------------------------------------------------ 绘制

function Draw-DetailsUi {
    param([System.Drawing.Graphics]$G, [int]$W, [int]$H)

    $S = $script:UiScale
    $L = $script:UiLayout
    $C = @{}
    foreach ($k in $script:UiPalette.Keys) { $C[$k] = [System.Drawing.ColorTranslator]::FromHtml($script:UiPalette[$k]) }

    $G.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $G.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $G.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    # 窗口底先填边框色：Region/DWM 裁掉圆角处不会露黑边
    $G.Clear($C['border'])

    $sev        = Get-UiSeverity
    $state      = $script:State
    $accent     = $script:UiAccent[$sev]
    $accentFill = [System.Drawing.ColorTranslator]::FromHtml($accent.fill)
    $accentText = [System.Drawing.ColorTranslator]::FromHtml($accent.text)

    $pad = $L.Pad * $S
    $bw  = [single][math]::Max(1, [math]::Round($S))   # 边框按物理像素取整，150% 下也是干净的 1px

    $brBg   = New-Object System.Drawing.SolidBrush $C['bg']
    $brEdge = New-Object System.Drawing.SolidBrush $C['border']
    Fill-UiRing -G $G -X 0 -Y 0 -W $W -H $H -R (10 * $S) -FillBrush $brBg -EdgeBrush $brEdge -Bw $bw

    $sfLeft  = New-Object System.Drawing.StringFormat
    $sfLeft.Alignment = [System.Drawing.StringAlignment]::Near
    $sfRight = New-Object System.Drawing.StringFormat
    $sfRight.Alignment = [System.Drawing.StringAlignment]::Far

    $brText  = New-Object System.Drawing.SolidBrush $C['text']
    $brDim   = New-Object System.Drawing.SolidBrush $C['textDim']
    $brLabel = New-Object System.Drawing.SolidBrush $C['textLabel']
    $brMute  = New-Object System.Drawing.SolidBrush $C['textMute']
    $brAcc   = New-Object System.Drawing.SolidBrush $accentText

    # ---------------- 标题
    $titleText = 'DeepSeek 用量'
    if ($state -and $state.mode -eq 'platform') { $titleText = 'DeepSeek 账号余额' }
    elseif ($state -and $state.mode -eq 'balance') { $titleText = 'DeepSeek 余额' }
    $G.DrawString($titleText, (Get-UiFont 'Microsoft YaHei UI' (14 * $S) 'Bold'), $brText, $pad, ($L.TitleY * $S), $sfLeft)

    # ---------------- 关闭按钮（自绘 ✕）
    $cs = $L.CloseSize * $S
    $cx = $W - $pad - $cs
    $cy = $L.CloseY * $S
    if ($script:UiHover -eq 'close') {
        $hp = New-RoundRectPath $cx $cy $cs $cs (5 * $S)
        $G.FillPath((New-Object System.Drawing.SolidBrush $C['hover']), $hp)
        $hp.Dispose()
    }
    $xPen = New-Object System.Drawing.Pen -ArgumentList $C['textLabel'], ([single][math]::Max(1.2, 1.5 * $S))
    $ip = 6 * $S
    $G.DrawLine($xPen, ($cx + $ip), ($cy + $ip), ($cx + $cs - $ip), ($cy + $cs - $ip))
    $G.DrawLine($xPen, ($cx + $cs - $ip), ($cy + $ip), ($cx + $ip), ($cy + $cs - $ip))
    $xPen.Dispose()

    # ---------------- 状态胶囊
    $pillText = $script:UiStatusText[$sev]
    $pillFont = Get-UiFont 'Microsoft YaHei UI' (11.5 * $S) 'Bold'
    $tsz = $G.MeasureString($pillText, $pillFont)
    $pw = [single]($tsz.Width + 28 * $S)
    $ph = [single]($L.PillH * $S)
    $px = [single]($cx - 8 * $S - $pw)
    $py = [single]($L.PillY * $S)
    $pillPath = New-RoundRectPath $px $py $pw $ph ($ph / 2)
    $G.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38, $accentFill))), $pillPath)
    $dot = [single](6 * $S)
    $G.FillEllipse((New-Object System.Drawing.SolidBrush $accentFill), ($px + 10 * $S), ($py + ($ph - $dot) / 2), $dot, $dot)
    $G.DrawString($pillText, $pillFont, $brAcc, ($px + 21 * $S), ($py + ($ph - $tsz.Height) / 2), $sfLeft)

    # ---------------- 主数字
    $heroColor = $C['text']
    if ($sev -eq 'low' -or $sev -eq 'critical' -or $sev -eq 'error') { $heroColor = $accentText }
    $brHero = New-Object System.Drawing.SolidBrush $heroColor

    $metaText = ''
    if ($state -and $state.ok) {
        $heroText = [string]$state.hero
        $heroLabel = ''
        try { $heroLabel = [string]$state.heroLabel } catch { }

        $avail = [single]($W - $pad * 2 - 120 * $S)
        $heroSize = [single]($L.HeroSize * $S)
        while ($heroSize -gt 14 * $S) {
            $fnt = Get-UiFont 'Segoe UI' $heroSize 'Bold'
            if ($G.MeasureString($heroText, $fnt).Width -le $avail) { break }
            $heroSize -= 1 * $S
        }
        $G.DrawString($heroText, (Get-UiFont 'Segoe UI' $heroSize 'Bold'), $brHero, $pad, ($L.HeroY * $S), $sfLeft)

        # 主数字右边的小字说明（可用余额 / 今日折算花费）
        if ($heroLabel) {
            $G.DrawString($heroLabel, (Get-UiFont 'Microsoft YaHei UI' (11 * $S)), $brLabel,
                ([single]($W - $pad)), (($L.HeroY + 13) * $S), $sfRight)
        }
        $metaText = [string]$state.meta
    } elseif ($state) {
        $G.DrawString([string]$state.hero, (Get-UiFont 'Microsoft YaHei UI' (17 * $S) 'Bold'), $brAcc, $pad, (($L.HeroY + 4) * $S), $sfLeft)
        $msg = [string]$state.meta
        if ($msg.Length -gt 40) { $msg = $msg.Substring(0, 39) + '…' }
        $G.DrawString($msg, (Get-UiFont 'Microsoft YaHei UI' (12 * $S)), $brDim, $pad, (($L.HeroY + 34) * $S), $sfLeft)
        $metaText = '{0} · 下个周期自动重试' -f (Get-Date).ToString('HH:mm')
    } else {
        $G.DrawString('正在读取数据…', (Get-UiFont 'Microsoft YaHei UI' (17 * $S) 'Bold'), $brAcc, $pad, (($L.HeroY + 4) * $S), $sfLeft)
    }

    # meta 行自动缩字号：余额模式下这行可能很长（充值/赠金/今日/累计），保证不溢出
    if ($metaText) {
        $metaSize = [single](11 * $S)
        $metaFont = Get-UiFont 'Microsoft YaHei UI' $metaSize
        $maxMetaW = [single]($W - $pad * 2)
        while ($metaSize -gt 9 * $S -and $G.MeasureString($metaText, $metaFont).Width -gt $maxMetaW) {
            $metaSize -= 0.5 * $S
            $metaFont = Get-UiFont 'Microsoft YaHei UI' $metaSize
        }
        $G.DrawString($metaText, $metaFont, $brLabel, $pad, ($L.MetaY * $S), $sfLeft)
    }

    # ---------------- 今日 token 统计条（4 列）
    $stats = @()
    if ($state -and $state.PSObject.Properties['stats'] -and $state.stats) { $stats = @($state.stats) }

    $cyCard = $L.ChartY * $S
    $ch = [single]($L.ChartH * $S)
    if ($stats.Count -eq 0) {
        # 没有 token 数据（API Key 模式）时，把统计条的空间让给走势图
        $cyCard = $L.StatsY * $S
        $ch = [single](($L.ChartY + $L.ChartH - $L.StatsY) * $S)
    } else {
        $sy = $L.StatsY * $S
        $sh = [single]($L.StatsH * $S)
        $sx = $pad
        $sw = [single]($W - $pad * 2)
        $sp = New-RoundRectPath $sx $sy $sw $sh (8 * $S)
        $G.FillPath((New-Object System.Drawing.SolidBrush $C['subtle']), $sp)

        $colW = [single]($sw / $stats.Count)
        for ($i = 1; $i -lt $stats.Count; $i++) {
            $lx = [single]($sx + $colW * $i)
            $G.FillRectangle((New-Object System.Drawing.SolidBrush $C['grid']),
                $lx, ($sy + 7 * $S), $bw, ($sh - 14 * $S))
        }

        $sfC = New-Object System.Drawing.StringFormat
        $sfC.Alignment     = [System.Drawing.StringAlignment]::Center
        $sfC.LineAlignment = [System.Drawing.StringAlignment]::Center
        $statLblFont = Get-UiFont 'Microsoft YaHei UI' (10.5 * $S)
        $statValFont = Get-UiFont 'Microsoft YaHei UI' (12.5 * $S) 'Bold'
        for ($i = 0; $i -lt $stats.Count; $i++) {
            $colX = [single]($sx + $colW * $i)
            $lblRect = New-Object System.Drawing.RectangleF -ArgumentList $colX, ($sy + 3 * $S), $colW, (13 * $S)
            $valRect = New-Object System.Drawing.RectangleF -ArgumentList $colX, ($sy + 16 * $S), $colW, (15 * $S)
            $G.DrawString([string]$stats[$i].label, $statLblFont, $brLabel, $lblRect, $sfC)
            $G.DrawString([string]$stats[$i].value, $statValFont, $brText, $valRect, $sfC)
        }
        $sfC.Dispose(); $sp.Dispose()
    }

    # ---------------- 走势卡片
    $cw = [single]($W - $pad * 2)
    $cardPath = New-RoundRectPath $pad $cyCard $cw $ch (8 * $S)
    $G.FillPath((New-Object System.Drawing.SolidBrush $C['subtle']), $cardPath)

    $plotL = [single]($pad + 10 * $S)
    $plotR = [single]($pad + $cw - 10 * $S)
    $plotT = [single]($cyCard + 14 * $S)
    $plotB = [single]($cyCard + $ch - 10 * $S)

    $pts = @()
    if ($state -and $state.chart) { $pts = @($state.chart) }

    # 只有真的有走势时才画网格；空态只留提示文字，免得虚线从字后面穿过
    if ($pts.Count -ge 2) {
        foreach ($frac in 0.33, 0.66) {
            $gy = [single]($plotT + ($plotB - $plotT) * $frac)
            $gPen = New-Object System.Drawing.Pen -ArgumentList $C['grid'], ([single][math]::Max(1, $S))
            $gPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
            $G.DrawLine($gPen, $plotL, $gy, $plotR, $gy)
            $gPen.Dispose()
        }
    }

    if ($pts.Count -lt 2) {
        $hint = '暂无消耗记录'
        if ($pts.Count -eq 1) { $hint = '今天的数据已就位，明天开始累积走势' }
        $hintFont = Get-UiFont 'Microsoft YaHei UI' (11 * $S)
        $hsz = $G.MeasureString($hint, $hintFont)
        $G.DrawString($hint, $hintFont, $brMute,
            ([single]($pad + ($cw - $hsz.Width) / 2)), ([single]($cyCard + ($ch - $hsz.Height) / 2)), $sfLeft)
    } else {
        $vals = @($pts | ForEach-Object { [double]$_.value })
        $n = $vals.Count
        $vmin = ($vals | Measure-Object -Minimum).Minimum
        $vmax = ($vals | Measure-Object -Maximum).Maximum
        if ($vmax -le $vmin) { $vmax = $vmin + 1.0 }

        $pf = New-Object 'System.Drawing.PointF[]' $n
        for ($i = 0; $i -lt $n; $i++) {
            $x = [single]($plotL + $i * ($plotR - $plotL) / [math]::Max(1, $n - 1))
            $y = [single]($plotB - (($vals[$i] - $vmin) / ($vmax - $vmin)) * ($plotB - $plotT))
            $pf[$i] = New-Object System.Drawing.PointF -ArgumentList $x, $y
        }

        $ac = $C['accent']
        $area = New-Object System.Drawing.Drawing2D.GraphicsPath
        if ($n -ge 3) { $area.AddCurve($pf, 0.5) } else { $area.AddLines($pf) }
        $area.AddLine($pf[$n - 1].X, $pf[$n - 1].Y, $pf[$n - 1].X, $plotB)
        $area.AddLine($pf[$n - 1].X, $plotB, $pf[0].X, $plotB)
        $area.CloseFigure()
        $gTop = New-Object System.Drawing.PointF -ArgumentList 0, $plotT
        $gBot = New-Object System.Drawing.PointF -ArgumentList 0, $plotB
        $gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $gTop, $gBot,
            ([System.Drawing.Color]::FromArgb(46, $ac)), ([System.Drawing.Color]::FromArgb(0, $ac))
        $G.FillPath($gb, $area)
        $gb.Dispose(); $area.Dispose()

        $linePen = New-Object System.Drawing.Pen -ArgumentList $ac, ([single][math]::Max(1.5, 1.8 * $S))
        $linePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $linePen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        if ($n -ge 3) { $G.DrawCurve($linePen, $pf, 0.5) } else { $G.DrawLines($linePen, $pf) }
        $linePen.Dispose()

        $last = $pf[$n - 1]
        $G.FillEllipse((New-Object System.Drawing.SolidBrush $C['subtle']), ($last.X - 4 * $S), ($last.Y - 4 * $S), 8 * $S, 8 * $S)
        $G.FillEllipse((New-Object System.Drawing.SolidBrush $ac), ($last.X - 2.5 * $S), ($last.Y - 2.5 * $S), 5 * $S, 5 * $S)

        $tiny = Get-UiFont 'Segoe UI' (10 * $S)
        $G.DrawString(('{0:N2}' -f $vmax), $tiny, $brMute, $plotL, ($cyCard + 3 * $S), $sfLeft)
        $G.DrawString(('{0:N2}' -f $vmin), $tiny, $brMute, $plotR, ($cyCard + $ch - 15 * $S), $sfRight)
    }

    # ---------------- 按钮
    $btnY = $L.BtnY * $S
    $btnH = $L.BtnH * $S
    $openLabel = '会话目录'
    if ($state -and $state.mode -eq 'platform') { $openLabel = '去充值' }
    elseif ($state -and $state.mode -eq 'balance') { $openLabel = '开放平台' }

    $openX = [single]($W - $pad - $L.OpenW * $S)
    $copyX = [single]($openX - 8 * $S - $L.CopyW * $S)

    $script:UiButtons = @(
        @{ Key = 'refresh'; Text = '立即刷新'; X = $pad;  Y = $btnY; W = [single]($L.RefreshW * $S); H = $btnH; Style = 'primary' },
        @{ Key = 'copy';    Text = '复制';     X = $copyX; Y = $btnY; W = [single]($L.CopyW * $S);    H = $btnH; Style = 'ghost' },
        @{ Key = 'open';    Text = $openLabel; X = $openX; Y = $btnY; W = [single]($L.OpenW * $S);    H = $btnH; Style = 'ghost' }
    )

    $btnFont = Get-UiFont 'Microsoft YaHei UI' (12.5 * $S)
    foreach ($b in $script:UiButtons) {
        $hovered = ($script:UiHover -eq $b.Key)
        $r = New-RoundRectPath $b.X $b.Y $b.W $b.H (6 * $S)
        if ($b.Style -eq 'primary') {
            $fill = $C['accent']
            if ($hovered) { $fill = $C['accentHover'] }
            $G.FillPath((New-Object System.Drawing.SolidBrush $fill), $r)
            $fg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        } else {
            $fill = $C['bg']
            if ($hovered) { $fill = $C['hover'] }
            $G.FillPath((New-Object System.Drawing.SolidBrush $fill), $r)
            $G.DrawPath((New-Object System.Drawing.Pen -ArgumentList $C['borderHard'], ([single][math]::Max(1, $S))), $r)
            $fg = New-Object System.Drawing.SolidBrush $C['text']
        }
        $ts = $G.MeasureString($b.Text, $btnFont)
        $G.DrawString($b.Text, $btnFont, $fg,
            ([single]($b.X + ($b.W - $ts.Width) / 2)), ([single]($b.Y + ($b.H - $ts.Height) / 2)), $sfLeft)
        $r.Dispose()
    }

    # 倒计时放在主按钮和右侧按钮之间的空隙里（必须够短，否则会压到「复制」按钮）
    if ($script:NextRefresh -and $script:NextRefresh -gt (Get-Date)) {
        $secs = [int](($script:NextRefresh - (Get-Date)).TotalSeconds)
        $nFont = Get-UiFont 'Microsoft YaHei UI' (11 * $S)
        $G.DrawString("${secs}s", $nFont, $brLabel,
            ([single]($pad + $L.RefreshW * $S + 10 * $S)), ([single]($btnY + 8 * $S)), $sfLeft)
    }

    $sfLeft.Dispose(); $sfRight.Dispose()
    $brText.Dispose(); $brDim.Dispose(); $brLabel.Dispose(); $brMute.Dispose()
    $brAcc.Dispose(); $brHero.Dispose(); $brBg.Dispose(); $brEdge.Dispose()
    $cardPath.Dispose(); $pillPath.Dispose()
}

# ------------------------------------------------------------------ 交互

$script:UiDragging    = $false
$script:UiDragCursor  = $null
$script:UiDragFormLoc = $null

function Update-DetailsWindow {
    if ($script:DetailsForm -and -not $script:DetailsForm.IsDisposed) {
        try { $script:DetailsForm.Invalidate() } catch { }
    }
}

function Show-BalanceDetails {
    if ($script:DetailsForm -and -not $script:DetailsForm.IsDisposed) {
        Update-DetailsWindow
        try { $script:DetailsForm.Activate() } catch { }
        return
    }

    try {
        $size = Get-UiWindowSize

        $f = New-Object System.Windows.Forms.Form
        $f.Text            = 'DeepSeek 用量'
        $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $f.ShowInTaskbar   = $false
        $f.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $f.ClientSize      = New-Object System.Drawing.Size -ArgumentList $size.W, $size.H
        $f.BackColor       = [System.Drawing.ColorTranslator]::FromHtml($script:UiPalette['bg'])
        $f.TopMost         = $true
        $f.KeyPreview      = $true

        $f.Add_HandleCreated({
            param($sender, $e)
            try {
                # 按窗口实际所在显示器的 DPI 再校一次（多屏不同缩放时更准）
                $dpi = 0
                try { $dpi = [int][BalanceTray.Dpi]::GetDpiForWindow($sender.Handle) } catch { }
                if ($dpi -ge 96 -and [math]::Abs(($dpi / 96.0) - $script:UiScale) -gt 0.01) {
                    $script:UiScale = $dpi / 96.0
                    $script:UiFontCache = @{}
                    $sz = Get-UiWindowSize
                    $sender.ClientSize = New-Object System.Drawing.Size -ArgumentList $sz.W, $sz.H
                }
                if ([Environment]::OSVersion.Version.Build -ge 22000) {
                    $pref = 2   # DWMWCP_ROUND
                    [void][BalanceTray.Dwm]::DwmSetWindowAttribute($sender.Handle, 33, [ref]$pref, 4)
                } else {
                    $rr = New-RoundRectPath 0 0 $sender.ClientSize.Width $sender.ClientSize.Height (10 * $script:UiScale)
                    $sender.Region = New-Object System.Drawing.Region -ArgumentList $rr
                    $rr.Dispose()
                }
            } catch { }
        })

        $f.Add_Paint({
            param($sender, $e)
            try { Draw-DetailsUi -G $e.Graphics -W $sender.ClientSize.Width -H $sender.ClientSize.Height } catch { }
        })

        $f.Add_MouseMove({
            param($sender, $e)
            try {
                if ($script:UiDragging) {
                    $now = [System.Windows.Forms.Cursor]::Position
                    $sender.Location = New-Object System.Drawing.Point `
                        (($script:UiDragFormLoc.X + $now.X - $script:UiDragCursor.X)),
                        (($script:UiDragFormLoc.Y + $now.Y - $script:UiDragCursor.Y))
                    return
                }
                $hit = $null
                $closeRect = Get-UiCloseRect -W $sender.ClientSize.Width
                if ($closeRect.Contains($e.X, $e.Y)) {
                    $hit = 'close'
                } else {
                    foreach ($b in $script:UiButtons) {
                        if ($e.X -ge $b.X -and $e.X -le ($b.X + $b.W) -and $e.Y -ge $b.Y -and $e.Y -le ($b.Y + $b.H)) { $hit = $b.Key; break }
                    }
                }
                if ($hit -ne $script:UiHover) {
                    $script:UiHover = $hit
                    if ($hit) { $sender.Cursor = [System.Windows.Forms.Cursors]::Hand }
                    else { $sender.Cursor = [System.Windows.Forms.Cursors]::Default }
                    $sender.Invalidate()
                }
            } catch { }
        })

        $f.Add_MouseLeave({
            param($sender, $e)
            $script:UiHover = $null
            try { $sender.Cursor = [System.Windows.Forms.Cursors]::Default; $sender.Invalidate() } catch { }
        })

        $f.Add_MouseDown({
            param($sender, $e)
            try {
                if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                if ((Get-UiCloseRect -W $sender.ClientSize.Width).Contains($e.X, $e.Y)) { $sender.Close(); return }
                # 顶部区域 = 标题栏，可拖动
                if ($e.Y -lt (34 * $script:UiScale)) {
                    $script:UiDragging    = $true
                    $script:UiDragCursor  = [System.Windows.Forms.Cursor]::Position
                    $script:UiDragFormLoc = $sender.Location
                }
            } catch { }
        })

        $f.Add_MouseUp({
            param($sender, $e)
            $script:UiDragging = $false
            try {
                if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                foreach ($b in $script:UiButtons) {
                    if ($e.X -ge $b.X -and $e.X -le ($b.X + $b.W) -and $e.Y -ge $b.Y -and $e.Y -le ($b.Y + $b.H)) {
                        switch ($b.Key) {
                            'refresh' { Start-BalanceFetch -Force }
                            'copy'    { Copy-BalanceToClipboard }
                            'open'    {
                                $mode = ''
                                if ($script:State) { $mode = [string]$script:State.mode }
                                if ($mode -eq 'platform') { Start-Process 'https://platform.deepseek.com/top_up' }
                                elseif ($mode -eq 'balance') { Start-Process 'https://platform.deepseek.com/usage' }
                                else { Start-Process (Join-Path $env:USERPROFILE '.dsh\sessions') }
                            }
                        }
                        break
                    }
                }
            } catch { }
        })

        $f.Add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.Close() }
        })

        $f.Add_FormClosed({
            $script:DetailsForm = $null
            $script:UiHover = $null
            $script:UiDragging = $false
            foreach ($font in $script:UiFontCache.Values) { try { $font.Dispose() } catch { } }
            $script:UiFontCache = @{}
        })

        $script:DetailsForm = $f
        $script:UiHover = $null
        [void]$f.Show()
        try { $f.Activate() } catch { }
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "详情窗创建失败: $($_.Exception.Message)" -Level 'ERROR'
        $script:DetailsForm = $null
    }
}
