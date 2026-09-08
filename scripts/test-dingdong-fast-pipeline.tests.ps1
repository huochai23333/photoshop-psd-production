$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

function Assert-True { param([bool]$Condition, [string]$Name) if (-not $Condition) { throw "ASSERT FAILED: $Name" }; "PASS: $Name" }

$tempRoot = Join-Path $env:TEMP "codex-dingdong-fast-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $detailDefinitionPath = Join-Path $skillRoot 'assets\templates\definitions\dingdong-haoshiguang-detail-2step.json'
  $mainDefinitionPath = Join-Path $skillRoot 'assets\templates\definitions\dingdong-haoshiguang-main-7board.json'
  $detailDefinition = Read-Utf8Json $detailDefinitionPath
  $mainDefinition = Read-Utf8Json $mainDefinitionPath
  $indexFixturePath = Join-Path $tempRoot 'detail-index.json'
  $layers = @(
    [pscustomobject]@{ id=17; parentId=$null; siblingIndex=0; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='头版' },
    [pscustomobject]@{ id=5990; parentId=17; siblingIndex=2; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='头版/图1' },
    [pscustomobject]@{ id=5442; parentId=17; siblingIndex=3; typename='ArtLayer'; kind='LayerKind.SOLIDFILL'; visible=$true; grouped=$false; path='头版/底1' },
    [pscustomobject]@{ id=20; parentId=$null; siblingIndex=1; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='版2' },
    [pscustomobject]@{ id=5991; parentId=20; siblingIndex=1; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='版2/图2' },
    [pscustomobject]@{ id=205; parentId=20; siblingIndex=2; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$false; path='版2/底2' },
    [pscustomobject]@{ id=30; parentId=$null; siblingIndex=2; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='步骤2' },
    [pscustomobject]@{ id=5999; parentId=30; siblingIndex=1; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='步骤2/图3' },
    [pscustomobject]@{ id=2538; parentId=30; siblingIndex=2; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$false; path='步骤2/底3' },
    [pscustomobject]@{ id=31; parentId=$null; siblingIndex=3; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='步骤3' },
    [pscustomobject]@{ id=6000; parentId=31; siblingIndex=1; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='步骤3/图3' },
    [pscustomobject]@{ id=3922; parentId=31; siblingIndex=2; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$false; path='步骤3/底3' },
    [pscustomobject]@{ id=40; parentId=$null; siblingIndex=3; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='版4' },
    [pscustomobject]@{ id=6001; parentId=40; siblingIndex=0; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='版4/图4' },
    [pscustomobject]@{ id=2673; parentId=40; siblingIndex=1; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$false; path='版4/底4' },
    [pscustomobject]@{ id=50; parentId=$null; siblingIndex=4; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='版5' },
    [pscustomobject]@{ id=6002; parentId=50; siblingIndex=4; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='版5/图5' },
    [pscustomobject]@{ id=3248; parentId=50; siblingIndex=5; typename='ArtLayer'; kind='LayerKind.NORMAL'; visible=$true; grouped=$false; path='版5/底5' },
    [pscustomobject]@{ id=60; parentId=$null; siblingIndex=5; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='版6' },
    [pscustomobject]@{ id=6005; parentId=60; siblingIndex=0; typename='ArtLayer'; kind='LayerKind.NORMAL'; visible=$true; grouped=$false; path='版6/装饰叠层' },
    [pscustomobject]@{ id=6004; parentId=60; siblingIndex=1; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='版6/图6' },
    [pscustomobject]@{ id=3892; parentId=60; siblingIndex=2; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$false; path='版6/底6' },
    [pscustomobject]@{ id=70; parentId=$null; siblingIndex=6; typename='LayerSet'; kind=''; visible=$true; grouped=$false; path='版8' },
    [pscustomobject]@{ id=6007; parentId=70; siblingIndex=0; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$true; path='版8/图7' },
    [pscustomobject]@{ id=3933; parentId=70; siblingIndex=1; typename='ArtLayer'; kind='LayerKind.SMARTOBJECT'; visible=$true; grouped=$false; path='版8/底7' }
  )
  Write-Utf8Json -Path $indexFixturePath -Value ([pscustomobject]@{ indexVersion=1; document=[pscustomobject]@{ layers=$layers } }) | Out-Null
  $resolved = & (Join-Path $PSScriptRoot 'resolve-dingdong-detail-sources.ps1') -DetailIndexPath $indexFixturePath -DetailDefinitionPath $detailDefinitionPath -MainDefinitionPath $mainDefinitionPath | ConvertFrom-Json
  $resolvedIds = @($resolved.items | ForEach-Object { [int]$_.sourceLayerId })
  Assert-True (($resolvedIds -join ',') -ceq '5990,5991,5999,6001,6002,6004,6007') 'detail resolver selects all seven registered product image layers'
  Assert-True ($resolvedIds -contains 6004 -and $resolvedIds -notcontains 6005) 'screen 6 excludes the decorative overlay and selects the clipped smart object'

  $grammar = Read-Utf8Json (Join-Path $skillRoot ([string]$detailDefinition.copyGrammarBaselinePath))
  $templateIndex = Read-Utf8Json (Join-Path $skillRoot 'assets\templates\indexes\dingdong-haoshiguang-detail-2step.index.json')
  $layerById = @{}
  foreach ($document in @($templateIndex.documents)) { foreach ($layer in @($document.layers)) { $layerById[[string]$layer.id] = $layer } }
  $grammarById = @{}; foreach ($target in @($grammar.targets)) { $grammarById[[string]$target.id] = $target }
  $requiredSourceIds = @('1853','3911','2689','2687','3886','3899','4811','4819','4076')
  $copyReplacements = @()
  foreach ($sourceId in $requiredSourceIds) {
    $layer = $layerById[$sourceId]; $grammarTarget = $grammarById[$sourceId]
    $replacementText = [string]$layer.text
    $replacementLines = @($grammarTarget.lines | ForEach-Object { [pscustomobject]@{ sourceSegments=@($_.sourceSegments); proposedSegments=@($_.sourceSegments | ForEach-Object { $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json }) } })
    $replacementEvidenceIds = @('fixture-fact')
    if ($sourceId -ceq '3899') {
      $replacementText = '特调' + $replacementText.Substring(2)
      $replacementLines[0].proposedSegments[0].text = '特调'
    }
    if ($sourceId -ceq '4076') {
      $replacementText = "下班回家轻松煮`r煮好后热乎上桌`r"
      $replacementLines[0].proposedSegments[0].text = '下班回家'
      $replacementLines[0].proposedSegments[2].text = '煮'
      $replacementLines[1].proposedSegments[0].text = '煮好后'
    }
    if ($sourceId -ceq '4811') {
      $replacementText = "洋葱：炒制后清甜爽脆，增添香气`r"
      @('洋葱','炒制后','清甜爽脆','增添香气') | ForEach-Object -Begin { $segmentIndex = 0 } -Process {
        $replacementLines[0].proposedSegments[$segmentIndex].text = $_; $segmentIndex++
      }
      $replacementEvidenceIds = @('fixture-onion')
    }
    if ($sourceId -ceq '4819') {
      $replacementText = "豆芽：保持根根口感脆嫩，提鲜解腻`r`r"
      @('豆芽','保持','根根口感','脆嫩','提鲜','解腻') | ForEach-Object -Begin { $segmentIndex = 0 } -Process {
        $replacementLines[0].proposedSegments[$segmentIndex].text = $_; $segmentIndex++
      }
      $replacementEvidenceIds = @('fixture-sprout')
    }
    $copyReplacements += [pscustomobject][ordered]@{
      label = "fixture-$sourceId"; id = [int]$sourceId; path = [string]$layer.path; oldText = [string]$layer.text; text = $replacementText
      mode = 'structure-adapted'
      lines = $replacementLines
      evidenceIds = $replacementEvidenceIds
    }
  }
  foreach ($step in @($detailDefinition.currentSteps)) {
    $layer = $layerById[[string]$step.instructionTextId]
    $copyReplacements += [pscustomobject][ordered]@{ label="step-$($step.number)"; id=[int]$step.instructionTextId; path=[string]$layer.path; oldText=[string]$layer.text; text=[string]$layer.text; sourceText=[string]$layer.text; mode='verbatim'; evidenceIds=@('fixture-fact') }
  }
  $copyPath = Join-Path $tempRoot 'copy.json'
  $legacyEvidence = (@($detailDefinition.legacyCopyTerms) -join ' ')
  Write-Utf8Json -Path $copyPath -Value ([pscustomobject][ordered]@{
    copyVersion=2; templateId='dingdong-haoshiguang-detail-2step'; facts=@(
      [pscustomobject]@{id='fixture-fact';kind='user';statement=$legacyEvidence;source='test fixture'}
      [pscustomobject]@{id='fixture-onion';kind='user';category='side-dish';terms=@('洋葱');statement='当前配菜含洋葱';source='test fixture'}
      [pscustomobject]@{id='fixture-sprout';kind='user';category='side-dish';terms=@('豆芽');statement='当前配菜含豆芽';source='test fixture'}
    ); terminologyDecisions=@(); protectedOverrides=@(); textReplacements=$copyReplacements
  }) | Out-Null
  $mappingPath = Join-Path $tempRoot 'mapping.json'
  & (Join-Path $PSScriptRoot 'new-dingdong-main-mapping.ps1') -ApprovedDetailCopyPath $copyPath -ApprovedCopySha256 (Get-Sha256 $copyPath) -DetailIndexPath $indexFixturePath -OutputPath $mappingPath | Out-Null
  $mapping = Read-Utf8Json $mappingPath
  $board2LockedIds = @($mainDefinition.unchangedTextTargets | Where-Object { [string]$_.artboard -ceq '2' } | ForEach-Object { [string]$_.targetId })
  $generatedTextIds = @($mapping.textReplacements | ForEach-Object { [string]$_.id })
  Assert-True ($mapping.generated -eq $true -and @($mapping.imageMappings).Count -eq 7) 'automatic main mapping contains seven detail-derived images'
  Assert-True (@($generatedTextIds | Where-Object { $board2LockedIds -contains $_ }).Count -eq 0) 'automatic main mapping never authors board 2'
  $countReplacement = @($mapping.textReplacements | Where-Object { [string]$_.id -ceq '1588' })
  Assert-True ($countReplacement.Count -eq 1 -and
    [string]$countReplacement[0].text -ceq "开盒即烹`r2步即烹 轻松到胃`r" -and
    [string]$countReplacement[0].generatedFrom -ceq 'sync-step-count' -and
    [int]$countReplacement[0].stepCount -eq 2) 'two-step mapping changes only the board 3 step-count digit from 3 to 2'
  $oneStepTitle = Get-DingdongStepCountSynchronizedText `
    -BaselineText "开盒即烹`r3步即烹 轻松到胃`r" `
    -StepCount 1 `
    -BaselineStepCount 3 `
    -AllowedStepCounts @(1, 2, 4)
  Assert-True ($oneStepTitle -ceq "开盒即烹`r1步即烹 轻松到胃`r") 'one-step synchronization changes only the board 3 step-count digit from 3 to 1'
  Assert-DingdongStepCountSyncReplacement `
    -Replacement ([pscustomobject]@{ text=$oneStepTitle; generatedFrom='sync-step-count'; stepCount=1 }) `
    -BaselineText "开盒即烹`r3步即烹 轻松到胃`r" `
    -BaselineStepCount 3 `
    -AllowedStepCounts @(1, 2, 4) | Out-Null
  $fourStepTitle = Get-DingdongStepCountSynchronizedText `
    -BaselineText "开盒即烹`r3步即烹 轻松到胃`r" `
    -StepCount 4 `
    -BaselineStepCount 3 `
    -AllowedStepCounts @(2, 4)
  Assert-True ($fourStepTitle -ceq "开盒即烹`r4步即烹 轻松到胃`r") 'four-step synchronization changes only the board 3 step-count digit from 3 to 4'
  Assert-DingdongStepCountSyncReplacement `
    -Replacement ([pscustomobject]@{ text=$fourStepTitle; generatedFrom='sync-step-count'; stepCount=4 }) `
    -BaselineText "开盒即烹`r3步即烹 轻松到胃`r" `
    -BaselineStepCount 3 `
    -AllowedStepCounts @(2, 4) | Out-Null
  $generatedTexts = @($mapping.textReplacements | ForEach-Object { [string]$_.text })
  Assert-True (@($generatedTexts | Where-Object { $_.Contains("`n") }).Count -eq 0 -and
    @($generatedTexts | Where-Object { $_.Contains("`r") }).Count -gt 0) 'automatic main mapping writes Photoshop CR line breaks and no LF line breaks'

  $dummyDetailPsd = Join-Path $tempRoot 'detail.psd'; [IO.File]::WriteAllBytes($dummyDetailPsd, [byte[]](1,2,3))
  $mainJobPath = Join-Path $tempRoot 'main-job.json'
  & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') -DetailPsdPath $dummyDetailPsd -MappingPath $mappingPath -TargetPsdPath (Join-Path $tempRoot 'main.psd') -OutputPath $mainJobPath -DetailWorkDir $tempRoot | Out-Null
  $mainJob = Read-Utf8Json $mainJobPath
  $expectedProtectedMainCount = @($mainDefinition.unchangedTextTargets).Count +
    @($mainDefinition.textTargets | Where-Object { [string]$_.mode -ceq 'sync-detail-current' }).Count - 1
  Assert-True (@($mainJob.protectedTextTargets).Count -eq $expectedProtectedMainCount -and
    @($mainJob.protectedTextTargets | Where-Object { [string]$_.id -ceq '1588' }).Count -eq 0) 'authorized two-step sync removes only the count title from the protected snapshot'
  $resolvedMainJob = Resolve-PsdJob -Task $mainJob -TaskPath $mainJobPath -SkillRoot $skillRoot -RunPath (Join-Path $tempRoot 'main-run.json')
  Assert-True (@($resolvedMainJob.textReplacements | Where-Object { [string]$_.id -ceq '1588' }).Count -eq 1 -and
    @($resolvedMainJob.protectedTextTargets | Where-Object { [string]$_.id -ceq '1588' }).Count -eq 0) 'prepare-stage guard accepts only the registered count sync and keeps it out of protected validation'

  foreach ($invalidCase in @(
      [pscustomobject]@{ name='extra-title-copy'; mutate={ param($item) $item.text = "开盒即烹`r2步即烹 轻松到胃！`r" } },
      [pscustomobject]@{ name='unsupported-five-steps'; mutate={ param($item) $item.stepCount = 5; $item.text = "开盒即烹`r5步即烹 轻松到胃`r" } },
      [pscustomobject]@{ name='missing-step-count'; mutate={ param($item) $item.PSObject.Properties.Remove('stepCount') } },
      [pscustomobject]@{ name='forged-mode'; mutate={ param($item) $item.generatedFrom = 'verbatim' } }
    )) {
    $invalidMapping = $mapping | ConvertTo-Json -Depth 60 | ConvertFrom-Json
    $invalidReplacement = @($invalidMapping.textReplacements | Where-Object { [string]$_.id -ceq '1588' })[0]
    & $invalidCase.mutate $invalidReplacement
    $invalidMappingPath = Join-Path $tempRoot "$($invalidCase.name)-mapping.json"
    Write-Utf8Json -Path $invalidMappingPath -Value $invalidMapping | Out-Null
    $invalidFailed = $false
    try {
      & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') -DetailPsdPath $dummyDetailPsd -MappingPath $invalidMappingPath -TargetPsdPath (Join-Path $tempRoot "$($invalidCase.name).psd") -OutputPath (Join-Path $tempRoot "$($invalidCase.name)-job.json") -DetailWorkDir $tempRoot | Out-Null
    } catch {
      $invalidFailed = $_.Exception.Message -like '*invalid-step-count-sync*'
    }
    Assert-True $invalidFailed "step-count guard rejects $($invalidCase.name)"
  }

  $handwrittenExpandedJob = $mainJob | ConvertTo-Json -Depth 60 | ConvertFrom-Json
  $handwrittenExpandedReplacement = @($handwrittenExpandedJob.textReplacements | Where-Object { [string]$_.id -ceq '1588' })[0]
  $handwrittenExpandedReplacement.text = "开盒即烹`r2步即烹 轻松到胃！`r"
  $handwrittenExpandedFailed = $false
  try {
    Resolve-PsdJob -Task $handwrittenExpandedJob -TaskPath $mainJobPath -SkillRoot $skillRoot -RunPath (Join-Path $tempRoot 'handwritten-expanded-run.json') | Out-Null
  } catch {
    $handwrittenExpandedFailed = $_.Exception.Message -like '*invalid-step-count-sync*'
  }
  Assert-True $handwrittenExpandedFailed 'handwritten job cannot widen the count-only exception'

  $threeStepDefinitionPath = Join-Path $skillRoot 'assets\templates\definitions\dingdong-haoshiguang-detail-3step.json'
  $threeStepDefinition = Read-Utf8Json $threeStepDefinitionPath
  $threeStepIndex = Read-Utf8Json (Join-Path $skillRoot 'assets\templates\indexes\dingdong-haoshiguang-detail-3step.index.json')
  $threeStepLayerById = @{}
  foreach ($document in @($threeStepIndex.documents)) { foreach ($layer in @($document.layers)) { $threeStepLayerById[[string]$layer.id] = $layer } }
  $threeStepReplacements = @()
  foreach ($sourceId in $requiredSourceIds) {
    $layer = $threeStepLayerById[$sourceId]; $grammarTarget = $grammarById[$sourceId]
    $replacementText = [string]$layer.text
    $replacementLines = @($grammarTarget.lines | ForEach-Object { [pscustomobject]@{ sourceSegments=@($_.sourceSegments); proposedSegments=@($_.sourceSegments | ForEach-Object { $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json }) } })
    $replacementEvidenceIds = @('fixture-fact')
    if ($sourceId -ceq '3899') {
      $replacementText = '特调' + $replacementText.Substring(2)
      $replacementLines[0].proposedSegments[0].text = '特调'
    }
    if ($sourceId -ceq '4076') {
      $replacementText = "下班回家轻松煮`r煮好后热乎上桌`r"
      $replacementLines[0].proposedSegments[0].text = '下班回家'
      $replacementLines[0].proposedSegments[2].text = '煮'
      $replacementLines[1].proposedSegments[0].text = '煮好后'
    }
    if ($sourceId -ceq '4811') {
      $replacementText = "洋葱：炒制后清甜爽脆，增添香气`r"
      @('洋葱','炒制后','清甜爽脆','增添香气') | ForEach-Object -Begin { $segmentIndex = 0 } -Process {
        $replacementLines[0].proposedSegments[$segmentIndex].text = $_; $segmentIndex++
      }
      $replacementEvidenceIds = @('fixture-onion')
    }
    if ($sourceId -ceq '4819') {
      $replacementText = "豆芽：保持根根口感脆嫩，提鲜解腻`r`r"
      @('豆芽','保持','根根口感','脆嫩','提鲜','解腻') | ForEach-Object -Begin { $segmentIndex = 0 } -Process {
        $replacementLines[0].proposedSegments[$segmentIndex].text = $_; $segmentIndex++
      }
      $replacementEvidenceIds = @('fixture-sprout')
    }
    $threeStepReplacements += [pscustomobject][ordered]@{
      label = "fixture-$sourceId"; id = [int]$sourceId; path = [string]$layer.path; oldText = [string]$layer.text; text = $replacementText
      mode = 'structure-adapted'
      lines = $replacementLines
      evidenceIds = $replacementEvidenceIds
    }
  }
  foreach ($step in @($threeStepDefinition.currentSteps)) {
    $layer = $threeStepLayerById[[string]$step.instructionTextId]
    $threeStepReplacements += [pscustomobject][ordered]@{ label="step-$($step.number)"; id=[int]$step.instructionTextId; path=[string]$layer.path; oldText=[string]$layer.text; text=[string]$layer.text; sourceText=[string]$layer.text; mode='verbatim'; evidenceIds=@('fixture-fact') }
  }
  $threeStepCopyPath = Join-Path $tempRoot 'copy-3step.json'
  Write-Utf8Json -Path $threeStepCopyPath -Value ([pscustomobject][ordered]@{
    copyVersion=2; templateId='dingdong-haoshiguang-detail-3step'; facts=@(
      [pscustomobject]@{id='fixture-fact';kind='user';statement=(@($threeStepDefinition.legacyCopyTerms) -join ' ');source='test fixture'}
      [pscustomobject]@{id='fixture-onion';kind='user';category='side-dish';terms=@('洋葱');statement='当前配菜含洋葱';source='test fixture'}
      [pscustomobject]@{id='fixture-sprout';kind='user';category='side-dish';terms=@('豆芽');statement='当前配菜含豆芽';source='test fixture'}
    ); terminologyDecisions=@(); protectedOverrides=@(); textReplacements=$threeStepReplacements
  }) | Out-Null
  $threeStepMappingPath = Join-Path $tempRoot 'mapping-3step.json'
  & (Join-Path $PSScriptRoot 'new-dingdong-main-mapping.ps1') -ApprovedDetailCopyPath $threeStepCopyPath -ApprovedCopySha256 (Get-Sha256 $threeStepCopyPath) -DetailIndexPath $indexFixturePath -OutputPath $threeStepMappingPath | Out-Null
  $threeStepMapping = Read-Utf8Json $threeStepMappingPath
  Assert-True (@($threeStepMapping.textReplacements | Where-Object { [string]$_.id -ceq '1588' }).Count -eq 0) 'three-step detail mapping keeps the template count title unchanged'
  Assert-True (-not (Test-ObjectProperty $mainJob.organizeUsedAssets 'sourceLayerIds')) 'used-image organization scans every visible smart object in the formal detail PSD instead of only seven main sources'
  $organizerSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'organize-used-assets.ps1'), $script:PsdJobUtf8NoBom)
  Assert-True ($organizerSource -match 'app\.activeDocument=doc;') 'used-image organization activates the requested PSD before descriptor reads'
  Assert-True ($organizerSource -match 'journalLooksEmpty' -and $organizerSource -match 'refusing to create an empty complete journal') 'used-image organization rejects and repairs silent empty scans'

  $pipelineRoot = Join-Path $tempRoot 'pipeline'
  New-Item -ItemType Directory -Force -Path $pipelineRoot | Out-Null
  Write-Utf8Json -Path (Join-Path $pipelineRoot 'historical-detail-run.json') -Value ([pscustomobject][ordered]@{
    state = 'committed'
    preparedResult = [pscustomobject][ordered]@{ imageChangedCount = 0 }
  }) | Out-Null
  & (Join-Path $PSScriptRoot 'invoke-dingdong-product.ps1') -TaskDirectory $pipelineRoot -ApprovedDetailCopyPath $copyPath -ApprovedCopySha256 (Get-Sha256 $copyPath) -DetailPsdPath $dummyDetailPsd -DetailIndexPath $indexFixturePath -MainTargetPsdPath (Join-Path $tempRoot 'pipeline-main.psd') -PrepareMain:$false -RefreshDetailIndex:$false | Out-Null
  $pipelineState = Read-Utf8Json (Join-Path $pipelineRoot 'dingdong-product-state.json')
  $pipelineMapping = Read-Utf8Json (Join-Path $pipelineRoot 'main-mapping.auto.json')
  $mappingHashBeforeResume = Get-Sha256 (Join-Path $pipelineRoot 'main-mapping.auto.json')
  Assert-True ([string]$pipelineState.stage -ceq 'detail-images-ready' -and @($pipelineState.phaseTimings).Count -ge 2 -and [int]$pipelineState.photoshopInvocationCount -eq 0) 'unified pipeline records stage timing without opening Photoshop when preparation is disabled'
  Assert-True (@($pipelineMapping.imageMappings).Count -eq 7 -and
    @($pipelineMapping.imageMappings | Where-Object { Test-ObjectProperty $_ 'source' }).Count -eq 7) 'historical detail imageChangedCount=0 cannot override seven current detail-index image sources'
  & (Join-Path $PSScriptRoot 'invoke-dingdong-product.ps1') -TaskDirectory $pipelineRoot -ApprovedDetailCopyPath $copyPath -ApprovedCopySha256 (Get-Sha256 $copyPath) -DetailPsdPath $dummyDetailPsd -DetailIndexPath $indexFixturePath -MainTargetPsdPath (Join-Path $tempRoot 'pipeline-main.psd') -PrepareMain:$false -RefreshDetailIndex:$false | Out-Null
  $resumedState = Read-Utf8Json (Join-Path $pipelineRoot 'dingdong-product-state.json')
  Assert-True ((Get-Sha256 (Join-Path $pipelineRoot 'main-mapping.auto.json')) -ceq $mappingHashBeforeResume -and @($resumedState.cacheHits) -contains 'main-mapping' -and @($resumedState.cacheHits) -contains 'main-job') 'unified pipeline resumes from cached approved copy mapping and job'

  [IO.File]::WriteAllBytes($dummyDetailPsd, [byte[]](1,2,3,4))
  & (Join-Path $PSScriptRoot 'invoke-dingdong-product.ps1') -TaskDirectory $pipelineRoot -ApprovedDetailCopyPath $copyPath -ApprovedCopySha256 (Get-Sha256 $copyPath) -DetailPsdPath $dummyDetailPsd -DetailIndexPath $indexFixturePath -MainTargetPsdPath (Join-Path $tempRoot 'pipeline-main.psd') -PrepareMain:$false -RefreshDetailIndex:$false | Out-Null
  $changedState = Read-Utf8Json (Join-Path $pipelineRoot 'dingdong-product-state.json')
  $changedMapping = Read-Utf8Json (Join-Path $pipelineRoot 'main-mapping.auto.json')
  Assert-True ((Get-Sha256 (Join-Path $pipelineRoot 'main-mapping.auto.json')) -cne $mappingHashBeforeResume -and
    [string]$changedMapping.sourceManifest.detailPsdSha256 -ceq (Get-Sha256 $dummyDetailPsd) -and
    [string]$changedState.detailPsdSha256 -ceq (Get-Sha256 $dummyDetailPsd)) 'detail PSD changes invalidate the cached main mapping and update the state binding'

  $staleBoundIndexPath = Join-Path $tempRoot 'stale-bound-index.json'
  $staleBoundIndex = Read-Utf8Json $indexFixturePath
  $staleBoundIndex | Add-Member -NotePropertyName sourcePsd -NotePropertyValue ([pscustomobject][ordered]@{
    path = [IO.Path]::GetFullPath($dummyDetailPsd)
    sha256 = ('0' * 64)
    lastWriteTimeUtc = [DateTime]::UtcNow.ToString('o')
  }) -Force
  Write-Utf8Json -Path $staleBoundIndexPath -Value $staleBoundIndex | Out-Null
  $staleBoundIndexFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'resolve-dingdong-detail-sources.ps1') `
      -DetailIndexPath $staleBoundIndexPath `
      -DetailPsdPath $dummyDetailPsd `
      -DetailDefinitionPath $detailDefinitionPath `
      -MainDefinitionPath $mainDefinitionPath | Out-Null
  } catch {
    $staleBoundIndexFailed = $_.Exception.Message -like '*Detail index is stale*'
  }
  Assert-True $staleBoundIndexFailed 'a detail index bound to an older PSD hash is rejected before main-image mapping'

  $commonScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'psd-job-common.ps1'), [Text.UTF8Encoding]::new($false, $true))
  Assert-True ($commonScript.Contains('PhotoshopRunningObjectTable') -and $commonScript.Contains('Get-RunningPhotoshopApplication')) 'shared Photoshop attachment supports PowerShell 7 running-object lookup'
  foreach ($connectionScriptName in @('get-active-psd-info.ps1', 'index-psd-template.ps1', 'probe-photoshop-capabilities.ps1', 'list-text-layers.ps1')) {
    $connectionScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $connectionScriptName), [Text.UTF8Encoding]::new($false, $true))
    Assert-True ($connectionScript.Contains('Get-RunningPhotoshopApplication') -and
      -not $connectionScript.Contains("Marshal]::GetActiveObject")) "$connectionScriptName uses the PowerShell 7-compatible Photoshop attachment helper"
  }

  $completeScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'complete-psd-job.ps1'), [Text.UTF8Encoding]::new($false, $true))
  Assert-True ($completeScript.Contains("psdState -NotePropertyValue 'committed'") -and $completeScript.Contains("workflowState -NotePropertyValue")) 'completion records PSD commit separately from post-commit workflow attention'
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
