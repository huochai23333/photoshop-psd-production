[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [AllowEmptyString()]
  [string]$ReplyText
)

$ErrorActionPreference = 'Stop'

# 只校验将要发给用户的完整文案回复，不读取或写入商品目录。
$normalized = ($ReplyText -replace "`r`n", "`n" -replace "`r", "`n").Trim()
$memoryFooter = '(?s)\n+<oai-mem-citation>\n<citation_entries>.*?</citation_entries>\n<rollout_ids>.*?</rollout_ids>\n</oai-mem-citation>$'
if ($normalized -match $memoryFooter) {
  # 平台要求的末尾引用块是元数据；正文仍须严格只有两列表格。
  $normalized = $normalized.Substring(0, $normalized.Length - $Matches[0].Length).TrimEnd()
}
$lines = @($normalized -split "`n")

if ($lines.Count -lt 3) {
  throw '初稿回复必须包含表头、分隔行和至少一行文案。'
}
if ($lines[0] -notmatch '^\|\s*板块\s*\|\s*新文\s*\|$') {
  throw '初稿回复的表头只能是“板块｜新文”。'
}
if ($lines[1] -notmatch '^\|\s*:?-{3,}:?\s*\|\s*:?-{3,}:?\s*\|$') {
  throw '初稿回复需要恰好两列的 Markdown 分隔行。'
}

$boards = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
for ($index = 2; $index -lt $lines.Count; $index++) {
  $line = $lines[$index]
  if ($line -notmatch '^\|\s*(?<board>[^|]+?)\s*\|\s*(?<copy>[^|]+?)\s*\|$') {
    throw "第 $($index + 1) 行不是两列表格行；初稿回复不能附加说明或提示。"
  }

  $board = $Matches['board'].Trim()
  $copy = $Matches['copy'].Trim()
  if (-not $boards.Add($board)) {
    throw ('板块 {0} 重复；每个板块只能占一行。' -f $board)
  }
  if ($copy -match '^(无候选|无合规候选|待补充)$') {
    throw ('板块 {0} 的新文不能是占位文字。' -f $board)
  }

  # 同一单元格允许用 <br> 合并多段文字，但每一段都须有内容。
  foreach ($segment in @($copy -split '<br>', 0, 'IgnoreCase')) {
    if ([string]::IsNullOrWhiteSpace($segment)) {
      throw ('板块 {0} 的新文包含空段落。' -f $board)
    }
  }
}

# 返回最小通过凭证，供发送前确认；脚本不代替语法或事实校验。
[pscustomobject]@{
  ok = $true
  boardCount = $boards.Count
} | ConvertTo-Json -Compress
