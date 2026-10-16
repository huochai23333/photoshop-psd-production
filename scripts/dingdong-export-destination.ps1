# 导出目录规则独立于 Photoshop，错误位置必须在读取 PSD 或创建输出之前拦截。
function Resolve-DingdongExportDestination {
  param(
    [Parameter(Mandatory = $true)][string]$ProductDirectory,
    [string]$DestinationRoot,
    [string]$UserDestinationInstruction
  )
  $product = (Resolve-Path -LiteralPath $ProductDirectory -ErrorAction Stop).Path
  if (-not (Test-Path -LiteralPath $product -PathType Container)) { throw '商品目录必须是已有文件夹。' }
  $parent = [IO.Directory]::GetParent($product.TrimEnd('\')).FullName
  $explicitDestination = -not [string]::IsNullOrWhiteSpace($DestinationRoot)
  $hasUserInstruction = -not [string]::IsNullOrWhiteSpace($UserDestinationInstruction)
  if ($hasUserInstruction -and -not $explicitDestination) { throw '用户指定位置时必须同时传入 DestinationRoot。' }
  if (-not $explicitDestination -and [IO.Path]::GetFileName($parent) -cne '小梅园') {
    throw '商品父目录不是小梅园；请核对商品路径，或提供用户本次明确指定的输出位置及原话。'
  }
  $requested = if ($explicitDestination) { $DestinationRoot } else { $parent }
  if (-not [IO.Path]::IsPathFullyQualified($requested)) { throw '压缩包目标目录必须使用绝对路径。' }
  $destination = [IO.Path]::GetFullPath($requested).TrimEnd('\')
  # 解析已有目录后再比较，避免相对路径、大小写或目录链接造成位置误判。
  if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw "压缩包目标目录不存在：$destination" }
  $destination = (Resolve-Path -LiteralPath $destination).Path.TrimEnd('\')
  $isDefault = $destination.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($parent) -ceq '小梅园'
  if (-not $isDefault -and -not $hasUserInstruction) {
    throw "压缩包位置不符合规则：必须放在商品上一级小梅园目录 $parent。只有用户本次明确指定其他位置时，才可同时传入 DestinationRoot 和 UserDestinationInstruction。"
  }
  [pscustomobject]@{
    productDirectory = $product
    destinationRoot = $destination
    rule = $(if ($isDefault) { 'product-parent-xiaomeiyuan' } else { 'explicit-user-destination' })
    userDestinationInstruction = $(if ($isDefault) { $null } else { $UserDestinationInstruction })
  }
}

function Assert-DingdongArchiveDestination {
  param(
    [Parameter(Mandatory = $true)]$DestinationPolicy,
    [Parameter(Mandatory = $true)][string]$ExpectedArchivePath,
    [Parameter(Mandatory = $true)]$Package
  )
  # 完成凭证必须同时满足实际落盘位置、非空文件及压缩脚本返回的哈希和大小。
  $expected = [IO.Path]::GetFullPath($ExpectedArchivePath)
  $reported = [IO.Path]::GetFullPath([string]$Package.archivePath)
  if (-not $expected.Equals($reported, [StringComparison]::OrdinalIgnoreCase) -or
      -not [IO.Path]::GetDirectoryName($reported).Equals($DestinationPolicy.destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw '压缩包实际位置与已核准目录不一致，禁止报告完成。'
  }
  if ($Package.ok -ne $true -or [IO.Path]::GetExtension($reported) -ine '.7z' -or
      -not (Test-Path -LiteralPath $reported -PathType Leaf)) { throw '压缩包未成功落盘，禁止报告完成。' }
  $file = Get-Item -LiteralPath $reported
  $actualPath = (Resolve-Path -LiteralPath $reported).Path
  if (-not [IO.Path]::GetDirectoryName($actualPath).Equals($DestinationPolicy.destinationRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $file.Length -le 0 -or $file.Length -ne [int64]$Package.archiveBytes -or
      (Get-FileHash -LiteralPath $actualPath -Algorithm SHA256).Hash -cne [string]$Package.archiveSha256) {
    throw '压缩包位置、大小或哈希核验失败，禁止报告完成。'
  }
}
