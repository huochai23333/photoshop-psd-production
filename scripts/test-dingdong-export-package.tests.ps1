$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding($false, $true)

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "FAIL: $Message" }
  Write-Output "PASS: $Message"
}

$scriptPaths = @(
  'scripts\export-psd-jpg.ps1',
  'scripts\export-psd-slices.ps1',
  'scripts\find-dingdong-export-psds.ps1',
  'scripts\compress-image-package.ps1',
  'scripts\export-dingdong-image-package.ps1'
)
foreach ($relativePath in $scriptPaths) {
  $path = Join-Path $skillRoot $relativePath
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  Assert-True (@($errors).Count -eq 0) "$relativePath has valid PowerShell syntax"
  $bytes = [IO.File]::ReadAllBytes($path)
  [void]$utf8.GetString($bytes)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  Assert-True (-not $hasBom) "$relativePath is UTF-8 without BOM"
}

$skillText = [IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md'), $utf8)
$advancedText = [IO.File]::ReadAllText((Join-Path $skillRoot 'references\advanced-workflows.md'), $utf8)
$dingdongText = [IO.File]::ReadAllText((Join-Path $skillRoot 'references\dingdong.md'), $utf8)
$sliceScriptText = [IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\export-psd-slices.ps1'), $utf8)
$discoveryScriptText = [IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\find-dingdong-export-psds.ps1'), $utf8)
$packageScriptText = [IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\export-dingdong-image-package.ps1'), $utf8)
Assert-True ($skillText.Contains('永久禁止读取母版、模板定义、模板索引、历史切片高度或母版参考线作为切片依据')) 'skill forbids master-derived slice boundaries'
Assert-True ($advancedText.Contains('再只读取指定目录内当前商品详情 PSD 自己保存的水平参考线')) 'advanced workflow uses current product PSD guides only'
Assert-True ($dingdongText.Contains('不得使用母版或旧导出结果补齐')) 'Dingdong workflow blocks master and stale-export fallbacks'
Assert-True (-not $sliceScriptText.Contains('assets\templates') -and -not $discoveryScriptText.Contains('assets\templates')) 'export scripts have no template registry or master lookup'
Assert-True ($skillText.Contains('整包导出主图必须按名称顺序导出画板 0–7，不排除画板 0') -and
  $advancedText.Contains('画板 `0` 必须包含在整包导出中') -and
  $dingdongText.Contains('画板 0 不得排除') -and
  $packageScriptText.Contains("-ArtboardNames @('0', '1', '2', '3', '4', '5', '6', '7')") -and
  $packageScriptText.Contains("mainArtboards = @('0', '1', '2', '3', '4', '5', '6', '7')") -and
  $discoveryScriptText.Contains("mainArtboardNames = @('0', '1', '2', '3', '4', '5', '6', '7')")) 'whole-package export includes main artboard 0 through 7 in order'
Assert-True ($skillText.Contains('详情页固定同时导出完整长图和切片') -and
  $advancedText.Contains('`详情页长图.jpg`') -and
  $dingdongText.Contains('固定导出一张原画布尺寸的 `详情页长图.jpg`') -and
  $packageScriptText.Contains("Join-Path `$detailOutput '详情页长图.jpg'") -and
  $packageScriptText.Contains("'export-psd-jpg.ps1'")) 'whole-package export includes a full detail-page long image before guide slices'
Assert-True ($skillText.Contains('精确文件名 `包装图.jpg`、`白标.jpg`') -and
  $advancedText.Contains('精确文件名 `包装图.jpg`、`白标.jpg`') -and
  $dingdongText.Contains('精确文件名 `包装图.jpg`、`白标.jpg`') -and
  $packageScriptText.Contains("`$mainAttachmentBaseNames = @('白底图', '标签', '包装图', '白标')") -and
  $packageScriptText.Contains('$baseName -notin @(''包装图'', ''白标'') -or $_.Name.Equals("$baseName.jpg"') -and
  $packageScriptText.Contains('Main attachment copy hash mismatch') -and
  $packageScriptText.Contains('Original main attachment changed during packaging')) 'optional white-background and label images are copied from the product root into main outputs without changing sources'
Assert-True ($skillText.Contains('商品目录内固定保留一套时间戳命名的未压缩') -and
  $advancedText.Contains('未压缩图片-yyyyMMdd-HHmmss') -and
  $dingdongText.Contains('未压缩图片-yyyyMMdd-HHmmss') -and
  $packageScriptText.Contains('uncompressedOutputDirectory = $uncompressedOutputRoot') -and
  $packageScriptText.Contains('Uncompressed output changed during packaging')) 'whole-package export keeps an unchanged uncompressed copy inside the product directory'
Assert-True ($skillText.Contains('指定路径 `已使用` 中的图片禁止压缩') -and
  $advancedText.Contains('只对临时目录中的 `详情页/` 和 `主图/`') -and
  $dingdongText.Contains('`已使用/` 图片保持未压缩') -and
  $packageScriptText.Contains("-CompressSubdirectories @('详情页', '主图')")) 'whole-package export excludes used images from compression'

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempRoot "codex-image-package-test-$([guid]::NewGuid().ToString('N'))"
$testFullPath = [IO.Path]::GetFullPath($testRoot)
if (-not $testFullPath.StartsWith($tempRoot + '\codex-image-package-test-', [StringComparison]::OrdinalIgnoreCase)) {
  throw "Unsafe test path: $testFullPath"
}
try {
  $detailDir = Join-Path $testFullPath '详情页'
  $mainDir = Join-Path $testFullPath '主图'
  $usedDir = Join-Path $testFullPath '已使用'
  New-Item -ItemType Directory -Force -Path $detailDir, $mainDir, $usedDir | Out-Null
  Add-Type -AssemblyName System.Drawing.Common
  foreach ($imagePath in @(
      (Join-Path $detailDir '详情页长图.png'),
      (Join-Path $detailDir 'detail-0001.png'),
      (Join-Path $mainDir '0.png'),
      (Join-Path $mainDir '1.png'),
      (Join-Path $mainDir '白底图.png'),
      (Join-Path $mainDir '标签.png'),
      (Join-Path $mainDir '包装图.jpg'),
      (Join-Path $mainDir '白标.jpg'),
      (Join-Path $usedDir '素材.png')
    )) {
    $bitmap = New-Object Drawing.Bitmap 10, 10
    try {
      $graphics = [Drawing.Graphics]::FromImage($bitmap)
      try { $graphics.Clear([Drawing.Color]::OrangeRed) } finally { $graphics.Dispose() }
      $format = if ([IO.Path]::GetExtension($imagePath).ToLowerInvariant() -eq '.jpg') {
        [Drawing.Imaging.ImageFormat]::Jpeg
      } else {
        [Drawing.Imaging.ImageFormat]::Png
      }
      $bitmap.Save($imagePath, $format)
    } finally {
      $bitmap.Dispose()
    }
  }
  $archivePath = Join-Path $tempRoot "codex-image-package-test-$([guid]::NewGuid().ToString('N')).7z"
  $usedStagedPath = Join-Path $usedDir '素材.png'
  $usedHashBefore = (Get-FileHash -LiteralPath $usedStagedPath -Algorithm SHA256).Hash
  $usedBytesBefore = (Get-Item -LiteralPath $usedStagedPath).Length
  try {
    $package = & (Join-Path $PSScriptRoot 'compress-image-package.ps1') `
      -InputDirectory $testFullPath `
      -ArchivePath $archivePath `
      -CompressorPath 'D:\谷鱼视觉\小梅园\images\image-compressor.exe' `
      -CompressSubdirectories @('详情页', '主图') | ConvertFrom-Json
    Assert-True ($package.ok -eq $true -and [int]$package.imageCount -eq 9 -and
      [int]$package.compressedImageCount -eq 8 -and [int]$package.uncompressedImageCount -eq 1) 'compressor processes the detail long image, slices, main artboards and optional main attachments but excludes used images'
    Assert-True ((Get-Item -LiteralPath $usedStagedPath).Length -eq $usedBytesBefore -and
      (Get-FileHash -LiteralPath $usedStagedPath -Algorithm SHA256).Hash -ceq $usedHashBefore) 'used image bytes and SHA-256 remain unchanged after compression stage'
    Assert-True ((Test-Path -LiteralPath $archivePath -PathType Leaf) -and [string]$package.archiveFormat -ceq '7z') 'package is created as a verified 7z archive'
    $extracted = Join-Path $testFullPath '已验证归档'
    New-Item -ItemType Directory -Force -Path $extracted | Out-Null
    & tar.exe -xf $archivePath -C $extracted
    Assert-True ($LASTEXITCODE -eq 0) '7z can be extracted for content verification'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '详情页\详情页长图.png') -PathType Leaf) '7z contains the full detail-page long image'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '详情页\detail-0001.png') -PathType Leaf) '7z contains the detail slice'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '主图\0.png') -PathType Leaf) '7z contains main artboard 0'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '主图\1.png') -PathType Leaf) '7z contains the main artboard image'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '主图\白底图.png') -PathType Leaf) '7z contains the optional white-background image in the main folder'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '主图\标签.png') -PathType Leaf) '7z contains the optional label image in the main folder'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '主图\包装图.jpg') -PathType Leaf) '7z contains the optional packaging image in the main folder'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '主图\白标.jpg') -PathType Leaf) '7z contains the optional white-label image in the main folder'
    Assert-True (Test-Path -LiteralPath (Join-Path $extracted '已使用\素材.png') -PathType Leaf) '7z contains the used image'
  } finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
  }
} finally {
  if (Test-Path -LiteralPath $testFullPath -PathType Container) {
    $verifiedTestPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testFullPath).Path)
    if (-not $verifiedTestPath.StartsWith($tempRoot + '\codex-image-package-test-', [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to clean unsafe test path: $verifiedTestPath"
    }
    Remove-Item -LiteralPath $verifiedTestPath -Recurse -Force
  }
}
