param(
  [Parameter(Mandatory = $true)][string]$DocumentPath,
  [string]$TaskPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'psd-page-copy.ps1')
# 可在出稿前只读检查当前商品 PSD；提供任务时，检查应用该任务后的完整页面。
$plan = if ($TaskPath) { Read-Utf8Json $TaskPath } else { @{} }
$report = Test-PsdPageCopy -DocumentPath $DocumentPath -Job $plan
$report | ConvertTo-Json -Depth 12
if (-not $report.ok) { throw 'duplicate-page-copy: 请先处理报告中的重复文案，再进入写入。' }
