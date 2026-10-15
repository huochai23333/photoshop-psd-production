$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')
$skillRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-dingdong-natural-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-NaturalCopy {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "ASSERT FAILED: $Name" }
  "PASS: $Name"
}

function Copy-NaturalFixture {
  param($Value)
  return ($Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
}

function Test-NaturalFixture {
  param($Value, [string]$Name)
  $fixturePath = Join-Path $testRoot ($Name + '.json')
  Write-Utf8Json -Path $fixturePath -Value $Value | Out-Null
  return Test-DingdongCopyCompliance -CopyPath $fixturePath -SkillRoot $skillRoot
}

function Assert-NaturalError {
  param($Result, [string]$Code)
  Assert-NaturalCopy (@($Result.errors | Where-Object { $_.code -ceq $Code }).Count -gt 0) $Code
}

try {
  foreach ($stepCount in @(1, 2, 3, 4)) {
    $templateId = "dingdong-haoshiguang-detail-$($stepCount)step"
    $context = Get-DingdongTemplateContext -TemplateId $templateId -SkillRoot $skillRoot
    $layers = Get-DingdongLayerLookup (Read-Utf8Json $context.indexPath)
    $headline = $layers['1853']
    # 使用新的完整句式、标点和词数，不提供原文分词、词性或语义角色。
    # 测试只验证放宽后的输入能进入任务，文案是否适合正式商品仍需人工审核。
    $fixture = [ordered]@{
      copyVersion = 2
      templateId = $templateId
      facts = @([ordered]@{
        id = 'current-product'; kind = 'user'
        statement = '当前商品是九层塔巴掌牛肉，配料有牛肉和九层塔，适合涮火锅。'
        source = '测试资料'
      })
      protectedOverrides = @()
      terminologyDecisions = @()
      textReplacements = @([ordered]@{
        label = '头版'; id = 1853; path = [string]$headline.path; oldText = [string]$headline.text
        text = "牛肉配上九层塔，涮一锅换个口味`r在家也能吃上一锅九层塔牛肉"
        mode = 'structure-adapted'; evidenceIds = @('current-product')
        lines = @(
          [ordered]@{ proposedSegments = @(
            @{ text = '牛肉'; separatorAfter = '' }
            @{ text = '配上'; separatorAfter = '' }
            @{ text = '九层塔'; separatorAfter = '，' }
            @{ text = '涮一锅'; separatorAfter = '' }
            @{ text = '换个'; separatorAfter = '' }
            @{ text = '口味'; separatorAfter = '' }
          ) }
          [ordered]@{ proposedSegments = @(
            @{ text = '在家'; separatorAfter = '' }
            @{ text = '也能'; separatorAfter = '' }
            @{ text = '吃上'; separatorAfter = '' }
            @{ text = '一锅'; separatorAfter = '' }
            @{ text = '九层塔'; separatorAfter = '' }
            @{ text = '牛肉'; separatorAfter = '' }
          ) }
        )
      })
    }
    $result = Test-NaturalFixture $fixture "natural-$stepCount"
    Assert-NaturalCopy $result.ok "$templateId accepts natural sentences without source grammar or one-character limits"
    Assert-NaturalCopy ([int]$result.items[0].proposedCounts.Split(' / ')[0] -gt 10) 'line lengths are recorded as a reference'
    $taskPath = Join-Path $testRoot "natural-$stepCount-task.json"
    & (Join-Path $PSScriptRoot 'new-dingdong-detail-job.ps1') -TemplateId $templateId `
      -CopyPath $result.copyPath -ApprovedCopySha256 $result.copySha256 `
      -TargetPsdPath (Join-Path $testRoot "natural-$stepCount.psd") -OutputPath $taskPath | Out-Null
    $task = Read-Utf8Json $taskPath
    Assert-NaturalCopy ($task.textReplacements[0].text -ceq $fixture.textReplacements[0].text -and
      $task.productionScope -ceq 'dingdong-copy-only' -and @($task.imageTransfers).Count -eq 0) 'generated task preserves the approved natural wording and text-only scope'
  }

  # 放宽句式后，证据、固定文案、保护图层、逐字来源和换行规则仍须拒绝违规输入。
  $noEvidence = Copy-NaturalFixture $fixture
  $noEvidence.textReplacements[0].evidenceIds = @()
  Assert-NaturalError (Test-NaturalFixture $noEvidence 'missing-evidence') 'missing-evidence'

  $wrongLines = Copy-NaturalFixture $fixture
  $wrongLines.textReplacements[0].text = $wrongLines.textReplacements[0].text.Replace("`r", '')
  Assert-NaturalError (Test-NaturalFixture $wrongLines 'wrong-lines') 'line-count-mismatch'

  $wrongReconstruction = Copy-NaturalFixture $fixture
  $wrongReconstruction.textReplacements[0].lines[0].proposedSegments[0].text = '鱼肉'
  Assert-NaturalError (Test-NaturalFixture $wrongReconstruction 'wrong-reconstruction') 'proposed-reconstruction-mismatch'

  $missingSegments = Copy-NaturalFixture $fixture
  $missingSegments.textReplacements[0].lines[0].proposedSegments = @()
  Assert-NaturalError (Test-NaturalFixture $missingSegments 'missing-segments') 'empty-segments'

  $ruNoun = Copy-NaturalFixture $fixture
  $ruNoun.textReplacements[0].text = $ruNoun.textReplacements[0].text.Replace('配上', '入味')
  $ruNoun.textReplacements[0].lines[0].proposedSegments[1].text = '入味'
  Assert-NaturalError (Test-NaturalFixture $ruNoun 'ru-noun') 'forbidden-ru-noun-pattern'

  $protected = Copy-NaturalFixture $fixture
  $protectedLayer = $layers['20']
  $protected.textReplacements = @([pscustomobject]@{
    label = '版2'; id = 20; path = [string]$protectedLayer.path; oldText = [string]$protectedLayer.text
    text = '这里仍然不能改'; sourceText = '这里仍然不能改'; mode = 'verbatim'; evidenceIds = @('current-product')
  })
  Assert-NaturalError (Test-NaturalFixture $protected 'protected-layer') 'immutable-protected-target'

  $fixed = Copy-NaturalFixture $fixture
  $fixedLayer = $layers['4076']
  $fixed.textReplacements = @([pscustomobject]@{
    label = '版8'; id = 4076; path = [string]$fixedLayer.path; oldText = [string]$fixedLayer.text
    text = "下班回家轻松煮`r五分钟热乎上桌`r"
    sourceText = "下班回家轻松煮`r五分钟热乎上桌`r"
    mode = 'verbatim'; evidenceIds = @('current-product')
  })
  Assert-NaturalError (Test-NaturalFixture $fixed 'fixed-copy') 'required-exact-copy'

  $verbatim = Copy-NaturalFixture $fixture
  $verbatim.textReplacements[0].mode = 'verbatim'
  $verbatim.textReplacements[0] | Add-Member -NotePropertyName sourceText -NotePropertyValue '另一个版本'
  Assert-NaturalError (Test-NaturalFixture $verbatim 'verbatim-change') 'verbatim-mismatch'
} finally {
  # 仅清理本测试创建的唯一临时目录，先核对绝对路径与固定前缀。
  $absoluteRoot = [IO.Path]::GetFullPath($testRoot)
  $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($absoluteRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($absoluteRoot).StartsWith('codex-dingdong-natural-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $absoluteRoot -Recurse
    if (Test-Path -LiteralPath $absoluteRoot) { throw '自然文案测试临时目录清理失败。' }
  }
}
