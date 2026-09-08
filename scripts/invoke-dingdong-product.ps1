param(
  [Parameter(Mandatory = $true)][string]$TaskDirectory,
  [Parameter(Mandatory = $true)][string]$ApprovedDetailCopyPath,
  [Parameter(Mandatory = $true)][string]$ApprovedCopySha256,
  [Parameter(Mandatory = $true)][string]$DetailPsdPath,
  [Parameter(Mandatory = $true)][string]$DetailIndexPath,
  [Parameter(Mandatory = $true)][string]$MainTargetPsdPath,
  [string]$DetailWorkDir,
  [string]$MainFinalOutputDirectory,
  [bool]$PrepareMain = $true,
  [bool]$RefreshDetailIndex = $true,
  [switch]$CommitMain,
  [switch]$CleanupDisposable
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$taskRoot = [IO.Path]::GetFullPath($TaskDirectory).TrimEnd('\')
New-Item -ItemType Directory -Force -Path $taskRoot | Out-Null
$statePath = Join-Path $taskRoot 'dingdong-product-state.json'
$mappingPath = Join-Path $taskRoot 'main-mapping.auto.json'
$jobPath = Join-Path $taskRoot 'main-task.json'
$runPath = Join-Path $taskRoot 'main-run.json'
$copyPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ApprovedDetailCopyPath).Path)
$detailPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DetailPsdPath).Path)
$indexPath = [IO.Path]::GetFullPath($DetailIndexPath)

function Save-State { param($Value) Write-Utf8Json -Path $statePath -Value $Value | Out-Null }
function Test-WithinTaskRoot {
  param([string]$Path)
  $full = [IO.Path]::GetFullPath($Path)
  return $full.StartsWith($taskRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Invoke-Phase {
  param([string]$Name, [scriptblock]$Action)
  $timer = [Diagnostics.Stopwatch]::StartNew()
  try { return & $Action }
  finally {
    $timer.Stop()
    $state.phaseTimings += [pscustomobject][ordered]@{ phase = $Name; elapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3); at = [DateTimeOffset]::Now.ToString('o') }
    Save-State $state
  }
}

$existingRun = if (Test-Path -LiteralPath $runPath -PathType Leaf) { Read-Utf8Json $runPath } else { $null }
$runProtectsPreparedWork = $null -ne $existingRun -and [string]$existingRun.state -in @('prepared', 'committed')
$currentDetailPsdSha256 = Get-Sha256 $detailPath

$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) { Read-Utf8Json $statePath } else {
  [pscustomobject][ordered]@{
    stateVersion = 1
    workflow = 'dingdong-product'
    stage = 'copy-approved'
    workflowState = 'in-progress'
    approvedCopyPath = $copyPath
    approvedCopySha256 = $ApprovedCopySha256.ToUpperInvariant()
    detailPsdPath = $detailPath
    detailPsdSha256 = $currentDetailPsdSha256
    detailIndexPath = $indexPath
    mainTargetPsdPath = [IO.Path]::GetFullPath($MainTargetPsdPath)
    mainMappingPath = $mappingPath
    mainJobPath = $jobPath
    mainRunPath = $runPath
    phaseTimings = @()
    cacheHits = @()
    photoshopInvocationCount = 0
    retryCount = 0
    postCommitErrors = @()
    createdAt = [DateTimeOffset]::Now.ToString('o')
  }
}

foreach ($binding in @(
  @('approvedCopyPath', $copyPath),
  @('approvedCopySha256', $ApprovedCopySha256.ToUpperInvariant()),
  @('detailPsdPath', $detailPath),
  @('detailIndexPath', $indexPath),
  @('mainTargetPsdPath', [IO.Path]::GetFullPath($MainTargetPsdPath))
)) {
  if ([string]$state.($binding[0]) -cne [string]$binding[1]) { throw "Existing Dingdong state is bound to another input: $($binding[0])" }
}
if (-not (Test-ObjectProperty $state 'detailPsdSha256')) {
  $state | Add-Member -NotePropertyName detailPsdSha256 -NotePropertyValue $currentDetailPsdSha256
} elseif (-not $runProtectsPreparedWork) {
  $state.detailPsdSha256 = $currentDetailPsdSha256
}

try {
  if (-not $runProtectsPreparedWork -and $RefreshDetailIndex) {
    Invoke-Phase 'refresh-detail-index' {
      & (Join-Path $PSScriptRoot 'index-psd-template.ps1') `
        -DocumentPath $detailPath `
        -OutputPath $indexPath | Out-Null
    }
    $refreshedIndex = Read-Utf8Json $indexPath
    if (-not (Test-ObjectProperty $refreshedIndex 'sourcePsd') -or
        [string]$refreshedIndex.sourcePsd.sha256 -cne $currentDetailPsdSha256) {
      throw 'Refreshed detail index is not bound to the current detail PSD.'
    }
  } elseif (-not $runProtectsPreparedWork -and -not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    throw "Detail index does not exist and RefreshDetailIndex is disabled: $indexPath"
  }

  if (-not $runProtectsPreparedWork) {
  $mappingCacheHit = $false
  if (Test-Path -LiteralPath $mappingPath -PathType Leaf) {
    $cachedMapping = Read-Utf8Json $mappingPath
    if ([string]$cachedMapping.approvedDetailCopy.copySha256 -ceq $ApprovedCopySha256.ToUpperInvariant() -and
        [string]$cachedMapping.sourceManifest.detailIndexSha256 -ceq (Get-Sha256 $indexPath) -and
        [string]$cachedMapping.sourceManifest.detailPsdSha256 -ceq $currentDetailPsdSha256) {
      $mappingCacheHit = $true
      $state.cacheHits += 'main-mapping'
    }
  }
  if (-not $mappingCacheHit) {
    Invoke-Phase 'resolve-detail-sources-and-build-main-mapping' {
      & (Join-Path $PSScriptRoot 'new-dingdong-main-mapping.ps1') `
        -ApprovedDetailCopyPath $copyPath `
        -ApprovedCopySha256 $ApprovedCopySha256 `
        -DetailIndexPath $indexPath `
        -DetailPsdPath $detailPath `
        -OutputPath $mappingPath | Out-Null
    }
  }
  $state.stage = 'detail-images-ready'
  Save-State $state

  $jobCacheHit = $false
  if (Test-Path -LiteralPath $jobPath -PathType Leaf) {
    $existingJob = Read-Utf8Json $jobPath
    $jobCacheHit = [string]$existingJob.mappingSha256 -ceq (Get-Sha256 $mappingPath)
    if ($jobCacheHit) { $state.cacheHits += 'main-job' }
  }
  if (-not $jobCacheHit) {
    Invoke-Phase 'build-main-job' {
      $arguments = @{
        DetailPsdPath = $detailPath
        MappingPath = $mappingPath
        TargetPsdPath = [IO.Path]::GetFullPath($MainTargetPsdPath)
        OutputPath = $jobPath
        DetailWorkDir = if ([string]::IsNullOrWhiteSpace($DetailWorkDir)) { Split-Path -Parent $detailPath } else { [IO.Path]::GetFullPath($DetailWorkDir) }
      }
      if (-not [string]::IsNullOrWhiteSpace($MainFinalOutputDirectory)) { $arguments.FinalOutputDirectory = [IO.Path]::GetFullPath($MainFinalOutputDirectory) }
      & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') @arguments | Out-Null
      $job = Read-Utf8Json $jobPath
      $job | Add-Member -NotePropertyName mappingSha256 -NotePropertyValue (Get-Sha256 $mappingPath) -Force
      Write-Utf8Json -Path $jobPath -Value $job | Out-Null
    }
  }
  }

  if ($PrepareMain -and -not (Test-Path -LiteralPath $runPath -PathType Leaf)) {
    $state.photoshopInvocationCount = [int]$state.photoshopInvocationCount + 1
    Invoke-Phase 'prepare-main-psd' { & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $jobPath -RunPath $runPath | Out-Null }
  }
  if (Test-Path -LiteralPath $runPath -PathType Leaf) {
    $run = Read-Utf8Json $runPath
    if ([string]$run.state -ceq 'prepared') { $state.stage = 'main-prepared' }
    elseif ([string]$run.state -ceq 'committed') { $state.stage = 'main-committed' }
  }

  if ($CommitMain -and [string]$state.stage -ceq 'main-prepared') {
    $state.photoshopInvocationCount = [int]$state.photoshopInvocationCount + 1
    Invoke-Phase 'commit-verify-and-organize' { & (Join-Path $PSScriptRoot 'complete-psd-job.ps1') -RunPath $runPath | Out-Null }
    $run = Read-Utf8Json $runPath
    $state.stage = if ([string]$run.workflowState -ceq 'complete') { 'complete' } else { 'needs-attention' }
    $state.workflowState = [string]$run.workflowState
    $state.postCommitErrors = @($run.postCommitErrors)
  }

  if ($CleanupDisposable -and [string]$state.stage -eq 'complete' -and (Test-Path -LiteralPath $runPath -PathType Leaf)) {
    $run = Read-Utf8Json $runPath
    $disposable = [string]$run.workingPsdPath
    if (-not [string]::IsNullOrWhiteSpace($disposable) -and (Test-WithinTaskRoot $disposable) -and
        [IO.Path]::GetFullPath($disposable) -cne [IO.Path]::GetFullPath([string]$run.targetPsdPath) -and
        (Test-Path -LiteralPath $disposable -PathType Leaf)) {
      Remove-Item -LiteralPath $disposable -Force
      $state | Add-Member -NotePropertyName cleanedDisposablePaths -NotePropertyValue @($disposable) -Force
    }
  }
  $state | Add-Member -NotePropertyName updatedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('o')) -Force
  Save-State $state
  Get-Content -LiteralPath $statePath -Encoding utf8 -Raw
} catch {
  $state.workflowState = 'needs-attention'
  $state.stage = 'needs-attention'
  $state.postCommitErrors = @($state.postCommitErrors) + @($_.Exception.Message)
  $state | Add-Member -NotePropertyName updatedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('o')) -Force
  Save-State $state
  throw
}
