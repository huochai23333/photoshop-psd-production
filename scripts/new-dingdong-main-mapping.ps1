param(
  [Parameter(Mandatory = $true)][string]$ApprovedDetailCopyPath,
  [Parameter(Mandatory = $true)][string]$ApprovedCopySha256,
  [Parameter(Mandatory = $true)][string]$DetailIndexPath,
  [string]$DetailPsdPath,
  [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')

function Normalize-MainText {
  param([string]$Text)
  $normalized = (Normalize-DingdongLineBreaks $Text).TrimEnd([char[]]"`n")
  return $normalized.Replace("`n", "`r")
}

$skillRoot = Split-Path -Parent $PSScriptRoot
$copyPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ApprovedDetailCopyPath).Path)
$compliance = Test-DingdongCopyCompliance -CopyPath $copyPath -SkillRoot $skillRoot -ExpectedSha256 $ApprovedCopySha256
if (-not $compliance.ok) {
  $messages = @($compliance.errors | ForEach-Object { "$([string]$_.code): $([string]$_.message)" })
  throw "Approved detail copy is invalid: $($messages -join ' | ')"
}
$copy = Read-Utf8Json $copyPath
$detailDefinition = Read-Utf8Json $compliance.definitionPath
$mainDefinitionPath = Join-Path $skillRoot 'assets\templates\definitions\dingdong-haoshiguang-main-7board.json'
$mainDefinition = Read-Utf8Json $mainDefinitionPath
$mainIndex = Read-Utf8Json (Join-Path $skillRoot ([string]$mainDefinition.fullIndex.skillRelativePath))
$mainLayerById = @{}
foreach ($document in @($mainIndex.documents)) {
  foreach ($layer in @($document.layers)) { $mainLayerById[[string]$layer.id] = $layer }
}
$detailStepCount = Get-DingdongContiguousStepCount $detailDefinition
$textById = @{}
foreach ($replacement in @($copy.textReplacements)) { $textById[[string]$replacement.id] = $replacement }

$textReplacements = @()
foreach ($target in @($mainDefinition.textTargets)) {
  $mode = [string]$target.mode
  if ($mode -ceq 'sync-detail-current') { continue }
  $text = ''
  if ($mode -ceq 'sync-step-count') {
    $protectedTarget = @($mainDefinition.unchangedTextTargets | Where-Object { [string]$_.targetId -ceq [string]$target.targetId } | Select-Object -First 1)
    if ($protectedTarget.Count -ne 1 -or -not [bool]$protectedTarget[0].allowStepCountSync) {
      throw "invalid-step-count-sync: main target $($target.targetId) is not registered for the narrow count exception."
    }
    if ($detailStepCount -eq [int]$protectedTarget[0].baselineStepCount) { continue }
    if (-not $mainLayerById.ContainsKey([string]$target.targetId) -or
        -not (Test-ObjectProperty $mainLayerById[[string]$target.targetId] 'text')) {
      throw "invalid-step-count-sync: main template index lacks baseline text for target $($target.targetId)."
    }
    $text = Get-DingdongStepCountSynchronizedText `
      -BaselineText ([string]$mainLayerById[[string]$target.targetId].text) `
      -StepCount $detailStepCount `
      -BaselineStepCount ([int]$protectedTarget[0].baselineStepCount) `
      -AllowedStepCounts @($protectedTarget[0].allowedStepCounts | ForEach-Object { [int]$_ })
    $textReplacements += [pscustomobject][ordered]@{
      id = [int]$target.targetId
      text = $text
      generatedFrom = 'sync-step-count'
      stepCount = $detailStepCount
    }
    continue
  } elseif ($mode -ceq 'sync-detail-approved') {
    $parts = @()
    foreach ($sourceId in @($target.sourceDetailIds)) {
      $key = [string]$sourceId
      if (-not $textById.ContainsKey($key)) { throw "Approved detail copy is missing source id $key for main target $($target.targetId)." }
      $parts += Normalize-MainText ([string]$textById[$key].text)
    }
    $text = $parts -join "`r"
  } elseif ($mode -ceq 'compose-detail-approved') {
    $sourceIds = @($target.sourceDetailIds | ForEach-Object { [string]$_ })
    if ($sourceIds.Count -ne 2 -or -not $textById.ContainsKey($sourceIds[0]) -or -not $textById.ContainsKey($sourceIds[1])) {
      throw "Approved detail copy lacks compose sources for main target $($target.targetId)."
    }
    $first = @(Get-DingdongContentLines ([string]$textById[$sourceIds[0]].text))
    $second = @(Get-DingdongContentLines ([string]$textById[$sourceIds[1]].text))
    if ($second.Count -lt 2) { throw "Second compose source needs at least two lines for main target $($target.targetId)." }
    $text = "$($first[0])`r$($second[1])"
  } elseif ($mode -ceq 'verbatim-step-block') {
    $steps = @()
    foreach ($step in @($detailDefinition.currentSteps | Sort-Object { [int]$_.number })) {
      $key = [string]$step.instructionTextId
      if (-not $textById.ContainsKey($key) -or [string]$textById[$key].mode -cne 'verbatim') {
        throw "Approved detail copy lacks verbatim step source $key."
      }
      $steps += Normalize-MainText ([string]$textById[$key].text)
    }
    $text = $steps -join "`r`r"
  } else {
    throw "Unsupported automatic main-text mode: $mode"
  }
  $textReplacements += [pscustomobject][ordered]@{ id = [int]$target.targetId; text = $text; generatedFrom = $mode }
}

$sourceArguments = @{
  DetailIndexPath = $DetailIndexPath
  DetailDefinitionPath = $compliance.definitionPath
  MainDefinitionPath = $mainDefinitionPath
}
if (-not [string]::IsNullOrWhiteSpace($DetailPsdPath)) { $sourceArguments.DetailPsdPath = $DetailPsdPath }
$sourceResolution = & (Join-Path $PSScriptRoot 'resolve-dingdong-detail-sources.ps1') @sourceArguments | ConvertFrom-Json
$imageMappings = @($sourceResolution.items | ForEach-Object {
  [pscustomobject][ordered]@{
    target = [pscustomobject][ordered]@{ id = [int]$_.targetLayerId }
    source = [pscustomobject][ordered]@{ id = [int]$_.sourceLayerId; path = [string]$_.sourcePath }
    name = "详情页板块$([int]$_.screen)图片"
    fit = [string]$_.fit
  }
})
$mapping = [pscustomobject][ordered]@{
  mappingVersion = 2
  generated = $true
  approvedDetailCopy = [pscustomobject][ordered]@{ copyPath = $copyPath; copySha256 = $compliance.copySha256 }
  textReplacements = @($textReplacements)
  imageMappings = @($imageMappings)
  sourceManifest = $sourceResolution
}
Write-Utf8Json -Path $OutputPath -Value $mapping | Out-Null
Get-Content -LiteralPath $OutputPath -Encoding utf8 -Raw
