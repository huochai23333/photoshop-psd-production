$ErrorActionPreference = 'Stop'

$script:PsdJobUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DingdongBlock4ForbiddenPrepPackagingTerms = @(
  '分装', '装好', '包好', '包装', '整包', '单包', '每包', '按包',
  '装袋', '袋装', '盒装', '碗装', '杯装', '罐装', '瓶装',
  '整袋', '整盒', '整份', '切好', '预切', '切配', '预处理',
  '预制', '预装', '配好', '备好', '处理好'
)
$script:DingdongBlock4ForbiddenInstructionTerms = @(
  '步骤', '锅中', '另起锅', '热锅', '冷油', '大火', '中火', '小火',
  '下锅', '下入', '放入', '加入', '倒入', '倒出', '备用', '翻炒',
  '炒制', '煸炒', '炒香', '煮制', '蒸制', '焯水', '断生', '变色',
  '上色', '分钟', '秒钟'
)

function Read-Utf8Json {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "JSON file does not exist: $Path"
  }
  $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
  return [IO.File]::ReadAllText($resolved, $script:PsdJobUtf8NoBom) | ConvertFrom-Json
}

function Write-Utf8Json {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowNull()]$Value,
    [int]$Depth = 60
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $directory = Split-Path -Parent $fullPath
  if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $temporary = "$fullPath.tmp-$([guid]::NewGuid().ToString('N'))"
  [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth $Depth) + "`n"), $script:PsdJobUtf8NoBom)
  Move-Item -LiteralPath $temporary -Destination $fullPath -Force
  return $fullPath
}

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-ObjectProperty {
  param([AllowNull()]$Value, [Parameter(Mandatory = $true)][string]$Name)

  return $null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]
}

function Get-UsedAssetSourceLayerIdsForCompletion {
  param([Parameter(Mandatory = $true)]$Run)

  # A Dingdong main mapping names only the seven images copied to the main PSD.
  # Asset organization belongs to the formal detail PSD and must scan every
  # visible smart object there, including step and detail-only images.
  if ((Test-ObjectProperty $Run 'workflow') -and [string]$Run.workflow -ceq 'dingdong-main') {
    return @()
  }
  if ((Test-ObjectProperty $Run 'organizeUsedAssets') -and
      $Run.organizeUsedAssets -and
      $Run.organizeUsedAssets -ne $false -and
      -not ($Run.organizeUsedAssets -is [bool]) -and
      (Test-ObjectProperty $Run.organizeUsedAssets 'sourceLayerIds')) {
    return @($Run.organizeUsedAssets.sourceLayerIds | ForEach-Object { [int]$_ })
  }
  return @()
}

function Test-DingdongBlock4Path {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $normalized = $Path.Replace('\', '/')
  return @($normalized.Split('/') | Where-Object { $_ -ceq '版4' }).Count -gt 0
}

function Get-DingdongBlock4ForbiddenPrepPackagingTerm {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $null }
  foreach ($term in $script:DingdongBlock4ForbiddenPrepPackagingTerms) {
    if ($Text.IndexOf($term, [StringComparison]::Ordinal) -ge 0) { return $term }
  }
  return $null
}

function Get-DingdongBlock4ForbiddenInstructionTerm {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $null }
  foreach ($term in $script:DingdongBlock4ForbiddenInstructionTerms) {
    if ($Text.IndexOf($term, [StringComparison]::Ordinal) -ge 0) { return $term }
  }
  return $null
}

function Get-DingdongContiguousStepCount {
  param([Parameter(Mandatory = $true)]$DetailDefinition)

  if (-not (Test-ObjectProperty $DetailDefinition 'currentSteps')) {
    throw 'invalid-step-count-sync: detail definition has no currentSteps.'
  }
  $numbers = @($DetailDefinition.currentSteps | ForEach-Object {
    if (-not (Test-ObjectProperty $_ 'number')) {
      throw 'invalid-step-count-sync: every currentSteps entry requires a number.'
    }
    [int]$_.number
  } | Sort-Object)
  if ($numbers.Count -lt 1 -or @($numbers | Select-Object -Unique).Count -ne $numbers.Count) {
    throw 'invalid-step-count-sync: currentSteps numbers must be present and unique.'
  }
  for ($index = 0; $index -lt $numbers.Count; $index++) {
    if ($numbers[$index] -ne ($index + 1)) {
      throw 'invalid-step-count-sync: currentSteps numbers must be contiguous from 1.'
    }
  }
  return $numbers.Count
}

function Get-DingdongStepCountSynchronizedText {
  param(
    [Parameter(Mandatory = $true)][string]$BaselineText,
    [Parameter(Mandatory = $true)][int]$StepCount,
    [int]$BaselineStepCount = 3,
    [int[]]$AllowedStepCounts = @(1, 2, 4)
  )

  $supportedStepCounts = @($BaselineStepCount) + @($AllowedStepCounts) | Select-Object -Unique
  if ($StepCount -notin $supportedStepCounts) {
    throw "invalid-step-count-sync: only $($supportedStepCounts -join ', ') steps are supported."
  }
  $matches = [regex]::Matches($BaselineText, '(?<![0-9])([0-9]+)步')
  if ($matches.Count -ne 1 -or [int]$matches[0].Groups[1].Value -ne $BaselineStepCount) {
    throw "invalid-step-count-sync: baseline text must contain exactly one ${BaselineStepCount}步 phrase."
  }
  if ($StepCount -eq $BaselineStepCount) { return $BaselineText }

  $numberGroup = $matches[0].Groups[1]
  return $BaselineText.Remove($numberGroup.Index, $numberGroup.Length).Insert($numberGroup.Index, [string]$StepCount)
}

function Assert-DingdongStepCountSyncReplacement {
  param(
    [Parameter(Mandatory = $true)]$Replacement,
    [Parameter(Mandatory = $true)][string]$BaselineText,
    [int]$BaselineStepCount = 3,
    [int[]]$AllowedStepCounts = @(1, 2, 4)
  )

  $generatedFrom = if (Test-ObjectProperty $Replacement 'generatedFrom') { [string]$Replacement.generatedFrom } else { '' }
  $stepCount = if (Test-ObjectProperty $Replacement 'stepCount') { [int]$Replacement.stepCount } else { -1 }
  $replacementText = if (Test-ObjectProperty $Replacement 'text') { [string]$Replacement.text } else { $null }
  if ($generatedFrom -cne 'sync-step-count' -or $stepCount -notin $AllowedStepCounts -or $null -eq $replacementText) {
    throw "invalid-step-count-sync: the protected step-count title requires generatedFrom=sync-step-count and stepCount in $($AllowedStepCounts -join ', ')."
  }
  $expectedText = Get-DingdongStepCountSynchronizedText `
    -BaselineText $BaselineText `
    -StepCount $stepCount `
    -BaselineStepCount $BaselineStepCount `
    -AllowedStepCounts $AllowedStepCounts
  if ($replacementText -cne $expectedText) {
    throw 'invalid-step-count-sync: only the single protected step-count digit may change; all other characters must match the template.'
  }
  return $true
}

function Get-OptionalArray {
  param([AllowNull()]$Value, [Parameter(Mandatory = $true)][string]$Name)

  if (-not (Test-ObjectProperty $Value $Name) -or $null -eq $Value.$Name) { return }
  foreach ($item in @($Value.$Name)) {
    if ($null -eq $item) { continue }
    if ($item -is [psobject] -and @($item.PSObject.Properties).Count -eq 0) { continue }
    $item
  }
}

function Resolve-JobPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BaseDirectory
  )

  if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
  return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function ConvertTo-JsString {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) { return 'null' }
  $text = $Value -replace '\\', '\\\\'
  $text = $text -replace '"', '\"'
  $text = $text -replace "`r", '\r'
  $text = $text -replace "`n", '\n'
  return '"' + $text + '"'
}

function Get-RunningPhotoshopApplication {
  $photoshopType = [Type]::GetTypeFromProgID('Photoshop.Application')
  if (-not $photoshopType) { throw 'Photoshop COM registration was not found.' }

  $legacyMethod = [Runtime.InteropServices.Marshal].GetMethod(
    'GetActiveObject',
    [Reflection.BindingFlags]'Public, Static',
    $null,
    [type[]]@([string]),
    $null
  )
  if ($legacyMethod) {
    return $legacyMethod.Invoke($null, [object[]]@('Photoshop.Application'))
  }

  if (-not ('Codex.PhotoshopRunningObjectTable' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Codex
{
    public static class PhotoshopRunningObjectTable
    {
        [DllImport("oleaut32.dll", PreserveSig = true)]
        public static extern int GetActiveObject(
            ref Guid rclsid,
            IntPtr reserved,
            [MarshalAs(UnmanagedType.Interface)] out object instance);
    }
}
'@
  }

  $classId = $photoshopType.GUID
  $instance = $null
  $result = [Codex.PhotoshopRunningObjectTable]::GetActiveObject(
    [ref]$classId,
    [IntPtr]::Zero,
    [ref]$instance
  )
  if ($result -ne 0 -or $null -eq $instance) {
    [Runtime.InteropServices.Marshal]::ThrowExceptionForHR($result)
  }
  return $instance
}

function Invoke-PhotoshopJavaScript {
  param(
    [Parameter(Mandatory = $true)][string]$Script,
    [int]$Retries = 12,
    [int]$DelayMilliseconds = 1000
  )

  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    try {
      $photoshopType = [Type]::GetTypeFromProgID('Photoshop.Application')
      if (-not $photoshopType) { throw 'Photoshop COM registration was not found.' }
      $app = [Activator]::CreateInstance($photoshopType)
      return $app.DoJavaScript($Script)
    } catch {
      $message = $_.Exception.Message
      $busy = $message -match 'RPC_E_SERVERCALL_RETRYLATER|application is busy|应用程序.*忙|应用.*忙|message filter'
      if (-not $busy -or $attempt -eq $Retries) { throw }
      Start-Sleep -Milliseconds $DelayMilliseconds
    }
  }
}

function Get-OpenPhotoshopDocumentState {
  param([Parameter(Mandatory = $true)][string]$Path)

  $wanted = ([IO.Path]::GetFullPath($Path) -replace '\\', '/')
  $wantedJs = ConvertTo-JsString $wanted
  $jsx = @"
function q(s) { return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; }
var wanted = $wantedJs;
var matches = [];
for (var i = 0; i < app.documents.length; i++) {
  var doc = app.documents[i], full = "";
  try { full = doc.fullName.fsName.replace(/\\/g, '/'); } catch (e) {}
  if (full.toLowerCase() == wanted.toLowerCase()) {
    matches.push('{"name":' + q(doc.name) + ',"saved":' + (doc.saved ? 'true' : 'false') + '}');
  }
}
'{"count":' + matches.length + ',"documents":[' + matches.join(',') + ']}';
"@
  return (Invoke-PhotoshopJavaScript -Script $jsx) | ConvertFrom-Json
}

function Resolve-PsdJob {
  param(
    [Parameter(Mandatory = $true)]$Task,
    [Parameter(Mandatory = $true)][string]$TaskPath,
    [Parameter(Mandatory = $true)][string]$SkillRoot,
    [Parameter(Mandatory = $true)][string]$RunPath
  )

  if (Test-ObjectProperty $Task 'schemaVersion') {
    throw '旧 schemaVersion/审批任务不再兼容。请建立 jobVersion: 1 任务。'
  }
  if (-not (Test-ObjectProperty $Task 'jobVersion') -or [int]$Task.jobVersion -ne 1) {
    throw 'Task must declare jobVersion: 1.'
  }

  $taskFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TaskPath).Path)
  $taskDirectory = Split-Path -Parent $taskFullPath
  $runFullPath = [IO.Path]::GetFullPath($RunPath)
  $runDirectory = Split-Path -Parent $runFullPath
  $sourceTemplateId = $null
  if ((Test-ObjectProperty $Task 'source') -and $Task.source -and (Test-ObjectProperty $Task.source 'templateId')) {
    $sourceTemplateId = [string]$Task.source.templateId
  }
  $directSource = if (Test-ObjectProperty $Task 'sourcePsdPath') { [string]$Task.sourcePsdPath } else { '' }
  if ([string]::IsNullOrWhiteSpace($sourceTemplateId) -eq [string]::IsNullOrWhiteSpace($directSource)) {
    throw 'Declare exactly one source: source.templateId or sourcePsdPath.'
  }

  $template = $null
  $templateDefinition = $null
  $templateIndex = $null
  $templateWarning = $null
  if (-not [string]::IsNullOrWhiteSpace($sourceTemplateId)) {
    $registryPath = Join-Path $SkillRoot 'assets\templates\registry.json'
    $registry = Read-Utf8Json $registryPath
    $matches = @($registry.templates | Where-Object { [string]$_.templateId -ceq $sourceTemplateId })
    if ($matches.Count -ne 1) { throw "Template id must resolve exactly once: $sourceTemplateId" }
    $template = $matches[0]
    $templatesRoot = Split-Path -Parent $registryPath
    if ((Test-ObjectProperty $template 'definitionPath') -and
        -not [string]::IsNullOrWhiteSpace([string]$template.definitionPath)) {
      $templateDefinitionPath = Resolve-JobPath -Path ([string]$template.definitionPath) -BaseDirectory $templatesRoot
      $templateDefinition = Read-Utf8Json $templateDefinitionPath
    }
    if ((Test-ObjectProperty $template 'indexPath') -and
        -not [string]::IsNullOrWhiteSpace([string]$template.indexPath)) {
      $templateIndexPath = Resolve-JobPath -Path ([string]$template.indexPath) -BaseDirectory $templatesRoot
      $templateIndex = Read-Utf8Json $templateIndexPath
    }
    $templatePathValue = if (Test-ObjectProperty $template 'psdPath') {
      [string]$template.psdPath
    } elseif ((Test-ObjectProperty $template 'master') -and $template.master) {
      [string]$template.master.externalPath
    } else {
      ''
    }
    if ([string]::IsNullOrWhiteSpace($templatePathValue)) { throw "Template has no PSD path: $sourceTemplateId" }
    $sourceFullPath = Resolve-JobPath -Path $templatePathValue -BaseDirectory (Split-Path -Parent $registryPath)
    if ((Test-ObjectProperty $template 'master') -and $template.master -and
        (Test-ObjectProperty $template.master 'sha256') -and (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
      $currentMasterHash = Get-Sha256 $sourceFullPath
      if ($currentMasterHash -cne [string]$template.master.sha256) {
        $templateWarning = "登记模板内容已变化，已按当前保存的 PSD 继续并刷新目标检查：$sourceTemplateId"
      }
    }
  } else {
    $sourceFullPath = Resolve-JobPath -Path $directSource -BaseDirectory $taskDirectory
  }

  if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) { throw "Source PSD/PSB does not exist: $sourceFullPath" }
  if (-not (Test-ObjectProperty $Task 'targetPsdPath') -or [string]::IsNullOrWhiteSpace([string]$Task.targetPsdPath)) {
    throw 'targetPsdPath is required.'
  }
  $targetFullPath = Resolve-JobPath -Path ([string]$Task.targetPsdPath) -BaseDirectory $taskDirectory
  $extension = [IO.Path]::GetExtension($targetFullPath)
  if ($extension -notin @('.psd', '.psb')) { throw 'targetPsdPath must end in .psd or .psb.' }
  $runStem = [IO.Path]::GetFileNameWithoutExtension($runFullPath)
  $workingPath = Join-Path $runDirectory ($runStem + '.working' + $extension)

  $previewEnabled = $true
  $previewPath = Join-Path $runDirectory ($runStem + '-preview.jpg')
  $previewMaxWidth = 1600
  $previewQuality = 9
  if ((Test-ObjectProperty $Task 'outputs') -and $Task.outputs -and (Test-ObjectProperty $Task.outputs 'preview')) {
    $preview = $Task.outputs.preview
    if ($preview -is [bool]) {
      $previewEnabled = [bool]$preview
    } elseif ($preview) {
      if (Test-ObjectProperty $preview 'enabled') { $previewEnabled = [bool]$preview.enabled }
      if ((Test-ObjectProperty $preview 'path') -and -not [string]::IsNullOrWhiteSpace([string]$preview.path)) {
        $previewPath = Resolve-JobPath -Path ([string]$preview.path) -BaseDirectory $taskDirectory
      }
      if (Test-ObjectProperty $preview 'maxWidth') { $previewMaxWidth = [int]$preview.maxWidth }
      if (Test-ObjectProperty $preview 'quality') { $previewQuality = [int]$preview.quality }
    }
  }

  $textReplacements = @(Get-OptionalArray $Task 'textReplacements')
  $protectedTextTargets = @(Get-OptionalArray $Task 'protectedTextTargets')
  $protectedOverrides = @(Get-OptionalArray $Task 'protectedOverrides')
  if ($protectedOverrides.Count -gt 0) {
    throw 'protected-overrides-forbidden: protectedOverrides cannot unlock permanently read-only template targets.'
  }
  $imageTransfers = @(Get-OptionalArray $Task 'imageTransfers')
  $sceneCards = @(Get-OptionalArray $Task 'sceneCards')
  foreach ($card in $sceneCards) {
    if ((Test-ObjectProperty $card 'text') -and $card.text) {
      $textSelector = if (Test-ObjectProperty $card 'textTarget') { $card.textTarget } else { $null }
      if (-not $textSelector) { throw 'sceneCards[].text requires textTarget.' }
      $textReplacements += [pscustomobject]@{
        id = if (Test-ObjectProperty $textSelector 'id') { $textSelector.id } else { $null }
        path = if (Test-ObjectProperty $textSelector 'path') { $textSelector.path } else { $null }
        name = if (Test-ObjectProperty $textSelector 'name') { $textSelector.name } else { $null }
        oldText = if (Test-ObjectProperty $textSelector 'oldText') { $textSelector.oldText } else { $null }
        text = [string]$card.text
        mode = if (Test-ObjectProperty $card 'mode') { [string]$card.mode } else { 'style-adapted' }
      }
    }
    if ((Test-ObjectProperty $card 'imagePath') -and -not [string]::IsNullOrWhiteSpace([string]$card.imagePath)) {
      if (-not (Test-ObjectProperty $card 'baseTarget') -or -not $card.baseTarget) { throw 'sceneCards[].imagePath requires baseTarget.' }
      $imageTransfers += [pscustomobject]@{
        imagePath = [string]$card.imagePath
        target = $card.baseTarget
        remove = if (Test-ObjectProperty $card 'oldImageTarget') { $card.oldImageTarget } else { $null }
        name = if (Test-ObjectProperty $card 'name') { [string]$card.name } else { '场景图' }
        fit = if (Test-ObjectProperty $card 'fit') { [string]$card.fit } else { 'cover' }
        clip = $true
      }
    }
  }

  $indexLayers = @()
  if ($null -ne $templateIndex) {
    if (Test-ObjectProperty $templateIndex 'documents') {
      foreach ($document in @($templateIndex.documents)) { $indexLayers += @($document.layers) }
    } elseif (Test-ObjectProperty $templateIndex 'document') {
      $indexLayers += @($templateIndex.document.layers)
    }
  }
  $indexLayerById = @{}
  $indexLayerByPath = @{}
  foreach ($layer in $indexLayers) {
    if ((Test-ObjectProperty $layer 'id') -and $null -ne $layer.id) {
      $indexLayerById[[string]$layer.id] = $layer
    }
    if ((Test-ObjectProperty $layer 'path') -and
        -not [string]::IsNullOrWhiteSpace([string]$layer.path)) {
      $indexLayerByPath[[string]$layer.path] = $layer
    }
  }

  $authorizedStepCountSyncIds = @{}
  if ($null -ne $templateDefinition -and (Test-ObjectProperty $templateDefinition 'unchangedTextTargets')) {
    foreach ($protectedTarget in @($templateDefinition.unchangedTextTargets | Where-Object {
        (Test-ObjectProperty $_ 'allowStepCountSync') -and [bool]$_.allowStepCountSync
      })) {
      $targetId = [string]$protectedTarget.targetId
      $replacementMatches = @($textReplacements | Where-Object {
          (Test-ObjectProperty $_ 'id') -and [string]$_.id -ceq $targetId
        })
      if ($replacementMatches.Count -eq 0) { continue }
      if ($replacementMatches.Count -ne 1 -or -not $indexLayerById.ContainsKey($targetId) -or
          -not (Test-ObjectProperty $indexLayerById[$targetId] 'text')) {
        throw "invalid-step-count-sync: protected step-count target $targetId must resolve uniquely to indexed baseline text."
      }
      Assert-DingdongStepCountSyncReplacement `
        -Replacement $replacementMatches[0] `
        -BaselineText ([string]$indexLayerById[$targetId].text) `
        -BaselineStepCount ([int]$protectedTarget.baselineStepCount) `
        -AllowedStepCounts @($protectedTarget.allowedStepCounts | ForEach-Object { [int]$_ }) | Out-Null
      $authorizedStepCountSyncIds[$targetId] = $true
    }
  }

  $structureAdaptedTargetIds = @{}
  $requiredPrefixByTargetId = @{}
  $requiredTextByTargetId = @{}
  if ($null -ne $templateDefinition) {
    if (Test-ObjectProperty $templateDefinition 'styleAdaptedTextTargets') {
      foreach ($target in @($templateDefinition.styleAdaptedTextTargets)) {
        if ((Test-ObjectProperty $target 'id') -and $null -ne $target.id) {
          $structureAdaptedTargetIds[[string]$target.id] = $true
          if ((Test-ObjectProperty $target 'requiredPrefix') -and
              -not [string]::IsNullOrWhiteSpace([string]$target.requiredPrefix)) {
            $requiredPrefixByTargetId[[string]$target.id] = [string]$target.requiredPrefix
          }
          if (Test-ObjectProperty $target 'requiredText') {
            $requiredTextByTargetId[[string]$target.id] = [string]$target.requiredText
          }
        }
      }
    }
    if (Test-ObjectProperty $templateDefinition 'textTargets') {
      foreach ($target in @($templateDefinition.textTargets | Where-Object {
          [string]$_.mode -in @('sync-detail-approved', 'compose-detail-approved')
        })) {
        if ((Test-ObjectProperty $target 'targetId') -and $null -ne $target.targetId) {
          $structureAdaptedTargetIds[[string]$target.targetId] = $true
        }
      }
    }
  }
  foreach ($replacement in $textReplacements) {
    $replacementId = if ((Test-ObjectProperty $replacement 'id') -and $null -ne $replacement.id) { [string]$replacement.id } else { '' }
    $replacementPath = if ((Test-ObjectProperty $replacement 'path') -and -not [string]::IsNullOrWhiteSpace([string]$replacement.path)) {
      [string]$replacement.path
    } elseif ($indexLayerById.ContainsKey($replacementId)) {
      [string]$indexLayerById[$replacementId].path
    } else {
      ''
    }
    $replacementMode = if (Test-ObjectProperty $replacement 'mode') { [string]$replacement.mode } else { '' }
    $generatedFrom = if (Test-ObjectProperty $replacement 'generatedFrom') { [string]$replacement.generatedFrom } else { '' }
    if ($requiredPrefixByTargetId.ContainsKey($replacementId)) {
      $requiredPrefix = [string]$requiredPrefixByTargetId[$replacementId]
      $replacementText = if (Test-ObjectProperty $replacement 'text') { [string]$replacement.text } else { '' }
      if (-not $replacementText.StartsWith($requiredPrefix, [StringComparison]::Ordinal)) {
        throw ('required-copy-prefix: id {0} 的版6标题必须以“{1}”开头。' -f $replacementId, $requiredPrefix)
      }
    }
    if ($requiredTextByTargetId.ContainsKey($replacementId)) {
      $requiredText = [string]$requiredTextByTargetId[$replacementId]
      $replacementText = if (Test-ObjectProperty $replacement 'text') { [string]$replacement.text } else { '' }
      if ($replacementText -cne $requiredText) {
        throw ('required-exact-copy: id {0} 的版8场景文案必须逐字符固定为“下班回家轻松煮”换行“煮好后热乎上桌”。' -f $replacementId)
      }
    }
    $mustRejectRuNoun = $replacementMode -ceq 'structure-adapted' -or
      $structureAdaptedTargetIds.ContainsKey($replacementId) -or
      $generatedFrom -in @('sync-detail-approved', 'compose-detail-approved')
    if ($mustRejectRuNoun -and (Test-ObjectProperty $replacement 'lines')) {
      foreach ($line in @($replacement.lines)) {
        foreach ($proposedSegment in @($line.proposedSegments)) {
          if ([string]$proposedSegment.text -match '^入\p{IsCJKUnifiedIdeographs}$') {
            $targetLabel = if ([string]::IsNullOrWhiteSpace($replacementId)) { 'unknown target' } else { "id $replacementId" }
            throw ('forbidden-ru-noun-pattern: {0} 使用了禁止的二字“入+名词”词组 {1}；请先改写文案，工作副本不会创建。' -f $targetLabel, [string]$proposedSegment.text)
          }
        }
      }
    }
    if ($mustRejectRuNoun -and (Test-DingdongBlock4Path $replacementPath)) {
      $forbiddenBlock4Term = Get-DingdongBlock4ForbiddenPrepPackagingTerm ([string]$replacement.text)
      if ($null -ne $forbiddenBlock4Term) {
        $targetLabel = if ([string]::IsNullOrWhiteSpace($replacementId)) { $replacementPath } else { "id $replacementId" }
        throw ('forbidden-block4-prep-packaging-copy: {0} 的版4文案使用了禁止的预制或包装描述“{1}”；请改写为食材、口感、风味或成品表现，工作副本不会创建。' -f $targetLabel, $forbiddenBlock4Term)
      }
    }
  }

  $protectedPathPrefixes = @(Get-OptionalArray $Task 'protectedPathPrefixes' | ForEach-Object { [string]$_ })
  $declaredProtectedTargets = [Collections.Generic.List[object]]::new()
  foreach ($target in $protectedTextTargets) { [void]$declaredProtectedTargets.Add($target) }
  if ($null -ne $templateDefinition) {
    if (Test-ObjectProperty $templateDefinition 'protectedTextTargets') {
      foreach ($target in @($templateDefinition.protectedTextTargets)) { [void]$declaredProtectedTargets.Add($target) }
    }
    if (Test-ObjectProperty $templateDefinition 'protectedPathPrefixes') {
      $protectedPathPrefixes += @($templateDefinition.protectedPathPrefixes | ForEach-Object { [string]$_ })
    }
    if (Test-ObjectProperty $templateDefinition 'unchangedTextTargets') {
      foreach ($target in @($templateDefinition.unchangedTextTargets)) {
        if ($authorizedStepCountSyncIds.ContainsKey([string]$target.targetId)) { continue }
        [void]$declaredProtectedTargets.Add([pscustomobject][ordered]@{
          id = $target.targetId
          label = if (Test-ObjectProperty $target 'label') { [string]$target.label } else { 'unchangedTextTarget' }
          artboard = if (Test-ObjectProperty $target 'artboard') { [string]$target.artboard } else { $null }
        })
      }
    }
    if (Test-ObjectProperty $templateDefinition 'textTargets') {
      foreach ($target in @($templateDefinition.textTargets | Where-Object { [string]$_.mode -ceq 'sync-detail-current' })) {
        [void]$declaredProtectedTargets.Add([pscustomobject][ordered]@{
          id = $target.targetId
          label = if (Test-ObjectProperty $target 'label') { [string]$target.label } else { 'sync-detail-current' }
          artboard = if (Test-ObjectProperty $target 'artboard') { [string]$target.artboard } else { $null }
        })
      }
    }
  }
  $protectedPathPrefixes = @($protectedPathPrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  foreach ($prefix in $protectedPathPrefixes) {
    foreach ($layer in $indexLayers) {
      if (-not (Test-ObjectProperty $layer 'path') -or -not (Test-ObjectProperty $layer 'text')) { continue }
      if (-not (Test-ObjectProperty $layer 'kind') -or [string]$layer.kind -cne 'LayerKind.TEXT') { continue }
      $layerPath = [string]$layer.path
      if ($layerPath -ceq $prefix -or $layerPath.StartsWith($prefix + '/', [StringComparison]::Ordinal)) {
        [void]$declaredProtectedTargets.Add([pscustomobject][ordered]@{
          id = $layer.id
          path = $layerPath
          label = "protectedPathPrefix:$prefix"
        })
      }
    }
  }

  $protectedTargetById = @{}
  $protectedTargetByPath = @{}
  $normalizedProtectedTargets = [Collections.Generic.List[object]]::new()
  $protectedTargetKeys = @{}
  foreach ($target in $declaredProtectedTargets) {
    $targetId = if ((Test-ObjectProperty $target 'id') -and $null -ne $target.id) {
      [string]$target.id
    } elseif ((Test-ObjectProperty $target 'targetId') -and $null -ne $target.targetId) {
      [string]$target.targetId
    } else { '' }
    $targetPath = if ((Test-ObjectProperty $target 'path') -and
        -not [string]::IsNullOrWhiteSpace([string]$target.path)) { [string]$target.path } else { '' }
    $indexedLayer = $null
    if (-not [string]::IsNullOrWhiteSpace($targetId) -and $indexLayerById.ContainsKey($targetId)) {
      $indexedLayer = $indexLayerById[$targetId]
    } elseif (-not [string]::IsNullOrWhiteSpace($targetPath) -and $indexLayerByPath.ContainsKey($targetPath)) {
      $indexedLayer = $indexLayerByPath[$targetPath]
    }
    if ($null -ne $indexedLayer) {
      if ([string]::IsNullOrWhiteSpace($targetId)) { $targetId = [string]$indexedLayer.id }
      if ([string]::IsNullOrWhiteSpace($targetPath)) { $targetPath = [string]$indexedLayer.path }
    }
    if ([string]::IsNullOrWhiteSpace($targetId) -and [string]::IsNullOrWhiteSpace($targetPath)) {
      throw 'Every protected text declaration requires an exact id or full path.'
    }
    $normalized = [pscustomobject][ordered]@{
      id = if ([string]::IsNullOrWhiteSpace($targetId)) { $null } else { $targetId }
      path = if ([string]::IsNullOrWhiteSpace($targetPath)) { $null } else { $targetPath }
      label = if (Test-ObjectProperty $target 'label') { [string]$target.label } else { 'protected-text-target' }
      artboard = if (Test-ObjectProperty $target 'artboard') { [string]$target.artboard } else { $null }
    }
    $key = if (-not [string]::IsNullOrWhiteSpace($targetId)) { "id:$targetId" } else { "path:$targetPath" }
    if (-not $protectedTargetKeys.ContainsKey($key)) {
      [void]$normalizedProtectedTargets.Add($normalized)
      $protectedTargetKeys[$key] = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($targetId)) { $protectedTargetById[$targetId] = $target }
    if (-not [string]::IsNullOrWhiteSpace($targetPath)) { $protectedTargetByPath[$targetPath] = $target }
  }

  foreach ($replacement in $textReplacements) {
    $replacementId = if ((Test-ObjectProperty $replacement 'id') -and $null -ne $replacement.id) { [string]$replacement.id } else { '' }
    $replacementPath = if ((Test-ObjectProperty $replacement 'path') -and
        -not [string]::IsNullOrWhiteSpace([string]$replacement.path)) { [string]$replacement.path } else { '' }
    $indexedLayer = $null
    if (-not [string]::IsNullOrWhiteSpace($replacementId) -and $indexLayerById.ContainsKey($replacementId)) {
      $indexedLayer = $indexLayerById[$replacementId]
    } elseif (-not [string]::IsNullOrWhiteSpace($replacementPath) -and $indexLayerByPath.ContainsKey($replacementPath)) {
      $indexedLayer = $indexLayerByPath[$replacementPath]
    }
    if ($null -ne $indexedLayer -and [string]::IsNullOrWhiteSpace($replacementPath)) {
      $replacementPath = [string]$indexedLayer.path
    }
    $isProtected = (-not [string]::IsNullOrWhiteSpace($replacementId) -and $protectedTargetById.ContainsKey($replacementId)) -or
      (-not [string]::IsNullOrWhiteSpace($replacementPath) -and $protectedTargetByPath.ContainsKey($replacementPath))
    foreach ($prefix in $protectedPathPrefixes) {
      if ($replacementPath -ceq $prefix -or $replacementPath.StartsWith($prefix + '/', [StringComparison]::Ordinal)) {
        $isProtected = $true
        break
      }
    }
    if (-not $isProtected) { continue }

    $baselineText = $null
    if ($null -ne $indexedLayer -and (Test-ObjectProperty $indexedLayer 'text')) {
      $baselineText = [string]$indexedLayer.text
    } else {
      $protectedTarget = if (-not [string]::IsNullOrWhiteSpace($replacementId) -and $protectedTargetById.ContainsKey($replacementId)) {
        $protectedTargetById[$replacementId]
      } elseif (-not [string]::IsNullOrWhiteSpace($replacementPath) -and $protectedTargetByPath.ContainsKey($replacementPath)) {
        $protectedTargetByPath[$replacementPath]
      } else { $null }
      if ($null -ne $protectedTarget -and (Test-ObjectProperty $protectedTarget 'text')) {
        $baselineText = [string]$protectedTarget.text
      } elseif ($null -ne $protectedTarget -and (Test-ObjectProperty $protectedTarget 'oldText')) {
        $baselineText = [string]$protectedTarget.oldText
      }
    }
    $replacementText = if (Test-ObjectProperty $replacement 'text') { [string]$replacement.text } else { $null }
    $targetLabel = if (-not [string]::IsNullOrWhiteSpace($replacementId)) { "id $replacementId" } else { "path $replacementPath" }
    if ($null -eq $baselineText -or $null -eq $replacementText -or $replacementText -cne $baselineText) {
      throw "immutable-protected-target: $targetLabel is permanently read-only. Remove the change; the user will edit this location in Photoshop."
    }
  }
  $protectedTextTargets = @($normalizedProtectedTargets)

  $normalizedImages = @()
  foreach ($item in $imageTransfers) {
    $copy = [ordered]@{}
    foreach ($property in $item.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    if ($copy.Contains('imagePath') -and -not [string]::IsNullOrWhiteSpace([string]$copy.imagePath)) {
      $copy.imagePath = Resolve-JobPath -Path ([string]$copy.imagePath) -BaseDirectory $taskDirectory
      if (-not (Test-Path -LiteralPath $copy.imagePath -PathType Leaf)) { throw "Image file does not exist: $($copy.imagePath)" }
      $copy.imageSha256 = Get-Sha256 $copy.imagePath
    }
    if ($copy.Contains('sourcePsdPath') -and -not [string]::IsNullOrWhiteSpace([string]$copy.sourcePsdPath)) {
      $copy.sourcePsdPath = Resolve-JobPath -Path ([string]$copy.sourcePsdPath) -BaseDirectory $taskDirectory
      if (-not (Test-Path -LiteralPath $copy.sourcePsdPath -PathType Leaf)) { throw "Image source PSD does not exist: $($copy.sourcePsdPath)" }
    }
    $normalizedImages += [pscustomobject]$copy
  }

  $finalOutput = $null
  if ((Test-ObjectProperty $Task 'outputs') -and $Task.outputs -and (Test-ObjectProperty $Task.outputs 'final')) {
    $finalOutput = $Task.outputs.final
    if ($finalOutput) {
      $finalType = if (Test-ObjectProperty $finalOutput 'type') { [string]$finalOutput.type } else { 'document-jpg' }
      if ($finalType -eq 'document-jpg' -and (Test-ObjectProperty $finalOutput 'path') -and -not [string]::IsNullOrWhiteSpace([string]$finalOutput.path)) {
        $finalOutput.path = Resolve-JobPath -Path ([string]$finalOutput.path) -BaseDirectory $taskDirectory
      }
      if ($finalType -eq 'artboards' -and (Test-ObjectProperty $finalOutput 'outputDirectory') -and -not [string]::IsNullOrWhiteSpace([string]$finalOutput.outputDirectory)) {
        $finalOutput.outputDirectory = Resolve-JobPath -Path ([string]$finalOutput.outputDirectory) -BaseDirectory $taskDirectory
      }
    }
  }
  $organize = if (Test-ObjectProperty $Task 'organizeUsedAssets') { $Task.organizeUsedAssets } else { $false }
  if ($organize -and $organize -isnot [bool]) {
    foreach ($pathField in @('psdPath', 'workDir', 'journalPath')) {
      if ((Test-ObjectProperty $organize $pathField) -and -not [string]::IsNullOrWhiteSpace([string]$organize.$pathField)) {
        $organize.$pathField = Resolve-JobPath -Path ([string]$organize.$pathField) -BaseDirectory $taskDirectory
      }
    }
  }
  $catalog = $null
  if ((Test-ObjectProperty $Task 'catalog') -and $Task.catalog) {
    $catalog = $Task.catalog
    if (-not (Test-ObjectProperty $catalog 'imageDirectory') -or [string]::IsNullOrWhiteSpace([string]$catalog.imageDirectory)) {
      throw 'catalog.imageDirectory is required.'
    }
    $catalog.imageDirectory = Resolve-JobPath -Path ([string]$catalog.imageDirectory) -BaseDirectory $taskDirectory
    foreach ($item in @($catalog.items)) {
      $imagePath = Join-Path ([string]$catalog.imageDirectory) ([string]$item.image)
      if (Test-Path -LiteralPath $imagePath -PathType Leaf) {
        $item | Add-Member -NotePropertyName imageSha256 -NotePropertyValue (Get-Sha256 $imagePath) -Force
      }
    }
  }

  return [pscustomobject]@{
    jobVersion = 1
    workflow = if ((Test-ObjectProperty $Task 'workflow') -and -not [string]::IsNullOrWhiteSpace([string]$Task.workflow)) { [string]$Task.workflow } else { 'generic' }
    taskPath = $taskFullPath
    sourceTemplateId = $sourceTemplateId
    sourcePsdPath = $sourceFullPath
    targetPsdPath = $targetFullPath
    workingPsdPath = [IO.Path]::GetFullPath($workingPath)
    preview = [pscustomobject]@{
      enabled = $previewEnabled
      path = [IO.Path]::GetFullPath($previewPath)
      maxWidth = $previewMaxWidth
      quality = $previewQuality
    }
    textReplacements = @($textReplacements)
    protectedTextTargets = @($protectedTextTargets)
    imageTransfers = @($normalizedImages)
    catalog = $catalog
    finalOutput = $finalOutput
    organizeUsedAssets = $organize
    overwriteExistingOutputs = ((Test-ObjectProperty $Task 'overwriteExistingOutputs') -and [bool]$Task.overwriteExistingOutputs)
    warnings = @($templateWarning | Where-Object { $_ })
  }
}
