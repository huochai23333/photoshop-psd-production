$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dingdong-delivery-requirements.ps1')
$script:passed = 0
function Assert-Case { param([bool]$Condition,[string]$Name) if(-not $Condition){throw "FAIL: $Name"};$script:passed++;"PASS: $Name" }
function Assert-Rejected {
  param([scriptblock]$Action,[string]$Expected,[string]$Name)
  $message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
  Assert-Case ($message.Contains($Expected)) $Name
}
function Write-TestImage {
  param([string]$Path,[int]$Width=8,[int]$Height=8)
  $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -ErrorAction SilentlyContinue
  $bitmap=[Drawing.Bitmap]::new($Width,$Height)
  try {$bitmap.SetPixel(4,2,[Drawing.Color]::Red);$bitmap.Save($Path,[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$bitmap.Dispose()}
}
# 使用 C 盘系统临时数据重现缺图，完全不读取商品 PSD 或移动硬盘。
Add-Type -AssemblyName System.Drawing.Common
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root=Join-Path $tempParent ('codex-delivery-test-'+[guid]::NewGuid().ToString('N'))
try {
  $product=Join-Path $root '小梅园\源商品';$delivery=Join-Path $root '交付';$used=Join-Path $product '已使用'
  New-Item -ItemType Directory -Path $used,$delivery|Out-Null
  Write-TestImage (Join-Path $used '素材.jpg')
  Write-TestImage (Join-Path $product '标签.jpg')
  $facts=[pscustomobject]@{productDirectory=$product;detailCanvas=@{width=8;height=16};detailHorizontalGuides=@(8);mainArtboards=@(0..7|ForEach-Object{[pscustomobject]@{name="$_";rect=@(0,0,8,8)}})}
  Write-TestImage (Join-Path $delivery '详情页\详情页长图.jpg') 8 16
  foreach($name in @('detail-0001.jpg','detail-0002.jpg')){Write-TestImage (Join-Path $delivery "详情页\$name")}
  foreach($i in 0..7){Write-TestImage (Join-Path $delivery "主图\$i.jpg")}
  Copy-Item -LiteralPath (Join-Path $product '标签.jpg') -Destination (Join-Path $delivery '主图\标签.jpg')
  New-Item -ItemType Directory -Path (Join-Path $delivery '已使用')|Out-Null
  Copy-Item -LiteralPath (Join-Path $used '素材.jpg') -Destination (Join-Path $delivery '已使用\素材.jpg')
  $result=Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts
  Assert-Case ($result.ok -and $result.whiteBackgroundArtboard0FileVerified -and $result.visualReviewRequired -and $result.requiredMainArtboards.Count -eq 8) '完整交付通过，画板0单独核验并保留视觉检查要求'
  Assert-Rejected {Get-DingdongRequiredMainArtboards -ExcludedMainArtboards @('0') -UserMainExclusionInstruction '隐藏画板不导出'} '画板0白底图' '任何排除指令都不能排除画板0'
  Assert-Rejected {Get-DingdongRequiredMainArtboards -ExcludedMainArtboards @('6')} '本次明确指定' '隐藏画板6不自动变为排除授权'
  $zero=Join-Path $delivery '主图\0.jpg';$six=Join-Path $delivery '主图\6.jpg'
  $zeroBytes=[IO.File]::ReadAllBytes($zero);$sixBytes=[IO.File]::ReadAllBytes($six)
  Remove-Item -LiteralPath $zero,$six
  Assert-Rejected {Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts} '缺少画板0白底图' '重现旧六张清单1、2、3、4、5、7：即使数量正确也必须失败'
  $badArchive=Join-Path $root '缺白底图.7z'; & tar.exe -a -cf $badArchive -C $delivery '.';if($LASTEXITCODE -ne 0){throw '测试归档创建失败'}
  Assert-Rejected {Assert-DingdongArchiveDeliveryRequirements -ArchivePath $badArchive -SourceFacts $facts} '缺少画板0白底图' '真实7z即使可正常解压，缺画板0仍验收失败'
  [IO.File]::WriteAllBytes($zero,$zeroBytes)
  $result=Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts -ExcludedMainArtboards @('6') -UserMainExclusionInstruction '本次画板6不导出'
  Assert-Case ($result.requiredMainArtboards.Count -eq 7 -and '0' -in $result.requiredMainArtboards) '明确只排除6时仍须交付0、1、2、3、4、5、7'
  Assert-Rejected {Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts} '缺项：主图/6.jpg' '未授权排除时缺画板6失败'
  [IO.File]::WriteAllBytes($six,$sixBytes)
  $slice=Join-Path $delivery '详情页\detail-0002.jpg';$sliceBytes=[IO.File]::ReadAllBytes($slice);Remove-Item -LiteralPath $slice
  Assert-Rejected {Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts} 'detail-0002.jpg' '切片数量独立按当前PSD参考线要求检查'
  [IO.File]::WriteAllBytes($slice,$sliceBytes)
  $label=Join-Path $delivery '主图\标签.jpg';Remove-Item -LiteralPath $label
  Assert-Rejected {Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts} '标签.jpg' '独立扫描源商品附件，漏标签不能通过'
  Copy-Item -LiteralPath (Join-Path $product '标签.jpg') -Destination $label
  Write-TestImage $zero 9 8
  Assert-Rejected {Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts} '尺寸不符' '画板图片尺寸按源PSD凭证核对'
  [IO.File]::WriteAllBytes($zero,$zeroBytes)
  $blank=[Drawing.Bitmap]::new(8,8)
  try {$blank.Save($zero,[Drawing.Imaging.ImageFormat]::Jpeg)} finally {$blank.Dispose()}
  Assert-Rejected {Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts} '空白纯色图' '不能用纯色空图冒充画板0补齐数量'
  [IO.File]::WriteAllBytes($zero,$zeroBytes)
  $stagedUsed=Join-Path $delivery '已使用\素材.jpg';[IO.File]::WriteAllText($stagedUsed,'changed')
  Assert-Rejected {Assert-DingdongDeliveryRequirements -DeliveryDirectory $delivery -SourceFacts $facts} '素材字节变化' '已使用素材按源字节核验'
  Copy-Item -LiteralPath (Join-Path $used '素材.jpg') -Destination $stagedUsed
  $goodArchive=Join-Path $root '完整交付.7z'; & tar.exe -a -cf $goodArchive -C $delivery '.';if($LASTEXITCODE -ne 0){throw '测试归档创建失败'}
  $result=Assert-DingdongArchiveDeliveryRequirements -ArchivePath $goodArchive -SourceFacts $facts
  Assert-Case ($result.ok -and $result.verifiedFileCount -eq 13) '真实完整7z解压后逐项验收通过'
  # 沙盒内故意把生产入口改回错误六张清单，并伪造导出成功报告；独立验收仍必须阻止打包。
  $sandbox=Join-Path $root '生产入口回归'
  New-Item -ItemType Directory -Path $sandbox|Out-Null
  foreach($name in @('psd-job-common.ps1','dingdong-export-destination.ps1','dingdong-delivery-requirements.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $sandbox $name)}
  $entry=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'export-dingdong-image-package.ps1')).Replace('-ArtboardNames $requiredMainArtboards',"-ArtboardNames @('1','2','3','4','5','7')")
  [IO.File]::WriteAllText((Join-Path $sandbox 'export-dingdong-image-package.ps1'),$entry,[Text.UTF8Encoding]::new($false))
  $facts|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $sandbox 'facts.json') -Encoding utf8NoBOM
  foreach($name in @('detail.psd','main.psd')){[IO.File]::WriteAllText((Join-Path $product $name),'只供路径与哈希测试，不是PSD')}
  $stubFind=@'
param($ProductDirectory)
$f=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'facts.json') -Raw|ConvertFrom-Json
$f|Add-Member -NotePropertyName detailPsdPath -NotePropertyValue (Join-Path $ProductDirectory 'detail.psd')
$f|Add-Member -NotePropertyName mainPsdPath -NotePropertyValue (Join-Path $ProductDirectory 'main.psd')
$f|ConvertTo-Json -Depth 10
'@
  $stubLong=@'
param($SourcePsdPath,$OutputPath,$Quality,[switch]$Overwrite)
$null=New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\详情页\详情页长图.jpg') -Destination $OutputPath
'{"ok":true}'
'@
  $stubSlices=@'
param($SourcePsdPath,$OutputDirectory,$Format,$Quality,[switch]$Overwrite)
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixture\详情页') -Filter 'detail-*.jpg'|Copy-Item -Destination $OutputDirectory
'{"ok":true,"sliceCount":2}'
'@
  $stubMain=@'
param($SourcePsdPath,$OutputDirectory,$Format,$ArtboardNames,$Quality,[switch]$Overwrite)
foreach($n in $ArtboardNames){Copy-Item -LiteralPath (Join-Path $PSScriptRoot "fixture\主图\$n.jpg") -Destination $OutputDirectory}
'{"ok":true,"pageCount":6,"requestedArtboardNames":["1","2","3","4","5","7"]}'
'@
  $stubs=@{'find-dingdong-export-psds.ps1'=$stubFind;'export-psd-jpg.ps1'=$stubLong;'export-psd-slices.ps1'=$stubSlices;'export-artboards.ps1'=$stubMain;'compress-image-package.ps1'="throw '不应进入压缩步骤'"}
  foreach($name in $stubs.Keys){[IO.File]::WriteAllText((Join-Path $sandbox $name),$stubs[$name],[Text.UTF8Encoding]::new($false))}
  Copy-Item -LiteralPath $delivery -Destination (Join-Path $sandbox 'fixture') -Recurse
  Assert-Rejected {& (Join-Path $sandbox 'export-dingdong-image-package.ps1') -ProductDirectory $product -ArchiveName '不应生成.7z'} '缺少画板0白底图' '生产入口即使导出器与报告都改成六张，也在打包前阻断'
  Assert-Case (-not(Test-Path -LiteralPath (Join-Path (Split-Path -Parent $product) '不应生成.7z'))) '错误六张清单不能生成交付压缩包'
  "全部通过：$script:passed 项"
} finally {
  if(Test-Path -LiteralPath $root){$resolved=(Resolve-Path -LiteralPath $root).Path;if(-not $resolved.StartsWith($tempParent+'\codex-delivery-test-',[StringComparison]::OrdinalIgnoreCase)){throw '测试清理范围不符'};Remove-Item -LiteralPath $resolved -Recurse}
}
