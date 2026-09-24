param(
  [Parameter(Mandatory = $true)][string]$TaskPath,
  [Parameter(Mandatory = $true)][string]$RunPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'psd-job-photoshop.ps1')
. (Join-Path $PSScriptRoot 'psd-job-catalog.ps1')
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')

$taskFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TaskPath).Path)
$runFullPath = [IO.Path]::GetFullPath($RunPath)
if (Test-Path -LiteralPath $runFullPath) {
  throw "Run file already exists. Use a new RunPath or complete the existing run: $runFullPath"
}

$task = Read-Utf8Json $taskFullPath
$skillRoot = Split-Path -Parent $PSScriptRoot
$isCopyOnly = ((Test-ObjectProperty $task 'workflow') -and [string]$task.workflow -ceq 'dingdong-detail') -or
  ((Test-ObjectProperty $task 'productionScope') -and [string]$task.productionScope -ceq 'dingdong-copy-only')
if ($isCopyOnly) {
  # 文案确认只授权文字写入；在复制或打开 PSD 前拦截误加的图片与显隐操作。
  foreach ($field in @('imageTransfers', 'visibilityChanges', 'sceneCards')) {
    $items = if (Test-ObjectProperty $task $field) { @($task.$field | Where-Object { $null -ne $_ }) } else { @() }
    if ($items.Count -gt 0) { throw "Dingdong copy-only task cannot contain ${field}." }
  }
}
if ((Test-ObjectProperty $task 'workflow') -and [string]$task.workflow -ceq 'dingdong-detail') {
  if (-not (Test-ObjectProperty $task 'copyReview') -or $null -eq $task.copyReview) {
    throw 'Dingdong detail task must contain copyReview.'
  }
  foreach ($field in @('copyPath', 'copySha256', 'copyVersion')) {
    if (-not (Test-ObjectProperty $task.copyReview $field)) {
      throw "Dingdong detail copyReview is missing $field."
    }
  }
  if ([int]$task.copyReview.copyVersion -ne 2) {
    throw 'Dingdong detail copyReview must declare copyVersion: 2.'
  }
  $taskDirectory = Split-Path -Parent $taskFullPath
  $reviewCopyPath = Resolve-JobPath -Path ([string]$task.copyReview.copyPath) -BaseDirectory $taskDirectory
  $compliance = Test-DingdongCopyCompliance `
    -CopyPath $reviewCopyPath `
    -SkillRoot $skillRoot `
    -ExpectedSha256 ([string]$task.copyReview.copySha256) `
    -TaskReplacements @($task.textReplacements)
  if (-not $compliance.ok) {
    $messages = @($compliance.errors | ForEach-Object { "$([string]$_.code): $([string]$_.message)" })
    throw "Dingdong copy validation failed before working-copy creation: $($messages -join ' | ')"
  }
  if (-not (Test-ObjectProperty $task 'source') -or
      -not (Test-ObjectProperty $task.source 'templateId') -or
      [string]$task.source.templateId -cne [string]$compliance.templateId) {
    throw 'Dingdong task templateId does not match the approved copy file.'
  }
}
$job = Resolve-PsdJob -Task $task -TaskPath $taskFullPath -SkillRoot $skillRoot -RunPath $runFullPath

$sourceOpenState = Get-OpenPhotoshopDocumentState -Path $job.sourcePsdPath
if ($sourceOpenState.count -gt 1) { throw "Source PSD is open more than once: $($job.sourcePsdPath)" }
if ($sourceOpenState.count -eq 1 -and $sourceOpenState.documents[0].saved -ne $true) {
  throw "Source PSD has unsaved Photoshop changes: $($job.sourcePsdPath)"
}
foreach ($sourceImagePsd in @($job.imageTransfers | Where-Object { Test-ObjectProperty $_ 'sourcePsdPath' } | ForEach-Object { [string]$_.sourcePsdPath } | Select-Object -Unique)) {
  $state = Get-OpenPhotoshopDocumentState -Path $sourceImagePsd
  if ($state.count -gt 1 -or ($state.count -eq 1 -and $state.documents[0].saved -ne $true)) {
    throw "Image source PSD is open with an unsafe state: $sourceImagePsd"
  }
}

$targetExisted = Test-Path -LiteralPath $job.targetPsdPath -PathType Leaf
$targetHashBefore = if ($targetExisted) { Get-Sha256 $job.targetPsdPath } else { $null }
$workingDirectory = Split-Path -Parent $job.workingPsdPath
if ($workingDirectory) { New-Item -ItemType Directory -Force -Path $workingDirectory | Out-Null }
if (Test-Path -LiteralPath $job.workingPsdPath) { throw "Working PSD already exists: $($job.workingPsdPath)" }
if ($job.preview.enabled -and (Test-Path -LiteralPath $job.preview.path) -and -not $job.overwriteExistingOutputs) {
  throw "Preview output already exists and overwriteExistingOutputs is false: $($job.preview.path)"
}

Copy-Item -LiteralPath $job.sourcePsdPath -Destination $job.workingPsdPath
$sourceHash = Get-Sha256 $job.sourcePsdPath
$workingInitialHash = Get-Sha256 $job.workingPsdPath
if ($sourceHash -cne $workingInitialHash) { throw 'Working copy hash does not match the source before editing.' }

$temporaryResult = Join-Path $env:TEMP "codex-psd-prepared-$([guid]::NewGuid().ToString('N')).json"
try {
  $prepared = if ([string]$job.workflow -eq 'catalog-artboards') {
    Invoke-PsdCatalogJobApply -Job $job -ResultPath $temporaryResult
  } else {
    Invoke-PsdJobApply -Job $job -ResultPath $temporaryResult
  }
  if ($prepared.ok -ne $true -or $prepared.saved -ne $true) { throw 'Photoshop did not prepare a valid saved working copy.' }
  if (-not (Test-Path -LiteralPath $job.workingPsdPath -PathType Leaf)) { throw 'Working PSD is missing after Photoshop save.' }
  if ($job.preview.enabled -and -not (Test-Path -LiteralPath $job.preview.path -PathType Leaf)) { throw 'Preview is missing after preparation.' }

  $allWarnings = @($job.warnings) + @($prepared.warnings)
  $run = [ordered]@{
    runVersion = 1
    state = 'prepared'
    workflow = $job.workflow
    taskPath = $job.taskPath
    copyReview = if (Test-ObjectProperty $task 'copyReview') { $task.copyReview } else { $null }
    sourceTemplateId = $job.sourceTemplateId
    sourcePsdPath = $job.sourcePsdPath
    sourcePsdSha256 = $sourceHash
    targetPsdPath = $job.targetPsdPath
    targetExisted = $targetExisted
    targetPsdSha256Before = $targetHashBefore
    workingPsdPath = $job.workingPsdPath
    workingPsdSha256 = Get-Sha256 $job.workingPsdPath
    backupExistingTarget = ((Test-ObjectProperty $job 'backupExistingTarget') -and [bool]$job.backupExistingTarget)
    backupPsdPath = $null
    previewPath = if ($job.preview.enabled) { $job.preview.path } else { $null }
    finalOutput = $job.finalOutput
    organizeUsedAssets = $job.organizeUsedAssets
    overwriteExistingOutputs = $job.overwriteExistingOutputs
    textReplacements = @($job.textReplacements)
    visibilityChanges = @($job.visibilityChanges)
    temporaryCompatibility = $job.temporaryCompatibility
    protectedTextTargets = @($job.protectedTextTargets)
    imageTransfers = @($job.imageTransfers)
    catalog = $job.catalog
    preparedResult = $prepared
    reopenValidation = $null
    finalPsdSha256 = $null
    outputs = @()
    warnings = @($allWarnings)
    errors = @()
  }
  Write-Utf8Json -Path $runFullPath -Value $run | Out-Null
  Get-Content -LiteralPath $runFullPath -Encoding UTF8 -Raw
} catch {
  $failure = [ordered]@{
    runVersion = 1
    state = 'failed'
    workflow = $job.workflow
    taskPath = $job.taskPath
    copyReview = if (Test-ObjectProperty $task 'copyReview') { $task.copyReview } else { $null }
    sourcePsdPath = $job.sourcePsdPath
    targetPsdPath = $job.targetPsdPath
    workingPsdPath = $job.workingPsdPath
    warnings = @($job.warnings)
    errors = @($_.Exception.Message)
  }
  Write-Utf8Json -Path $runFullPath -Value $failure | Out-Null
  throw
} finally {
  Remove-Item -LiteralPath $temporaryResult -Force -ErrorAction SilentlyContinue
}
