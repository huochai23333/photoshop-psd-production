param(
  [Parameter(Mandatory = $true)][string]$CopyPath,
  [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')

function Format-ReviewCell {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) { return '' }
  $value = (Normalize-DingdongLineBreaks $Text).Replace('|', '\|')
  return $value.Replace("`n", '<br>')
}

function Get-DingdongReviewBoardLabel {
  param([Parameter(Mandatory = $true)][object]$Item)

  $path = [string]$Item.path
  if ($path -ceq '头版' -or $path.StartsWith('头版/', [StringComparison]::Ordinal)) {
    return '头版'
  }
  if ($path -ceq '尾版' -or $path.IndexOf('/尾版/', [StringComparison]::Ordinal) -ge 0) {
    return '尾版'
  }
  $match = [regex]::Match($path, '(^|/)版([0-9]+)(/|$)')
  if ($match.Success) {
    return '版' + $match.Groups[2].Value
  }
  return [string]$Item.label
}

function Join-DingdongReviewText {
  param([object[]]$Items, [string]$PropertyName)

  return (@($Items | ForEach-Object {
    (Normalize-DingdongLineBreaks ([string]$_.$PropertyName)).TrimEnd("`n")
  }) -join "`n")
}

$skillRoot = Split-Path -Parent $PSScriptRoot
$result = Test-DingdongCopyCompliance -CopyPath $CopyPath -SkillRoot $skillRoot
$definition = Read-Utf8Json $result.definitionPath
$index = Read-Utf8Json $result.indexPath
$layerById = Get-DingdongLayerLookup $index
$copy = Read-Utf8Json $result.copyPath
$replacementIds = @{}
foreach ($replacement in @($copy.textReplacements)) {
  $replacementIds[[string]$replacement.id] = $true
}

$lines = [Collections.Generic.List[string]]::new()
[void]$lines.Add('# 叮咚详情页文案审核')
[void]$lines.Add('')
[void]$lines.Add("- 模板：$($result.templateId)")
[void]$lines.Add("- Copy SHA-256：$($result.copySha256)")
[void]$lines.Add("- 校验状态：$(if ($result.ok) { '通过' } else { '失败' })")
[void]$lines.Add('')
[void]$lines.Add('| 版块 | 原文 | 原语法 | 原字数 | 新文 | 新语法 | 新字数 | 事实依据 | 状态 |')
[void]$lines.Add('|---|---|---|---|---|---|---|---|---|')

$reviewGroups = [ordered]@{}
foreach ($item in @($result.items)) {
  $boardLabel = Get-DingdongReviewBoardLabel -Item $item
  if (-not $reviewGroups.Contains($boardLabel)) {
    $reviewGroups[$boardLabel] = [Collections.Generic.List[object]]::new()
  }
  [void]$reviewGroups[$boardLabel].Add($item)
}

foreach ($boardLabel in @($reviewGroups.Keys)) {
  $boardItems = @($reviewGroups[$boardLabel])
  $itemLabels = @($boardItems | ForEach-Object { [string]$_.label })
  $itemErrors = @($result.errors | Where-Object { $itemLabels -ccontains [string]$_.label })
  $status = if ($itemErrors.Count -eq 0) { '通过' } else { '失败：' + (($itemErrors | ForEach-Object { [string]$_.message }) -join '；') }
  $sourceGrammar = @($boardItems | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace([string]$_.sourceGrammar)) { '逐字来源' } else { [string]$_.sourceGrammar }
  }) -join "`n"
  $proposedGrammar = @($boardItems | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace([string]$_.proposedGrammar)) { '逐字写入' } else { [string]$_.proposedGrammar }
  }) -join "`n"
  $sourceCounts = @($boardItems | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace([string]$_.sourceCounts)) { Get-DingdongVisibleLength (Normalize-DingdongLineBreaks ([string]$_.oldText)) } else { [string]$_.sourceCounts }
  }) -join "`n"
  $proposedCounts = @($boardItems | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace([string]$_.proposedCounts)) { Get-DingdongVisibleLength (Normalize-DingdongLineBreaks ([string]$_.text)) } else { [string]$_.proposedCounts }
  }) -join "`n"
  $evidence = @($boardItems | ForEach-Object { [string]$_.evidence } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join '；'
  $row = @(
    Format-ReviewCell ([string]$boardLabel)
    Format-ReviewCell (Join-DingdongReviewText -Items $boardItems -PropertyName 'oldText')
    Format-ReviewCell $sourceGrammar
    Format-ReviewCell ([string]$sourceCounts)
    Format-ReviewCell (Join-DingdongReviewText -Items $boardItems -PropertyName 'text')
    Format-ReviewCell $proposedGrammar
    Format-ReviewCell ([string]$proposedCounts)
    Format-ReviewCell $evidence
    Format-ReviewCell $status
  )
  [void]$lines.Add('| ' + ($row -join ' | ') + ' |')
}

$registeredTargets = [ordered]@{}
foreach ($target in @($definition.textAllowedBounds) + @($definition.protectedTextTargets)) {
  $id = [string]$target.id
  if (-not $registeredTargets.Contains($id)) {
    $registeredTargets[$id] = $target
  }
}
$retainedGroups = [ordered]@{}
foreach ($target in @($registeredTargets.Values)) {
  $id = [string]$target.id
  if ($replacementIds.ContainsKey($id)) { continue }
  $oldText = if ($layerById.ContainsKey($id)) { [string]$layerById[$id].text } else { [string]$target.path }
  $targetPath = if ($layerById.ContainsKey($id)) { [string]$layerById[$id].path } else { [string]$target.path }
  $count = @((Get-DingdongContentLines $oldText) | ForEach-Object { Get-DingdongVisibleLength $_ }) -join ' / '
  $isProtected = $false
  if (Test-ObjectProperty $definition 'protectedTextTargets') {
    $isProtected = @($definition.protectedTextTargets | Where-Object { [string]$_.id -ceq $id }).Count -gt 0
  }
  $retainReason = if ($isProtected) { '模板保护' } else { '本次未登记替换' }
  $retainedItem = [pscustomobject][ordered]@{
    label = $targetPath
    path = $targetPath
    oldText = $oldText
    text = $oldText
    count = $count
    reason = $retainReason
  }
  $boardLabel = Get-DingdongReviewBoardLabel -Item $retainedItem
  if (-not $retainedGroups.Contains($boardLabel)) {
    $retainedGroups[$boardLabel] = [Collections.Generic.List[object]]::new()
  }
  [void]$retainedGroups[$boardLabel].Add($retainedItem)
}

foreach ($boardLabel in @($retainedGroups.Keys)) {
  $boardItems = @($retainedGroups[$boardLabel])
  $counts = @($boardItems | ForEach-Object { [string]$_.count }) -join "`n"
  $reasons = @($boardItems | ForEach-Object { [string]$_.reason } | Select-Object -Unique) -join '；'
  $row = @(
    Format-ReviewCell ([string]$boardLabel)
    Format-ReviewCell (Join-DingdongReviewText -Items $boardItems -PropertyName 'oldText')
    '保护项'
    Format-ReviewCell $counts
    Format-ReviewCell (Join-DingdongReviewText -Items $boardItems -PropertyName 'text')
    '保护项'
    Format-ReviewCell $counts
    Format-ReviewCell $reasons
    '保留不改'
  )
  [void]$lines.Add('| ' + ($row -join ' | ') + ' |')
}

if ($result.errors.Count -gt 0) {
  [void]$lines.Add('')
  [void]$lines.Add('## 阻断项')
  [void]$lines.Add('')
  foreach ($errorItem in @($result.errors)) {
    $errorLabel = if ([string]::IsNullOrWhiteSpace([string]$errorItem.label)) { '全局' } else { [string]$errorItem.label }
    [void]$lines.Add("- [$([string]$errorItem.code)] $errorLabel：$([string]$errorItem.message)")
  }
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outputFullPath, (($lines -join "`n") + "`n"), $utf8NoBom)

[pscustomobject][ordered]@{
  ok = $result.ok
  copyPath = $result.copyPath
  copySha256 = $result.copySha256
  reviewPath = $outputFullPath
  errorCount = $result.errors.Count
} | ConvertTo-Json -Compress
if (-not $result.ok) { exit 2 }
