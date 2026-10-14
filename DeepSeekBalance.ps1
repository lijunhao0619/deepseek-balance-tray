#requires -version 5.1
<#
    DeepSeekBalance.ps1
    ------------------------------------------------------------------
    DeepSeek 余额查询核心库（被 BalanceTray.ps1 / Test-Balance.ps1 共用）

    对外函数：
      Get-BalanceConfig        读取 config.json（带默认值 + 环境变量兜底）
      Save-BalanceConfig       回写 config.json（菜单里切换选项时用）
      Get-DeepSeekBalance      请求 /user/balance 并返回标准化状态对象
      New-BalanceIconBitmap    把余额渲染成托盘图标位图
      Get-BalanceTooltip       生成托盘悬停提示（<=63 字符）
      Get-BalanceIconText      生成图标上的短数字
      Format-Money             格式化金额
      Add-BalanceHistory       追加一行历史 CSV
      Read-BalanceHistory      读取历史 CSV
      Write-BalanceLog         写日志（带自动截断）

    接口依据：https://api-docs.deepseek.com/zh-cn/api/get-user-balance
      GET /user/balance
      Authorization: Bearer <API_KEY>
      200 -> { is_available, balance_infos[] { currency, total_balance,
                                               granted_balance, topped_up_balance } }
#>

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# 严重程度 -> 颜色（图标底色 / 气泡 / 文字）
$script:SeverityColors = @{
    ok       = '#1F9D55'   # 绿：余额充足
    low      = '#D98E04'   # 琥珀：低于 lowThreshold
    critical = '#D64545'   # 红：低于 criticalThreshold
    error    = '#8A8F98'   # 灰：请求失败
    loading  = '#4A7DBF'   # 蓝：正在刷新
}

$script:ConfigKeys = @(
    'dataSource', 'apiKey', 'apiKeyProtected', 'baseUrl', 'refreshSeconds', 'lowThreshold', 'criticalThreshold',
    'preferCurrency', 'iconMode', 'iconShowSymbol', 'notifyOnLow', 'notifyOnDrop', 'notifyOnStart',
    'timeoutSeconds', 'proxy',
    'nodePath', 'usageIconMetric', 'dailyWarnCost', 'dailyCriticalCost', 'usageHistoryDays', 'pricing'
)

# ---------------------------------------------------------------- 配置

function Get-BalanceConfig {
    [CmdletBinding()]
    param([string]$Path)

    $defaults = [ordered]@{
        dataSource        = 'platform' # platform=账号余额（无需 key） | usage=本地用量 | balance=开放平台 API Key
        apiKey            = ''
        apiKeyProtected   = ''         # DPAPI 加密后的 Key（Base64），填了就优先用它
        baseUrl           = 'https://api.deepseek.com'
        refreshSeconds    = 60
        lowThreshold      = 20.0
        criticalThreshold = 5.0
        preferCurrency    = 'CNY'
        iconMode          = 'amount'   # amount | dot
        iconShowSymbol    = $false
        notifyOnLow       = $true
        notifyOnDrop      = $false     # 扣费提醒默认关，避免每次调用都弹气泡
        notifyOnStart     = $true      # 启动后弹一次气泡，告诉你图标在哪儿
        timeoutSeconds    = 20
        proxy             = ''
        # ---- 本地用量模式
        nodePath          = ''         # 留空自动找 DSH 自带运行时
        usageIconMetric   = 'cost'     # cost=今日折算花费 | tokens=今日 token
        dailyWarnCost     = 5.0        # 今日花费超过这个数变琥珀色
        dailyCriticalCost = 20.0       # 超过这个数变红色
        usageHistoryDays  = 14
    }

    $cfg = @{}
    foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }

    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'config.json' }
    if (Test-Path -LiteralPath $Path) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                foreach ($p in $obj.PSObject.Properties) {
                    if ($null -ne $p.Value -and "$($p.Value)" -ne '') { $cfg[$p.Name] = $p.Value }
                }
            }
        } catch {
            Write-Warning "config.json 解析失败（将使用默认值）: $($_.Exception.Message)"
        }
    }

    # 环境变量优先级低于配置文件，仅在配置为空时兜底
    if ([string]::IsNullOrWhiteSpace([string]$cfg['apiKey']) -and $env:DEEPSEEK_API_KEY) {
        $cfg['apiKey'] = $env:DEEPSEEK_API_KEY
    }

    $cfg['__path'] = $Path
    return $cfg
}

function Save-BalanceConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [string]$Path
    )
    if (-not $Path) { $Path = [string]$Config['__path'] }
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $PSScriptRoot 'config.json' }

    $out = [ordered]@{}
    foreach ($k in $script:ConfigKeys) {
        if ($Config.ContainsKey($k)) { $out[$k] = $Config[$k] }
    }
    ($out | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

# ---------------------------------------------------------------- 工具

# ---------------------------------------------------------------- 密钥读取 / 加密

function Get-BalanceApiKey {
    <#
        返回明文 API Key：apiKeyProtected（DPAPI，绑定当前 Windows 账号）优先，
        否则用 config.json 里的明文 apiKey，最后回退到环境变量 DEEPSEEK_API_KEY。
    #>
    [CmdletBinding()]
    param([hashtable]$Config)

    $protected = [string]$Config['apiKeyProtected']
    if (-not [string]::IsNullOrWhiteSpace($protected)) {
        try {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $enc   = [Convert]::FromBase64String($protected.Trim())
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                        $enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            return [Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            Write-Warning "API Key 解密失败（换了 Windows 账号或配置文件被复制到别的机器？）：$($_.Exception.Message)"
            return ''
        }
    }

    $plain = [string]$Config['apiKey']
    if (-not [string]::IsNullOrWhiteSpace($plain)) { return $plain.Trim() }
    return ''
}

function Protect-BalanceApiKey {
    <#
        把 config.json 里的明文 Key 换成 DPAPI 密文（只能用当前 Windows 账号解开）。
        $Config 会被就地修改并写回磁盘。
    #>
    [CmdletBinding()]
    param([hashtable]$Config, [string]$Path)

    $plain = [string]$Config['apiKey']
    if ([string]::IsNullOrWhiteSpace($plain)) { throw '当前配置里没有明文 API Key 可加密' }

    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $bytes = [Text.Encoding]::UTF8.GetBytes($plain.Trim())
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)

    $Config['apiKeyProtected'] = [Convert]::ToBase64String($enc)
    $Config['apiKey'] = ''
    return (Save-BalanceConfig -Config $Config -Path $Path)
}

function ConvertTo-DoubleSafe {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    $d = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return 0.0
}

function Format-Money {
    [CmdletBinding()]
    param(
        [double]$Value,
        [string]$Currency = 'CNY',
        [switch]$NoSymbol
    )
    $sym = ''
    if (-not $NoSymbol) {
        switch ("$Currency".ToUpperInvariant()) {
            'CNY' { $sym = '¥' }
            'USD' { $sym = '$' }
            default { $sym = "$Currency " }
        }
    }
    return ('{0}{1:N2}' -f $sym, $Value)
}

# 托盘图标上的短数字：尽量控制在 3-4 个字符，16px 的通知区域里才勉强可读
function Get-BalanceIconText {
    [CmdletBinding()]
    param([double]$Value, [string]$Currency = 'CNY', [switch]$WithSymbol)

    $abs = [math]::Abs($Value)
    if ($abs -ge 10000)    { $t = ('{0:0}k'   -f ($Value / 1000)) }
    elseif ($abs -ge 1000) { $t = ('{0:0.0}k' -f ($Value / 1000)) }
    elseif ($abs -ge 10)   { $t = ('{0:0}'    -f $Value) }
    elseif ($abs -ge 0.1)  { $t = ('{0:0.0}'  -f $Value) }
    else                   { $t = ('{0:0.00}' -f $Value) }

    if ($WithSymbol) {
        switch ("$Currency".ToUpperInvariant()) {
            'CNY' { $t = "¥$t" }
            'USD' { $t = "$$t" }
        }
    }
    return $t
}

function Get-BalanceSeverity {
    param([double]$Value, [double]$Low, [double]$Critical)
    if ($Value -le $Critical) { return 'critical' }
    if ($Value -le $Low)      { return 'low' }
    return 'ok'
}

function Merge-Hashtable {
    <#
        合并两个哈希表，后者覆盖前者。
        注意：不能用 $a + $b —— PowerShell 的哈希表相加是 .Add() 语义，
        键重复时会抛 "Item has already been added"。
    #>
    [CmdletBinding()]
    param([hashtable]$Base, [hashtable]$Overrides)
    $out = @{}
    if ($Base)      { foreach ($k in $Base.Keys)      { $out[$k] = $Base[$k] } }
    if ($Overrides) { foreach ($k in $Overrides.Keys) { $out[$k] = $Overrides[$k] } }
    return $out
}

# ---------------------------------------------------------------- 绘制工具

function Get-ShiftColor {
    <# 把颜色整体提亮（Delta>0）或压暗（Delta<0），保持透明度 #>
    [CmdletBinding()]
    param([System.Drawing.Color]$C, [int]$Delta)
    $r = [int][math]::Max(0, [math]::Min(255, $C.R + $Delta))
    $g = [int][math]::Max(0, [math]::Min(255, $C.G + $Delta))
    $b = [int][math]::Max(0, [math]::Min(255, $C.B + $Delta))
    return [System.Drawing.Color]::FromArgb($C.A, $r, $g, $b)
}

function New-RoundRectPath {
    <# 圆角矩形 GraphicsPath；半径为 0 时退化成直角矩形 #>
    [CmdletBinding()]
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0 -or $W -le 0 -or $H -le 0) {
        $p.AddRectangle((New-Object System.Drawing.RectangleF -ArgumentList $X, $Y, $W, $H))
        return $p
    }
    $d = $R * 2
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# ---------------------------------------------------------------- 图标渲染

function New-BalanceIconBitmap {
    <#
        生成托盘图标位图：圆角方块底色 + 居中白色粗体文字。
        32x32 起步，Windows 会按 DPI 缩放；字号自动收缩以塞进图标。
    #>
    [CmdletBinding()]
    param(
        [string]$Text  = '?',
        [string]$Color = '#8A8F98',
        [int]$Size     = 32
    )

    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    # 圆角方块（偏 squircle）+ 竖向渐变 + 顶部玻璃高光，比纯色块立体得多
    $radius = [single][math]::Max(3, $Size * 0.30)
    $path = New-RoundRectPath 0 0 $Size $Size $radius
    $base = [System.Drawing.ColorTranslator]::FromHtml($Color)
    $cTop = Get-ShiftColor -C $base -Delta 30
    $cBot = Get-ShiftColor -C $base -Delta -22
    $pt0  = New-Object System.Drawing.PointF -ArgumentList 0, 0
    $pt1  = New-Object System.Drawing.PointF -ArgumentList 0, $Size
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $pt0, $pt1, $cTop, $cBot
    $g.FillPath($grad, $path)

    # 顶部高光（白到透明）
    $glossH  = [single]($Size * 0.48)
    $gloss   = New-RoundRectPath 1 1 ($Size - 2) $glossH ([single]($radius * 0.8))
    $gp0     = New-Object System.Drawing.PointF -ArgumentList 0, 1
    $gp1     = New-Object System.Drawing.PointF -ArgumentList 0, (1 + $glossH)
    $glossBr = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList `
        $gp0, $gp1,
        ([System.Drawing.Color]::FromArgb(54, 255, 255, 255)),
        ([System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    $g.FillPath($glossBr, $gloss)

    # 文字（自动缩放字号直到放得下）
    # 关键：必须显式 NoWrap，否则 DrawString 会在矩形内自动折行，数字被拆成两行
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.FormatFlags   = [System.Drawing.StringFormatFlags]::NoWrap

    $maxW = [single]($Size * 0.84)
    $maxH = [single]($Size * 0.62)
    $origin = New-Object System.Drawing.PointF -ArgumentList 0, 0
    $fontSize = [single]($Size * 0.50)
    $font = $null
    while ($fontSize -ge 5) {
        $try = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', $fontSize,
                    ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        # 不带布局矩形测量 = 真实不换行尺寸
        $measured = $g.MeasureString($Text, $try, $origin, $sf)
        if ($measured.Width -le $maxW -and $measured.Height -le $maxH) { $font = $try; break }
        $try.Dispose()
        $fontSize = [single]($fontSize - 0.5)
    }
    if ($null -eq $font) {
        $font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', ([single]6),
                    ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    }

    # 文字：先画一层很淡的下移阴影，再压白色，缩到 16px 时更立得住
    $rect   = New-Object System.Drawing.RectangleF -ArgumentList 0, 0, ([single]$Size), ([single]$Size)
    $shRect = New-Object System.Drawing.RectangleF -ArgumentList 0, ([single]($Size * 0.04)), ([single]$Size), ([single]$Size)
    $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(58, 0, 0, 0))
    $g.DrawString($Text, $font, $shadow, $shRect, $sf)
    $fg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.DrawString($Text, $font, $fg, $rect, $sf)

    $fg.Dispose(); $shadow.Dispose(); $font.Dispose(); $grad.Dispose(); $glossBr.Dispose()
    $path.Dispose(); $gloss.Dispose(); $g.Dispose()
    return $bmp
}

function Get-BalanceTooltip {
    <#
        托盘悬停提示。刻意使用单行：Win32 通知区域的 szTip 本质是单行字符串，
        换行符在多数 Windows 版本上不会正常折行。完整信息在详情窗口（左键点击）。
        NotifyIcon.Text 上限 63 字符。
    #>
    [CmdletBinding()]
    param($State, [int]$RefreshSeconds = 60)

    if ($State -and $State.ok) {
        $stamp = (Get-Date).ToString('HH:mm')
        try { if ($State.fetchedAt) { $stamp = $State.fetchedAt.ToString('HH:mm') } } catch { }
        $t = 'DeepSeek {0} ｜ 赠金 {1} ｜ 充值 {2} ｜ {3} 更新' -f `
            (Format-Money -Value $State.total -Currency $State.currency),
            (Format-Money -Value $State.granted -Currency $State.currency),
            (Format-Money -Value $State.toppedUp -Currency $State.currency),
            $stamp
    } elseif ($State -and $State.error) {
        $t = "DeepSeek 余额获取失败：$($State.error)"
    } else {
        $t = 'DeepSeek 余额加载中…'
    }

    if ($t.Length -gt 63) { $t = $t.Substring(0, 62) + '…' }
    return $t
}

# ---------------------------------------------------------------- 历史 / 日志

function Add-BalanceHistory {
    [CmdletBinding()]
    param($State, [string]$Path)
    if (-not $State -or -not $State.ok) { return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            'time,currency,total,granted,topped_up' | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        $line = '{0},{1},{2},{3},{4}' -f $State.fetchedAt.ToString('yyyy-MM-dd HH:mm:ss'),
                $State.currency,
                $State.total.ToString([Globalization.CultureInfo]::InvariantCulture),
                $State.granted.ToString([Globalization.CultureInfo]::InvariantCulture),
                $State.toppedUp.ToString([Globalization.CultureInfo]::InvariantCulture)
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    } catch { }
}

function Read-BalanceHistory {
    [CmdletBinding()]
    param([string]$Path, [int]$Max = 120)
    $result = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    try {
        $rows = Import-Csv -LiteralPath $Path
        if ($rows.Count -gt $Max) { $rows = $rows[($rows.Count - $Max)..($rows.Count - 1)] }
        foreach ($r in $rows) {
            $null = $result.Add([pscustomobject]@{
                time  = "$($r.time)"
                total = ConvertTo-DoubleSafe $r.total
            })
        }
    } catch { }
    return $result
}

function Write-BalanceLog {
    [CmdletBinding()]
    param([string]$Path, [string]$Message, [string]$Level = 'INFO')
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
        # 日志超过 800 行就截断保留最后 400 行
        $all = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
        if ($all.Count -gt 800) {
            $all[-400..-1] | Set-Content -LiteralPath $Path -Encoding UTF8
        }
    } catch { }
}

# ---------------------------------------------------------------- 余额查询

function Get-DeepSeekBalance {
    <#
        请求 GET {baseUrl}/user/balance，返回标准化状态对象：
        ok / isAvailable / infos / currency / total / granted / toppedUp /
        severity / iconText / color / tooltip / fetchedAt / latencyMs / error / kind / status
    #>
    [CmdletBinding()]
    param([hashtable]$Config)

    if (-not $Config) { $Config = Get-BalanceConfig }

    $Base = [string]$Config['baseUrl']
    if ([string]::IsNullOrWhiteSpace($Base)) { $Base = 'https://api.deepseek.com' }
    $Url = "$($Base.TrimEnd('/'))/user/balance"

    $Key = Get-BalanceApiKey -Config $Config
    if (-not [string]::IsNullOrWhiteSpace($Key)) { $Key = $Key.Trim() }

    $Low      = ConvertTo-DoubleSafe $Config['lowThreshold']
    $Critical = ConvertTo-DoubleSafe $Config['criticalThreshold']
    $Prefer   = [string]$Config['preferCurrency']

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return [pscustomobject]@{
            ok = $false; kind = 'config'; error = '未配置 API Key（请编辑 config.json 或设置 DEEPSEEK_API_KEY）'
            infos = @(); fetchedAt = (Get-Date)
        }
    }

    # PS 5.1 默认可能还是 TLS 1.0，DeepSeek 需要 1.2+
    try {
        $protos = [Net.SecurityProtocolType]::Tls12
        try { $protos = $protos -bor [Net.SecurityProtocolType]::Tls11 } catch { }
        [Net.ServicePointManager]::SecurityProtocol = $protos
    } catch { }

    $Timeout = 20
    try { $Timeout = [int]$Config['timeoutSeconds'] } catch { }
    if ($Timeout -lt 5) { $Timeout = 5 }

    $params = @{
        Uri        = $Url
        Method     = 'Get'
        Headers    = @{ Authorization = "Bearer $Key"; Accept = 'application/json' }
        TimeoutSec = $Timeout
        ErrorAction = 'Stop'
    }
    $proxy = [string]$Config['proxy']
    if (-not [string]::IsNullOrWhiteSpace($proxy)) { $params['Proxy'] = $proxy.Trim() }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $payload = Invoke-RestMethod @params
        $sw.Stop()
    } catch {
        $sw.Stop()
        $status = $null
        $body   = $null
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        try {
            if ($_.Exception.Response) {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader -ArgumentList $stream
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            }
        } catch { }

        $msg  = $_.Exception.Message
        $kind = 'network'
        $human = '网络不可达'
        if ($status -eq 401) {
            $kind = 'auth'
            $human = 'API Key 无效或已被撤销'
            # 免得多花时间排查：DeepSeek 的 Key 一律以 sk- 开头
            if ($Key -notmatch '^sk-') { $human += '（当前 Key 不以 sk- 开头，很可能填错了）' }
        }
        elseif ($status -eq 402) { $kind = 'balance'; $human = '账户余额不足' }
        elseif ($status -eq 422) { $kind = 'param';   $human = '请求参数不合法 (HTTP 422)' }
        elseif ($status -eq 429) { $kind = 'rate';    $human = '请求过于频繁，请稍后重试' }
        elseif ($status -ge 500) { $kind = 'server';  $human = "DeepSeek 服务端错误 (HTTP $status)" }
        elseif ($status -ge 400) { $kind = 'http';    $human = "请求被拒绝 (HTTP $status)" }
        else {
            if     ($msg -match '超时|timeout|timed out')          { $human = '请求超时' }
            elseif ($msg -match '名称解析|resolve|remote name')     { $human = 'DNS 解析失败' }
            elseif ($msg -match '代理|proxy|407')                   { $human = '代理连接失败' }
            elseif ($msg -match 'SSL|TLS|信任|trust')               { $human = 'TLS/证书握手失败' }
        }
        if ($body) {
            try {
                $j = $body | ConvertFrom-Json
                if ($j.error.message) { $human = "$human — $($j.error.message)" }
            } catch { }
        }

        return [pscustomobject]@{
            ok        = $false
            kind      = $kind
            status    = $status
            error     = $human
            detail    = $msg
            infos     = @()
            fetchedAt = (Get-Date)
            latencyMs = $sw.ElapsedMilliseconds
            severity  = 'error'
            color     = $script:SeverityColors['error']
            iconText  = '!'
        }
    }

    # ---- 解析成功响应
    $infos = New-Object System.Collections.ArrayList
    $isAvailable = $true
    try { if ($null -ne $payload.is_available) { $isAvailable = [bool]$payload.is_available } } catch { }
    foreach ($b in @($payload.balance_infos)) {
        if ($null -eq $b) { continue }
        $null = $infos.Add([pscustomobject]@{
            currency = [string]$b.currency
            total    = ConvertTo-DoubleSafe $b.total_balance
            granted  = ConvertTo-DoubleSafe $b.granted_balance
            toppedUp = ConvertTo-DoubleSafe $b.topped_up_balance
        })
    }

    if ($infos.Count -eq 0) {
        return [pscustomobject]@{
            ok = $false; kind = 'parse'; error = '响应中没有 balance_infos 数据'
            infos = $infos; fetchedAt = (Get-Date); latencyMs = $sw.ElapsedMilliseconds
            severity = 'error'; color = $script:SeverityColors['error']; iconText = '!'
        }
    }

    # 选一个用于主显示的币种：preferCurrency 命中优先，否则 CNY，再否则第一个
    $primary = $infos[0]
    if (-not [string]::IsNullOrWhiteSpace($Prefer) -and $Prefer -ne 'auto') {
        $hit = $infos | Where-Object { "$($_.currency)".ToUpperInvariant() -eq $Prefer.ToUpperInvariant() } | Select-Object -First 1
        if ($hit) { $primary = $hit }
    } else {
        $hit = $infos | Where-Object { "$($_.currency)".ToUpperInvariant() -eq 'CNY' } | Select-Object -First 1
        if ($hit) { $primary = $hit }
    }

    $severity = Get-BalanceSeverity -Value $primary.total -Low $Low -Critical $Critical
    $iconText = Get-BalanceIconText -Value $primary.total -Currency $primary.currency `
                                    -WithSymbol:([bool]$Config['iconShowSymbol'])

    $state = [pscustomobject]@{
        ok          = $true
        isAvailable = $isAvailable
        infos       = $infos
        currency    = $primary.currency
        total       = $primary.total
        granted     = $primary.granted
        toppedUp    = $primary.toppedUp
        severity    = $severity
        color       = $script:SeverityColors[$severity]
        iconText    = $iconText
        fetchedAt   = (Get-Date)
        latencyMs   = $sw.ElapsedMilliseconds
        error       = $null
        kind        = $null
    }
    $state | Add-Member -NotePropertyName tooltip -NotePropertyValue (Get-BalanceTooltip -State $state -RefreshSeconds ([int]$Config['refreshSeconds'])) -Force
    return $state
}

function ConvertTo-BalanceState {
    <#
        把余额查询结果标准化成界面 state。
        和 ConvertTo-UsageState 输出同一套字段，详情窗只认这套结构：
          mode / ok / severity / hero / iconText / rows[] / meta / chart[] / chartLabel / tooltip / error
    #>
    [CmdletBinding()]
    param($State, [hashtable]$Config)

    $base = @{
        mode       = 'balance'
        currency   = 'CNY'
        fetchedAt  = (Get-Date)
        rows       = @()
        stats      = @()
        chart      = @()
        chartLabel = '余额走势'
        raw        = $State
    }

    if (-not $State -or -not $State.ok) {
        $msg = '余额数据暂时不可用'
        if ($State -and $State.error) { $msg = [string]$State.error }
        return [pscustomobject](Merge-Hashtable $base @{
            ok = $false; severity = 'error'; iconText = '!'
            hero = '暂时拿不到余额'; meta = $msg; error = $msg; stats = @()
        })
    }

    $chart = @()
    foreach ($h in @($script:History)) {
        $t = [string]$h.time
        if ($t.Length -ge 10) { $t = $t.Substring(5, 5) }
        $chart += @{ label = $t; value = [double]$h.total }
    }

    # 字段全部做防御式取值：接口结构变动或演示数据不完整时不至于崩
    $stamp = (Get-Date).ToString('HH:mm:ss')
    try { if ($State.fetchedAt) { $stamp = $State.fetchedAt.ToString('HH:mm:ss') } } catch { }
    $latency = 0
    try { if ($null -ne $State.latencyMs) { $latency = [int]$State.latencyMs } } catch { }
    $availNote = ''
    try { if ($State.isAvailable -eq $false) { $availNote = ' · 账户不可用' } } catch { }

    $st = [pscustomobject](Merge-Hashtable $base @{
        ok         = $true
        severity   = $State.severity
        currency   = $State.currency
        hero       = (Format-Money -Value $State.total -Currency $State.currency)
        heroLabel  = '账户余额'
        iconText   = $State.iconText
        rows       = @(
            @{ label = '赠金'; value = (Format-Money -Value $State.granted  -Currency $State.currency) },
            @{ label = '充值'; value = (Format-Money -Value $State.toppedUp -Currency $State.currency) }
        )
        meta       = '{0} 更新 · 每 {1} 秒刷新 · 延迟 {2}ms{3}' -f `
                        $stamp, [int]$Config['refreshSeconds'], $latency, $availNote
        chart      = $chart
        total      = $State.total
        granted    = $State.granted
        toppedUp   = $State.toppedUp
    })
    $st | Add-Member -NotePropertyName tooltip -Force -NotePropertyValue `
        (Get-BalanceTooltip -State $State -RefreshSeconds ([int]$Config['refreshSeconds']))
    return $st
}
