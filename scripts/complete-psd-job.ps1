param(
  [Parameter(Mandatory = $true)][string]$RunPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'psd-job-photoshop.ps1')

$runFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RunPath).Path)
$run = Read-Utf8Json $runFullPath
if ([int]$run.runVersion -ne 1) { throw '旧运行记录不再兼容。请重新运行 prepare-psd-job.ps1。' }
if ([string]$run.state -eq 'committed') {
  Get-Content -LiteralPath $runFullPath -Encoding UTF8 -Raw
  return
}
if ([string]$run.state -eq 'failed' -and -not $run.finalPsdSha256) {
  $run.state = 'prepared'
  $run.errors = @()
} elseif ([string]$run.state -ne 'prepared') {
  throw "Run state must be prepared, not $($run.state)."
}
foreach ($path in @([string]$run.sourcePsdPath, [string]$run.workingPsdPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required PSD is missing: $path" }
}
if ((Get-Sha256 $run.sourcePsdPath) -cne [string]$run.sourcePsdSha256) { throw 'Source PSD changed after preparation.' }
if ((Get-Sha256 $run.workingPsdPath) -cne [string]$run.workingPsdSha256) { throw 'Working PSD changed after preparation.' }

$targetExistsNow = Test-Path -LiteralPath $run.targetPsdPath -PathType Leaf
if ([bool]$run.targetExisted -ne $targetExistsNow) { throw 'Target PSD existence changed after preparation.' }
if ($targetExistsNow -and (Get-Sha256 $run.targetPsdPath) -cne [string]$run.targetPsdSha256Before) {
  throw 'Target PSD changed after preparation.'
}

$targetDirectory = Split-Path -Parent $run.targetPsdPath
if ($targetDirectory) { New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null }
$extension = [IO.Path]::GetExtension([string]$run.targetPsdPath)
$stem = [IO.Path]::GetFileNameWithoutExtension([string]$run.targetPsdPath)
$backupRequested = (Test-ObjectProperty $run 'backupExistingTarget') -and [bool]$run.backupExistingTarget
$backupPath = $null
if ($targetExistsNow -and $backupRequested) {
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backupPath = Join-Path $targetDirectory "$stem.backup-$timestamp$extension"
}
$stagingPath = Join-Path $targetDirectory "$stem.codex-staging-$([guid]::NewGuid().ToString('N'))$extension"
$targetCommitted = $false

try {
  if ($backupPath) {
    Copy-Item -LiteralPath $run.targetPsdPath -Destination $backupPath
    if ((Get-Sha256 $backupPath) -cne [string]$run.targetPsdSha256Before) { throw 'Backup hash verification failed.' }
  }
  Copy-Item -LiteralPath $run.workingPsdPath -Destination $stagingPath
  if ((Get-Sha256 $stagingPath) -cne [string]$run.workingPsdSha256) { throw 'Commit staging hash verification failed.' }
  Move-Item -LiteralPath $stagingPath -Destination $run.targetPsdPath -Force
  $targetCommitted = $true
  if ((Get-Sha256 $run.targetPsdPath) -cne [string]$run.workingPsdSha256) { throw 'Committed PSD hash differs from the working copy.' }

  $verificationJob = [pscustomobject]@{
    textReplacements = @($run.textReplacements)
    protectedTextTargets = @($run.protectedTextTargets)
    preparedResult = $run.preparedResult
  }
  $reopenValidation = Test-PsdJobSavedTargets -Job $verificationJob -DocumentPath $run.targetPsdPath
  if ($reopenValidation.ok -ne $true) { throw "Reopen validation failed: $($reopenValidation.errors -join '; ')" }

  $outputErrors = @()
  $organizationResult = $null
  if ($run.organizeUsedAssets -and $run.organizeUsedAssets -ne $false) {
    try {
      if ($run.organizeUsedAssets -is [bool]) { throw 'organizeUsedAssets must provide psdPath/workDir when enabled.' }
      $organizationArguments = @{
        PsdPath = [string]$run.organizeUsedAssets.psdPath
        WorkDir = [string]$run.organizeUsedAssets.workDir
      }
      if ((Test-ObjectProperty $run.organizeUsedAssets 'journalPath') -and
          -not [string]::IsNullOrWhiteSpace([string]$run.organizeUsedAssets.journalPath)) {
        $organizationArguments.JournalPath = [string]$run.organizeUsedAssets.journalPath
      }
      $organizationSourceLayerIds = @(Get-UsedAssetSourceLayerIdsForCompletion -Run $run)
      if ($organizationSourceLayerIds.Count -gt 0) {
        $organizationArguments.SourceLayerIds = $organizationSourceLayerIds
      }
      $organizationResult = & (Join-Path $PSScriptRoot 'organize-used-assets.ps1') @organizationArguments | ConvertFrom-Json
    } catch {
      $outputErrors += "素材整理未完成：$($_.Exception.Message)"
    }
  }

  $outputs = @()
  if ($run.finalOutput) {
    try {
      $type = if (Test-ObjectProperty $run.finalOutput 'type') { [string]$run.finalOutput.type } else { 'document-jpg' }
      if ($type -eq 'document-jpg') {
        if (-not (Test-ObjectProperty $run.finalOutput 'path') -or [string]::IsNullOrWhiteSpace([string]$run.finalOutput.path)) {
          throw 'finalOutput.path is required for document-jpg.'
        }
        $args = @{
          SourcePsdPath = [string]$run.targetPsdPath
          OutputPath = [string]$run.finalOutput.path
          MaxWidth = if (Test-ObjectProperty $run.finalOutput 'maxWidth') { [int]$run.finalOutput.maxWidth } else { 0 }
          Quality = if (Test-ObjectProperty $run.finalOutput 'quality') { [int]$run.finalOutput.quality } else { 10 }
        }
        if ([bool]$run.overwriteExistingOutputs) { $args.Overwrite = $true }
        $outputs += (& (Join-Path $PSScriptRoot 'export-psd-jpg.ps1') @args | ConvertFrom-Json)
      } elseif ($type -eq 'artboards') {
        $args = @{
          SourcePsdPath = [string]$run.targetPsdPath
          OutputDirectory = [string]$run.finalOutput.outputDirectory
          ArtboardNames = @($run.finalOutput.artboardNames)
          Format = if (Test-ObjectProperty $run.finalOutput 'format') { [string]$run.finalOutput.format } else { 'jpg' }
          MaxWidth = if (Test-ObjectProperty $run.finalOutput 'maxWidth') { [int]$run.finalOutput.maxWidth } else { 0 }
          Quality = if (Test-ObjectProperty $run.finalOutput 'quality') { [int]$run.finalOutput.quality } else { 10 }
        }
        if ([bool]$run.overwriteExistingOutputs) { $args.Overwrite = $true }
        $outputs += (& (Join-Path $PSScriptRoot 'export-artboards.ps1') @args | ConvertFrom-Json)
      } else {
        throw "Unsupported final output type: $type"
      }
    } catch {
      $outputErrors += $_.Exception.Message
    }
  }

  $run.state = 'committed'
  $run | Add-Member -NotePropertyName psdState -NotePropertyValue 'committed' -Force
  $run | Add-Member -NotePropertyName workflowState -NotePropertyValue $(if ($outputErrors.Count -eq 0) { 'complete' } else { 'needs-attention' }) -Force
  $run | Add-Member -NotePropertyName postCommitErrors -NotePropertyValue @($outputErrors) -Force
  $run.backupPsdPath = $backupPath
  $run.reopenValidation = $reopenValidation
  $run.finalPsdSha256 = Get-Sha256 $run.targetPsdPath
  $run.outputs = @($outputs)
  if ($organizationResult) { $run | Add-Member -NotePropertyName organizationResult -NotePropertyValue $organizationResult -Force }
  $run.warnings = @($run.warnings) + @($outputErrors)
  $run.errors = @()
  Write-Utf8Json -Path $runFullPath -Value $run | Out-Null
  Get-Content -LiteralPath $runFullPath -Encoding UTF8 -Raw
} catch {
  $message = $_.Exception.Message
  $rolledBack = $false
  if ($targetCommitted -and $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    Copy-Item -LiteralPath $backupPath -Destination $run.targetPsdPath -Force
    $rolledBack = $true
  } elseif ($targetCommitted -and -not $targetExistsNow -and (Test-Path -LiteralPath $run.targetPsdPath -PathType Leaf)) {
    Remove-Item -LiteralPath $run.targetPsdPath -Force
    $rolledBack = $true
  }
  $run.state = 'failed'
  $failedPsdState = if ($rolledBack) { 'rolled-back' } elseif ($targetCommitted) { 'committed-unverified' } else { 'not-committed' }
  $run | Add-Member -NotePropertyName psdState -NotePropertyValue $failedPsdState -Force
  $run | Add-Member -NotePropertyName workflowState -NotePropertyValue 'failed' -Force
  $run.backupPsdPath = $backupPath
  $run.errors = @($message)
  Write-Utf8Json -Path $runFullPath -Value $run | Out-Null
  throw
} finally {
  Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
}
