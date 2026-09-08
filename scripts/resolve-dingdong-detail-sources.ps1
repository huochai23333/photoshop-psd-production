param(
  [Parameter(Mandatory = $true)][string]$DetailIndexPath,
  [string]$DetailPsdPath,
  [Parameter(Mandatory = $true)][string]$DetailDefinitionPath,
  [Parameter(Mandatory = $true)][string]$MainDefinitionPath,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

function Get-IndexLayers {
  param($Index)
  if ((Test-ObjectProperty $Index 'document') -and $Index.document) { return @($Index.document.layers) }
  $rows = @()
  foreach ($document in @($Index.documents)) { $rows += @($document.layers) }
  return @($rows)
}

function Test-EffectiveVisibility {
  param($Layer, [hashtable]$ById)
  $current = $Layer
  while ($null -ne $current) {
    if ((Test-ObjectProperty $current 'visible') -and $current.visible -ne $true) { return $false }
    if (-not (Test-ObjectProperty $current 'parentId') -or $null -eq $current.parentId) { break }
    $parentKey = [string]$current.parentId
    if (-not $ById.ContainsKey($parentKey)) { break }
    $current = $ById[$parentKey]
  }
  return $true
}

$indexPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DetailIndexPath).Path)
$detailDefinition = Read-Utf8Json ([IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DetailDefinitionPath).Path))
$mainDefinition = Read-Utf8Json ([IO.Path]::GetFullPath((Resolve-Path -LiteralPath $MainDefinitionPath).Path))
$index = Read-Utf8Json $indexPath
$detailPsdFullPath = $null
$detailPsdSha256 = $null
$detailPsdLastWriteTimeUtc = $null
if (-not [string]::IsNullOrWhiteSpace($DetailPsdPath)) {
  $detailPsdFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DetailPsdPath).Path)
  $detailPsdFile = Get-Item -LiteralPath $detailPsdFullPath
  $detailPsdSha256 = Get-Sha256 $detailPsdFullPath
  $detailPsdLastWriteTimeUtc = $detailPsdFile.LastWriteTimeUtc.ToString('o')
  if ((Test-ObjectProperty $index 'sourcePsd') -and $index.sourcePsd) {
    if ((Test-ObjectProperty $index.sourcePsd 'path') -and
        -not [string]::IsNullOrWhiteSpace([string]$index.sourcePsd.path) -and
        -not [IO.Path]::GetFullPath([string]$index.sourcePsd.path).Equals($detailPsdFullPath, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Detail index belongs to another PSD. Refresh the detail index before main-image production.'
    }
    if ((Test-ObjectProperty $index.sourcePsd 'sha256') -and
        -not [string]::IsNullOrWhiteSpace([string]$index.sourcePsd.sha256) -and
        [string]$index.sourcePsd.sha256 -cne $detailPsdSha256) {
      throw 'Detail index is stale for the current PSD. Refresh the detail index before main-image production.'
    }
  }
} elseif ((Test-ObjectProperty $index 'sourcePsd') -and $index.sourcePsd) {
  $detailPsdFullPath = [string]$index.sourcePsd.path
  $detailPsdSha256 = [string]$index.sourcePsd.sha256
  $detailPsdLastWriteTimeUtc = [string]$index.sourcePsd.lastWriteTimeUtc
}
$layers = @(Get-IndexLayers $index)
$byId = @{}
foreach ($layer in $layers) {
  $key = [string]$layer.id
  if ($byId.ContainsKey($key)) { throw "Detail index contains duplicate layer id: $key" }
  $byId[$key] = $layer
}

$mainTargetByScreen = @{}
foreach ($target in @($mainDefinition.imageTargets)) {
  $screen = [string]$target.sourceDetailBlock
  if ($screen -ceq '8') { $screen = '7' }
  $mainTargetByScreen[$screen] = $target
}

$items = @()
foreach ($slot in @($detailDefinition.mainImageSourceSlots | Sort-Object { [int]$_.screen })) {
  $screen = [string]$slot.screen
  $baseId = if ((Test-ObjectProperty $slot 'selector') -and [string]$slot.selector -ceq 'last-step-image-placeholder') {
    $steps = @($detailDefinition.currentSteps | Sort-Object { [int]$_.number })
    if ($steps.Count -eq 0) { throw 'Detail definition has no currentSteps for the last-step image slot.' }
    [string]$steps[-1].imagePlaceholderId
  } else {
    [string]$slot.baseLayerId
  }
  if (-not $byId.ContainsKey($baseId)) { throw "Detail image base layer is missing from the index for screen ${screen}: $baseId" }
  $base = $byId[$baseId]
  $candidates = @($layers | Where-Object {
    [string]$_.parentId -ceq [string]$base.parentId -and
    [int]$_.siblingIndex -lt [int]$base.siblingIndex -and
    [string]$_.typename -ceq 'ArtLayer' -and
    [string]$_.kind -ceq 'LayerKind.SMARTOBJECT' -and
    $_.grouped -eq $true -and
    (Test-EffectiveVisibility -Layer $_ -ById $byId)
  } | Sort-Object { [int]$_.siblingIndex } -Descending)
  if ($candidates.Count -eq 0) { throw "No visible clipped smart-object source was found before the registered base for screen $screen." }
  $nearestSibling = [int]$candidates[0].siblingIndex
  $nearest = @($candidates | Where-Object { [int]$_.siblingIndex -eq $nearestSibling })
  if ($nearest.Count -ne 1) { throw "Detail image source is ambiguous for screen $screen." }
  if (-not $mainTargetByScreen.ContainsKey($screen)) { throw "Main-image definition has no image target for screen $screen." }
  $source = $nearest[0]
  $target = $mainTargetByScreen[$screen]
  $items += [pscustomobject][ordered]@{
    screen = [int]$screen
    label = [string]$slot.label
    baseLayerId = [int]$base.id
    sourceLayerId = [int]$source.id
    sourcePath = [string]$source.path
    sourceSiblingIndex = [int]$source.siblingIndex
    targetLayerId = [int]$target.targetId
    targetName = [string]$target.targetName
    fit = [string]$target.fit
  }
}
if ($items.Count -ne 7) { throw "Expected seven resolved detail sources, found $($items.Count)." }

$result = [pscustomobject][ordered]@{
  resolverVersion = 1
  detailIndexPath = $indexPath
  detailIndexSha256 = Get-Sha256 $indexPath
  detailPsdPath = $detailPsdFullPath
  detailPsdSha256 = $detailPsdSha256
  detailPsdLastWriteTimeUtc = $detailPsdLastWriteTimeUtc
  resolvedAt = [DateTimeOffset]::Now.ToString('o')
  items = @($items)
}
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Write-Utf8Json -Path $OutputPath -Value $result | Out-Null }
$result | ConvertTo-Json -Depth 20 -Compress
