$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dingdong-export-destination.ps1')
$script:passed = 0
function Assert-Case {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "FAIL: $Name" }
  $script:passed++
  "PASS: $Name"
}
function Assert-Rejected {
  param([scriptblock]$Action, [string]$ExpectedMessage, [string]$Name)
  $message = ''
  try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
  Assert-Case ($message.Contains($ExpectedMessage)) $Name
}

# 所有测试只在系统临时目录创建虚拟商品，不打开 Photoshop，不访问移动硬盘。
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-export-destination-test-' + [guid]::NewGuid().ToString('N'))
try {
  $parent = Join-Path $testRoot '小梅园'
  $product = Join-Path $parent '测试商品'
  $outside = Join-Path $testRoot 'outputs'
  New-Item -ItemType Directory -Path $product, $outside | Out-Null
  $default = Resolve-DingdongExportDestination -ProductDirectory $product
  Assert-Case ($default.destinationRoot -ceq $parent -and $default.rule -ceq 'product-parent-xiaomeiyuan') '默认路径取商品实际父目录，与盘符无关'
  $same = Resolve-DingdongExportDestination -ProductDirectory $product -DestinationRoot ($parent + '\')
  Assert-Case ($same.destinationRoot -ceq $parent) '显式传入相同父目录及末尾分隔符仍有效'
  Assert-Rejected { Resolve-DingdongExportDestination -ProductDirectory $product -DestinationRoot $outside } '压缩包位置不符合规则' '擅自改放 outputs 被拦截'
  Assert-Rejected { Resolve-DingdongExportDestination -ProductDirectory $product -DestinationRoot '.' } '必须使用绝对路径' '相对路径被拦截'
  Assert-Rejected { Resolve-DingdongExportDestination -ProductDirectory $product -UserDestinationInstruction '用户指定位置' } '必须同时传入' '只有授权文字而没有位置时被拦截'
  Assert-Rejected { Resolve-DingdongExportDestination -ProductDirectory $outside } '商品父目录不是小梅园' '错误商品层级被拦截'
  $custom = Resolve-DingdongExportDestination -ProductDirectory $product -DestinationRoot $outside -UserDestinationInstruction '请把本次压缩包放到此测试 outputs 目录'
  Assert-Case ($custom.destinationRoot -ceq $outside -and $custom.rule -ceq 'explicit-user-destination') '用户本次明确指定的位置可用且保留原话'
  # 直接调用生产入口验证：目录错误先于素材检查和 Photoshop 读取失败。
  Assert-Rejected { & (Join-Path $PSScriptRoot 'export-dingdong-image-package.ps1') -ProductDirectory $product -DestinationRoot $outside } '压缩包位置不符合规则' '生产入口在任何 PSD 操作前拦截错误位置'
  Assert-Case (@(Get-ChildItem -LiteralPath $product -Recurse -File).Count -eq 0) '被拦截的生产入口未创建导出文件'
  # 这里只验证落盘凭证，7z 格式及内容由现有压缩器流程负责校验。
  $archive = Join-Path $parent '测试.7z'
  [IO.File]::WriteAllBytes($archive, [byte[]]@(55,122,188,175,39,28,1))
  $package = [pscustomobject]@{ok=$true;archivePath=$archive;archiveBytes=7;archiveSha256=(Get-FileHash -LiteralPath $archive).Hash}
  Assert-DingdongArchiveDestination -DestinationPolicy $default -ExpectedArchivePath $archive -Package $package
  Assert-Case $true '正确实际位置、大小和哈希通过完成核验'
  Assert-Rejected { Assert-DingdongArchiveDestination -DestinationPolicy $custom -ExpectedArchivePath $archive -Package $package } '实际位置' '完成前再次拦截错误实际目录'
  $package.archiveSha256 = 'WRONG'
  Assert-Rejected { Assert-DingdongArchiveDestination -DestinationPolicy $default -ExpectedArchivePath $archive -Package $package } '哈希核验失败' '实际压缩包内容不一致时禁止报告完成'
  $package.archiveSha256 = (Get-FileHash -LiteralPath $archive).Hash
  $package.archiveBytes = 0
  Assert-Rejected { Assert-DingdongArchiveDestination -DestinationPolicy $default -ExpectedArchivePath $archive -Package $package } '哈希核验失败' '大小凭证不一致时禁止报告完成'
  "全部通过：$script:passed 项"
} finally {
  # 只清理本次唯一测试目录；先确认绝对路径仍在系统临时目录之内。
  if (Test-Path -LiteralPath $testRoot) {
    $resolved = (Resolve-Path -LiteralPath $testRoot).Path
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $resolved.StartsWith($tempParent + '\codex-export-destination-test-', [StringComparison]::OrdinalIgnoreCase)) { throw '拒绝清理测试范围外路径' }
    Remove-Item -LiteralPath $resolved -Recurse
  }
}
