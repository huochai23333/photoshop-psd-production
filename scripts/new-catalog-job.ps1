param(
  [Parameter(Mandatory = $true)][string]$ItemsPath,
  [Parameter(Mandatory = $true)][string]$SourcePsdPath,
  [Parameter(Mandatory = $true)][string]$TargetPsdPath,
  [Parameter(Mandatory = $true)][string]$ImageDirectory,
  [Parameter(Mandatory = $true)][string]$TemplateArtboard,
  [Parameter(Mandatory = $true)][int]$ExpectedExistingProductArtboards,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [int]$StartArtboardNumber = 5,
  [int]$ItemsPerArtboard = 2,
  [ValidateSet('cover-mask', 'contain', 'original-size')][string]$PlacementMode = 'cover-mask'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$raw = Read-Utf8Json $ItemsPath
$items = if (Test-ObjectProperty $raw 'items') { @($raw.items) } else { @($raw) }
if ($items.Count -eq 0) { throw 'Catalog item list is empty.' }
$job = [ordered]@{
  jobVersion = 1
  workflow = 'catalog-artboards'
  sourcePsdPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourcePsdPath).Path)
  targetPsdPath = [IO.Path]::GetFullPath($TargetPsdPath)
  textReplacements = @()
  imageTransfers = @()
  catalog = [ordered]@{
    imageDirectory = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ImageDirectory).Path)
    layout = [ordered]@{
      templateArtboard = $TemplateArtboard
      startArtboardNumber = $StartArtboardNumber
      itemsPerArtboard = $ItemsPerArtboard
      expectedExistingProductArtboards = $ExpectedExistingProductArtboards
    }
    imagePlacement = [ordered]@{ mode = $PlacementMode; edgeOverscanPercent = 0.3 }
    items = $items
  }
  outputs = [ordered]@{ preview = [ordered]@{ enabled = $true; maxWidth = 1800; quality = 9 }; final = $null }
  organizeUsedAssets = $false
}
Write-Utf8Json -Path $OutputPath -Value $job | Out-Null
Get-Content -LiteralPath $OutputPath -Encoding UTF8 -Raw
