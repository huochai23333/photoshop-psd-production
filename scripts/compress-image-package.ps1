param(
  [Parameter(Mandatory = $true)][string]$InputDirectory,
  [Parameter(Mandatory = $true)][string]$ArchivePath,
  [string]$CompressorPath = 'D:\谷鱼视觉\小梅园\images\image-compressor.exe',
  [ValidateRange(1, 102400)][int]$TargetKb = 600,
  [string[]]$CompressSubdirectories = @(),
  [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$inputRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $InputDirectory).Path).TrimEnd('\')
$archiveFullPath = [IO.Path]::GetFullPath($ArchivePath)
$compressorFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CompressorPath).Path)
if (-not (Test-Path -LiteralPath $inputRoot -PathType Container)) { throw "Package input directory is missing: $inputRoot" }
if ([IO.Path]::GetExtension($archiveFullPath).ToLowerInvariant() -cne '.7z') { throw 'ArchivePath must end in .7z.' }
if (-not (Test-Path -LiteralPath $compressorFullPath -PathType Leaf)) { throw "Image compressor is missing: $compressorFullPath" }
if ((Test-Path -LiteralPath $archiveFullPath) -and -not $Overwrite) { throw "Archive already exists: $archiveFullPath" }

$supportedExtensions = @('.jpg', '.jpeg', '.png', '.webp')
$allImages = @(Get-ChildItem -LiteralPath $inputRoot -Recurse -File | Where-Object {
  $_.Extension.ToLowerInvariant() -in $supportedExtensions
} | Sort-Object FullName)
if ($allImages.Count -lt 1) { throw 'The package staging directory contains no compressor-supported images.' }

$compressRoots = @()
if (@($CompressSubdirectories).Count -eq 0) {
  $compressRoots = @($inputRoot)
} else {
  foreach ($relativeDirectory in @($CompressSubdirectories)) {
    if ([string]::IsNullOrWhiteSpace($relativeDirectory) -or [IO.Path]::IsPathRooted($relativeDirectory)) {
      throw 'CompressSubdirectories entries must be non-empty relative directory paths.'
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $inputRoot $relativeDirectory)).TrimEnd('\')
    if (-not ($candidate.Equals($inputRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($inputRoot + '\', [StringComparison]::OrdinalIgnoreCase))) {
      throw "Compression subdirectory escaped the package root: $relativeDirectory"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { throw "Compression subdirectory is missing: $candidate" }
    $compressRoots += $candidate
  }
  $compressRoots = @($compressRoots | Select-Object -Unique)
}
$images = @($allImages | Where-Object {
  $imagePath = [IO.Path]::GetFullPath($_.FullName)
  @($compressRoots | Where-Object {
    $imagePath.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase)
  }).Count -gt 0
})
if ($images.Count -lt 1) { throw 'The selected compression subdirectories contain no supported images.' }

$beforeAll = @{}
foreach ($image in $allImages) {
  $relative = [IO.Path]::GetRelativePath($inputRoot, $image.FullName).Replace('\', '/')
  $beforeAll[$relative] = [pscustomobject]@{
    bytes = [int64]$image.Length
    sha256 = Get-Sha256 $image.FullName
  }
}

$oldOutputEncoding = [Console]::OutputEncoding
$compressorLines = @()
try {
  [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
  $compressorArguments = @('--target-kb', [string]$TargetKb, '--recursive', '--no-pause') + @($compressRoots)
  $compressorLines = @(& $compressorFullPath @compressorArguments 2>&1 | ForEach-Object { [string]$_ })
  $compressorExitCode = $LASTEXITCODE
} finally {
  [Console]::OutputEncoding = $oldOutputEncoding
}
$compressorErrors = @($compressorLines | Where-Object { $_ -match '^\[ERROR\]' })
$compressorWarnings = @($compressorLines | Where-Object { $_ -match '^\[WARN\]' })
if ($compressorExitCode -notin @(0, 2) -or $compressorErrors.Count -gt 0) {
  throw "Image compressor failed with exit code $compressorExitCode. $($compressorErrors -join '; ')"
}
$doneLine = @($compressorLines | Where-Object { $_ -match '^Done\. Processed [0-9]+ file\(s\)' } | Select-Object -Last 1)
if ($doneLine.Count -ne 1 -or $doneLine[0] -notmatch '^Done\. Processed ([0-9]+) file\(s\)') {
  throw 'Image compressor did not report a verifiable processed-image count.'
}
if ([int]$Matches[1] -ne $images.Count) {
  throw "Image compressor processed $($Matches[1]) images, but the staging directory contains $($images.Count)."
}

$afterImages = @(Get-ChildItem -LiteralPath $inputRoot -Recurse -File | Where-Object {
  $_.Extension.ToLowerInvariant() -in $supportedExtensions
} | Sort-Object FullName)
if ($afterImages.Count -ne $allImages.Count) { throw 'Package image count changed during compression.' }
$compressedRelativeSet = @{}
foreach ($image in $images) {
  $compressedRelativeSet[[IO.Path]::GetRelativePath($inputRoot, $image.FullName).Replace('\', '/')] = $true
}
$items = @($afterImages | Where-Object {
  $compressedRelativeSet.ContainsKey([IO.Path]::GetRelativePath($inputRoot, $_.FullName).Replace('\', '/'))
} | ForEach-Object {
  $relative = [IO.Path]::GetRelativePath($inputRoot, $_.FullName).Replace('\', '/')
  if (-not $beforeAll.ContainsKey($relative) -or $_.Length -le 0) { throw "Compressed image is missing, renamed, or empty: $relative" }
  [pscustomobject][ordered]@{
    relativePath = $relative
    bytesBefore = [int64]$beforeAll[$relative].bytes
    bytesAfter = [int64]$_.Length
    sha256Before = [string]$beforeAll[$relative].sha256
    sha256After = Get-Sha256 $_.FullName
  }
})
foreach ($image in $afterImages) {
  $relative = [IO.Path]::GetRelativePath($inputRoot, $image.FullName).Replace('\', '/')
  if ($compressedRelativeSet.ContainsKey($relative)) { continue }
  if (-not $beforeAll.ContainsKey($relative) -or
      [int64]$image.Length -ne [int64]$beforeAll[$relative].bytes -or
      (Get-Sha256 $image.FullName) -cne [string]$beforeAll[$relative].sha256) {
    throw "An image outside the selected compression subdirectories changed: $relative"
  }
}

$archiveDirectory = Split-Path -Parent $archiveFullPath
if ($archiveDirectory) { New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null }
$temporaryArchive = "$archiveFullPath.tmp-$([guid]::NewGuid().ToString('N')).7z"
try {
  $tarCommand = Get-Command tar.exe -ErrorAction Stop
  $tarOutput = @(& $tarCommand.Source '-a' '-cf' $temporaryArchive '-C' $inputRoot '.' 2>&1 | ForEach-Object { [string]$_ })
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryArchive -PathType Leaf)) {
    throw "7z creation failed. $($tarOutput -join '; ')"
  }
  $expectedSignature = [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)
  $signature = New-Object byte[] $expectedSignature.Length
  $signatureStream = [IO.File]::OpenRead($temporaryArchive)
  try { $signatureLength = $signatureStream.Read($signature, 0, $signature.Length) } finally { $signatureStream.Dispose() }
  if ($signatureLength -lt $expectedSignature.Length) { throw 'Created archive is too small to be a 7z file.' }
  for ($index = 0; $index -lt $expectedSignature.Length; $index++) {
    if ($signature[$index] -ne $expectedSignature[$index]) { throw 'Created archive does not have the 7z signature.' }
  }
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
  $verificationRoot = Join-Path $tempRoot "codex-7z-verify-$([guid]::NewGuid().ToString('N'))"
  $verificationFullPath = [IO.Path]::GetFullPath($verificationRoot)
  if (-not $verificationFullPath.StartsWith($tempRoot + '\codex-7z-verify-', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe 7z verification path: $verificationFullPath"
  }
  try {
    New-Item -ItemType Directory -Force -Path $verificationFullPath | Out-Null
    $extractOutput = @(& $tarCommand.Source '-xf' $temporaryArchive '-C' $verificationFullPath 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "Created 7z archive could not be extracted for verification. $($extractOutput -join '; ')" }
    $stagedFiles = @(Get-ChildItem -LiteralPath $inputRoot -Recurse -File | Sort-Object FullName)
    $extractedFiles = @(Get-ChildItem -LiteralPath $verificationFullPath -Recurse -File | Sort-Object FullName)
    if ($extractedFiles.Count -ne $stagedFiles.Count) {
      throw "7z archive file count mismatch: staged=$($stagedFiles.Count), extracted=$($extractedFiles.Count)."
    }
    foreach ($stagedFile in $stagedFiles) {
      $relative = [IO.Path]::GetRelativePath($inputRoot, $stagedFile.FullName)
      $extractedPath = Join-Path $verificationFullPath $relative
      if (-not (Test-Path -LiteralPath $extractedPath -PathType Leaf)) { throw "7z archive is missing a staged file: $relative" }
      if ((Get-Sha256 $extractedPath) -cne (Get-Sha256 $stagedFile.FullName)) { throw "7z archive content hash mismatch: $relative" }
    }
  } finally {
    if (Test-Path -LiteralPath $verificationFullPath -PathType Container) {
      $verifiedPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $verificationFullPath).Path)
      if (-not $verifiedPath.StartsWith($tempRoot + '\codex-7z-verify-', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unsafe 7z verification path: $verifiedPath"
      }
      Remove-Item -LiteralPath $verifiedPath -Recurse -Force
    }
  }
  if ((Test-Path -LiteralPath $archiveFullPath) -and $Overwrite) { Remove-Item -LiteralPath $archiveFullPath -Force }
  Move-Item -LiteralPath $temporaryArchive -Destination $archiveFullPath
} finally {
  Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
  ok = $true
  archivePath = $archiveFullPath
  archiveBytes = (Get-Item -LiteralPath $archiveFullPath).Length
  archiveSha256 = Get-Sha256 $archiveFullPath
  archiveFormat = '7z'
  compressorPath = $compressorFullPath
  targetKb = $TargetKb
  imageCount = $allImages.Count
  compressedImageCount = $images.Count
  uncompressedImageCount = $allImages.Count - $images.Count
  compressSubdirectories = @($CompressSubdirectories)
  compressorExitCode = $compressorExitCode
  compressorWarnings = @($compressorWarnings)
  items = @($items)
} | ConvertTo-Json -Depth 12 -Compress
