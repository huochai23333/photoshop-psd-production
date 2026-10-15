$ErrorActionPreference = 'Stop'

if (-not (Get-Command Read-Utf8Json -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'psd-job-common.ps1')
}

# 将版面与词组检查独立加载，主流程只负责事实、保护范围和确认绑定。
. (Join-Path $PSScriptRoot 'dingdong-copy-layout.ps1')

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

  $requiredTextByTargetId = @{}
  if (Test-ObjectProperty $definition 'styleAdaptedTextTargets') {
    foreach ($target in @($definition.styleAdaptedTextTargets)) {
      if ((Test-ObjectProperty $target 'id') -and
          (Test-ObjectProperty $target 'requiredText')) {
        $requiredTextByTargetId[[string]$target.id] = [string]$target.requiredText
      }
    }
  }

  $seenIds = @{}
  $seenPaths = @{}
  # 版6沿用通用事实与文案审核，不再强制标题前缀或配菜分配格式。
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
    # 字数按实际行记录，仅供后续预览参考，不作为语言结构限制。
    $sourceCounts = @((Get-DingdongContentLines $oldText) | ForEach-Object { Get-DingdongVisibleLength $_ })
    $proposedCounts = @((Get-DingdongContentLines $newText) | ForEach-Object { Get-DingdongVisibleLength $_ })
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
      Test-DingdongNaturalCopyLines -Replacement $replacement -OldText $oldText -NewText $newText -Label $label -Errors $errors
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
      sourceLayout = ('{0} 行；尾随换行 {1}' -f @(Get-DingdongContentLines $oldText).Count, (Get-DingdongTrailingLineBreakCount $oldText))
      copyMethod = $(if ($mode -ceq 'verbatim') { '逐字写入' } else { '自然改写；待预览检查版面' })
      sourceCounts = ($sourceCounts -join ' / ')
      proposedCounts = ($proposedCounts -join ' / ')
      evidence = $evidenceSummary
    })
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
