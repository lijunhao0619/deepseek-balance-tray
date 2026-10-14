#requires -version 5.1
<#
    BalanceTray.ps1 —— DeepSeek 余额系统托盘（零依赖：Windows PowerShell + WinForms）

    用法：
      双击 Start-BalanceTray.vbs        （无控制台窗口，推荐）
      powershell -ExecutionPolicy Bypass -File .\BalanceTray.ps1   （调试用）

    特性：
      · 托盘图标直接渲染余额数字，颜色随余额分级（绿/琥珀/红/灰）
      · 悬停显示总余额 / 赠金 / 充值 / 更新时间
      · 左键点击打开详情窗（含余额历史折线）
      · 右键菜单：立即刷新、刷新间隔、低余额提醒、扣费提醒、开机自启等
      · 后台线程异步刷新，不会卡住菜单
      · 网络/鉴权异常只改图标与提示，不会崩掉进程

    测试参数（仅自动化用）：
      -ExitAfterSeconds 8   运行 8 秒后自动退出
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$ExitAfterSeconds = 0,
    [double]$SimulateBalance = -1,  # >=0 时进入离线演示模式，不联网，用假数据走完整流程
    [string]$CaptureUi = '',        # 指定 PNG 路径时，只渲染详情窗口截图后退出（自动化验收用）
    [switch]$ShowPanel              # 启动后自动弹出详情窗口（手动双击快捷方式时用）
)

$ErrorActionPreference = 'Stop'

$script:Root        = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'config.json' }
$script:ConfigPath  = $ConfigPath
$script:LogPath     = Join-Path $script:Root 'run.log'
$script:HistoryPath = Join-Path $script:Root 'history.csv'
$script:LibPath     = Join-Path $script:Root 'DeepSeekBalance.ps1'

# ------------------------------------------------------------------ BOM 自检
# PowerShell 5.1 读 .ps1 时：有 UTF-8 BOM 才按 UTF-8 解析，没有就按系统 ANSI(GBK) 解析。
# 这些脚本里有中文注释，一旦 BOM 丢失，中文会被错解并吃掉字符串引号，
# 结果就是 dot-source 时整份脚本解析失败、进程静默退出（无窗口启动时错误根本看不到）。
# 编辑器/工具改写文件很容易把 BOM 弄丢，所以启动时先自检补回。
function Repair-AuxScriptBom {
    param([string]$Path)
    try {
        $b = @(Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 3 -ErrorAction Stop)
        if ($b.Count -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return $false }
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        Set-Content -LiteralPath $Path -Value $text -Encoding UTF8 -NoNewline
        return $true
    } catch {
        return $false
    }
}

foreach ($dep in 'DeepSeekBalance.ps1', 'Usage.ps1', 'Platform.ps1', 'Autostart.ps1', 'DetailsWindow.ps1') {
    $depPath = Join-Path $script:Root $dep
    if (-not (Test-Path -LiteralPath $depPath)) { continue }
    if (Repair-AuxScriptBom -Path $depPath) {
        try {
            Add-Content -LiteralPath $script:LogPath -Encoding UTF8 `
                -Value ('{0} [WARN] 依赖脚本缺少 UTF-8 BOM，已自动修复：{1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $dep)
        } catch { }
    }
}

. $script:LibPath
. (Join-Path $script:Root 'Usage.ps1')
. (Join-Path $script:Root 'Platform.ps1')
. (Join-Path $script:Root 'Autostart.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('BalanceTray.Win32' -as [type])) {
    Add-Type -Namespace BalanceTray -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@
}

if (-not ('BalanceTray.Dpi' -as [type])) {
    Add-Type -Namespace BalanceTray -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetDpiForSystem();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetDpiForWindow(System.IntPtr hwnd);
'@
}

# ------------------------------------------------------------------ DPI 感知
# 这一步必须在创建任何窗口之前做。
# 不声明的后果：系统按 96 DPI 渲染，再按显示缩放把整张位图拉伸 —— 150% 下就是整体发糊。
$dpiDeclared = $false
try { $dpiDeclared = [BalanceTray.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) } catch { }   # PER_MONITOR_AWARE_V2
if (-not $dpiDeclared) { try { [void][BalanceTray.Dpi]::SetProcessDPIAware() } catch { } }

$script:SystemDpi = 96
try {
    $d = [int][BalanceTray.Dpi]::GetDpiForSystem()
    if ($d -ge 96) { $script:SystemDpi = $d }
} catch { }
$script:UiScale = $script:SystemDpi / 96.0
# 托盘图标按 16 逻辑像素算，150% -> 24 物理像素，正好是 Windows 想要的大小，不需要它再缩放
$script:TrayIconSize = [int][math]::Max(16, [math]::Round(16 * $script:UiScale))

# Win10 1809+ 的暗色标题栏（属性 20；旧版本用 19）
if (-not ('BalanceTray.Dwm' -as [type])) {
    Add-Type -Namespace BalanceTray -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll", SetLastError = true)]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);
'@
}

# ------------------------------------------------------------------ 单实例检查
# 托盘程序是无窗口启动的，用户看不到任何反馈就很容易反复双击，结果堆出一串图标。
# 第二次启动时直接弹个框告诉他「已经在跑了 + 图标在哪」，比默默再开一个有用得多。
$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\DeepSeekUsageTray')
$script:IsFirstInstance = $false
try { $script:IsFirstInstance = $script:InstanceMutex.WaitOne(0, $false) } catch { $script:IsFirstInstance = $true }

if (-not $script:IsFirstInstance -and -not $CaptureUi -and $ExitAfterSeconds -le 0) {
    Write-BalanceLog -Path $script:LogPath -Message '检测到已有实例在运行，本次不再重复启动'
    $msg = "DeepSeek 用量托盘已经在运行了，不用再开一个。`r`n`r`n" +
           "图标在右下角通知区域。`r`n" +
           "Windows 11 默认把它收进「^」溢出菜单里 —— 展开后把图标拖到任务栏上就能固定住。`r`n`r`n" +
           "左键单击托盘图标可以打开详情窗口。"
    # 用 WScript.Shell.Popup 而不是 MessageBox：前者带超时会自己关掉，
    # 万一没人点也不至于留一个看不见的进程挂在那里。
    try {
        $shPopup = New-Object -ComObject WScript.Shell
        [void]$shPopup.Popup($msg, 20, 'DeepSeek 用量', 64)   # 64 = 信息图标，20 秒后自动关闭
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'DeepSeek 用量', 'OK', 'Information')
    }
    return
}

# ------------------------------------------------------------------ 状态
$script:Config          = Get-BalanceConfig -Path $script:ConfigPath
$script:State           = $null
$script:PrevTotal       = $null
$script:LastNotifyKey   = $null
$script:IconHandle      = [IntPtr]::Zero
$script:IconObject      = $null
$script:FetchPs         = $null
$script:FetchHandle     = $null
$script:FetchRunspace   = $null
$script:DetailsForm     = $null
$script:NextRefresh     = [datetime]::MinValue
$script:FailStreak      = 0
$script:SimulateBalance = $SimulateBalance
$script:StartedAt       = Get-Date
$script:History         = Read-BalanceHistory -Path $script:HistoryPath -Max 120
$script:StartBalloonShown = $false
$script:ShowPanelPending  = [bool]$ShowPanel
$script:EverOk            = $false

Write-BalanceLog -Path $script:LogPath -Message "托盘启动 pid=$PID config=$($script:ConfigPath)"

# ------------------------------------------------------------------ 图标 / 提示

function Set-TrayIcon {
    param([string]$Text, [string]$Color)
    try {
        $bmp   = New-BalanceIconBitmap -Text $Text -Color $Color -Size $script:TrayIconSize
        $hIcon = $bmp.GetHicon()
        $icon  = [System.Drawing.Icon]::FromHandle($hIcon)
        $script:NotifyIcon.Icon = $icon
        # 换完再销毁上一代句柄，避免 GDI 句柄泄漏
        if ($script:IconHandle -ne [IntPtr]::Zero) {
            [void][BalanceTray.Win32]::DestroyIcon($script:IconHandle)
        }
        $script:IconHandle = $hIcon
        $script:IconObject = $icon
        $bmp.Dispose()
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "图标渲染失败: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Set-TrayTooltip {
    param([string]$Text)
    try {
        if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 62) + '…' }
        $script:NotifyIcon.Text = $Text
    } catch {
        try { $script:NotifyIcon.Text = 'DeepSeek 余额' } catch { }
    }
}

# ------------------------------------------------------------------ 菜单

function New-MenuItem {
    param(
        [string]$Text,
        [scriptblock]$OnClick,
        [switch]$Checked,
        [switch]$Disabled
    )
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList $Text
    if ($Checked)  { $mi.Checked = $true }
    if ($Disabled) { $mi.Enabled = $false }
    if ($OnClick)  { $mi.Add_Click($OnClick) }
    return $mi
}

function Update-MenuState {
    try {
        $script:MiHead.Text = if ($script:State -and $script:State.ok) {
            "$($script:State.hero)  $($script:State.fetchedAt.ToString('HH:mm:ss'))"
        } elseif ($script:State) { "取不到数据：$($script:State.meta)" } else { '加载中…' }
        if ($script:MiHead.Text.Length -gt 46) { $script:MiHead.Text = $script:MiHead.Text.Substring(0, 45) + '…' }

        if ($script:MiSourceMap) {
            foreach ($kv in $script:MiSourceMap.GetEnumerator()) {
                $kv.Value.Checked = ([string]$script:Config['dataSource'] -eq [string]$kv.Key)
            }
        }

        $sec = [double]$script:Config['refreshSeconds']
        foreach ($pair in $script:MiIntervalMap.GetEnumerator()) {
            $pair.Value.Checked = ([math]::Abs($pair.Key - $sec) -lt 0.5)
        }
        $script:MiLow.Checked     = [bool]$script:Config['notifyOnLow']
        $script:MiDrop.Checked    = [bool]$script:Config['notifyOnDrop']
        $script:MiAmount.Checked  = ([string]$script:Config['iconMode'] -ne 'dot')
        $script:MiAutostart.Checked = (Test-BalanceAutostart)
        if ($script:DetailsForm -and -not $script:DetailsForm.IsDisposed) { Update-DetailsWindow }
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "菜单状态刷新失败: $($_.Exception.Message)" -Level 'WARN'
    }
}

# ------------------------------------------------------------------ 详情窗口
# 界面实现在 DetailsWindow.ps1（无边框自绘卡片），这里只负责挂载
. (Join-Path $script:Root 'DetailsWindow.ps1')
# ------------------------------------------------------------------ 动作

function Copy-BalanceToClipboard {
    try {
        $s = $script:State
        if ($s -and $s.ok) {
            $rows = (@($s.rows) | ForEach-Object { "$($_.label) $($_.value)" }) -join ' / '
            $head = 'DeepSeek 今日折算花费'
            if ($s.mode -eq 'balance') { $head = 'DeepSeek 余额' }
            $text = "$head $($s.hero)"
            if ($rows) { $text += "（$rows）" }
        } elseif ($s) { $text = "DeepSeek 数据获取失败：$($s.meta)" } else { $text = 'DeepSeek 数据加载中' }
        [System.Windows.Forms.Clipboard]::SetText($text)
        $script:NotifyIcon.ShowBalloonTip(2500, '已复制', $text, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "复制失败: $($_.Exception.Message)" -Level 'WARN'
    }
}

function Set-RefreshInterval {
    param([int]$Seconds)
    $script:Config['refreshSeconds'] = $Seconds
    try { [void](Save-BalanceConfig -Config $script:Config -Path $script:ConfigPath) } catch {
        Write-BalanceLog -Path $script:LogPath -Message "配置写入失败: $($_.Exception.Message)" -Level 'WARN'
    }
    $script:NextRefresh = (Get-Date)
    Update-MenuState
    Write-BalanceLog -Path $script:LogPath -Message "刷新间隔改为 ${Seconds}s"
}

function Set-ConfigFlag {
    param([string]$Key, [bool]$Value)
    $script:Config[$Key] = $Value
    try { [void](Save-BalanceConfig -Config $script:Config -Path $script:ConfigPath) } catch {
        Write-BalanceLog -Path $script:LogPath -Message "配置写入失败: $($_.Exception.Message)" -Level 'WARN'
    }
    Update-MenuState
}

function Set-DataSource {
    <# 切换数据源：platform（账号余额，无需 key） / usage（本地用量） / balance（开放平台 API Key） #>
    param([string]$Key)
    if ($Key -ne 'usage' -and $Key -ne 'balance' -and $Key -ne 'platform') { return }
    $script:Config['dataSource'] = $Key
    try { [void](Save-BalanceConfig -Config $script:Config -Path $script:ConfigPath) } catch {
        Write-BalanceLog -Path $script:LogPath -Message "配置写入失败: $($_.Exception.Message)" -Level 'WARN'
    }
    $script:UsageCache = $null
    $script:State = $null
    $script:LastNotifyKey = $null
    $script:NextRefresh = (Get-Date)
    Write-BalanceLog -Path $script:LogPath -Message "数据源切换为 $Key"
    Start-BalanceFetch -Force
    Update-MenuState
}

function Toggle-Autostart {
    try {
        if (Test-BalanceAutostart) {
            [void](Uninstall-BalanceAutostart)
            Write-BalanceLog -Path $script:LogPath -Message '已关闭开机自启'
        } else {
            [void](Install-BalanceAutostart -Root $script:Root)
            Write-BalanceLog -Path $script:LogPath -Message '已开启开机自启'
        }
        Update-MenuState
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "开机自启设置失败: $($_.Exception.Message)" -Level 'ERROR'
        $script:NotifyIcon.ShowBalloonTip(4000, '开机自启设置失败', "$($_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# ------------------------------------------------------------------ 异步拉取

function Start-BalanceFetch {
    [CmdletBinding()]
    param([switch]$Force)

    # 离线演示模式：造数据走完整流程（不联网、不读日志），用于预览界面
    if ($script:SimulateBalance -ge 0) {
        $val = [double]$script:SimulateBalance

        if ([string]$script:Config['dataSource'] -eq 'usage') {
            $days = @()
            foreach ($i in 6..0) {
                $days += [pscustomobject]@{
                    date = (Get-Date).AddDays(-$i).ToString('yyyy-MM-dd')
                    cost = [math]::Round($val * (1 - $i * 0.08), 4)
                }
            }
            $fake = [pscustomobject]@{
                ok    = $true
                today = [pscustomobject]@{
                    date = (Get-Date).ToString('yyyy-MM-dd'); cost = $val
                    inputTokens = 391460; outputTokens = 369569; cacheReadTokens = 29067520
                    cacheWriteTokens = 0; totalTokens = 29828549
                    requests = 274; peakRequests = 125; offPeakRequests = 149
                }
                days  = $days
                files = [pscustomobject]@{ total = 6 }
            }
            Apply-BalanceState -State (ConvertTo-UsageState -Snapshot $fake -Config $script:Config)
        } elseif ([string]$script:Config['dataSource'] -eq 'platform') {
            # 演示用的假数字刻意取明显不真实的量级，避免截图被人误当成真实账单
            $days = @()
            foreach ($i in 6..0) {
                $days += [pscustomobject]@{
                    date = (Get-Date).AddDays(-$i).ToString('yyyy-MM-dd')
                    cost = [math]::Round(56.8 * (1 - $i * 0.08), 4)
                }
            }
            $fakeBal = [pscustomobject]@{
                ok = $true; currency = 'CNY'
                recharge = $val; bonus = 0.0; available = $val; lifetimeCost = 1234.56
            }
            $fakeUse = [pscustomobject]@{
                ok = $true
                today = [pscustomobject]@{ date = (Get-Date).ToString('yyyy-MM-dd'); cost = 56.78; totalTokens = 81005000 }
                days = $days
                files = [pscustomobject]@{ total = 6 }
            }
            Apply-BalanceState -State (ConvertTo-PlatformState -Balance $fakeBal -Usage $fakeUse -Config $script:Config)
        } else {
            $cur = [string]$script:Config['preferCurrency']
            if ([string]::IsNullOrWhiteSpace($cur) -or $cur -eq 'auto') { $cur = 'CNY' }
            $fake = [pscustomobject]@{
                ok          = $true
                isAvailable = $true
                infos       = @([pscustomobject]@{ currency = $cur; total = $val; granted = 3.5; toppedUp = ($val - 3.5) })
                currency    = $cur
                total       = $val
                granted     = 3.5
                toppedUp    = ($val - 3.5)
                severity    = (Get-BalanceSeverity -Value $val `
                                -Low (ConvertTo-DoubleSafe $script:Config['lowThreshold']) `
                                -Critical (ConvertTo-DoubleSafe $script:Config['criticalThreshold']))
                iconText    = Get-BalanceIconText -Value $val -Currency $cur -WithSymbol:([bool]$script:Config['iconShowSymbol'])
                latencyMs   = 0
                error       = $null
            }
            Apply-BalanceState -State (ConvertTo-BalanceState -State $fake -Config $script:Config)
        }
        return
    }

    if ($script:FetchPs) { return }   # 已有请求在跑

    if (-not $script:FetchRunspace -or $script:FetchRunspace.RunspaceStateInfo.State -ne 'Opened') {
        $script:FetchRunspace = [runspacefactory]::CreateRunspace()
        $script:FetchRunspace.ApartmentState = 'MTA'
        $script:FetchRunspace.ThreadOptions  = 'ReuseThread'
        $script:FetchRunspace.Open()
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $script:FetchRunspace
    # 线程里只负责「取原始数据」；标准化放到主线程做，因为余额模式的走势图依赖 $script:History
    [void]$ps.AddScript({
        param($Root, $Cfg, $Mode)
        . (Join-Path $Root 'DeepSeekBalance.ps1')
        $c = Get-BalanceConfig -Path $Cfg
        if ($Mode -eq 'usage') {
            . (Join-Path $Root 'Usage.ps1')
            return Get-UsageSnapshot -Config $c -Root $Root -Force
        }
        if ($Mode -eq 'platform') {
            # 账号余额 + 本地用量一起取：一屏同时看到「还剩多少钱」和「今天花了多少」
            . (Join-Path $Root 'Usage.ps1')
            . (Join-Path $Root 'Platform.ps1')
            return [pscustomobject]@{
                kind    = 'platform'
                balance = (Get-PlatformBalance -Config $c)
                usage   = (Get-UsageSnapshot -Config $c -Root $Root -Force)
            }
        }
        return Get-DeepSeekBalance -Config $c
    })
    [void]$ps.AddArgument($script:Root)
    [void]$ps.AddArgument($script:ConfigPath)
    [void]$ps.AddArgument([string]$script:Config['dataSource'])

    try {
        $script:FetchPs     = $ps
        $script:FetchHandle = $ps.BeginInvoke()
        # 只在首次加载时显示蓝色「…」，后续静默刷新，避免图标闪烁
        if (-not $script:State) { Set-TrayIcon -Text '…' -Color $script:SeverityColors['loading'] }
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "发起请求失败: $($_.Exception.Message)" -Level 'ERROR'
        try { $ps.Dispose() } catch { }
        $script:FetchPs = $null; $script:FetchHandle = $null
        Apply-BalanceState -State ([pscustomobject]@{
            ok = $false; kind = 'internal'; error = "内部错误: $($_.Exception.Message)"
            fetchedAt = (Get-Date); severity = 'error'; color = $script:SeverityColors['error']; iconText = '!'
        })
    }
}

function Complete-BalanceFetch {
    if (-not $script:FetchPs -or -not $script:FetchHandle) { return $false }
    if (-not $script:FetchHandle.IsCompleted) { return $false }

    $raw = $null
    try {
        $out = $script:FetchPs.EndInvoke($script:FetchHandle)
        $errs = $script:FetchPs.Streams.Error
        if ($errs -and $errs.Count -gt 0) {
            $msg = (@($errs | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join ' | ')
            Write-BalanceLog -Path $script:LogPath -Message "请求线程报错: $msg" -Level 'WARN'
        }
        foreach ($o in @($out)) { if ($null -ne $o) { $raw = $o; break } }
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "取回结果失败: $($_.Exception.Message)" -Level 'ERROR'
    } finally {
        try { $script:FetchPs.Dispose() } catch { }
        $script:FetchPs = $null
        $script:FetchHandle = $null
    }

    Apply-BalanceState -State (ConvertTo-UiState -Raw $raw)
    return $true
}

function ConvertTo-UiState {
    <# 把原始数据（余额结果 / 用量快照 / 平台余额）标准化成界面 state #>
    param($Raw)
    $mode = [string]$script:Config['dataSource']
    if ($mode -eq 'usage') {
        return ConvertTo-UsageState -Snapshot $Raw -Config $script:Config
    }
    if ($mode -eq 'platform') {
        $bal = $null
        $use = $null
        if ($Raw) { $bal = $Raw.balance; $use = $Raw.usage }
        return ConvertTo-PlatformState -Balance $bal -Usage $use -Config $script:Config
    }
    return ConvertTo-BalanceState -State $Raw -Config $script:Config
}

function Apply-BalanceState {
    param($State)

    $script:State = $State
    $base = [double]$script:Config['refreshSeconds']
    if ($base -lt 10) { $base = 10 }

    if ($State.ok) {
        $text = $State.iconText
        if ([string]$script:Config['iconMode'] -eq 'dot') { $text = '' }
        Set-TrayIcon -Text $text -Color $script:SeverityColors[$State.severity]
        Set-TrayTooltip -Text $State.tooltip

        # 只有余额模式写历史文件；用量模式的走势直接来自采集器
        if ($State.mode -eq 'balance' -and $State.raw) {
            Add-BalanceHistory -State $State.raw -Path $script:HistoryPath
            $script:History = Read-BalanceHistory -Path $script:HistoryPath -Max 120
        }

        Write-BalanceLog -Path $script:LogPath -Message ("[{0}] {1} 分级={2} | {3}" -f `
            $State.mode, $State.hero, $State.severity, $State.meta)

        # 阈值告警：跨过阈值只提醒一次，恢复后自动复位
        if ([bool]$script:Config['notifyOnLow'] -and ($State.severity -eq 'low' -or $State.severity -eq 'critical')) {
            if ($script:LastNotifyKey -ne $State.severity) {
                $isCrit = ($State.severity -eq 'critical')
                if ($State.mode -ne 'usage') {
                    $title = 'DeepSeek 余额偏低'; if ($isCrit) { $title = 'DeepSeek 余额告急' }
                    $body = "当前可用余额 $($State.hero)，请及时充值。"
                } else {
                    $title = '今日用量提醒'; if ($isCrit) { $title = '今日用量告急' }
                    $body = "今日折算花费 $($State.hero)，注意控制用量。"
                }
                $script:NotifyIcon.ShowBalloonTip(10000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Warning)
                Write-BalanceLog -Path $script:LogPath -Message "已发出阈值提醒（$($State.severity)）" -Level 'WARN'
                $script:LastNotifyKey = $State.severity
            }
        } else {
            $script:LastNotifyKey = $null
        }

        # 扣费提醒只对余额模式有意义（用量模式余额只会越用越多）
        if ($State.mode -eq 'balance' -and $State.raw -and [bool]$script:Config['notifyOnDrop'] -and
            $null -ne $script:PrevTotal -and $State.raw.total -lt $script:PrevTotal) {
            $delta = $script:PrevTotal - $State.raw.total
            if ($delta -ge 0.01) {
                $script:NotifyIcon.ShowBalloonTip(4000, 'DeepSeek 余额变动',
                    ("-{0}" -f (Format-Money -Value $delta -Currency $State.raw.currency)),
                    [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
        if ($State.mode -eq 'balance' -and $State.raw) { $script:PrevTotal = $State.raw.total }

        $script:FailStreak = 0
        $script:EverOk = $true
        $script:NextRefresh = (Get-Date).AddSeconds($base)

        # 启动后的第一个结果弹一次气泡：无窗口启动最怕「不知道到底起没起来」
        if (-not $script:StartBalloonShown) {
            $script:StartBalloonShown = $true
            if ([bool]$script:Config['notifyOnStart']) {
                $script:NotifyIcon.ShowBalloonTip(8000, 'DeepSeek 用量托盘已启动',
                    ("今日折算花费 {0}。图标在右下角通知区域，Win11 可能在「^」里。" -f $State.hero),
                    [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    } else {
        Set-TrayIcon -Text '!' -Color $script:SeverityColors['error']
        Set-TrayTooltip -Text ('{0}：{1}' -f $State.hero, $State.meta)

        if (-not $script:StartBalloonShown) {
            $script:StartBalloonShown = $true
            if ([bool]$script:Config['notifyOnStart']) {
                $script:NotifyIcon.ShowBalloonTip(8000, 'DeepSeek 用量托盘已启动（但读数据失败）',
                    ("{0}。详情请左键点托盘图标。" -f $State.meta),
                    [System.Windows.Forms.ToolTipIcon]::Warning)
            }
        }

        # 失败退避：首次失败快速重试（别让用户干等），之后 2 的幂递增，上限 15 分钟
        $script:FailStreak = [int]$script:FailStreak + 1
        if (-not $script:EverOk) {
            $delay = 15
        } else {
            $delay = $base * [math]::Pow(2, [math]::Max(0, $script:FailStreak - 1))
            if ($delay -gt 900) { $delay = 900 }
        }
        $script:NextRefresh = (Get-Date).AddSeconds($delay)
        Write-BalanceLog -Path $script:LogPath -Message ("取数失败 [{0}] {1}（连续第 {2} 次，{3}s 后重试）" -f `
            $State.mode, $State.meta, $script:FailStreak, [int]$delay) -Level 'WARN'
    }

    Update-MenuState
}

# ------------------------------------------------------------------ 构建托盘

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip

$script:MiHead = New-MenuItem -Text '加载中…' -Disabled
[void]$script:Menu.Items.Add($script:MiHead)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

[void]$script:Menu.Items.Add((New-MenuItem -Text '立即刷新' -OnClick { Start-BalanceFetch -Force; Update-MenuState }))
[void]$script:Menu.Items.Add((New-MenuItem -Text '显示详情…' -OnClick { Show-BalanceDetails }))
[void]$script:Menu.Items.Add((New-MenuItem -Text '复制当前数据' -OnClick { Copy-BalanceToClipboard }))
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# 数据源（本地用量 / 开放平台余额）
$script:MiSourceMap = @{}
$miSource = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '数据源'
foreach ($pair in @(
        @('platform', '账号余额（充值余额，无需 Key）'),
        @('usage',    '本地用量（今日花费，无需 Key）'),
        @('balance',  '开放平台 API 余额（需 sk- Key）'))) {
    $item = New-MenuItem -Text $pair[1] -OnClick ([scriptblock]::Create("Set-DataSource -Key '$($pair[0])'"))
    $script:MiSourceMap[$pair[0]] = $item
    [void]$miSource.DropDownItems.Add($item)
}
[void]$script:Menu.Items.Add($miSource)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# 刷新间隔
# 注意：这里必须用普通哈希表。OrderedDictionary 带 Item[int index] 重载，
# 用整数当键会被 PowerShell 绑成「按索引赋值」，空字典上直接 ArgumentOutOfRange。
$script:MiIntervalMap = @{}
$miInterval = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList '刷新间隔'
foreach ($sec in 15, 30, 60, 120, 300, 900) {
    $label = if ($sec -lt 60) { "$sec 秒" } else { "$([int]($sec / 60)) 分钟" }
    $item  = New-MenuItem -Text $label -OnClick ([scriptblock]::Create("Set-RefreshInterval -Seconds $sec"))
    $script:MiIntervalMap[[string]$sec] = $item
    [void]$miInterval.DropDownItems.Add($item)
}
[void]$script:Menu.Items.Add($miInterval)

$script:MiLow  = New-MenuItem -Text '阈值提醒' -OnClick { Set-ConfigFlag -Key 'notifyOnLow'  -Value (-not [bool]$script:Config['notifyOnLow']) }
$script:MiDrop = New-MenuItem -Text '扣费提醒'   -OnClick { Set-ConfigFlag -Key 'notifyOnDrop' -Value (-not [bool]$script:Config['notifyOnDrop']) }
$script:MiAutostart = New-MenuItem -Text '随 Windows 启动' -OnClick { Toggle-Autostart }
[void]$script:Menu.Items.Add($script:MiLow)
[void]$script:Menu.Items.Add($script:MiDrop)
[void]$script:Menu.Items.Add($script:MiAutostart)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:MiAmount = New-MenuItem -Text '图标上显示金额' -OnClick {
    $script:Config['iconMode'] = if ([string]$script:Config['iconMode'] -eq 'dot') { 'amount' } else { 'dot' }
    try { [void](Save-BalanceConfig -Config $script:Config -Path $script:ConfigPath) } catch { }
    if ($script:State -and $script:State.ok) {
        $text = $script:State.iconText
        if ([string]$script:Config['iconMode'] -eq 'dot') { $text = '' }
        Set-TrayIcon -Text $text -Color $script:SeverityColors[$script:State.severity]
    }
    Update-MenuState
}
[void]$script:Menu.Items.Add($script:MiAmount)
[void]$script:Menu.Items.Add((New-MenuItem -Text '加密保存 API Key（DPAPI）' -OnClick {
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Config['apiKeyProtected'])) {
            $script:NotifyIcon.ShowBalloonTip(3000, '已经是加密保存', 'config.json 中的 API Key 已是 DPAPI 密文，无需重复操作。', [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            [void](Protect-BalanceApiKey -Config $script:Config -Path $script:ConfigPath)
            $script:Config = Get-BalanceConfig -Path $script:ConfigPath
            Write-BalanceLog -Path $script:LogPath -Message 'API Key 已改为 DPAPI 加密保存'
            $script:NotifyIcon.ShowBalloonTip(5000, '已加密保存',
                '明文 Key 已替换为 DPAPI 密文，只有当前 Windows 账号能解开。注意：配置文件复制到别的机器或账号会失效。',
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "加密 API Key 失败: $($_.Exception.Message)" -Level 'ERROR'
        $script:NotifyIcon.ShowBalloonTip(5000, '加密失败', "$($_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
    }
}))
[void]$script:Menu.Items.Add((New-MenuItem -Text '打开开放平台' -OnClick { Start-Process 'https://platform.deepseek.com/usage' }))
[void]$script:Menu.Items.Add((New-MenuItem -Text '打开配置文件' -OnClick { Start-Process 'notepad.exe' -ArgumentList $script:ConfigPath }))
[void]$script:Menu.Items.Add((New-MenuItem -Text '打开日志'     -OnClick { Start-Process 'notepad.exe' -ArgumentList $script:LogPath }))
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:Menu.Items.Add((New-MenuItem -Text '退出' -OnClick {
    Write-BalanceLog -Path $script:LogPath -Message '用户从菜单退出'
    [System.Windows.Forms.Application]::Exit()
}))

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.ContextMenuStrip = $script:Menu
$script:NotifyIcon.Text = 'DeepSeek 余额加载中…'
$script:NotifyIcon.Visible = $true
Set-TrayIcon -Text '…' -Color $script:SeverityColors['loading']
$script:NotifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-BalanceDetails }
})
$script:NotifyIcon.Add_BalloonTipClicked({ Show-BalanceDetails })

Update-MenuState

# ------------------------------------------------------------------ 主循环

$script:UiTimer = New-Object System.Windows.Forms.Timer
$script:UiTimer.Interval = 300
$script:UiTimer.Add_Tick({
    try {
        [void](Complete-BalanceFetch)

        # 手动双击启动时自动把详情窗弹出来：不然用户看不到任何反馈，会以为没启动成功
        if ($script:ShowPanelPending -and $script:State) {
            $script:ShowPanelPending = $false
            Write-BalanceLog -Path $script:LogPath -Message '手动启动：自动弹出详情窗口'
            Show-BalanceDetails
        }

        if ((Get-Date) -ge $script:NextRefresh -and -not $script:FetchPs) {
            Start-BalanceFetch
        }

        if ($ExitAfterSeconds -gt 0 -and ((Get-Date) - $script:StartedAt).TotalSeconds -ge $ExitAfterSeconds) {
            Write-BalanceLog -Path $script:LogPath -Message "冒烟测试到时退出（$ExitAfterSeconds s）"
            [System.Windows.Forms.Application]::Exit()
        }
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "主循环异常: $($_.Exception.Message)" -Level 'ERROR'
    }
})
$script:UiTimer.Start()

$ctx = New-Object System.Windows.Forms.ApplicationContext

Start-BalanceFetch

# ---- 自动化验收：把详情窗口画成 PNG 后直接退出，不进消息循环
if ($CaptureUi) {
    $outPath = $CaptureUi
    if (-not [System.IO.Path]::IsPathRooted($outPath)) { $outPath = Join-Path $script:Root $outPath }
    try {
        Show-BalanceDetails
        for ($i = 0; $i -lt 20; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $w = $script:DetailsForm.Width
        $h = $script:DetailsForm.Height
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $w, $h
        $script:DetailsForm.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $w, $h))
        $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-BalanceLog -Path $script:LogPath -Message "详情窗截图已保存: $outPath"
        Write-Host "详情窗截图: $outPath"
    } catch {
        Write-BalanceLog -Path $script:LogPath -Message "截图失败: $($_.Exception.Message)" -Level 'ERROR'
        Write-Host "截图失败: $($_.Exception.Message)" -ForegroundColor Red
    }
    try { $script:UiTimer.Stop(); $script:UiTimer.Dispose() } catch { }
    try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch { }
    try { if ($script:IconHandle -ne [IntPtr]::Zero) { [void][BalanceTray.Win32]::DestroyIcon($script:IconHandle) } } catch { }
    try { if ($script:FetchRunspace) { $script:FetchRunspace.Close() } } catch { }
    try { if ($script:DetailsForm) { $script:DetailsForm.Close(); $script:DetailsForm.Dispose() } } catch { }
    return
}

try {
    [System.Windows.Forms.Application]::Run($ctx)
} finally {
    try { $script:UiTimer.Stop(); $script:UiTimer.Dispose() } catch { }
    try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch { }
    try { if ($script:IconHandle -ne [IntPtr]::Zero) { [void][BalanceTray.Win32]::DestroyIcon($script:IconHandle) } } catch { }
    try { if ($script:FetchPs) { $script:FetchPs.Dispose() } } catch { }
    try { if ($script:FetchRunspace) { $script:FetchRunspace.Close(); $script:FetchRunspace.Dispose() } } catch { }
    try { if ($script:DetailsForm -and -not $script:DetailsForm.IsDisposed) { $script:DetailsForm.Dispose() } } catch { }
    Write-BalanceLog -Path $script:LogPath -Message '托盘已退出'
}
