#requires -version 5.1
<#
    Test-Usage.ps1 —— 命令行查看本地用量统计（不需要 API Key）

    用法：
      .\Test-Usage.ps1              打印今天的用量汇总
      .\Test-Usage.ps1 -Days 7      打印最近 7 天
      .\Test-Usage.ps1 -Json        输出原始 JSON
      .\Test-Usage.ps1 -NoCache     忽略磁盘缓存，强制重新解析所有会话
#>
[CmdletBinding()]
param(
    [int]$Days = 7,
    [switch]$Json,
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
. (Join-Path $Root 'DeepSeekBalance.ps1')
. (Join-Path $Root 'Usage.ps1')

$cfg = Get-BalanceConfig -Path (Join-Path $Root 'config.json')

$node = Find-NodeRuntime -Config $cfg
if (-not $node) {
    Write-Host '找不到带 zstd 支持的 node.exe' -ForegroundColor Red
    Write-Host '需要 DSH 自带运行时（~/.dsh/dsh-runtimes/...）或 node >= 22.15' -ForegroundColor DarkGray
    exit 1
}
Write-Host "node: $node" -ForegroundColor DarkGray

if ($NoCache) { Remove-Item (Join-Path $Root 'usage-cache.json') -Force -ErrorAction SilentlyContinue }

$snap = Get-UsageSnapshot -Config $cfg -Root $Root -Force

if ($Json) {
    $snap | ConvertTo-Json -Depth 6
    exit 0
}

if (-not $snap -or -not $snap.ok) {
    Write-Host '用量采集失败：' -ForegroundColor Red
    if ($snap.errors) { @($snap.errors) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
    exit 1
}

$t = $snap.today
Write-Host ''
Write-Host ("今日 [{0}]  折算花费 {1}" -f $t.date, (Format-Money -Value ([double]$t.cost) -Currency 'CNY')) -ForegroundColor Green
Write-Host ("  输入     {0,10}" -f (Format-Tokens -Value ([double]$t.inputTokens)))
Write-Host ("  输出     {0,10}" -f (Format-Tokens -Value ([double]$t.outputTokens)))
Write-Host ("  缓存读   {0,10}" -f (Format-Tokens -Value ([double]$t.cacheReadTokens)))
Write-Host ("  合计     {0,10}   （{1} 次请求，其中高峰 {2} 次）" -f (Format-Tokens -Value ([double]$t.totalTokens)), $t.requests, $t.peakRequests)

Write-Host ''
Write-Host "最近 $Days 天：" -ForegroundColor Cyan
$rows = @($snap.days) | Select-Object -Last $Days
foreach ($d in $rows) {
    Write-Host ("  {0}   {1,10}   {2,10} tokens   {3,4} 次" -f `
        $d.date, (Format-Money -Value ([double]$d.cost) -Currency 'CNY'), (Format-Tokens -Value ([double]$d.totalTokens)), $d.requests)
}

Write-Host ''
Write-Host ('按模型：') -ForegroundColor Cyan
foreach ($p in $snap.models.PSObject.Properties) {
    Write-Host ("  {0}: {1}  {2} 次请求" -f $p.Name, (Format-Money -Value ([double]$p.Value.cost) -Currency 'CNY'), $p.Value.requests)
}

Write-Host ''
Write-Host ("扫描 {0} 个会话文件（本次新解析 {1}，命中缓存 {2}）" -f $snap.files.total, $snap.files.parsed, $snap.files.cached) -ForegroundColor DarkGray
Write-Host '计价依据：DeepSeek 官方价目表（空闲价；高峰时段 ×2）' -ForegroundColor DarkGray
if ($snap.errors -and @($snap.errors).Count -gt 0) {
    Write-Host '警告：' -ForegroundColor Yellow
    @($snap.errors) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}
