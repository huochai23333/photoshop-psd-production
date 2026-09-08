$ErrorActionPreference = 'Stop'

if (-not (Get-Command Read-Utf8Json -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'psd-job-common.ps1')
}

$script:DingdongAllowedPartsOfSpeech = @(
  'noun',
  'verb',
  'adjective',
  'adverb',
  'number',
  'unit',
  'fixed'
)

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

function Get-DingdongTemplateContext {
  param(
    [Parameter(Mandatory = $true)][string]$TemplateId,
    [Parameter(Mandatory = $true)][string]$SkillRoot
  )

  $registryPath = Join-Path $SkillRoot 'assets\templates\registry.json'
  $registry = Read-Utf8Json $registryPath
  $matches = @($registry.templates | Where-Object { [string]$_.templateId -ceq $TemplateId })
  if ($matches.Count -ne 1) { throw "Template id must resolve exactly once: $TemplateId" }
  $template = $matches[0]
  if ([string]$template.workflow -cne 'dingdong-detail') {
    throw "Template is not a Dingdong detail template: $TemplateId"
  }
  if (-not (Test-ObjectProperty $template 'definitionPath') -or
      [string]::IsNullOrWhiteSpace([string]$template.definitionPath)) {
    throw "Template has no definitionPath: $TemplateId"
  }
  if (-not (Test-ObjectProperty $template 'indexPath') -or
      [string]::IsNullOrWhiteSpace([string]$template.indexPath)) {
    throw "Template has no indexPath: $TemplateId"
  }
  $templatesRoot = Split-Path -Parent $registryPath
  return [pscustomobject][ordered]@{
    template = $template
    definitionPath = [IO.Path]::GetFullPath((Join-Path $templatesRoot ([string]$template.definitionPath)))
    indexPath = [IO.Path]::GetFullPath((Join-Path $templatesRoot ([string]$template.indexPath)))
  }
}

function Get-DingdongLayerLookup {
  param([Parameter(Mandatory = $true)]$Index)

  $byId = @{}
  foreach ($document in @($Index.documents)) {
    foreach ($layer in @($document.layers)) {
      $key = [string]$layer.id
      if ($byId.ContainsKey($key)) {
        throw "Template index contains duplicate layer id: $key"
      }
      $byId[$key] = $layer
    }
  }
  return $byId
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

function Get-DingdongGrammarLabel {
  param([Parameter(Mandatory = $true)][object[]]$Segments)

  return (($Segments | ForEach-Object { "$([string]$_.pos):$([string]$_.role)" }) -join ' + ')
}

function Get-DingdongCountLabel {
  param([Parameter(Mandatory = $true)][object[]]$Segments)

  $parts = [Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $Segments.Count; $i++) {
    [void]$parts.Add([string](Get-DingdongVisibleLength ([string]$Segments[$i].text)))
    if ($i -lt $Segments.Count - 1) {
      if ([string]::IsNullOrEmpty([string]$Segments[$i].separatorAfter)) {
        [void]$parts.Add('+')
      } else {
        [void]$parts.Add(' | ')
      }
    }
  }
  return ($parts -join '')
}

function Get-DingdongClauseLengths {
  param([Parameter(Mandatory = $true)][object[]]$Segments)

  $lengths = [Collections.Generic.List[int]]::new()
  $current = 0
  for ($i = 0; $i -lt $Segments.Count; $i++) {
    $current += Get-DingdongVisibleLength ([string]$Segments[$i].text)
    if (-not [string]::IsNullOrEmpty([string]$Segments[$i].separatorAfter)) {
      [void]$lengths.Add($current)
      $current = 0
    }
  }
  if ($current -gt 0 -or $lengths.Count -eq 0) {
    [void]$lengths.Add($current)
  }
  return @($lengths)
}

function Test-DingdongSegmentsEqual {
  param(
    [Parameter(Mandatory = $true)][object[]]$Left,
    [Parameter(Mandatory = $true)][object[]]$Right
  )

  if ($Left.Count -ne $Right.Count) { return $false }
  for ($index = 0; $index -lt $Left.Count; $index++) {
    foreach ($field in @('text', 'pos', 'role', 'separatorAfter')) {
      if ([string]$Left[$index].$field -cne [string]$Right[$index].$field) { return $false }
    }
  }
  return $true
}

function Add-DingdongCopyError {
  param(
    [Parameter(Mandatory = $true)]$Errors,
    [Parameter(Mandatory = $true)][string]$Code,
    [string]$Label,
    [Parameter(Mandatory = $true)][string]$Message
  )

  [void]$Errors.Add([pscustomobject][ordered]@{
    code = $Code
    label = $Label
    message = $Message
  })
}

function Test-DingdongSegmentSet {
  param(
    [Parameter(Mandatory = $true)][object[]]$Segments,
    [Parameter(Mandatory = $true)][string]$Side,
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)]$Errors
  )

  if ($Segments.Count -eq 0) {
    Add-DingdongCopyError $Errors 'empty-segments' $Label "$Side segments must not be empty."
    return
  }
  for ($i = 0; $i -lt $Segments.Count; $i++) {
    $segment = $Segments[$i]
    $prefix = "$Side segment $($i + 1)"
    foreach ($property in @('text', 'pos', 'role', 'separatorAfter')) {
      if (-not (Test-ObjectProperty $segment $property)) {
        Add-DingdongCopyError $Errors 'missing-segment-field' $Label "$prefix is missing $property."
      }
    }
    $text = if (Test-ObjectProperty $segment 'text') { [string]$segment.text } else { '' }
    $pos = if (Test-ObjectProperty $segment 'pos') { [string]$segment.pos } else { '' }
    $role = if (Test-ObjectProperty $segment 'role') { [string]$segment.role } else { '' }
    $separator = if (Test-ObjectProperty $segment 'separatorAfter') { [string]$segment.separatorAfter } else { '' }
    if ([string]::IsNullOrEmpty($text)) {
      Add-DingdongCopyError $Errors 'empty-segment-text' $Label "$prefix text must not be empty."
    }
    if ($text -match '\s') {
      Add-DingdongCopyError $Errors 'segment-contains-whitespace' $Label "$prefix text must not contain whitespace; use separatorAfter."
    }
    if ($script:DingdongAllowedPartsOfSpeech -cnotcontains $pos) {
      Add-DingdongCopyError $Errors 'invalid-pos' $Label "$prefix pos is invalid: $pos"
    }
    if ([string]::IsNullOrWhiteSpace($role)) {
      Add-DingdongCopyError $Errors 'missing-role' $Label "$prefix role must not be empty."
    }
    if ($separator -match '[\p{L}\p{N}]') {
      Add-DingdongCopyError $Errors 'invalid-separator' $Label "$prefix separatorAfter may contain only punctuation or whitespace."
    }
  }
}

function Test-DingdongTaskReplacementBinding {
  param(
    [Parameter(Mandatory = $true)][object[]]$CopyReplacements,
    [Parameter(Mandatory = $true)][object[]]$TaskReplacements,
    [Parameter(Mandatory = $true)]$Errors
  )

  if ($CopyReplacements.Count -ne $TaskReplacements.Count) {
    Add-DingdongCopyError $Errors 'task-replacement-count-mismatch' '' 'Task replacements do not match the approved copy file.'
    return
  }
  foreach ($copyReplacement in $CopyReplacements) {
    $matches = @($TaskReplacements | Where-Object {
      [string]$_.id -ceq [string]$copyReplacement.id -and
      [string]$_.path -ceq [string]$copyReplacement.path
    })
    if ($matches.Count -ne 1) {
      Add-DingdongCopyError $Errors 'task-target-mismatch' ([string]$copyReplacement.label) 'Approved target is missing or duplicated in the task.'
      continue
    }
    $taskReplacement = $matches[0]
    foreach ($field in @('oldText', 'text', 'mode')) {
      if ([string]$taskReplacement.$field -cne [string]$copyReplacement.$field) {
        Add-DingdongCopyError $Errors 'task-copy-mismatch' ([string]$copyReplacement.label) "Task field changed after copy approval: $field"
      }
    }
  }
}

function Test-DingdongCopyCompliance {
  param(
    [Parameter(Mandatory = $true)][string]$CopyPath,
    [Parameter(Mandatory = $true)][string]$SkillRoot,
    [string]$ExpectedSha256,
    [AllowNull()][object[]]$TaskReplacements
  )

  $errors = [Collections.Generic.List[object]]::new()
  $items = [Collections.Generic.List[object]]::new()
  $copyFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CopyPath).Path)
  $copySha256 = Get-Sha256 $copyFullPath
  $copy = Read-Utf8Json $copyFullPath

  if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
      Add-DingdongCopyError $errors 'invalid-approved-hash' '' 'Approved copy SHA-256 must contain 64 hexadecimal characters.'
    } elseif ($copySha256 -cne $ExpectedSha256.ToUpperInvariant()) {
      Add-DingdongCopyError $errors 'approved-hash-mismatch' '' 'Copy file changed after approval.'
    }
  }
  if (-not (Test-ObjectProperty $copy 'copyVersion') -or [int]$copy.copyVersion -ne 2) {
    Add-DingdongCopyError $errors 'invalid-copy-version' '' 'Dingdong detail copy must declare copyVersion: 2.'
  }
  $templateId = if (Test-ObjectProperty $copy 'templateId') { [string]$copy.templateId } else { '' }
  if ([string]::IsNullOrWhiteSpace($templateId)) {
    Add-DingdongCopyError $errors 'missing-template-id' '' 'copy.json must declare templateId.'
    return [pscustomobject][ordered]@{
      schemaVersion = 2
      ok = $false
      copyPath = $copyFullPath
      copySha256 = $copySha256
      templateId = $templateId
      items = @($items)
      errors = @($errors)
    }
  }

  $context = Get-DingdongTemplateContext -TemplateId $templateId -SkillRoot $SkillRoot
  $definition = Read-Utf8Json $context.definitionPath
  $index = Read-Utf8Json $context.indexPath
  $layerById = Get-DingdongLayerLookup $index
  $grammarById = @{}
  if (-not (Test-ObjectProperty $definition 'copyGrammarBaselinePath') -or
      [string]::IsNullOrWhiteSpace([string]$definition.copyGrammarBaselinePath)) {
    Add-DingdongCopyError $errors 'missing-grammar-baseline' '' 'Dingdong detail template has no template-owned grammar baseline.'
  } else {
    $grammarPath = [IO.Path]::GetFullPath((Join-Path $SkillRoot ([string]$definition.copyGrammarBaselinePath)))
    if (-not (Test-Path -LiteralPath $grammarPath -PathType Leaf)) {
      Add-DingdongCopyError $errors 'missing-grammar-baseline' '' "Template grammar baseline does not exist: $grammarPath"
    } else {
      $grammarBaseline = Read-Utf8Json $grammarPath
      foreach ($grammarTarget in @($grammarBaseline.targets)) {
        $grammarId = [string]$grammarTarget.id
        if ([string]::IsNullOrWhiteSpace($grammarId) -or $grammarById.ContainsKey($grammarId)) {
          Add-DingdongCopyError $errors 'invalid-grammar-baseline' '' "Grammar baseline contains a missing or duplicate target id: $grammarId"
        } else {
          $grammarById[$grammarId] = $grammarTarget
        }
      }
    }
  }
  $maxDelta = 1
  if ((Test-ObjectProperty $definition 'copyValidation') -and
      (Test-ObjectProperty $definition.copyValidation 'maxSegmentCharacterDelta')) {
    $maxDelta = [int]$definition.copyValidation.maxSegmentCharacterDelta
  }
  $board6SideDishTargetIds = @()
  if ((Test-ObjectProperty $definition 'copyValidation') -and
      (Test-ObjectProperty $definition.copyValidation 'board6SideDishTargetIds')) {
    $board6SideDishTargetIds = @($definition.copyValidation.board6SideDishTargetIds | ForEach-Object { [string]$_ })
  }

  $facts = @()
  if (Test-ObjectProperty $copy 'facts') { $facts = @($copy.facts) }
  $factById = @{}
  foreach ($fact in $facts) {
    $id = if (Test-ObjectProperty $fact 'id') { [string]$fact.id } else { '' }
    if ([string]::IsNullOrWhiteSpace($id)) {
      Add-DingdongCopyError $errors 'missing-fact-id' '' 'Every fact must declare a non-empty id.'
      continue
    }
    if ($factById.ContainsKey($id)) {
      Add-DingdongCopyError $errors 'duplicate-fact-id' '' "Duplicate fact id: $id"
      continue
    }
    $factById[$id] = $fact
    foreach ($field in @('kind', 'statement', 'source')) {
      if (-not (Test-ObjectProperty $fact $field) -or [string]::IsNullOrWhiteSpace([string]$fact.$field)) {
        Add-DingdongCopyError $errors 'incomplete-fact' '' "Fact $id is missing $field."
      }
    }
    if ((Test-ObjectProperty $fact 'kind') -and
        @('document', 'image', 'user') -cnotcontains [string]$fact.kind) {
      Add-DingdongCopyError $errors 'invalid-fact-kind' '' "Fact $id has invalid kind: $([string]$fact.kind)"
    }
    if ((Test-ObjectProperty $fact 'category') -and [string]$fact.category -ceq 'side-dish') {
      $sideDishTerms = if (Test-ObjectProperty $fact 'terms') { @($fact.terms | ForEach-Object { [string]$_ }) } else { @() }
      if ($sideDishTerms.Count -eq 0 -or @($sideDishTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne $sideDishTerms.Count) {
        Add-DingdongCopyError $errors 'incomplete-side-dish-fact' '' "Side-dish fact $id must declare non-empty terms."
      }
    }
  }

  $protectedPrefixes = @()
  if (Test-ObjectProperty $definition 'protectedPathPrefixes') {
    $protectedPrefixes = @($definition.protectedPathPrefixes | ForEach-Object { [string]$_ })
  }
  $protectedTargetIds = @{}
  $protectedTargetPaths = @{}
  if (Test-ObjectProperty $definition 'protectedTextTargets') {
    foreach ($protectedTarget in @($definition.protectedTextTargets)) {
      if ((Test-ObjectProperty $protectedTarget 'id') -and $null -ne $protectedTarget.id) {
        $protectedTargetIds[[string]$protectedTarget.id] = $true
      }
      if ((Test-ObjectProperty $protectedTarget 'path') -and
          -not [string]::IsNullOrWhiteSpace([string]$protectedTarget.path)) {
        $protectedTargetPaths[[string]$protectedTarget.path] = $true
      }
    }
  }
  $overrides = @()
  if (Test-ObjectProperty $copy 'protectedOverrides') { $overrides = @($copy.protectedOverrides) }
  if ($overrides.Count -gt 0) {
    Add-DingdongCopyError $errors 'protected-overrides-forbidden' '' 'protectedOverrides is forbidden. Template-protected targets are permanently read-only and must be edited by the user in Photoshop.'
  }
  $replacements = @()
  if (Test-ObjectProperty $copy 'textReplacements') { $replacements = @($copy.textReplacements) }
  if ($replacements.Count -eq 0) {
    Add-DingdongCopyError $errors 'missing-replacements' '' 'copy.json must contain textReplacements.'
  }

  $requiredPrefixByTargetId = @{}
  $requiredTextByTargetId = @{}
  if (Test-ObjectProperty $definition 'styleAdaptedTextTargets') {
    foreach ($target in @($definition.styleAdaptedTextTargets)) {
      if ((Test-ObjectProperty $target 'id') -and
          (Test-ObjectProperty $target 'requiredPrefix') -and
          -not [string]::IsNullOrWhiteSpace([string]$target.requiredPrefix)) {
        $requiredPrefixByTargetId[[string]$target.id] = [string]$target.requiredPrefix
      }
      if ((Test-ObjectProperty $target 'id') -and
          (Test-ObjectProperty $target 'requiredText')) {
        $requiredTextByTargetId[[string]$target.id] = [string]$target.requiredText
      }
    }
  }

  $seenIds = @{}
  $seenPaths = @{}
  $board6SideDishFactByTargetId = @{}
  foreach ($replacement in $replacements) {
    $label = if (Test-ObjectProperty $replacement 'label') { [string]$replacement.label } else { '' }
    if ([string]::IsNullOrWhiteSpace($label)) { $label = '未命名文案' }
    foreach ($field in @('id', 'path', 'oldText', 'text', 'mode', 'evidenceIds')) {
      if (-not (Test-ObjectProperty $replacement $field)) {
        Add-DingdongCopyError $errors 'missing-replacement-field' $label "Replacement is missing $field."
      }
    }
    $id = if (Test-ObjectProperty $replacement 'id') { [string]$replacement.id } else { '' }
    $path = if (Test-ObjectProperty $replacement 'path') { [string]$replacement.path } else { '' }
    $oldText = if (Test-ObjectProperty $replacement 'oldText') { [string]$replacement.oldText } else { '' }
    $newText = if (Test-ObjectProperty $replacement 'text') { [string]$replacement.text } else { '' }
    $mode = if (Test-ObjectProperty $replacement 'mode') { [string]$replacement.mode } else { '' }
    $evidenceIds = if (Test-ObjectProperty $replacement 'evidenceIds') { @($replacement.evidenceIds | ForEach-Object { [string]$_ }) } else { @() }

    if ($requiredPrefixByTargetId.ContainsKey($id)) {
      $requiredPrefix = [string]$requiredPrefixByTargetId[$id]
      if (-not $newText.StartsWith($requiredPrefix, [StringComparison]::Ordinal)) {
        Add-DingdongCopyError $errors 'required-copy-prefix' $label ('版6标题必须以“{0}”开头。' -f $requiredPrefix)
      }
    }
    if ($requiredTextByTargetId.ContainsKey($id)) {
      $requiredText = [string]$requiredTextByTargetId[$id]
      if ($newText -cne $requiredText) {
        Add-DingdongCopyError $errors 'required-exact-copy' $label '版8场景文案必须逐字符固定为“下班回家轻松煮”换行“煮好后热乎上桌”。'
      }
    }

    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($path)) {
      Add-DingdongCopyError $errors 'missing-target-selector' $label 'Every replacement must declare both id and full path.'
    } else {
      if ($seenIds.ContainsKey($id)) { Add-DingdongCopyError $errors 'duplicate-target-id' $label "Duplicate target id: $id" } else { $seenIds[$id] = $true }
      if ($seenPaths.ContainsKey($path)) { Add-DingdongCopyError $errors 'duplicate-target-path' $label "Duplicate target path: $path" } else { $seenPaths[$path] = $true }
      if (-not $layerById.ContainsKey($id)) {
        Add-DingdongCopyError $errors 'unknown-target-id' $label "Target id is not present in the template index: $id"
      } else {
        $layer = $layerById[$id]
        if ([string]$layer.path -cne $path) {
          Add-DingdongCopyError $errors 'target-path-mismatch' $label 'Target path does not match the template index.'
        }
        if ([string]$layer.text -cne $oldText) {
          Add-DingdongCopyError $errors 'old-text-mismatch' $label 'oldText is not character-identical to the template index.'
        }
      }
    }

    $isProtected = $protectedTargetIds.ContainsKey($id) -or $protectedTargetPaths.ContainsKey($path)
    foreach ($prefix in $protectedPrefixes) {
      if ($path -ceq $prefix -or $path.StartsWith($prefix + '/', [StringComparison]::Ordinal)) {
        $isProtected = $true
        break
      }
    }
    if ($isProtected -and $newText -cne $oldText) {
      Add-DingdongCopyError $errors 'immutable-protected-target' $label 'Template-protected text is permanently read-only. Remove this change; the user will edit this location in Photoshop.'
    }

    if (@('structure-adapted', 'verbatim') -cnotcontains $mode) {
      Add-DingdongCopyError $errors 'invalid-copy-mode' $label "Mode must be structure-adapted or verbatim: $mode"
    }
    if ($evidenceIds.Count -eq 0) {
      Add-DingdongCopyError $errors 'missing-evidence' $label 'Every replacement must cite at least one current-product fact.'
    }
    foreach ($evidenceId in $evidenceIds) {
      if (-not $factById.ContainsKey($evidenceId)) {
        Add-DingdongCopyError $errors 'unknown-evidence' $label "Unknown evidence id: $evidenceId"
      }
    }
    if ($board6SideDishTargetIds -ccontains $id) {
      $citedSideDishFactIds = @($evidenceIds | Where-Object {
        $factById.ContainsKey($_) -and
        (Test-ObjectProperty $factById[$_] 'category') -and
        [string]$factById[$_].category -ceq 'side-dish'
      })
      if ($citedSideDishFactIds.Count -eq 0) {
        Add-DingdongCopyError $errors 'missing-board6-side-dish-evidence' $label '版6两个说明必须分别描写配菜，并引用 category=side-dish 的配菜事实。'
      } else {
        $matchingSideDishFactIds = @($citedSideDishFactIds | Where-Object {
          $sideDishFact = $factById[$_]
          $terms = if (Test-ObjectProperty $sideDishFact 'terms') { @($sideDishFact.terms | ForEach-Object { [string]$_ }) } else { @() }
          @($terms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $newText.IndexOf($_, [StringComparison]::Ordinal) -ge 0 }).Count -gt 0
        })
        if ($matchingSideDishFactIds.Count -eq 0) {
          Add-DingdongCopyError $errors 'board6-side-dish-term-missing' $label '版6配菜说明必须在正文中出现所引用配菜事实的 terms 之一。'
        } elseif ($matchingSideDishFactIds.Count -gt 1) {
          Add-DingdongCopyError $errors 'ambiguous-board6-side-dish-copy' $label '版6每个说明只可绑定并描写一种配菜。'
        } else {
          $board6SideDishFactByTargetId[$id] = [string]$matchingSideDishFactIds[0]
        }
      }
    }

    $sourceGrammar = @()
    $proposedGrammar = @()
    $sourceCounts = @()
    $proposedCounts = @()
    if ($mode -ceq 'verbatim') {
      if (-not (Test-ObjectProperty $replacement 'sourceText')) {
        Add-DingdongCopyError $errors 'missing-source-text' $label 'Verbatim replacement must declare sourceText.'
      } elseif ([string]$replacement.sourceText -cne $newText) {
        Add-DingdongCopyError $errors 'verbatim-mismatch' $label 'Verbatim text differs from sourceText.'
      }
    } elseif ($mode -ceq 'structure-adapted') {
      if (Test-DingdongBlock4Path $path) {
        $forbiddenBlock4Term = Get-DingdongBlock4ForbiddenPrepPackagingTerm $newText
        if ($null -ne $forbiddenBlock4Term) {
          $block4Message = '版4普通适配文案禁止描述分装、装好、切好、整包等预制或包装状态，命中“{0}”。请改写为食材、口感、风味或成品表现，任务不会创建。' -f $forbiddenBlock4Term
          Add-DingdongCopyError $errors 'forbidden-block4-prep-packaging-copy' $label $block4Message
        }
        $forbiddenBlock4InstructionTerm = Get-DingdongBlock4ForbiddenInstructionTerm $newText
        if ($null -ne $forbiddenBlock4InstructionTerm) {
          $block4InstructionMessage = '版4普通适配文案永久禁止复述使用步骤或烹饪操作，命中“{0}”。请只写食材特征、口感、风味或成品表现，任务不会创建。' -f $forbiddenBlock4InstructionTerm
          Add-DingdongCopyError $errors 'forbidden-block4-instruction-copy' $label $block4InstructionMessage
        }
      }
      if (-not (Test-ObjectProperty $replacement 'lines')) {
        Add-DingdongCopyError $errors 'missing-lines' $label 'Structure-adapted replacement must declare lines.'
      } else {
        $lines = @($replacement.lines)
        $baselineLines = @()
        if (-not $grammarById.ContainsKey($id)) {
          Add-DingdongCopyError $errors 'missing-target-grammar' $label "Template grammar baseline has no source grammar for target $id."
        } else {
          $baselineLines = @($grammarById[$id].lines)
          if ($baselineLines.Count -ne $lines.Count) {
            Add-DingdongCopyError $errors 'source-grammar-line-count-mismatch' $label 'Task source grammar line count differs from the template baseline.'
          }
        }
        $sourceLines = @(Get-DingdongContentLines $oldText)
        $proposedLines = @(Get-DingdongContentLines $newText)
        $sourceTrailingLineBreaks = Get-DingdongTrailingLineBreakCount $oldText
        $proposedTrailingLineBreaks = Get-DingdongTrailingLineBreakCount $newText
        if ($sourceTrailingLineBreaks -ne $proposedTrailingLineBreaks) {
          Add-DingdongCopyError $errors 'trailing-line-break-mismatch' $label 'Trailing line-break count differs between original and proposed text.'
        }
        if ($sourceLines.Count -ne $proposedLines.Count -or $lines.Count -ne $sourceLines.Count) {
          Add-DingdongCopyError $errors 'line-count-mismatch' $label 'Original, proposed, and annotated line counts must match.'
        }
        $lineCount = [Math]::Min($lines.Count, [Math]::Min($sourceLines.Count, $proposedLines.Count))
        for ($lineIndex = 0; $lineIndex -lt $lineCount; $lineIndex++) {
          $line = $lines[$lineIndex]
          $sourceSegments = if (Test-ObjectProperty $line 'sourceSegments') { @($line.sourceSegments) } else { @() }
          $proposedSegments = if (Test-ObjectProperty $line 'proposedSegments') { @($line.proposedSegments) } else { @() }
          if ($lineIndex -lt $baselineLines.Count) {
            $baselineSegments = @($baselineLines[$lineIndex].sourceSegments)
            if (-not (Test-DingdongSegmentsEqual -Left $sourceSegments -Right $baselineSegments)) {
              Add-DingdongCopyError $errors 'source-grammar-baseline-mismatch' $label "Source grammar differs from the template baseline on line $($lineIndex + 1)."
            }
            $sourceSegments = $baselineSegments
          }
          $sourceLineIsEmpty = [string]::IsNullOrEmpty([string]$sourceLines[$lineIndex])
          $proposedLineIsEmpty = [string]::IsNullOrEmpty([string]$proposedLines[$lineIndex])
          if ($sourceLineIsEmpty -and $proposedLineIsEmpty) {
            if ($sourceSegments.Count -ne 0 -or $proposedSegments.Count -ne 0) {
              Add-DingdongCopyError $errors 'empty-line-annotation' $label "Blank line $($lineIndex + 1) must use empty sourceSegments and proposedSegments."
            }
            $sourceGrammar += '空行'
            $proposedGrammar += '空行'
            $sourceCounts += '0'
            $proposedCounts += '0'
            continue
          }
          if ($sourceLineIsEmpty -ne $proposedLineIsEmpty) {
            Add-DingdongCopyError $errors 'blank-line-mismatch' $label "Blank-line position differs on line $($lineIndex + 1)."
          }
          Test-DingdongSegmentSet $sourceSegments 'source' $label $errors
          Test-DingdongSegmentSet $proposedSegments 'proposed' $label $errors
          foreach ($proposedSegment in $proposedSegments) {
            if ([string]$proposedSegment.text -match '^入\p{IsCJKUnifiedIdeographs}$') {
              $ruNounMessage = '结构适配文案禁止使用二字“入+名词”词组：{0}。代理生成的普通候选请先改写；若这是用户明确指定的逐字替换，请把合并后的目标全文及 sourceText 登记为 verbatim，并记录 userInstruction。' -f [string]$proposedSegment.text
              Add-DingdongCopyError $errors 'forbidden-ru-noun-pattern' $label $ruNounMessage
            }
          }
          if ((Convert-DingdongSegmentsToText $sourceSegments) -cne $sourceLines[$lineIndex]) {
            Add-DingdongCopyError $errors 'source-reconstruction-mismatch' $label "Source segments do not reconstruct line $($lineIndex + 1)."
          }
          if ((Convert-DingdongSegmentsToText $proposedSegments) -cne $proposedLines[$lineIndex]) {
            Add-DingdongCopyError $errors 'proposed-reconstruction-mismatch' $label "Proposed segments do not reconstruct line $($lineIndex + 1)."
          }
          if ($sourceSegments.Count -ne $proposedSegments.Count) {
            Add-DingdongCopyError $errors 'segment-count-mismatch' $label "Segment count differs on line $($lineIndex + 1)."
          }
          $segmentCount = [Math]::Min($sourceSegments.Count, $proposedSegments.Count)
          for ($segmentIndex = 0; $segmentIndex -lt $segmentCount; $segmentIndex++) {
            $sourceSegment = $sourceSegments[$segmentIndex]
            $proposedSegment = $proposedSegments[$segmentIndex]
            if ([string]$sourceSegment.pos -cne [string]$proposedSegment.pos) {
              Add-DingdongCopyError $errors 'pos-mismatch' $label "Part of speech differs at line $($lineIndex + 1), segment $($segmentIndex + 1)."
            }
            if ([string]$sourceSegment.role -cne [string]$proposedSegment.role) {
              Add-DingdongCopyError $errors 'role-mismatch' $label "Semantic role differs at line $($lineIndex + 1), segment $($segmentIndex + 1)."
            }
            if ([string]$sourceSegment.separatorAfter -cne [string]$proposedSegment.separatorAfter) {
              Add-DingdongCopyError $errors 'separator-mismatch' $label "Spacing or punctuation differs at line $($lineIndex + 1), segment $($segmentIndex + 1)."
            }
            $sourceLength = Get-DingdongVisibleLength ([string]$sourceSegment.text)
            $proposedLength = Get-DingdongVisibleLength ([string]$proposedSegment.text)
            if ([Math]::Abs($sourceLength - $proposedLength) -gt $maxDelta) {
              Add-DingdongCopyError $errors 'segment-length-mismatch' $label "Character difference exceeds $maxDelta at line $($lineIndex + 1), segment $($segmentIndex + 1)."
            }
          }
          $sourceClauseLengths = @(Get-DingdongClauseLengths $sourceSegments)
          $proposedClauseLengths = @(Get-DingdongClauseLengths $proposedSegments)
          if ($sourceClauseLengths.Count -ne $proposedClauseLengths.Count) {
            Add-DingdongCopyError $errors 'clause-count-mismatch' $label "Clause count differs on line $($lineIndex + 1)."
          }
          $clauseCount = [Math]::Min($sourceClauseLengths.Count, $proposedClauseLengths.Count)
          for ($clauseIndex = 0; $clauseIndex -lt $clauseCount; $clauseIndex++) {
            if ([Math]::Abs($sourceClauseLengths[$clauseIndex] - $proposedClauseLengths[$clauseIndex]) -gt $maxDelta) {
              Add-DingdongCopyError $errors 'clause-length-mismatch' $label "Clause character difference exceeds $maxDelta at line $($lineIndex + 1), clause $($clauseIndex + 1)."
            }
          }
          $sourceGrammar += Get-DingdongGrammarLabel $sourceSegments
          $proposedGrammar += Get-DingdongGrammarLabel $proposedSegments
          $sourceCounts += Get-DingdongCountLabel $sourceSegments
          $proposedCounts += Get-DingdongCountLabel $proposedSegments
        }
      }
    }

    if (Test-ObjectProperty $definition 'legacyCopyTerms') {
      foreach ($termValue in @($definition.legacyCopyTerms)) {
        $term = [string]$termValue
        if ($newText.Contains($term)) {
          $supported = $false
          foreach ($evidenceId in $evidenceIds) {
            if ($factById.ContainsKey($evidenceId) -and [string]$factById[$evidenceId].statement -like "*$term*") {
              $supported = $true
              break
            }
          }
          if (-not $supported) {
            Add-DingdongCopyError $errors 'unsupported-legacy-term' $label "Legacy template term lacks current-product evidence: $term"
          }
        }
      }
    }

    $evidenceSummary = @($evidenceIds | ForEach-Object {
      if ($factById.ContainsKey($_)) { [string]$factById[$_].statement } else { "UNKNOWN:$_" }
    }) -join '；'
    [void]$items.Add([pscustomobject][ordered]@{
      label = $label
      id = $id
      path = $path
      mode = $mode
      oldText = $oldText
      text = $newText
      sourceGrammar = ($sourceGrammar -join ' / ')
      proposedGrammar = ($proposedGrammar -join ' / ')
      sourceCounts = ($sourceCounts -join ' / ')
      proposedCounts = ($proposedCounts -join ' / ')
      evidence = $evidenceSummary
    })
  }

  if ($board6SideDishFactByTargetId.Count -gt 1) {
    $boundSideDishFactIds = @($board6SideDishFactByTargetId.Values | Select-Object -Unique)
    if ($boundSideDishFactIds.Count -ne $board6SideDishFactByTargetId.Count) {
      Add-DingdongCopyError $errors 'duplicate-board6-side-dish-copy' '' '版6两个说明必须分别描写不同配菜，不得重复绑定同一种配菜。'
    }
  }

  $corpus = (@($facts | ForEach-Object { [string]$_.statement }) + @($replacements | ForEach-Object {
    [string]$_.text
    if (Test-ObjectProperty $_ 'sourceText') { [string]$_.sourceText }
  })) -join "`n"
  $defaultConflictGroups = @(
    [pscustomobject]@{ terms = @('肉末', '肉沫') }
  )
  $decisions = if (Test-ObjectProperty $copy 'terminologyDecisions') { @($copy.terminologyDecisions) } else { @() }
  foreach ($group in $defaultConflictGroups) {
    $present = @($group.terms | Where-Object { $corpus.Contains([string]$_) })
    if ($present.Count -lt 2) { continue }
    $matchingDecisions = @($decisions | Where-Object {
      $decisionTerms = @($_.terms | ForEach-Object { [string]$_ })
      ($group.terms | Where-Object { $decisionTerms -cnotcontains [string]$_ }).Count -eq 0
    })
    if ($matchingDecisions.Count -ne 1) {
      Add-DingdongCopyError $errors 'unresolved-terminology-conflict' '' "Conflicting terminology requires one decision: $($group.terms -join '/')"
      continue
    }
    $decision = $matchingDecisions[0]
    $decisionEvidenceIds = if (Test-ObjectProperty $decision 'evidenceIds') {
      @($decision.evidenceIds | ForEach-Object { [string]$_ })
    } else {
      @()
    }
    if ($decisionEvidenceIds.Count -eq 0) {
      Add-DingdongCopyError $errors 'missing-terminology-evidence' '' 'Terminology decision must cite current-product evidence.'
    }
    foreach ($decisionEvidenceId in $decisionEvidenceIds) {
      if (-not $factById.ContainsKey($decisionEvidenceId)) {
        Add-DingdongCopyError $errors 'unknown-terminology-evidence' '' "Unknown terminology evidence id: $decisionEvidenceId"
      }
    }
    $allowedByReplacement = if (Test-ObjectProperty $decision 'allowedByReplacement') {
      @($decision.allowedByReplacement)
    } else {
      @()
    }
    $seenTerminologyBindings = @{}
    foreach ($binding in $allowedByReplacement) {
      foreach ($field in @('id', 'path', 'allowedTerm', 'evidenceIds', 'userInstruction')) {
        if (-not (Test-ObjectProperty $binding $field)) {
          Add-DingdongCopyError $errors 'missing-terminology-binding-field' '' "Terminology target binding is missing $field."
        }
      }
      $bindingId = if (Test-ObjectProperty $binding 'id') { [string]$binding.id } else { '' }
      $bindingPath = if (Test-ObjectProperty $binding 'path') { [string]$binding.path } else { '' }
      $allowedTerm = if (Test-ObjectProperty $binding 'allowedTerm') { [string]$binding.allowedTerm } else { '' }
      $bindingInstruction = if (Test-ObjectProperty $binding 'userInstruction') { [string]$binding.userInstruction } else { '' }
      $bindingEvidenceIds = if (Test-ObjectProperty $binding 'evidenceIds') {
        @($binding.evidenceIds | ForEach-Object { [string]$_ })
      } else {
        @()
      }
      if ([string]::IsNullOrWhiteSpace($bindingId) -or [string]::IsNullOrWhiteSpace($bindingPath)) {
        Add-DingdongCopyError $errors 'missing-terminology-binding-target' '' 'Terminology target binding requires an exact id and full path.'
      } else {
        $bindingKey = "$bindingId`n$bindingPath"
        if ($seenTerminologyBindings.ContainsKey($bindingKey)) {
          Add-DingdongCopyError $errors 'duplicate-terminology-binding' '' "Duplicate terminology target binding: $bindingId"
        } else {
          $seenTerminologyBindings[$bindingKey] = $true
        }
        $bindingMatches = @($replacements | Where-Object {
          [string]$_.id -ceq $bindingId -and [string]$_.path -ceq $bindingPath
        })
        if ($bindingMatches.Count -ne 1) {
          Add-DingdongCopyError $errors 'terminology-binding-target-mismatch' '' 'Every terminology target binding must match exactly one replacement.'
        }
      }
      if ($group.terms -cnotcontains $allowedTerm) {
        Add-DingdongCopyError $errors 'invalid-terminology-binding-term' '' "Terminology target binding uses a term outside the conflict group: $allowedTerm"
      }
      if ([string]::IsNullOrWhiteSpace($bindingInstruction)) {
        Add-DingdongCopyError $errors 'missing-terminology-binding-instruction' '' 'Terminology target binding must include the user instruction.'
      }
      if ($bindingEvidenceIds.Count -eq 0) {
        Add-DingdongCopyError $errors 'missing-terminology-binding-evidence' '' 'Terminology target binding must cite its source evidence.'
      }
      foreach ($bindingEvidenceId in $bindingEvidenceIds) {
        if (-not $factById.ContainsKey($bindingEvidenceId)) {
          Add-DingdongCopyError $errors 'unknown-terminology-binding-evidence' '' "Unknown terminology binding evidence id: $bindingEvidenceId"
        }
      }
    }
    $hasAllowedByMode = Test-ObjectProperty $decision 'allowedByMode'
    if (-not $hasAllowedByMode -and $allowedByReplacement.Count -eq 0) {
      Add-DingdongCopyError $errors 'missing-terminology-mode-map' '' 'Terminology decision must declare allowedByMode or exact allowedByReplacement bindings.'
      continue
    }
    foreach ($replacement in $replacements) {
      $mode = [string]$replacement.mode
      $text = [string]$replacement.text
      $hits = @($group.terms | Where-Object { $text.Contains([string]$_) })
      if ($hits.Count -eq 0) { continue }
      $targetBindings = @($allowedByReplacement | Where-Object {
        [string]$_.id -ceq [string]$replacement.id -and
        [string]$_.path -ceq [string]$replacement.path
      })
      if ($targetBindings.Count -gt 1) {
        Add-DingdongCopyError $errors 'duplicate-terminology-binding' ([string]$replacement.label) 'More than one terminology binding matched this replacement.'
        continue
      }
      $allowed = ''
      if ($targetBindings.Count -eq 1) {
        $allowed = [string]$targetBindings[0].allowedTerm
      } else {
        $property = if ($hasAllowedByMode) { $decision.allowedByMode.PSObject.Properties[$mode] } else { $null }
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
          Add-DingdongCopyError $errors 'missing-terminology-mode' ([string]$replacement.label) "No approved terminology for mode or exact target: $mode"
          continue
        }
        $allowed = [string]$property.Value
      }
      foreach ($hit in $hits) {
        if ([string]$hit -cne $allowed) {
          Add-DingdongCopyError $errors 'terminology-mismatch' ([string]$replacement.label) "Term $hit is not approved for mode or target; use $allowed."
        }
      }
    }
  }

  if ($null -ne $TaskReplacements) {
    Test-DingdongTaskReplacementBinding $replacements @($TaskReplacements) $errors
  }

  return [pscustomobject][ordered]@{
    schemaVersion = 2
    ok = ($errors.Count -eq 0)
    copyPath = $copyFullPath
    copySha256 = $copySha256
    templateId = $templateId
    definitionPath = $context.definitionPath
    indexPath = $context.indexPath
    replacementCount = $replacements.Count
    items = @($items)
    errors = @($errors)
  }
}
