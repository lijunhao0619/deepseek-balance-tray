#requires -version 5.1
<#
    Usage.ps1 —— 本地用量数据源（不需要 API Key）

    DSH 的会话日志是 zstd 压缩的（多帧 seekable 格式），Windows PowerShell 5.1
    没有 zstd 能力，所以这里调用 DSH 自带的 node.exe（v24，内置 zstd）去跑
    UsageCollector.js，再把结果标准化成界面用的 state 对象。

    对外函数：
      Find-NodeRuntime       找一个带 zstd 支持的 node
      Get-UsageSnapshot      跑采集器，返回原始 JSON 对象
      ConvertTo-UsageState   标准化成界面 state
      Format-Tokens          把 token 数格式化成 2983万 / 1.2亿
#>

$script:NodePathCache = $null
$script:UsageCache    = $null

function Find-NodeRuntime {
    <#
        按优先级找一个支持 zstd 的 node：
          1. config.json 里的 nodePath
          2. DSH 自带运行时（~/.dsh/dsh-runtimes/*/dependencies/node/bin/node.exe）—— 通常是 v24
          3. PATH 里的 node（需 >= 22.15 或 >= 23.8）
    #>
    [CmdletBinding()]
    param([hashtable]$Config)

    if ($script:NodePathCache) { return $script:NodePathCache }

    $candidates = New-Object System.Collections.ArrayList
    if ($Config -and $Config['nodePath']) { [void]$candidates.Add([string]$Config['nodePath']) }

    $runtimes = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes'
    if (Test-Path -LiteralPath $runtimes) {
        Get-ChildItem -LiteralPath $runtimes -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Join-Path $_.FullName 'dependencies\node\bin\node.exe'
            if (Test-Path -LiteralPath $p) { [void]$candidates.Add($p) }
        }
    }

    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }

    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            $probe = & $c -e "process.stdout.write(typeof require('zlib').zstdDecompressSync)" 2>$null
            if ("$probe".Trim() -eq 'function') {
                $script:NodePathCache = $c
                return $c
            }
        } catch { }
    }
    return $null
}

function Get-UsageSnapshot {
    <#
        调用 UsageCollector.js，返回它输出的 JSON 对象。
        同一刷新周期内会复用缓存，避免频繁解压会话日志。
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [string]$Root,
        [switch]$Force
    )

    if (-not $Root) { $Root = $script:Root }
    if (-not $Root) { $Root = $PSScriptRoot }

    $ttl = 30
    try { $ttl = [double]$Config['refreshSeconds'] } catch { }
    if ($ttl -lt 10) { $ttl = 10 }

    if (-not $Force -and $script:UsageCache) {
        if (((Get-Date) - $script:UsageCache.at).TotalSeconds -lt $ttl) { return $script:UsageCache.data }
    }

    $fail = {
        param($msg)
        return [pscustomobject]@{ ok = $false; errors = @($msg); today = $null; days = @() }
    }

    $node = Find-NodeRuntime -Config $Config
    if (-not $node) {
        $snap = & $fail '找不到带 zstd 支持的 node.exe（需要 DSH 自带运行时，或 node >= 22.15）'
        $script:UsageCache = @{ at = (Get-Date); data = $snap }
        return $snap
    }

    $collector = Join-Path $Root 'UsageCollector.js'
    if (-not (Test-Path -LiteralPath $collector)) {
        $snap = & $fail "找不到采集脚本: $collector"
        $script:UsageCache = @{ at = (Get-Date); data = $snap }
        return $snap
    }

    $configPath = [string]$Config['__path']
    $cacheFile  = Join-Path $Root 'usage-cache.json'
    # 每个进程用独立的输出文件，避免多实例互相踩
    $outFile    = Join-Path $Root "usage-out.$PID.json"
    $days = 14
    try { if ($Config['usageHistoryDays']) { $days = [int]$Config['usageHistoryDays'] } } catch { }

    $snap = $null
    $diag = ''
    # 偶发失败（子进程启动竞争、文件被占）原地立刻重试一次，别让用户干等一个退避周期
    for ($attempt = 1; $attempt -le 2 -and -not $snap; $attempt++) {
        $diag = ''
        try {
            if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
            # 让采集器把结果写文件，而不是靠捕获 stdout：
            # PowerShell 抓子进程输出会受控制台编码/换行宽度影响，任何 stderr 都会污染结果。
            $stdout = & $node $collector '--config' $configPath '--cache' $cacheFile '--days' "$days" '--out' $outFile 2>&1
            $exitCode = $LASTEXITCODE

            if (Test-Path -LiteralPath $outFile) {
                $text = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
                if ($text -and $text.Trim()) {
                    $snap = $text | ConvertFrom-Json
                } else {
                    $diag = '输出文件为空'
                }
            } else {
                $so = ((@($stdout) | Out-String).Trim())
                if ($so.Length -gt 400) { $so = $so.Substring(0, 400) }
                $diag = "采集器未生成输出文件（exit=$exitCode 输出=$so）"
            }
        } catch {
            $diag = "调用采集器异常: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
        if (-not $snap -and $attempt -lt 2) {
            Write-BalanceLog -Path (Join-Path $Root 'run.log') -Message "用量采集第 1 次失败（$diag），立刻重试" -Level 'WARN'
            Start-Sleep -Milliseconds 800
        }
    }

    if (-not $snap) {
        $snap = & $fail ("用量采集器没有返回可解析的结果" + $(if ($diag) { " —— $diag" } else { '' }))
    }

    $script:UsageCache = @{ at = (Get-Date); data = $snap }
    return $snap
}

function Format-Tokens {
    <# token 数按中文习惯换算：2983万 / 1.2亿 #>
    [CmdletBinding()]
    param([double]$Value)
    $v = [math]::Abs($Value)
    $sign = ''
    if ($Value -lt 0) { $sign = '-' }
    if ($v -ge 1e8) { return ('{0}{1:0.##}亿' -f $sign, ($v / 1e8)) }
    if ($v -ge 1e4) { return ('{0}{1:0.#}万' -f $sign, ($v / 1e4)) }
    return ('{0}{1:N0}' -f $sign, $v)
}

function ConvertTo-UsageState {
    <#
        把采集器输出标准化成界面 state（与余额模式共用同一套渲染）。
    #>
    [CmdletBinding()]
    param($Snapshot, [hashtable]$Config, [string]$CollectorPath)

    $base = @{
        mode       = 'usage'
        currency   = 'CNY'
        fetchedAt  = (Get-Date)
        chartLabel = '最近 14 天花费走势'
        rows       = @()
        chart      = @()
        raw        = $Snapshot
    }

    if (-not $Snapshot -or -not $Snapshot.ok) {
        $msg = '用量数据暂时不可用'
        if ($Snapshot -and $Snapshot.errors -and @($Snapshot.errors).Count -gt 0) {
            $msg = (@($Snapshot.errors) | Select-Object -First 2) -join '；'
        }
        return [pscustomobject](Merge-Hashtable $base @{
            ok = $false; severity = 'error'; iconText = '!'
            hero = '暂时拿不到用量'; meta = $msg; error = $msg; stats = @()
        })
    }

    $today = $Snapshot.today
    $cost  = [double]$today.cost
    $warn  = ConvertTo-DoubleSafe $Config['dailyWarnCost']
    $crit  = ConvertTo-DoubleSafe $Config['dailyCriticalCost']

    $sev = 'ok'
    if ($cost -ge $crit) { $sev = 'critical' }
    elseif ($cost -ge $warn) { $sev = 'low' }

    $metric = [string]$Config['usageIconMetric']
    if (-not $metric) { $metric = 'cost' }
    if ($metric -eq 'tokens') {
        $iconText = Format-Tokens -Value ([double]$today.totalTokens)
        # 图标只有 4 个字符左右，中文单位要再压一压
        $iconText = $iconText -replace '万$', 'w' -replace '亿$', 'e'
    } else {
        $iconText = Get-BalanceIconText -Value $cost -Currency 'CNY' -WithSymbol:([bool]$Config['iconShowSymbol'])
    }

    $peakPart = ''
    if ($today.peakRequests -gt 0) { $peakPart = " · 高峰 $($today.peakRequests) 次" }

    $state = [pscustomobject](Merge-Hashtable $base @{
        ok        = $true
        severity  = $sev
        hero      = (Format-Money -Value $cost -Currency 'CNY')
        heroLabel = '今日折算花费'
        iconText  = $iconText
        # 今日 token 分解。inputTokens 是「缓存未命中」的那部分
        # （totalTokens = inputTokens + outputTokens + cacheReadTokens，已用日志核对过）
        stats     = @(
            @{ label = '缓存命中';   value = (Format-Tokens -Value ([double]$today.cacheReadTokens)) },
            @{ label = '缓存未命中'; value = (Format-Tokens -Value ([double]$today.inputTokens)) },
            @{ label = '输出';       value = (Format-Tokens -Value ([double]$today.outputTokens)) },
            @{ label = '今日合计';   value = (Format-Tokens -Value ([double]$today.totalTokens)) }
        )
        rows      = @()
        meta      = '{0} 更新 · {1} 次请求{2}' -f (Get-Date).ToString('HH:mm'), $today.requests, $peakPart
        chart     = @(@($Snapshot.days) | Select-Object -Last 14 | ForEach-Object {
                        @{ label = ([string]$_.date).Substring(5); value = [double]$_.cost }
                    })
        filesNote = '扫描 {0} 个会话文件' -f $Snapshot.files.total
    })

    $todayCostText = Format-Money -Value $cost -Currency 'CNY'
    $tip = '今日 {0} ｜ 输入 {1} 输出 {2} ｜ {3}' -f `
        $todayCostText,
        (Format-Tokens -Value ([double]$today.inputTokens)),
        (Format-Tokens -Value ([double]$today.outputTokens)),
        (Get-Date).ToString('HH:mm')
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + '…' }
    $state | Add-Member -NotePropertyName tooltip -NotePropertyValue $tip -Force
    return $state
}
