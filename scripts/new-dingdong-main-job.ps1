param(
  [string]$DetailPsdPath,
  [Parameter(Mandatory = $true)][string]$MappingPath,
  [Parameter(Mandatory = $true)][string]$TargetPsdPath,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [string]$FinalOutputDirectory,
  [string]$DetailWorkDir,
  [switch]$OrganizeUsedAssets
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')

function Get-MainNormalizedContent {
  param([AllowNull()][string]$Text)

  return (Normalize-DingdongLineBreaks $Text).TrimEnd([char[]]"`n")
}

$mappingFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $MappingPath).Path)
$mappingDirectory = Split-Path -Parent $mappingFullPath
$mapping = Read-Utf8Json $mappingFullPath
$skillRoot = Split-Path -Parent $PSScriptRoot
$mainDefinition = Read-Utf8Json (Join-Path $skillRoot 'assets\templates\definitions\dingdong-haoshiguang-main-7board.json')
$mainIndex = Read-Utf8Json (Join-Path $skillRoot ([string]$mainDefinition.fullIndex.skillRelativePath))
$mainLayerById = @{}
foreach ($document in @($mainIndex.documents)) {
  foreach ($layer in @($document.layers)) { $mainLayerById[[string]$layer.id] = $layer }
}
$detailPath = if ([string]::IsNullOrWhiteSpace($DetailPsdPath)) {
  $null
} else {
  [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DetailPsdPath).Path)
}
$mappedTextReplacements = [object[]]::new(0)
if ((Test-ObjectProperty $mapping 'textReplacements') -and @($mapping.textReplacements).Count -gt 0) {
  $mappedTextReplacements = [object[]]@($mapping.textReplacements)
}
$immutableMainTargets = @($mainDefinition.unchangedTextTargets) + @(
  $mainDefinition.textTargets | Where-Object { [string]$_.mode -ceq 'sync-detail-current' }
)
$unchangedTargetIds = @{}
foreach ($target in @($mainDefinition.unchangedTextTargets)) {
  $unchangedTargetIds[[string]$target.targetId] = $target
}
$allowedTextTargets = @{}
foreach ($target in @($mainDefinition.textTargets)) {
  $allowedTextTargets[[string]$target.targetId] = $target
}
$artboardBoundsByName = @{}
foreach ($artboard in @($mainDefinition.artboards)) { $artboardBoundsByName[[string]$artboard.name] = @($artboard.rect) }
$seenTextTargetIds = @{}
$stepCountSyncCandidateIds = @{}
$authorizedStepCountSyncIds = @{}
foreach ($replacement in $mappedTextReplacements) {
  if (-not (Test-ObjectProperty $replacement 'id') -or [string]::IsNullOrWhiteSpace([string]$replacement.id)) {
    throw 'Every main-image text replacement requires an exact target id.'
  }
  $replacementId = [string]$replacement.id
  if ($unchangedTargetIds.ContainsKey($replacementId)) {
    $protectedTarget = $unchangedTargetIds[$replacementId]
    $isCountSyncTarget = (Test-ObjectProperty $protectedTarget 'allowStepCountSync') -and [bool]$protectedTarget.allowStepCountSync
    if (-not $isCountSyncTarget) {
      throw "immutable-protected-target: main-image text is permanently read-only: artboard $([string]$protectedTarget.artboard), $([string]$protectedTarget.label), id $replacementId"
    }
    if (-not $mainLayerById.ContainsKey($replacementId) -or -not (Test-ObjectProperty $mainLayerById[$replacementId] 'text')) {
      throw "invalid-step-count-sync: main template index lacks baseline text for target $replacementId."
    }
    Assert-DingdongStepCountSyncReplacement `
      -Replacement $replacement `
      -BaselineText ([string]$mainLayerById[$replacementId].text) `
      -BaselineStepCount ([int]$protectedTarget.baselineStepCount) `
      -AllowedStepCounts @($protectedTarget.allowedStepCounts | ForEach-Object { [int]$_ }) | Out-Null
    $stepCountSyncCandidateIds[$replacementId] = $true
  }
  if (-not $allowedTextTargets.ContainsKey($replacementId)) {
    throw "Main-image text target is not registered for replacement: $replacementId"
  }
  if ($seenTextTargetIds.ContainsKey($replacementId)) {
    throw "Duplicate main-image text target: $replacementId"
  }
  $registeredTextTarget = $allowedTextTargets[$replacementId]
  if (-not (Test-ObjectProperty $replacement 'allowedBounds') -and $artboardBoundsByName.ContainsKey([string]$registeredTextTarget.artboard)) {
    $replacement | Add-Member -NotePropertyName allowedBounds -NotePropertyValue @($artboardBoundsByName[[string]$registeredTextTarget.artboard]) -Force
  }
  $seenTextTargetIds[$replacementId] = $true
}
if ($mappedTextReplacements.Count -gt 0) {
  if (-not (Test-ObjectProperty $mapping 'approvedDetailCopy') -or $null -eq $mapping.approvedDetailCopy) {
    throw 'Main-image text replacements require approvedDetailCopy with copyPath and copySha256.'
  }
  foreach ($field in @('copyPath', 'copySha256')) {
    if (-not (Test-ObjectProperty $mapping.approvedDetailCopy $field) -or
        [string]::IsNullOrWhiteSpace([string]$mapping.approvedDetailCopy.$field)) {
      throw "approvedDetailCopy is missing $field."
    }
  }
  $detailCopyPath = Resolve-JobPath -Path ([string]$mapping.approvedDetailCopy.copyPath) -BaseDirectory $mappingDirectory
  $detailCompliance = Test-DingdongCopyCompliance `
    -CopyPath $detailCopyPath `
    -SkillRoot $skillRoot `
    -ExpectedSha256 ([string]$mapping.approvedDetailCopy.copySha256)
  if (-not $detailCompliance.ok) {
    $messages = @($detailCompliance.errors | ForEach-Object { "$([string]$_.code): $([string]$_.message)" })
    throw "Approved detail copy is invalid for main-image synchronization: $($messages -join ' | ')"
  }
  $detailCopy = Read-Utf8Json $detailCopyPath
  $detailDefinition = Read-Utf8Json $detailCompliance.definitionPath
  $detailStepCount = Get-DingdongContiguousStepCount $detailDefinition
  $detailTextById = @{}
  foreach ($detailReplacement in @($detailCopy.textReplacements)) {
    $detailTextById[[string]$detailReplacement.id] = $detailReplacement
  }
  foreach ($replacement in $mappedTextReplacements) {
    $replacementId = [string]$replacement.id
    $targetDefinition = $allowedTextTargets[$replacementId]
    $targetMode = [string]$targetDefinition.mode
    if ($targetMode -ceq 'sync-detail-current') {
      throw "immutable-protected-target: main-image sync-detail-current text is permanently read-only: $replacementId"
    }
    $replacementText = if (Test-ObjectProperty $replacement 'text') { [string]$replacement.text } else { '' }
    if ($targetMode -ceq 'sync-step-count') {
      $protectedTarget = $unchangedTargetIds[$replacementId]
      $allowedStepCounts = @($protectedTarget.allowedStepCounts | ForEach-Object { [int]$_ })
      if (-not $stepCountSyncCandidateIds.ContainsKey($replacementId) -or
          -not (Test-ObjectProperty $replacement 'stepCount') -or
          [int]$replacement.stepCount -ne $detailStepCount -or
          $detailStepCount -notin $allowedStepCounts) {
        throw "invalid-step-count-sync: the replacement stepCount must match the approved contiguous detail steps and be one of $($allowedStepCounts -join ', ')."
      }
      $authorizedStepCountSyncIds[$replacementId] = $true
    } elseif ($targetMode -ceq 'sync-detail-approved') {
      $sourceIds = @($targetDefinition.sourceDetailIds | ForEach-Object { [string]$_ })
      $sourceTexts = @()
      foreach ($sourceId in $sourceIds) {
        if (-not $detailTextById.ContainsKey($sourceId)) {
          throw "Approved detail copy is missing source text id $sourceId for main target $replacementId."
        }
        $sourceTexts += Get-MainNormalizedContent ([string]$detailTextById[$sourceId].text)
      }
      $expectedText = $sourceTexts -join "`n"
      if ((Get-MainNormalizedContent $replacementText) -cne $expectedText) {
        throw "Main-image text must exactly synchronize approved detail copy for target $replacementId."
      }
    } elseif ($targetMode -ceq 'compose-detail-approved') {
      $sourceIds = @($targetDefinition.sourceDetailIds | ForEach-Object { [string]$_ })
      if ($sourceIds.Count -ne 2 -or
          -not $detailTextById.ContainsKey($sourceIds[0]) -or
          -not $detailTextById.ContainsKey($sourceIds[1])) {
        throw "Approved detail copy lacks the two sources required for composed main target $replacementId."
      }
      $firstLines = @((Normalize-DingdongLineBreaks ([string]$detailTextById[$sourceIds[0]].text)).Split("`n"))
      $secondLines = @((Normalize-DingdongLineBreaks ([string]$detailTextById[$sourceIds[1]].text)).Split("`n"))
      if ($firstLines.Count -lt 1 -or $secondLines.Count -lt 2) {
        throw "Approved detail copy has insufficient lines for composed main target $replacementId."
      }
      $expectedText = "$($firstLines[0])`n$($secondLines[1])"
      if ((Get-MainNormalizedContent $replacementText) -cne $expectedText) {
        throw "Composed main-image text differs from approved detail copy for target $replacementId."
      }
    } elseif ($targetMode -ceq 'verbatim-step-block') {
      $stepTexts = @()
      foreach ($step in @($detailDefinition.currentSteps | Sort-Object { [int]$_.number })) {
        $stepId = [string]$step.instructionTextId
        if (-not $detailTextById.ContainsKey($stepId)) {
          throw "Approved detail copy is missing verbatim step id $stepId."
        }
        $stepReplacement = $detailTextById[$stepId]
        if ([string]$stepReplacement.mode -cne 'verbatim') {
          throw "Main-image step source is not verbatim: $stepId"
        }
        $stepTexts += [string]$stepReplacement.text
      }
      $normalizedMainSteps = Normalize-DingdongLineBreaks $replacementText
      $searchStart = 0
      foreach ($stepText in $stepTexts) {
        $normalizedStep = Normalize-DingdongLineBreaks $stepText
        $foundAt = $normalizedMainSteps.IndexOf($normalizedStep, $searchStart, [StringComparison]::Ordinal)
        if ($foundAt -lt 0) {
          throw "Main-image step block does not preserve approved verbatim steps in order for target $replacementId."
        }
        $searchStart = $foundAt + $normalizedStep.Length
      }
    }
  }
}
$imageMappings = if (Test-ObjectProperty $mapping 'imageMappings') { @($mapping.imageMappings) } else { @() }
if ($imageMappings.Count -ne 7) { throw 'Dingdong main job requires exactly seven imageMappings.' }
$expectedImageTargets = @{}
foreach ($target in @($mainDefinition.imageTargets)) {
  $expectedImageTargets[[string]$target.targetId] = $target
}
$seenImageTargetIds = @{}
$directImageEntries = @()
$detailImageEntryCount = 0
$transfers = @()
foreach ($entry in $imageMappings) {
  if (-not (Test-ObjectProperty $entry 'target') -or -not $entry.target) {
    throw 'Each image mapping needs a target selector.'
  }
  if (-not (Test-ObjectProperty $entry.target 'id') -or [string]::IsNullOrWhiteSpace([string]$entry.target.id)) {
    throw 'Each main-image mapping target requires an exact id.'
  }
  $targetId = [string]$entry.target.id
  if (-not $expectedImageTargets.ContainsKey($targetId)) {
    throw "Unknown main-image target id: $targetId"
  }
  if ($seenImageTargetIds.ContainsKey($targetId)) {
    throw "Duplicate main-image target id: $targetId"
  }
  $seenImageTargetIds[$targetId] = $true
  $hasImagePath = (Test-ObjectProperty $entry 'imagePath') -and
    -not [string]::IsNullOrWhiteSpace([string]$entry.imagePath)
  $hasSource = (Test-ObjectProperty $entry 'source') -and $null -ne $entry.source
  if ($hasImagePath -eq $hasSource) {
    throw 'Each image mapping must declare exactly one source: imagePath or source.'
  }
  $transfer = [ordered]@{
    target = $entry.target
    name = if (Test-ObjectProperty $entry 'name') { [string]$entry.name } else { '主图图片' }
    fit = if (Test-ObjectProperty $entry 'fit') { [string]$entry.fit } else { 'cover' }
    clip = $true
  }
  if ($hasImagePath) {
    $imagePath = Resolve-JobPath -Path ([string]$entry.imagePath) -BaseDirectory $mappingDirectory
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
      throw "Main-image source file does not exist: $imagePath"
    }
    $transfer.imagePath = $imagePath
    $directImageEntries += [pscustomobject]@{
      targetId = $targetId
      imagePath = $imagePath
    }
  } else {
    if ([string]::IsNullOrWhiteSpace($detailPath)) {
      throw 'DetailPsdPath is required when an image mapping uses a source selector.'
    }
    $detailImageEntryCount++
    $transfer.sourcePsdPath = $detailPath
    $transfer.source = $entry.source
  }
  $transfers += [pscustomobject]$transfer
}
if ($seenImageTargetIds.Count -ne $expectedImageTargets.Count) {
  throw 'Main-image mapping must target every registered artboard image slot exactly once.'
}
if ($directImageEntries.Count -gt 0 -and $detailImageEntryCount -gt 0) {
  throw 'Main-image imageMappings cannot mix direct image files with formal detail-PSD sources.'
}
if ($directImageEntries.Count -gt 0) {
  if (-not (Test-ObjectProperty $mapping 'imageSelectionApproval') -or $null -eq $mapping.imageSelectionApproval) {
    throw 'Direct main-image files require imageSelectionApproval from a displayed seven-artboard mapping.'
  }
  if (-not (Test-ObjectProperty $mapping.imageSelectionApproval 'userInstruction') -or
      [string]::IsNullOrWhiteSpace([string]$mapping.imageSelectionApproval.userInstruction)) {
    throw 'imageSelectionApproval must include the user instruction confirming the displayed mapping.'
  }
  $imageApprovalInstruction = [string]$mapping.imageSelectionApproval.userInstruction
  if ($imageApprovalInstruction -notmatch '确认.{0,8}(图片|七图).{0,8}(映射|选图)|(图片|七图).{0,8}(映射|选图).{0,8}确认') {
    throw 'Direct image mapping requires an explicit user instruction containing “确认图片映射” or equivalent; a generic request to make or remake the main image is not approval.'
  }
  $approvedItems = if (Test-ObjectProperty $mapping.imageSelectionApproval 'items') {
    @($mapping.imageSelectionApproval.items)
  } else {
    @()
  }
  if ($approvedItems.Count -ne $directImageEntries.Count) {
    throw 'imageSelectionApproval items must match every direct image mapping.'
  }
  foreach ($directEntry in $directImageEntries) {
    $matches = @($approvedItems | Where-Object {
      [string]$_.targetId -ceq [string]$directEntry.targetId -and
      (Resolve-JobPath -Path ([string]$_.imagePath) -BaseDirectory $mappingDirectory) -ceq [string]$directEntry.imagePath
    })
    if ($matches.Count -ne 1) {
      throw "Direct image mapping is not approved for target $([string]$directEntry.targetId)."
    }
  }
}
$final = if ($FinalOutputDirectory) {
  [pscustomobject]@{
    type = 'artboards'
    outputDirectory = [IO.Path]::GetFullPath($FinalOutputDirectory)
    artboardNames = @('1', '2', '3', '4', '5', '6', '7')
    format = 'jpg'
    maxWidth = 800
    quality = 12
  }
} else {
  $null
}
$organization = $false
$shouldOrganizeUsedAssets = $OrganizeUsedAssets.IsPresent -or $detailImageEntryCount -eq 7
if ($shouldOrganizeUsedAssets) {
  if ([string]::IsNullOrWhiteSpace($detailPath)) { throw 'DetailPsdPath is required when organizing used assets.' }
  $work = if ([string]::IsNullOrWhiteSpace($DetailWorkDir)) {
    Split-Path -Parent $detailPath
  } else {
    [IO.Path]::GetFullPath($DetailWorkDir)
  }
  $organization = [pscustomobject]@{
    psdPath = $detailPath
    workDir = $work
    journalPath = Join-Path $work '.used-assets-journal.json'
  }
}
$job = [ordered]@{
  jobVersion = 1
  workflow = 'dingdong-main'
  source = [ordered]@{ templateId = 'dingdong-haoshiguang-main-7board' }
  targetPsdPath = [IO.Path]::GetFullPath($TargetPsdPath)
  textReplacements = $mappedTextReplacements
  protectedTextTargets = @($immutableMainTargets | Where-Object {
    -not $authorizedStepCountSyncIds.ContainsKey([string]$_.targetId)
  } | ForEach-Object {
    [pscustomobject][ordered]@{
      id = [int]$_.targetId
      label = [string]$_.label
      artboard = [string]$_.artboard
    }
  })
  imageTransfers = $transfers
  outputs = [ordered]@{
    preview = [ordered]@{ enabled = $true; maxWidth = 1800; quality = 10 }
    final = $final
  }
  organizeUsedAssets = $organization
}
Write-Utf8Json -Path $OutputPath -Value $job | Out-Null
Get-Content -LiteralPath $OutputPath -Encoding UTF8 -Raw
