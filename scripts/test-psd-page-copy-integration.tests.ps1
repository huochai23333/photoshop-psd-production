$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'psd-job-photoshop.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-psd-page-copy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$sourcePath = Join-Path $testRoot 'source.psd'
$targetPath = Join-Path $testRoot 'target.psd'

function Assert-PageCase {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
  "PASS: $Message"
}
function Assert-PageBlocked {
  param([scriptblock]$Action)
  $caught = $false
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -notmatch 'duplicate-page-copy') { throw }
    $caught = $true
  }
  Assert-PageCase $caught '真实入口以 duplicate-page-copy 阻断重复稿'
}

try {
  # 创建独立小 PSD，真实验证读取、拦截、写入和提交，不触碰商品或母版。
  $sourceJs = ConvertTo-JsString ($sourcePath -replace '\\', '/')
  $fixtureJs = @"
(function () {
  var doc = app.documents.add(200, 200, 72, 'codex-page-copy-fixture');
  var board7 = doc.layerSets.add(); board7.name = '版7';
  var copy7 = board7.artLayers.add(); copy7.kind = LayerKind.TEXT;
  copy7.textItem.contents = '本板块原有独立说明';
  var board8 = doc.layerSets.add(); board8.name = '版8';
  var copy81 = board8.artLayers.add(); copy81.kind = LayerKind.TEXT;
  copy81.textItem.contents = '宅家开火 从容不匆忙';
  var copy82 = board8.artLayers.add(); copy82.kind = LayerKind.TEXT;
  copy82.textItem.contents = '陪你度过美味“好食光”';
  doc.saveAs(new File($sourceJs), new PhotoshopSaveOptions(), false, Extension.LOWERCASE);
  var result = '{"editable":' + copy7.id + ',"protected1":' + copy81.id + ',"protected2":' + copy82.id + '}';
  doc.close(SaveOptions.DONOTSAVECHANGES);
  return result;
}());
"@
  $ids = (Invoke-PhotoshopJavaScript -Script $fixtureJs) | ConvertFrom-Json
  $sourceHash = Get-Sha256 $sourcePath
  $duplicateText = '宅家开火 从容不匆忙' + "`r" + '陪你度过美味“好食光”'
  $task = [pscustomobject]@{
    jobVersion = 1; workflow = 'generic'; sourcePsdPath = $sourcePath; targetPsdPath = $targetPath
    textReplacements = @([pscustomobject]@{ id = $ids.editable; text = $duplicateText })
    protectedTextTargets = @([pscustomobject]@{id=$ids.protected1}, [pscustomobject]@{id=$ids.protected2})
    preview = [pscustomobject]@{enabled=$false}
  }
  $taskPath = Join-Path $testRoot 'task.json'
  $runPath = Join-Path $testRoot 'run.json'
  Write-Utf8Json -Path $taskPath -Value $task | Out-Null
  Assert-PageBlocked { & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $taskPath -RunPath $runPath }
  Assert-PageCase (-not (Test-Path -LiteralPath $runPath) -and
    -not (Test-Path -LiteralPath (Join-Path $testRoot 'run.working.psd')) -and
    -not (Test-Path -LiteralPath $targetPath)) '来源预检失败，未创建运行记录、工作副本或成品'
  Assert-PageCase ((Get-Sha256 $sourcePath) -ceq $sourceHash) '预检失败后来源 PSD 哈希未变'

  # 即使直接调用实际写入函数，也要在首个文字操作前拒绝，不依赖 prepare 已执行。
  $directRun = Join-Path $testRoot 'direct-run.json'
  $directJob = Resolve-PsdJob -Task $task -TaskPath $taskPath -SkillRoot (Split-Path -Parent $PSScriptRoot) -RunPath $directRun
  Copy-Item -LiteralPath $sourcePath -Destination $directJob.workingPsdPath
  Assert-PageBlocked { Invoke-PsdJobApply -Job $directJob -ResultPath (Join-Path $testRoot 'direct-result.json') }
  Assert-PageCase ((Get-Sha256 $directJob.workingPsdPath) -ceq $sourceHash -and
    (Test-PsdPageCopy -DocumentPath $directJob.workingPsdPath).ok) '写入入口拦截后磁盘及实际文字均保持原样'

  $task.textReplacements[0].text = '省去切配麻烦 下厨更省时'
  Write-Utf8Json -Path $taskPath -Value $task | Out-Null
  & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $taskPath -RunPath $runPath | Out-Null
  $prepared = Read-Utf8Json $runPath
  Assert-PageCase ($prepared.pageCopyValidation.ok -and $prepared.preparedResult.pageCopyValidation.ok -and
    $prepared.preparedResult.texts[0].after -ceq $task.textReplacements[0].text -and
    @($prepared.preparedResult.protectedTexts).Count -eq 2) '处理重复后能写入，两个未改标题保留并核对'
  & (Join-Path $PSScriptRoot 'complete-psd-job.ps1') -RunPath $runPath | Out-Null
  $committed = Read-Utf8Json $runPath
  Assert-PageCase ($committed.psdState -ceq 'committed' -and $committed.reopenValidation.ok -and
    $committed.pageCopyValidation.ok -and (Get-Sha256 $sourcePath) -ceq $sourceHash) '正常稿完成提交及重开验证，来源未被修改'

  # 模拟已有 prepared 记录：工作副本含重复，即使哈希与记录匹配也不得覆盖正式成品。
  $workingJs = ConvertTo-JsString ($committed.workingPsdPath -replace '\\', '/')
  $duplicateJs = ConvertTo-JsString $duplicateText
  $poisonJs = @"
(function () {
  var doc = app.open(new File($workingJs));
  function change(container) {
    for (var i=0; i<container.layers.length; i++) {
      var layer=container.layers[i];
      if (layer.id === $($ids.editable)) layer.textItem.contents = $duplicateJs;
      if (layer.typename === 'LayerSet') change(layer);
    }
  }
  change(doc); doc.save(); doc.close(SaveOptions.DONOTSAVECHANGES); return 'fixture updated';
}());
"@
  Invoke-PhotoshopJavaScript -Script $poisonJs | Out-Null
  $targetHash = Get-Sha256 $targetPath
  $committed.state = 'prepared'; $committed.targetExisted = $true
  $committed.targetPsdSha256Before = $targetHash
  $committed.workingPsdSha256 = Get-Sha256 $committed.workingPsdPath
  Write-Utf8Json -Path $runPath -Value $committed | Out-Null
  Assert-PageBlocked { & (Join-Path $PSScriptRoot 'complete-psd-job.ps1') -RunPath $runPath }
  Assert-PageCase ((Get-Sha256 $targetPath) -ceq $targetHash) '提交前发现重复，正式成品哈希保持不变'
  'PASS: Photoshop whole-page copy integration completed'
} finally {
  # 只清理本脚本的随机测试目录，先核对绝对路径；不删除任何商品及已有工作。
  $absoluteRoot = [IO.Path]::GetFullPath($testRoot)
  $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($absoluteRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($absoluteRoot).StartsWith('codex-psd-page-copy-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $absoluteRoot -Recurse
    if (Test-Path -LiteralPath $absoluteRoot) { throw '整页文案测试临时目录清理失败。' }
  }
}
