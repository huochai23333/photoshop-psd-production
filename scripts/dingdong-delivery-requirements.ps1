# 完整交付规则与导出器分离：本文件不接收导出请求清单、导出成功数量或运行报告作为验收依据。
function Get-DingdongRequiredMainArtboards {
  param([string[]]$ExcludedMainArtboards = @(), [string]$UserMainExclusionInstruction)
  $baseline = @('0', '1', '2', '3', '4', '5', '6', '7')
  if ('0' -in $ExcludedMainArtboards) { throw '画板0白底图是必交项，禁止排除。' }
  foreach ($name in $ExcludedMainArtboards) {
    if ($name -notin $baseline) { throw "未知的排除画板：$name" }
  }
  if ($ExcludedMainArtboards.Count -gt 0 -and [string]::IsNullOrWhiteSpace($UserMainExclusionInstruction)) {
    throw '排除非0画板必须记录用户本次明确指定的原话，隐藏状态不能代替排除授权。'
  }
  @($baseline | Where-Object { $_ -notin $ExcludedMainArtboards })
}

function Assert-DingdongDeliveryRequirements {
  param(
    [Parameter(Mandatory = $true)][string]$DeliveryDirectory,
    [Parameter(Mandatory = $true)]$SourceFacts,
    [string[]]$ExcludedMainArtboards = @(),
    [string]$UserMainExclusionInstruction
  )
  $root = (Resolve-Path -LiteralPath $DeliveryDirectory -ErrorAction Stop).Path
  $requiredBoards = @(Get-DingdongRequiredMainArtboards -ExcludedMainArtboards $ExcludedMainArtboards -UserMainExclusionInstruction $UserMainExclusionInstruction)
  $expected = @{}
  $width = [int]$SourceFacts.detailCanvas.width
  $height = [int]$SourceFacts.detailCanvas.height
  $guides = @($SourceFacts.detailHorizontalGuides | Sort-Object -Unique)
  if ($width -le 0 -or $height -le 0 -or $guides.Count -lt 1) { throw '缺少当前商品 PSD 的画布和参考线凭证，不能验收。' }
  $expected['详情页/详情页长图.jpg'] = @{width=$width; height=$height}
  $boundaries = @(0) + $guides + @($height)
  for ($i=0; $i -lt $boundaries.Count-1; $i++) {
    $sliceHeight = [int]$boundaries[$i+1] - [int]$boundaries[$i]
    if ($sliceHeight -le 0 -or [int]$boundaries[$i+1] -gt $height) { throw '当前 PSD 参考线凭证无效。' }
    $expected[('详情页/detail-{0:D4}.jpg' -f ($i+1))] = @{width=$width; height=$sliceHeight}
  }
  foreach ($name in $requiredBoards) {
    $boards = @($SourceFacts.mainArtboards | Where-Object name -CEQ $name)
    if ($boards.Count -ne 1) { throw "缺少当前 PSD 的画板尺寸凭证：$name" }
    $rect = $boards[0].rect
    $expected["主图/$name.jpg"] = @{width=([int]$rect[2]-[int]$rect[0]);height=([int]$rect[3]-[int]$rect[1])}
  }
  # 独立扫描源商品附件和已使用素材，不能依赖导出器传来的附件列表或导出数量。
  $supported = @('.jpg','.jpeg','.png','.webp')
  $unsupported = @('.bmp','.gif','.tif','.tiff','.avif','.heic','.heif')
  foreach ($base in @('白底图','标签','包装图','白标')) {
    $files = @(Get-ChildItem -LiteralPath $SourceFacts.productDirectory -File | Where-Object BaseName -EQ $base)
    if (@($files | Where-Object { $_.Extension.ToLowerInvariant() -in $unsupported }).Count) { throw "源附件格式不支持：$base" }
    $matches = @($files | Where-Object { $_.Extension.ToLowerInvariant() -in $supported -and ($base -notin @('包装图','白标') -or $_.Name -ieq "$base.jpg") })
    if ($matches.Count -gt 1) { throw "源附件不唯一：$base" }
    if ($matches.Count -eq 1) { $expected['主图/'+$matches[0].Name] = @{} }
  }
  $usedRoot = Join-Path $SourceFacts.productDirectory '已使用'
  $used = @(Get-ChildItem -LiteralPath $usedRoot -Recurse -File -ErrorAction Stop | Where-Object { $_.Extension.ToLowerInvariant() -in $supported })
  if ($used.Count -lt 1) { throw '源商品缺少已使用图片，不能验收。' }
  foreach ($file in $used) {
    $relative = [IO.Path]::GetRelativePath($usedRoot,$file.FullName).Replace('\','/')
    $expected['已使用/'+$relative] = @{sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
  }
  $actual = @{}
  foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
    $relative = [IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
    $actual[$relative] = $file
  }
  # 必须逐项检查，而非只核对总数；白底附件或其他画板文件不能替代画板0的交付位置。
  if (-not $actual.ContainsKey('主图/0.jpg')) { throw '完整交付缺少画板0白底图：主图/0.jpg。' }
  foreach ($relative in $expected.Keys) {
    if (-not $actual.ContainsKey($relative)) { throw "完整交付缺项：$relative" }
  }
  foreach ($relative in $actual.Keys) {
    if (-not $expected.ContainsKey($relative)) { throw "交付出现未约定文件：$relative" }
    $file = $actual[$relative]
    if ($file.Length -le 0) { throw "交付图片为空：$relative" }
    $requirement = $expected[$relative]
    if ($requirement.ContainsKey('sha256')) {
      if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -cne $requirement.sha256) { throw "已使用素材字节变化：$relative" }
    } elseif ($requirement.ContainsKey('width')) {
      Add-Type -AssemblyName System.Drawing.Common
      $image = $null
      try {
        $image = [Drawing.Image]::FromFile($file.FullName)
        if ($image.Width -ne $requirement.width -or $image.Height -ne $requirement.height) { throw "交付图片尺寸不符：$relative" }
        if ($relative -eq '主图/0.jpg') {
          # 防止用纯色空图补齐数量；商品对应关系和白底画面仍须按 Skill 另行视觉核对。
          $origin = $image.GetPixel(0,0).ToArgb()
          $hasContent = $false
          $stepX = [Math]::Max(1,[int][Math]::Floor($image.Width/32))
          $stepY = [Math]::Max(1,[int][Math]::Floor($image.Height/32))
          for ($y=0; $y -lt $image.Height -and -not $hasContent; $y+=$stepY) {
            for ($x=0; $x -lt $image.Width; $x+=$stepX) {
              if ($image.GetPixel($x,$y).ToArgb() -ne $origin) { $hasContent=$true; break }
            }
          }
          if (-not $hasContent) { throw '画板0白底图为空白纯色图，不能交付。' }
        }
      } finally { if ($null -ne $image) { $image.Dispose() } }
    }
  }
  [pscustomobject]@{ok=$true;standard='dingdong-complete-delivery-v1';whiteBackgroundArtboard0FileVerified=$true;visualReviewRequired=$true;requiredMainArtboards=$requiredBoards;detailSliceCount=($boundaries.Count-1);verifiedFileCount=$actual.Count}
}

function Assert-DingdongArchiveDeliveryRequirements {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)]$SourceFacts,
    [string[]]$ExcludedMainArtboards = @(),
    [string]$UserMainExclusionInstruction
  )
  # 真正解压最终包再验收，不能用临时输出、运行报告或包外补图替代包内内容。
  $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
  $verifyRoot = Join-Path $tempParent ('codex-delivery-verify-'+[guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $verifyRoot | Out-Null
    $extract = @(& tar.exe -xf $ArchivePath -C $verifyRoot 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "最终压缩包无法解压验收：$($extract -join '; ')" }
    Assert-DingdongDeliveryRequirements -DeliveryDirectory $verifyRoot -SourceFacts $SourceFacts -ExcludedMainArtboards $ExcludedMainArtboards -UserMainExclusionInstruction $UserMainExclusionInstruction
  } finally {
    if (Test-Path -LiteralPath $verifyRoot) {
      $resolved = (Resolve-Path -LiteralPath $verifyRoot).Path
      if (-not $resolved.StartsWith($tempParent+'\codex-delivery-verify-',[StringComparison]::OrdinalIgnoreCase)) { throw '验收临时目录范围不符' }
      Remove-Item -LiteralPath $resolved -Recurse
    }
  }
}
