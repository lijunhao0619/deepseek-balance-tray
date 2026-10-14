#requires -version 5.1
<#
    Platform.ps1 —— 账号余额数据源（同样不需要 API Key）

    DeepSeek Harness 登录用的就是开放平台账号（~/.dsh/.credentials.yaml 里
    issuer = https://platform.deepseek.com），所以可以直接用那份登录凭据
    查询账户钱包余额 —— 这正是 Harness「设置 → 账号与余额」显示的那个数。

    接口（从 Harness 自身代码里挖出来的）：
      GET {issuer}/api/v0/users/get_user_summary
      Header: x-dsh-auth-token: <登录 token>
      响应: { code, data: { biz_data: { normal_wallets[], bonus_wallets[], total_costs[] } } }

    对外函数：
      Get-PlatformCredential   读 ~/.dsh/.credentials.yaml
      Get-PlatformBalance      查余额
      ConvertTo-PlatformState  标准化成界面 state
#>

$script:CredentialCache = $null

function Get-PlatformCredential {
    <# 从 Harness 的凭据文件里取出账号平台的 token 和 issuer #>
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml' }

    $result = [pscustomobject]@{
        token  = $null
        issuer = 'https://platform.deepseek.com'
        path   = $Path
        error  = $null
    }

    if ($script:CredentialCache -and $script:CredentialCache.path -eq $Path) {
        return $script:CredentialCache
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $result.error = "找不到 Harness 登录凭据：$Path（可能没登录过）"
        return $result
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        # 定位 deepseek-account-platform/default 这一段记录
        $m = [regex]::Match($raw, 'deepseek-account-platform/default:[\s\S]*?(?=\r?\n\s{2}\S|\s*$)')
        if (-not $m.Success) {
            $result.error = '凭据文件里没有 deepseek-account-platform/default 记录（Harness 未登录？）'
            return $result
        }
        $t = [regex]::Match($m.Value, 'token:\s*(\S+)')
        if (-not $t.Success) {
            $result.error = '凭据记录里没有 token 字段'
            return $result
        }
        $result.token = $t.Groups[1].Value.Trim()
        $i = [regex]::Match($m.Value, 'issuer:\s*(\S+)')
        if ($i.Success) { $result.issuer = $i.Groups[1].Value.Trim().TrimEnd('/') }
    } catch {
        $result.error = "读取凭据失败: $($_.Exception.Message)"
    }

    $script:CredentialCache = $result
    return $result
}

function Get-PlatformBalance {
    <#
        查询账号钱包余额。
        返回 ok / normalWallets / bonusWallets / totalCosts / currency /
             recharge / bonus / available / lifetimeCost / error / kind
    #>
    [CmdletBinding()]
    param([hashtable]$Config)

    $cred = Get-PlatformCredential
    if (-not $cred.token) {
        return [pscustomobject]@{
            ok = $false; kind = 'auth'; error = $cred.error
            recharge = 0.0; bonus = 0.0; available = 0.0; lifetimeCost = 0.0; currency = 'CNY'
        }
    }

    try {
        $protos = [Net.SecurityProtocolType]::Tls12
        try { $protos = $protos -bor [Net.SecurityProtocolType]::Tls11 } catch { }
        [Net.ServicePointManager]::SecurityProtocol = $protos
    } catch { }

    $timeout = 20
    try { $timeout = [int]$Config['timeoutSeconds'] } catch { }
    if ($timeout -lt 5) { $timeout = 5 }

    $tzSeconds = [int][TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalSeconds

    $headers = @{
        'x-dsh-auth-token'          = $cred.token
        'x-client-bundle-id'        = ''
        'x-client-platform'         = 'desktop-win'
        'x-client-version'          = '1.0.0'
        'x-client-locale'           = 'zh_CN'
        'x-client-timezone-offset'  = "$tzSeconds"
        'accept'                    = 'application/json'
    }

    $url = "$($cred.issuer)/api/v0/users/get_user_summary"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $params = @{
            Uri         = $url
            Method      = 'Get'
            Headers     = $headers
            TimeoutSec  = $timeout
            ErrorAction = 'Stop'
        }
        $proxy = [string]$Config['proxy']
        if (-not [string]::IsNullOrWhiteSpace($proxy)) { $params['Proxy'] = $proxy.Trim() }

        $resp = Invoke-RestMethod @params
        $sw.Stop()
    } catch {
        $sw.Stop()
        $status = $null
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        $kind = 'network'
        $human = '网络不可达'
        if ($status -eq 401 -or $status -eq 403) { $kind = 'auth'; $human = 'Harness 登录已失效，请重新登录 DeepSeek Harness' }
        elseif ($status -ge 500) { $kind = 'server'; $human = "平台服务端错误 (HTTP $status)" }
        elseif ($status -ge 400) { $kind = 'http'; $human = "请求被拒绝 (HTTP $status)" }
        elseif ($_.Exception.Message -match '超时|timeout|timed out') { $human = '请求超时' }

        return [pscustomobject]@{
            ok = $false; kind = $kind; error = $human; status = $status
            latencyMs = $sw.ElapsedMilliseconds
            recharge = 0.0; bonus = 0.0; available = 0.0; lifetimeCost = 0.0; currency = 'CNY'
        }
    }

    # 结构：{ code, msg, data: { biz_code, biz_msg, biz_data: { normal_wallets, bonus_wallets, total_costs } } }
    $bd = $null
    try { $bd = $resp.data.biz_data } catch { }
    if (-not $bd) { try { $bd = $resp.biz_data } catch { } }
    if (-not $bd) {
        return [pscustomobject]@{
            ok = $false; kind = 'parse'; error = '平台响应结构不符（可能接口已变更）'
            latencyMs = $sw.ElapsedMilliseconds
            recharge = 0.0; bonus = 0.0; available = 0.0; lifetimeCost = 0.0; currency = 'CNY'
        }
    }

    $currency = 'CNY'
    $recharge = 0.0
    $bonus = 0.0
    foreach ($w in @($bd.normal_wallets)) {
        if ($null -eq $w) { continue }
        $recharge += ConvertTo-DoubleSafe $w.balance
        if ($w.currency) { $currency = [string]$w.currency }
    }
    foreach ($w in @($bd.bonus_wallets)) {
        if ($null -eq $w) { continue }
        $bonus += ConvertTo-DoubleSafe $w.balance
        if ($w.currency -and $recharge -eq 0) { $currency = [string]$w.currency }
    }
    $lifetime = 0.0
    foreach ($c in @($bd.total_costs)) {
        if ($null -eq $c) { continue }
        $lifetime += ConvertTo-DoubleSafe $c.amount
    }

    return [pscustomobject]@{
        ok           = $true
        kind         = $null
        error        = $null
        currency     = $currency
        recharge     = $recharge
        bonus        = $bonus
        available    = $recharge + $bonus
        lifetimeCost = $lifetime
        normalWallets = @($bd.normal_wallets)
        bonusWallets  = @($bd.bonus_wallets)
        latencyMs    = $sw.ElapsedMilliseconds
        fetchedAt    = (Get-Date)
        issuer       = $cred.issuer
    }
}

function ConvertTo-PlatformState {
    <#
        标准化成界面 state。余额是主指标，同时把本地用量（今日花费 / 走势）一并带上，
        这样一屏就能同时看到「还剩多少钱」和「今天花了多少」。
    #>
    [CmdletBinding()]
    param($Balance, $Usage, [hashtable]$Config)

    $base = @{
        mode       = 'platform'
        currency   = 'CNY'
        fetchedAt  = (Get-Date)
        rows       = @()
        chart      = @()
        chartLabel = '最近 14 天花费走势'
        raw        = $Balance
    }

    if (-not $Balance -or -not $Balance.ok) {
        $msg = '余额暂时不可用'
        if ($Balance -and $Balance.error) { $msg = [string]$Balance.error }
        return [pscustomobject](Merge-Hashtable $base @{
            ok = $false; severity = 'error'; iconText = '!'
            hero = '暂时拿不到余额'; meta = $msg; error = $msg; stats = @()
        })
    }

    $cur      = [string]$Balance.currency
    $recharge = [double]$Balance.recharge
    $bonus    = [double]$Balance.bonus
    $avail    = [double]$Balance.available

    $low  = ConvertTo-DoubleSafe $Config['lowThreshold']
    $crit = ConvertTo-DoubleSafe $Config['criticalThreshold']
    $sev  = 'ok'
    if ($avail -le $crit) { $sev = 'critical' }
    elseif ($avail -le $low) { $sev = 'low' }

    # 本地用量（可选，失败不影响余额显示）
    $todayCost = $null
    $todayText = '—'
    $chart = @()
    $stats = @()
    $metaCost = ''
    if ($Usage -and $Usage.ok) {
        $todayCost = [double]$Usage.today.cost
        $todayText = Format-Money -Value $todayCost -Currency 'CNY'
        $chart = @(@($Usage.days) | Select-Object -Last 14 | ForEach-Object {
                    @{ label = ([string]$_.date).Substring(5); value = [double]$_.cost } })
        $metaCost = ' · 累计 ' + (Format-Money -Value ([double]$Balance.lifetimeCost) -Currency $cur)
        # 今日 token 分解（与用量模式口径一致：inputTokens = 缓存未命中）
        $stats = @(
            @{ label = '缓存命中';   value = (Format-Tokens -Value ([double]$Usage.today.cacheReadTokens)) },
            @{ label = '缓存未命中'; value = (Format-Tokens -Value ([double]$Usage.today.inputTokens)) },
            @{ label = '输出';       value = (Format-Tokens -Value ([double]$Usage.today.outputTokens)) },
            @{ label = '今日合计';   value = (Format-Tokens -Value ([double]$Usage.today.totalTokens)) }
        )
    }

    $stamp = (Get-Date).ToString('HH:mm')

    $state = [pscustomobject](Merge-Hashtable $base @{
        ok        = $true
        severity  = $sev
        currency  = $cur
        hero      = (Format-Money -Value $avail -Currency $cur)
        heroLabel = '可用余额'
        iconText  = Get-BalanceIconText -Value $avail -Currency $cur -WithSymbol:([bool]$Config['iconShowSymbol'])
        stats     = $stats
        rows      = @()
        meta      = '{0} 更新 · 充值 {1} · 赠金 {2} · 今日 {3}{4}' -f `
                        $stamp,
                        (Format-Money -Value $recharge -Currency $cur),
                        (Format-Money -Value $bonus    -Currency $cur),
                        $todayText, $metaCost
        chart     = $chart
        recharge  = $recharge
        bonus     = $bonus
        available = $avail
    })

    $tip = '账户 {0} ｜ 充值 {1} 赠金 {2} ｜ {3}' -f `
        (Format-Money -Value $avail -Currency $cur),
        (Format-Money -Value $recharge -Currency $cur),
        (Format-Money -Value $bonus -Currency $cur),
        $stamp
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + '…' }
    $state | Add-Member -NotePropertyName tooltip -NotePropertyValue $tip -Force
    return $state
}
