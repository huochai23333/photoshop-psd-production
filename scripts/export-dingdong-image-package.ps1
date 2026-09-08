param(
  [Parameter(Mandatory = $true)][string]$ProductDirectory,
  [string]$DestinationRoot = 'D:\谷鱼视觉\小梅园',
  [string]$CompressorPath = 'D:\谷鱼视觉\小梅园\images\image-compressor.exe',
  [ValidateRange(1, 102400)][int]$TargetKb = 600,
  [string]$ArchiveName,
  [string]$UncompressedOutputDirectory,
  [switch]$OverwriteArchive
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$productRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ProductDirectory).Path).TrimEnd('\')
$destinationFullRoot = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $destinationFullRoot -PathType Container)) {
  throw "Archive destination root is missing: $destinationFullRoot"
}
$usedRoot = Join-Path $productRoot '已使用'
if (-not (Test-Path -LiteralPath $usedRoot -PathType Container)) {
  throw "The specified product directory has no 已使用 folder: $usedRoot"
}

$compressorSupported = @('.jpg', '.jpeg', '.png', '.webp')
$knownUnsupportedImages = @('.bmp', '.gif', '.tif', '.tiff', '.avif', '.heic', '.heif')
$mainAttachmentBaseNames = @('白底图', '标签', '包装图', '白标')
$mainAttachments = @()
foreach ($baseName in $mainAttachmentBaseNames) {
  $allNamedFiles = @(Get-ChildItem -LiteralPath $productRoot -File | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name).Equals($baseName, [StringComparison]::OrdinalIgnoreCase)
  } | Sort-Object FullName)
  $unsupportedNamedImages = @($allNamedFiles | Where-Object {
    $_.Extension.ToLowerInvariant() -in $knownUnsupportedImages
  })
  if ($unsupportedNamedImages.Count -gt 0) {
    throw "The root-level $baseName image uses an unsupported format: $(@($unsupportedNamedImages.FullName) -join '; ')"
  }
  $supportedNamedImages = @($allNamedFiles | Where-Object {
    $_.Extension.ToLowerInvariant() -in $compressorSupported -and
      ($baseName -notin @('包装图', '白标') -or $_.Name.Equals("$baseName.jpg", [StringComparison]::OrdinalIgnoreCase))
  })
  if ($supportedNamedImages.Count -gt 1) {
    throw "The product directory contains more than one root-level $baseName image: $(@($supportedNamedImages.FullName) -join '; ')"
  }
  if ($supportedNamedImages.Count -eq 1) {
    $attachment = $supportedNamedImages[0]
    $mainAttachments += [pscustomobject][ordered]@{
      baseName = $baseName
      fileName = $attachment.Name
      sourcePath = $attachment.FullName
      sourceBytes = [int64]$attachment.Length
      sourceSha256 = Get-Sha256 $attachment.FullName
    }
  }
}
$unsupportedUsedImages = @(Get-ChildItem -LiteralPath $usedRoot -Recurse -File | Where-Object {
  $_.Extension.ToLowerInvariant() -in $knownUnsupportedImages
})
if ($unsupportedUsedImages.Count -gt 0) {
  throw "The 已使用 folder contains image formats unsupported by image-compressor.exe: $(@($unsupportedUsedImages.FullName) -join '; ')"
}
$usedImages = @(Get-ChildItem -LiteralPath $usedRoot -Recurse -File | Where-Object {
  $_.Extension.ToLowerInvariant() -in $compressorSupported
} | Sort-Object FullName)
if ($usedImages.Count -lt 1) { throw 'The specified product directory has no compressor-supported images in 已使用.' }
$usedHashesBefore = @{}
foreach ($image in $usedImages) { $usedHashesBefore[$image.FullName] = Get-Sha256 $image.FullName }

$pair = & (Join-Path $PSScriptRoot 'find-dingdong-export-psds.ps1') -ProductDirectory $productRoot | ConvertFrom-Json
$detailHashBefore = Get-Sha256 ([string]$pair.detailPsdPath)
$mainHashBefore = Get-Sha256 ([string]$pair.mainPsdPath)

$runStamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
if ([string]::IsNullOrWhiteSpace($ArchiveName)) {
  $leaf = Split-Path -Leaf $productRoot
  foreach ($invalid in [IO.Path]::GetInvalidFileNameChars()) { $leaf = $leaf.Replace([string]$invalid, '_') }
  $ArchiveName = '{0}-图片-{1}.7z' -f $leaf, $runStamp
} elseif ([IO.Path]::GetExtension($ArchiveName).ToLowerInvariant() -cne '.7z') {
  throw 'ArchiveName must end in .7z.'
}
if ([IO.Path]::GetFileName($ArchiveName) -cne $ArchiveName) { throw 'ArchiveName must be a filename without directory components.' }
$archivePath = Join-Path $destinationFullRoot $ArchiveName
if ((Test-Path -LiteralPath $archivePath) -and -not $OverwriteArchive) { throw "Archive already exists: $archivePath" }

$uncompressedOutputRoot = if ([string]::IsNullOrWhiteSpace($UncompressedOutputDirectory)) {
  Join-Path $productRoot "未压缩图片-$runStamp"
} elseif ([IO.Path]::IsPathRooted($UncompressedOutputDirectory)) {
  [IO.Path]::GetFullPath($UncompressedOutputDirectory)
} else {
  [IO.Path]::GetFullPath((Join-Path $productRoot $UncompressedOutputDirectory))
}
$uncompressedOutputRoot = [IO.Path]::GetFullPath($uncompressedOutputRoot).TrimEnd('\')
if (-not $uncompressedOutputRoot.StartsWith($productRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "UncompressedOutputDirectory must be inside the product directory: $uncompressedOutputRoot"
}
if (Test-Path -LiteralPath $uncompressedOutputRoot) { throw "Uncompressed output directory already exists: $uncompressedOutputRoot" }

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$stagingRoot = Join-Path $tempRoot "codex-dingdong-export-$([guid]::NewGuid().ToString('N'))"
$stagingFullPath = [IO.Path]::GetFullPath($stagingRoot)
if (-not $stagingFullPath.StartsWith($tempRoot + '\codex-dingdong-export-', [StringComparison]::OrdinalIgnoreCase)) {
  throw "Unsafe export staging path: $stagingFullPath"
}
$detailOutput = Join-Path $stagingFullPath '详情页'
$mainOutput = Join-Path $stagingFullPath '主图'
$usedOutput = Join-Path $stagingFullPath '已使用'

try {
  New-Item -ItemType Directory -Force -Path $detailOutput, $mainOutput, $usedOutput | Out-Null
  $detailLongImagePath = Join-Path $detailOutput '详情页长图.jpg'
  $detailLongExport = & (Join-Path $PSScriptRoot 'export-psd-jpg.ps1') `
    -SourcePsdPath ([string]$pair.detailPsdPath) `
    -OutputPath $detailLongImagePath `
    -Quality 10 `
    -Overwrite | ConvertFrom-Json
  $detailExport = & (Join-Path $PSScriptRoot 'export-psd-slices.ps1') `
    -SourcePsdPath ([string]$pair.detailPsdPath) `
    -OutputDirectory $detailOutput `
    -Format jpg `
    -Quality 10 `
    -Overwrite | ConvertFrom-Json
  $mainExport = & (Join-Path $PSScriptRoot 'export-artboards.ps1') `
    -SourcePsdPath ([string]$pair.mainPsdPath) `
    -OutputDirectory $mainOutput `
    -Format jpg `
    -ArtboardNames @('0', '1', '2', '3', '4', '5', '6', '7') `
    -Quality 10 `
    -Overwrite | ConvertFrom-Json

  foreach ($attachment in $mainAttachments) {
    $destination = Join-Path $mainOutput ([string]$attachment.fileName)
    Copy-Item -LiteralPath ([string]$attachment.sourcePath) -Destination $destination
    if ((Get-Sha256 $destination) -cne [string]$attachment.sourceSha256) {
      throw "Main attachment copy hash mismatch: $($attachment.sourcePath)"
    }
  }

  foreach ($image in $usedImages) {
    $relative = [IO.Path]::GetRelativePath($usedRoot, $image.FullName)
    if ($relative.StartsWith('..', [StringComparison]::Ordinal)) { throw "Used image escaped its source directory: $($image.FullName)" }
    $destination = Join-Path $usedOutput $relative
    $parent = Split-Path -Parent $destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $image.FullName -Destination $destination
    if ((Get-Sha256 $destination) -cne (Get-Sha256 $image.FullName)) { throw "Used image copy hash mismatch: $($image.FullName)" }
  }

  New-Item -ItemType Directory -Path $uncompressedOutputRoot | Out-Null
  Copy-Item -LiteralPath $detailOutput, $mainOutput, $usedOutput -Destination $uncompressedOutputRoot -Recurse
  $uncompressedFiles = @(Get-ChildItem -LiteralPath $uncompressedOutputRoot -Recurse -File | Sort-Object FullName)
  $uncompressedHashes = @{}
  foreach ($file in $uncompressedFiles) { $uncompressedHashes[$file.FullName] = Get-Sha256 $file.FullName }

  $package = & (Join-Path $PSScriptRoot 'compress-image-package.ps1') `
    -InputDirectory $stagingFullPath `
    -ArchivePath $archivePath `
    -CompressorPath $CompressorPath `
    -TargetKb $TargetKb `
    -CompressSubdirectories @('详情页', '主图') `
    -Overwrite:$OverwriteArchive | ConvertFrom-Json

  if ((Get-Sha256 ([string]$pair.detailPsdPath)) -cne $detailHashBefore) { throw 'Detail PSD changed during the export package workflow.' }
  if ((Get-Sha256 ([string]$pair.mainPsdPath)) -cne $mainHashBefore) { throw 'Main PSD changed during the export package workflow.' }
  foreach ($image in $usedImages) {
    if (-not (Test-Path -LiteralPath $image.FullName -PathType Leaf)) { throw "Original used image disappeared during packaging: $($image.FullName)" }
    if ((Get-Sha256 $image.FullName) -cne [string]$usedHashesBefore[$image.FullName]) { throw "Original used image changed during packaging: $($image.FullName)" }
  }
  foreach ($attachment in $mainAttachments) {
    if (-not (Test-Path -LiteralPath ([string]$attachment.sourcePath) -PathType Leaf)) {
      throw "Original main attachment disappeared during packaging: $($attachment.sourcePath)"
    }
    $sourceFile = Get-Item -LiteralPath ([string]$attachment.sourcePath)
    if ([int64]$sourceFile.Length -ne [int64]$attachment.sourceBytes -or
        (Get-Sha256 $sourceFile.FullName) -cne [string]$attachment.sourceSha256) {
      throw "Original main attachment changed during packaging: $($attachment.sourcePath)"
    }
  }
  $uncompressedFilesAfter = @(Get-ChildItem -LiteralPath $uncompressedOutputRoot -Recurse -File | Sort-Object FullName)
  if ($uncompressedFilesAfter.Count -ne $uncompressedFiles.Count) { throw 'Uncompressed output file count changed during packaging.' }
  foreach ($file in $uncompressedFilesAfter) {
    if (-not $uncompressedHashes.ContainsKey($file.FullName) -or
        (Get-Sha256 $file.FullName) -cne [string]$uncompressedHashes[$file.FullName]) {
      throw "Uncompressed output changed during packaging: $($file.FullName)"
    }
  }

  [pscustomobject][ordered]@{
    ok = $true
    workflow = 'dingdong-export-image-package'
    productDirectory = $productRoot
    uncompressedOutputDirectory = $uncompressedOutputRoot
    uncompressedFileCount = $uncompressedFiles.Count
    discoveryRule = [string]$pair.discoveryRule
    detailPsdPath = [string]$pair.detailPsdPath
    detailPsdSha256 = $detailHashBefore
    detailLongImageName = [IO.Path]::GetFileName([string]$detailLongExport.outputPath)
    detailLongImageWidth = [int]$detailLongExport.widthPx
    detailLongImageHeight = [int]$detailLongExport.heightPx
    detailSliceSource = 'current-product-psd-horizontal-guides'
    detailHorizontalGuides = @($detailExport.horizontalGuides)
    detailSliceCount = [int]$detailExport.sliceCount
    mainPsdPath = [string]$pair.mainPsdPath
    mainPsdSha256 = $mainHashBefore
    mainArtboards = @('0', '1', '2', '3', '4', '5', '6', '7')
    mainAttachmentCount = $mainAttachments.Count
    mainAttachments = @($mainAttachments)
    usedImageCount = $usedImages.Count
    package = $package
  } | ConvertTo-Json -Depth 16 -Compress
} finally {
  if (Test-Path -LiteralPath $stagingFullPath -PathType Container) {
    $verifiedStaging = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $stagingFullPath).Path)
    if (-not $verifiedStaging.StartsWith($tempRoot + '\codex-dingdong-export-', [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean an unsafe staging path: $verifiedStaging"
    }
    Remove-Item -LiteralPath $verifiedStaging -Recurse -Force
  }
}
