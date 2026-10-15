# 文案先按商品事实自然撰写；这里只校验新文重建、行数和原有禁写词。
# 不比较原文与新文的词数、词性、语义角色、标点或字数差。
function Normalize-DingdongLineBreaks {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) { return '' }
  return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-DingdongTrailingLineBreakCount {
  param([AllowNull()][string]$Text)

  $normalized = Normalize-DingdongLineBreaks $Text
  $count = 0
  for ($i = $normalized.Length - 1; $i -ge 0; $i--) {
    if ($normalized[$i] -ne "`n") { break }
    $count++
  }
  return $count
}

function Get-DingdongVisibleLength {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

  if ($Text.Length -eq 0) { return 0 }
  return [Globalization.StringInfo]::ParseCombiningCharacters($Text).Count
}

function Get-DingdongContentLines {
  param([AllowNull()][string]$Text)

  $normalized = Normalize-DingdongLineBreaks $Text
  while ($normalized.EndsWith("`n", [StringComparison]::Ordinal)) {
    $normalized = $normalized.Substring(0, $normalized.Length - 1)
  }
  if ($normalized.Length -eq 0) { return @('') }
  return @($normalized.Split("`n"))
}

function Convert-DingdongSegmentsToText {
  param([Parameter(Mandatory = $true)][object[]]$Segments)

  $builder = [Text.StringBuilder]::new()
  foreach ($segment in $Segments) {
    [void]$builder.Append([string]$segment.text)
    [void]$builder.Append([string]$segment.separatorAfter)
  }
  return $builder.ToString()
}


function Test-DingdongProposedSegments {
  param(
    [AllowEmptyCollection()][object[]]$Segments,
    [string]$Label,
    $Errors
  )

  if ($Segments.Count -eq 0) {
    Add-DingdongCopyError $Errors 'empty-segments' $Label '非空文案行必须标注新文词组。'
    return
  }
  foreach ($segment in $Segments) {
    # 词组只用于重建新文及保留原有“入+名词”检查，不要求填写词性和角色。
    foreach ($field in @('text', 'separatorAfter')) {
      if (-not (Test-ObjectProperty $segment $field)) {
        Add-DingdongCopyError $Errors 'missing-segment-field' $Label "新文词组缺少 $field。"
      }
    }
    if ([string]::IsNullOrEmpty([string]$segment.text)) {
      Add-DingdongCopyError $Errors 'empty-segment-text' $Label '新文词组不能为空。'
    }
    if ([string]$segment.text -match '\s') {
      Add-DingdongCopyError $Errors 'segment-contains-whitespace' $Label '空格请放在 separatorAfter，不要写进词组。'
    }
    if ([string]$segment.separatorAfter -match '[\p{L}\p{N}]') {
      Add-DingdongCopyError $Errors 'invalid-separator' $Label '分隔符只能包含标点或空白。'
    }
    if ([string]$segment.text -match '^入\p{IsCJKUnifiedIdeographs}$') {
      Add-DingdongCopyError $Errors 'forbidden-ru-noun-pattern' $Label ('普通改写禁止使用二字“入+名词”词组：{0}。用户明确指定的逐字替换仍按 verbatim 处理。' -f [string]$segment.text)
    }
  }
}

function Test-DingdongNaturalCopyLines {
  param($Replacement, [string]$OldText, [string]$NewText, [string]$Label, $Errors)

  if (-not (Test-ObjectProperty $Replacement 'lines')) {
    Add-DingdongCopyError $Errors 'missing-lines' $Label '普通改写必须提供新文的逐行词组。'
    return
  }
  $lines = @($Replacement.lines)
  $sourceLines = @(Get-DingdongContentLines $OldText)
  $proposedLines = @(Get-DingdongContentLines $NewText)
  # 保留原版面的显式行数、空行位置和末尾换行；长度只做记录，不据此判定溢出。
  if ((Get-DingdongTrailingLineBreakCount $OldText) -ne (Get-DingdongTrailingLineBreakCount $NewText)) {
    Add-DingdongCopyError $Errors 'trailing-line-break-mismatch' $Label '末尾换行数量与原版面不同。'
  }
  if ($sourceLines.Count -ne $proposedLines.Count -or $lines.Count -ne $proposedLines.Count) {
    Add-DingdongCopyError $Errors 'line-count-mismatch' $Label '原版面、新文与新文标注的行数必须一致。'
  }
  $lineCount = [Math]::Min($lines.Count, [Math]::Min($sourceLines.Count, $proposedLines.Count))
  for ($i = 0; $i -lt $lineCount; $i++) {
    $segments = if (Test-ObjectProperty $lines[$i] 'proposedSegments') { @($lines[$i].proposedSegments) } else { @() }
    $sourceEmpty = [string]::IsNullOrEmpty([string]$sourceLines[$i])
    $proposedEmpty = [string]::IsNullOrEmpty([string]$proposedLines[$i])
    if ($sourceEmpty -ne $proposedEmpty) {
      Add-DingdongCopyError $Errors 'blank-line-mismatch' $Label "第 $($i + 1) 行的空行位置与原版面不同。"
    }
    if ($proposedEmpty) {
      if ($segments.Count -ne 0) {
        Add-DingdongCopyError $Errors 'empty-line-annotation' $Label '空行必须使用空 proposedSegments。'
      }
      continue
    }
    Test-DingdongProposedSegments -Segments $segments -Label $Label -Errors $Errors
    if ($segments.Count -gt 0 -and (Convert-DingdongSegmentsToText $segments) -cne $proposedLines[$i]) {
      Add-DingdongCopyError $Errors 'proposed-reconstruction-mismatch' $Label "新文词组无法逐字重建第 $($i + 1) 行。"
    }
  }
}
