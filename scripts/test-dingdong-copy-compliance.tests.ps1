$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$context = Get-DingdongTemplateContext -TemplateId 'dingdong-haoshiguang-detail-2step' -SkillRoot $skillRoot
$index = Read-Utf8Json $context.indexPath
$layers = Get-DingdongLayerLookup $index
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-dingdong-copy-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Copy-TestObject {
  param([Parameter(Mandatory = $true)]$Value)
  return ($Value | ConvertTo-Json -Depth 60 | ConvertFrom-Json)
}

function Write-TestCopy {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $path = Join-Path $tempRoot "$Name.json"
  Write-Utf8Json -Path $path -Value $Value | Out-Null
  return $path
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if (-not $Condition) { throw "ASSERT FAILED: $Name" }
  "PASS: $Name"
}

function Assert-ErrorCode {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Name
  )
  Assert-True (@($Result.errors | Where-Object { [string]$_.code -ceq $Code }).Count -gt 0) $Name
}

$headline = $layers['1853']
$valid = [ordered]@{
  copyVersion = 2
  templateId = 'dingdong-haoshiguang-detail-2step'
  facts = @(
    [ordered]@{
      id = 'fact-product'
      kind = 'document'
      statement = '当前产品为酸菜肉末米粉，酸菜和肉末为产品事实。'
      source = '测试产品资料'
    }
  )
  terminologyDecisions = @()
  protectedOverrides = @()
  textReplacements = @(
    [ordered]@{
      label = '头版主卖点'
      id = 1853
      path = [string]$headline.path
      oldText = [string]$headline.text
      text = "酸香浓郁 肉香醇厚`r宅家轻松解锁酸菜米粉"
      mode = 'structure-adapted'
      lines = @(
        [ordered]@{
          sourceSegments = @(
            [ordered]@{ text = '蒜香'; pos = 'noun'; role = 'aroma'; separatorAfter = '' }
            [ordered]@{ text = '浓厚'; pos = 'adjective'; role = 'degree'; separatorAfter = ' ' }
            [ordered]@{ text = '虾鲜'; pos = 'noun'; role = 'ingredient-flavour'; separatorAfter = '' }
            [ordered]@{ text = '爽弹'; pos = 'adjective'; role = 'texture'; separatorAfter = '' }
          )
          proposedSegments = @(
            [ordered]@{ text = '酸香'; pos = 'noun'; role = 'aroma'; separatorAfter = '' }
            [ordered]@{ text = '浓郁'; pos = 'adjective'; role = 'degree'; separatorAfter = ' ' }
            [ordered]@{ text = '肉香'; pos = 'noun'; role = 'ingredient-flavour'; separatorAfter = '' }
            [ordered]@{ text = '醇厚'; pos = 'adjective'; role = 'texture'; separatorAfter = '' }
          )
        }
        [ordered]@{
          sourceSegments = @(
            [ordered]@{ text = '宅家'; pos = 'noun'; role = 'scene'; separatorAfter = '' }
            [ordered]@{ text = '轻松'; pos = 'adverb'; role = 'state'; separatorAfter = '' }
            [ordered]@{ text = '解锁'; pos = 'verb'; role = 'action'; separatorAfter = '' }
            [ordered]@{ text = '海鲜'; pos = 'noun'; role = 'product-qualifier'; separatorAfter = '' }
            [ordered]@{ text = '硬菜'; pos = 'noun'; role = 'product'; separatorAfter = '' }
          )
          proposedSegments = @(
            [ordered]@{ text = '宅家'; pos = 'noun'; role = 'scene'; separatorAfter = '' }
            [ordered]@{ text = '轻松'; pos = 'adverb'; role = 'state'; separatorAfter = '' }
            [ordered]@{ text = '解锁'; pos = 'verb'; role = 'action'; separatorAfter = '' }
            [ordered]@{ text = '酸菜'; pos = 'noun'; role = 'product-qualifier'; separatorAfter = '' }
            [ordered]@{ text = '米粉'; pos = 'noun'; role = 'product'; separatorAfter = '' }
          )
        }
      )
      evidenceIds = @('fact-product')
    }
  )
}

try {
  $validPath = Write-TestCopy $valid 'valid'
  $validResult = Test-DingdongCopyCompliance -CopyPath $validPath -SkillRoot $skillRoot
  Assert-True $validResult.ok 'matching grammar and exact segment lengths pass'
  $cliResult = & (Join-Path $PSScriptRoot 'test-dingdong-copy-compliance.ps1') -CopyPath $validPath | ConvertFrom-Json
  Assert-True $cliResult.ok 'copy compliance CLI accepts valid copyVersion 2 input'

  $board6 = $layers['3899']
  $prefixAccepted = Copy-TestObject $valid
  $prefixAcceptedText = "特调酱香拌面调味酱`r酱香浓郁均匀挂汁 浓而油亮`r"
  $prefixAccepted.textReplacements = @($prefixAccepted.textReplacements) + @(
    [pscustomobject][ordered]@{
      label = '版6酱料卖点'
      id = 3899
      path = [string]$board6.path
      oldText = [string]$board6.text
      text = $prefixAcceptedText
      sourceText = $prefixAcceptedText
      mode = 'verbatim'
      evidenceIds = @('fact-product')
    }
  )
  $prefixAcceptedResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $prefixAccepted 'board6-prefix-accepted') -SkillRoot $skillRoot
  Assert-True $prefixAcceptedResult.ok 'board 6 title accepts the required TeDiao prefix'

  $prefixRejected = Copy-TestObject $prefixAccepted
  $prefixRejectedText = "秘制酱香拌面调味酱`r酱香浓郁均匀挂汁 浓而油亮`r"
  $prefixRejected.textReplacements[1].text = $prefixRejectedText
  $prefixRejected.textReplacements[1].sourceText = $prefixRejectedText
  $prefixRejectedResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $prefixRejected 'board6-prefix-rejected') -SkillRoot $skillRoot
  Assert-ErrorCode $prefixRejectedResult 'required-copy-prefix' 'board 6 title rejects any opening other than TeDiao'

  $board8 = $layers['4076']
  $board8Accepted = Copy-TestObject $valid
  $board8AcceptedText = "下班回家轻松煮`r煮好后热乎上桌`r"
  $board8Accepted.textReplacements = @($board8Accepted.textReplacements) + @(
    [pscustomobject][ordered]@{
      label = '版8场景'
      id = 4076
      path = [string]$board8.path
      oldText = [string]$board8.text
      text = $board8AcceptedText
      sourceText = $board8AcceptedText
      mode = 'verbatim'
      evidenceIds = @('fact-product')
    }
  )
  $board8AcceptedResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $board8Accepted 'board8-exact-copy-accepted') -SkillRoot $skillRoot
  Assert-True $board8AcceptedResult.ok 'board 8 accepts the locked two-line copy'

  $board8Rejected = Copy-TestObject $board8Accepted
  $board8RejectedText = "下班回家轻松煮`r5分钟热乎上桌`r"
  $board8Rejected.textReplacements[1].text = $board8RejectedText
  $board8Rejected.textReplacements[1].sourceText = $board8RejectedText
  $board8RejectedResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $board8Rejected 'board8-exact-copy-rejected') -SkillRoot $skillRoot
  Assert-ErrorCode $board8RejectedResult 'required-exact-copy' 'board 8 rejects any copy other than the locked two-line text'

  foreach ($templateId in @('dingdong-haoshiguang-detail-1step', 'dingdong-haoshiguang-detail-2step', 'dingdong-haoshiguang-detail-3step', 'dingdong-haoshiguang-detail-4step')) {
    $templateContext = Get-DingdongTemplateContext -TemplateId $templateId -SkillRoot $skillRoot
    $templateDefinition = Read-Utf8Json $templateContext.definitionPath
    $board8Target = @($templateDefinition.styleAdaptedTextTargets | Where-Object { [string]$_.id -ceq '4076' })
    Assert-True ($board8Target.Count -eq 1 -and [string]$board8Target[0].requiredText -ceq $board8AcceptedText) "$templateId registers the locked board 8 text"
    Assert-True ((@($templateDefinition.copyValidation.board6SideDishTargetIds | ForEach-Object { [string]$_ }) -join ',') -ceq '4811,4819') "$templateId registers both board 6 side-dish description targets"
  }

  $grammarReference = [IO.File]::ReadAllText(
    (Join-Path $skillRoot 'references\dingdong-copy-grammar.md'),
    (New-Object Text.UTF8Encoding($false))
  )
  $exampleMatch = [regex]::Match($grammarReference, '(?s)```json\s*(\{.*?\})\s*```')
  Assert-True $exampleMatch.Success 'grammar reference contains a JSON example'
  $examplePath = Join-Path $tempRoot 'reference-example.json'
  [IO.File]::WriteAllText($examplePath, $exampleMatch.Groups[1].Value, (New-Object Text.UTF8Encoding($false)))
  $exampleResult = Test-DingdongCopyCompliance -CopyPath $examplePath -SkillRoot $skillRoot
  Assert-True $exampleResult.ok 'grammar reference JSON example passes its validator'
  $dingdongReference = [IO.File]::ReadAllText(
    (Join-Path $skillRoot 'references\dingdong.md'),
    (New-Object Text.UTF8Encoding($false))
  )
  $skillReference = [IO.File]::ReadAllText(
    (Join-Path $skillRoot 'SKILL.md'),
    (New-Object Text.UTF8Encoding($false))
  )
  Assert-True ($dingdongReference.Contains('30 分钟') -and
    $dingdongReference.Contains('不得重新读取 Word') -and
    $dingdongReference.Contains('初稿阶段不要创建 `copy.json`')) 'workflow enforces the 30-minute budget and avoids repeated source analysis'
  Assert-True ($dingdongReference.Contains('禁止因为主图生成器需要图片来源而先创建临时详情页') -and
    $dingdongReference.Contains('直接图片模式必须先展示七行')) 'main-image workflow forbids temporary detail PSD staging'
  Assert-True ($dingdongReference.Contains('画板2全部文字') -and
    $dingdongReference.Contains('其余主图文案不得重新创作') -and
    $dingdongReference.Contains('不等于批准之前或当前由代理自行挑选的七张图片')) 'main-image workflow locks board 2 and requires approved copy and image mapping'
  Assert-True ($dingdongReference.Contains('正式详情页是七图主图的默认图片来源') -and
    $dingdongReference.Contains('按详情页模板定义中的 `mainImageSourceSlots` 自动建立七项 `source` 映射') -and
    $dingdongReference.Contains('不得自动回退到相似原图、旧映射或临时详情页')) 'main-image workflow defaults to authoritative formal detail images'
  Assert-True ($skillReference.Contains('第一项生产动作必须运行 `invoke-dingdong-product.ps1 -PrepareMain:$false`') -and
    $skillReference.Contains('永久禁止据此判断正式详情 PSD 当前是否含图') -and
    $dingdongReference.Contains('返回前禁止扫描产品原图、制作选图总览') -and
    $dingdongReference.Contains('不是 PSD 图片清单')) 'main-image workflow must inspect the current formal detail PSD before any direct-image selection'
  Assert-True ($dingdongReference.Contains('不再向用户索要第二次确认') -and
    $dingdongReference.Contains('SHA-256 是内部防篡改绑定') -and
    $grammarReference.Contains('不再请求用户确认哈希、任务或 PSD 写入')) 'copy confirmation directly authorizes detail-page templating'
  Assert-True ($skillReference.Contains('不得基于旧候选自由润色、降低标准或事后补标签') -and
    $dingdongReference.Contains('确认阶段的重新生成不是自由润色') -and
    $dingdongReference.Contains('未点名行逐字符不变') -and
    $grammarReference.Contains('完整执行初稿的资料门槛、审核顺序、语法、分句、字数') -and
    $grammarReference.Contains('任何后续修改都使上一版九列表、正式审核稿、`copy.json`、SHA-256、任务及套版授权失效')) 'confirmation-stage rewrites inherit every initial copy rule and invalidate stale approvals'
  Assert-True ($skillReference.Contains('每个板块只显示一行') -and
    $dingdongReference.Contains('禁止把版4主料标题与口感说明、版6标题与两条说明等拆成独立审核行') -and
    $grammarReference.Contains('duplicate-board-copy-focus') -and
    $grammarReference.Contains('标题与下方说明不得使用同词或近义词重复描述同一外观、口感、风味或卖点')) 'copy review groups each board and rejects repeated title-description focus'
  Assert-True ($dingdongReference.Contains('永久只读') -and
    $dingdongReference.Contains('不得询问是否解锁') -and
    $grammarReference.Contains('禁止填写非空 `protectedOverrides`') -and
    $grammarReference.Contains('由用户自行在 Photoshop 中修改')) 'all template-protected text is permanently read-only without authorization overrides'
  Assert-True ($grammarReference.Contains('forbidden-ru-noun-pattern') -and
    $grammarReference.Contains('完整二字“入+名词”词组') -and
    $grammarReference.Contains('`入 味` 不命中') -and
    $grammarReference.Contains('“A 改为 B”也属于逐字来源') -and
    $dingdongReference.Contains('普通适配文案不得出现完整二字“入+名词”词组') -and
    $dingdongReference.Contains('按合并后的目标全文登记为 `verbatim`')) 'workflow distinguishes generated ru-plus-noun copy from user-directed verbatim copy'
  Assert-True ($grammarReference.Contains('forbidden-block4-prep-packaging-copy') -and
    $grammarReference.Contains('版4的 `structure-adapted` 文案永久禁止') -and
    $grammarReference.Contains('`分装`、`装好`、`切好`、`整包`') -and
    $dingdongReference.Contains('版4普通适配文案不得描述预制或包装状态')) 'workflow documents the script-enforced block-4 prep and packaging rejection'
  Assert-True ($grammarReference.Contains('forbidden-block4-instruction-copy') -and
    $grammarReference.Contains('版4也永久禁止复述使用步骤') -and
    $dingdongReference.Contains('不得复述食用步骤、火候、时长或烹饪操作')) 'workflow documents the script-enforced block-4 instruction rejection'
  Assert-True ($grammarReference.Contains('missing-board6-side-dish-evidence') -and
    $grammarReference.Contains('duplicate-board6-side-dish-copy') -and
    $dingdongReference.Contains('版6两个说明必须各写一种不同配菜')) 'workflow documents the two distinct board-6 side-dish descriptions'
  Assert-True ($grammarReference.Contains('下班回家轻松煮') -and
    $grammarReference.Contains('煮好后热乎上桌') -and
    $grammarReference.Contains('required-exact-copy') -and
    $dingdongReference.Contains('required-exact-copy')) 'workflow documents the locked board 8 exact copy'

  foreach ($ruNounWord in @('入味', '入锅', '入口')) {
    $ruNoun = Copy-TestObject $valid
    $ruNoun.textReplacements[0].text = "酸香浓郁 肉香醇厚`r宅家轻松解锁酸菜$ruNounWord"
    $ruNoun.textReplacements[0].lines[1].proposedSegments[4].text = $ruNounWord
    $ruNounPath = Write-TestCopy $ruNoun "ru-noun-$ruNounWord"
    $ruNounResult = Test-DingdongCopyCompliance -CopyPath $ruNounPath -SkillRoot $skillRoot
    Assert-ErrorCode $ruNounResult 'forbidden-ru-noun-pattern' "structure-adapted copy rejects exact two-character word $ruNounWord"
  }

  $userDirectedRuNoun = Copy-TestObject $valid
  $userDirectedText = "酸香浓郁 肉香醇厚`r宅家轻松解锁鱼头入味"
  $userDirectedRuNoun.textReplacements[0].text = $userDirectedText
  $userDirectedRuNoun.textReplacements[0].mode = 'verbatim'
  $userDirectedRuNoun.textReplacements[0] | Add-Member -NotePropertyName sourceText -NotePropertyValue $userDirectedText
  $userDirectedRuNoun.textReplacements[0] | Add-Member -NotePropertyName userInstruction -NotePropertyValue '把原短语改为鱼头入味，就按这个字样'
  $userDirectedRuNoun.textReplacements[0].PSObject.Properties.Remove('lines')
  $userDirectedRuNounResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $userDirectedRuNoun 'user-directed-ru-noun') -SkillRoot $skillRoot
  Assert-True $userDirectedRuNounResult.ok 'user-directed verbatim copy preserves exact ru-plus-noun wording'

  $ruNounWhitespace = Copy-TestObject $valid
  $ruNounWhitespace.textReplacements[0].text = "酸香浓郁 肉香醇厚`r宅家轻松解锁酸菜入 锅"
  $ruNounWhitespace.textReplacements[0].lines[1].proposedSegments[4].text = '入'
  $ruNounWhitespace.textReplacements[0].lines[1].proposedSegments[4].separatorAfter = ' '
  $ruNounWhitespace.textReplacements[0].lines[1].proposedSegments += [pscustomobject][ordered]@{
    text = '锅'; pos = 'noun'; role = 'product'; separatorAfter = ''
  }
  $ruNounWhitespacePath = Write-TestCopy $ruNounWhitespace 'ru-noun-whitespace'
  $ruNounWhitespaceResult = Test-DingdongCopyCompliance -CopyPath $ruNounWhitespacePath -SkillRoot $skillRoot
  Assert-True (@($ruNounWhitespaceResult.errors | Where-Object {
      [string]$_.code -ceq 'forbidden-ru-noun-pattern'
    }).Count -eq 0) 'whitespace-separated ru and noun do not match the exact two-character rule'

  $longRuPhrase = Copy-TestObject $valid
  $longRuPhrase.textReplacements[0].text = "酸香浓郁 肉香醇厚`r宅家轻松解锁加入香菜"
  $longRuPhrase.textReplacements[0].lines[1].proposedSegments[3].text = '加入'
  $longRuPhrase.textReplacements[0].lines[1].proposedSegments[4].text = '香菜'
  $longRuPhrasePath = Write-TestCopy $longRuPhrase 'long-ru-phrase'
  $longRuPhraseResult = Test-DingdongCopyCompliance -CopyPath $longRuPhrasePath -SkillRoot $skillRoot
  Assert-True (@($longRuPhraseResult.errors | Where-Object {
      [string]$_.code -ceq 'forbidden-ru-noun-pattern'
    }).Count -eq 0) 'longer phrase jiaru-xiangcai is not misclassified as an exact two-character ru-plus-noun word'

  $plusOne = Copy-TestObject $valid
  $plusOne.textReplacements[0].text = "酸香很浓郁 肉香醇厚`r宅家轻松解锁酸菜米粉"
  $plusOne.textReplacements[0].lines[0].proposedSegments[1].text = '很浓郁'
  $plusOnePath = Write-TestCopy $plusOne 'plus-one'
  $plusOneResult = Test-DingdongCopyCompliance -CopyPath $plusOnePath -SkillRoot $skillRoot
  Assert-True $plusOneResult.ok 'one-character segment difference passes'

  $clausePlusTwo = Copy-TestObject $valid
  $clausePlusTwo.textReplacements[0].text = "酸香甜很浓郁 肉香醇厚`r宅家轻松解锁酸菜米粉"
  $clausePlusTwo.textReplacements[0].lines[0].proposedSegments[0].text = '酸香甜'
  $clausePlusTwo.textReplacements[0].lines[0].proposedSegments[1].text = '很浓郁'
  $clausePlusTwoPath = Write-TestCopy $clausePlusTwo 'clause-plus-two'
  $clausePlusTwoResult = Test-DingdongCopyCompliance -CopyPath $clausePlusTwoPath -SkillRoot $skillRoot
  Assert-ErrorCode $clausePlusTwoResult 'clause-length-mismatch' 'a clause cannot grow by two characters through separate segments'

  $plusTwo = Copy-TestObject $valid
  $plusTwo.textReplacements[0].text = "酸香非常浓郁 肉香醇厚`r宅家轻松解锁酸菜米粉"
  $plusTwo.textReplacements[0].lines[0].proposedSegments[1].text = '非常浓郁'
  $plusTwoPath = Write-TestCopy $plusTwo 'plus-two'
  $plusTwoResult = Test-DingdongCopyCompliance -CopyPath $plusTwoPath -SkillRoot $skillRoot
  Assert-ErrorCode $plusTwoResult 'segment-length-mismatch' 'two-character segment difference fails'

  $badGrammar = Copy-TestObject $valid
  $badGrammar.textReplacements[0].text = "酸菜入汤 肉末铺面`r宅家轻松解锁酸菜米粉"
  $badGrammar.textReplacements[0].lines[0].proposedSegments[0].text = '酸菜'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[0].role = 'ingredient'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[1].text = '入汤'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[1].pos = 'verb'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[1].role = 'action'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[2].text = '肉末'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[2].role = 'ingredient'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[3].text = '铺面'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[3].pos = 'verb'
  $badGrammar.textReplacements[0].lines[0].proposedSegments[3].role = 'action'
  $badGrammar.terminologyDecisions = @(
    [ordered]@{
      terms = @('肉末', '肉沫')
      allowedByMode = [ordered]@{ 'structure-adapted' = '肉末'; verbatim = '肉沫' }
      evidenceIds = @('fact-product')
    }
  )
  $badGrammarPath = Write-TestCopy $badGrammar 'bad-grammar'
  $badGrammarResult = Test-DingdongCopyCompliance -CopyPath $badGrammarPath -SkillRoot $skillRoot
  Assert-ErrorCode $badGrammarResult 'pos-mismatch' 'noun-verb rewrite fails grammar'
  Assert-ErrorCode $badGrammarResult 'role-mismatch' 'semantic-role rewrite fails grammar'

  $forgedSourceGrammar = Copy-TestObject $valid
  $forgedSourceGrammar.textReplacements[0].lines[0].sourceSegments[0].pos = 'verb'
  $forgedSourceGrammar.textReplacements[0].lines[0].proposedSegments[0].pos = 'verb'
  $forgedSourceGrammarPath = Write-TestCopy $forgedSourceGrammar 'forged-source-grammar'
  $forgedSourceGrammarResult = Test-DingdongCopyCompliance -CopyPath $forgedSourceGrammarPath -SkillRoot $skillRoot
  Assert-ErrorCode $forgedSourceGrammarResult 'source-grammar-baseline-mismatch' 'task cannot redefine template-owned source grammar to make a rewrite pass'

  $block4Layer = $layers['2689']
  $badBlock4 = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @($valid.facts)
    terminologyDecisions = @()
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '版4主料'
        id = 2689
        path = [string]$block4Layer.path
        oldText = [string]$block4Layer.text
        text = '猪肉入料 细制肉末浇头'
        mode = 'structure-adapted'
        lines = @(
          [ordered]@{
            sourceSegments = @(
              [ordered]@{ text = '青虾'; pos = 'noun'; role = 'ingredient'; separatorAfter = '' }
              [ordered]@{ text = '手工'; pos = 'adverb'; role = 'method'; separatorAfter = '' }
              [ordered]@{ text = '去壳'; pos = 'verb'; role = 'action'; separatorAfter = '' }
              [ordered]@{ text = '挑线'; pos = 'verb'; role = 'action'; separatorAfter = '' }
            )
            proposedSegments = @(
              [ordered]@{ text = '猪肉入料'; pos = 'noun'; role = 'ingredient'; separatorAfter = ' ' }
              [ordered]@{ text = '细制肉末浇头'; pos = 'noun'; role = 'product'; separatorAfter = '' }
            )
          }
        )
        evidenceIds = @('fact-product')
      }
    )
  }
  $badBlock4Path = Write-TestCopy $badBlock4 'bad-block4'
  $badBlock4Result = Test-DingdongCopyCompliance -CopyPath $badBlock4Path -SkillRoot $skillRoot
  Assert-ErrorCode $badBlock4Result 'segment-count-mismatch' '版4 free rewrite fails original sentence structure'

  $validBlock4 = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @(
      [ordered]@{
        id = 'fact-block4'
        kind = 'document'
        statement = '当前产品含鱼丸；成品图可见鱼丸颗颗圆润饱满。'
        source = '测试产品资料'
      }
    )
    terminologyDecisions = @()
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '版4主料信息'
        id = 2689
        path = [string]$block4Layer.path
        oldText = [string]$block4Layer.text
        text = '鱼丸颗颗圆润饱满'
        mode = 'structure-adapted'
        lines = @(
          [ordered]@{
            sourceSegments = @(
              [ordered]@{ text = '青虾'; pos = 'noun'; role = 'ingredient'; separatorAfter = '' }
              [ordered]@{ text = '手工'; pos = 'adverb'; role = 'method'; separatorAfter = '' }
              [ordered]@{ text = '去壳'; pos = 'verb'; role = 'action'; separatorAfter = '' }
              [ordered]@{ text = '挑线'; pos = 'verb'; role = 'result'; separatorAfter = '' }
            )
            proposedSegments = @(
              [ordered]@{ text = '鱼丸'; pos = 'noun'; role = 'ingredient'; separatorAfter = '' }
              [ordered]@{ text = '颗颗'; pos = 'adverb'; role = 'method'; separatorAfter = '' }
              [ordered]@{ text = '圆润'; pos = 'verb'; role = 'action'; separatorAfter = '' }
              [ordered]@{ text = '饱满'; pos = 'verb'; role = 'result'; separatorAfter = '' }
            )
          }
        )
        evidenceIds = @('fact-block4')
      }
    )
  }
  $validBlock4Path = Write-TestCopy $validBlock4 'valid-block4'
  $validBlock4Result = Test-DingdongCopyCompliance -CopyPath $validBlock4Path -SkillRoot $skillRoot
  Assert-True $validBlock4Result.ok '版4 food appearance copy remains allowed'

  foreach ($forbiddenInstructionTerm in @('锅中', '大火', '中火', '下入', '加入', '倒出', '备用', '翻炒', '炒制', '断生', '变色', '分钟')) {
    $forbiddenInstruction = Copy-TestObject $validBlock4
    $forbiddenInstruction.textReplacements[0].text = "鱼丸$($forbiddenInstructionTerm)圆润饱满"
    $forbiddenInstruction.textReplacements[0].lines[0].proposedSegments[1].text = $forbiddenInstructionTerm
    $forbiddenInstructionPath = Write-TestCopy $forbiddenInstruction "forbidden-block4-instruction-$forbiddenInstructionTerm"
    $forbiddenInstructionResult = Test-DingdongCopyCompliance -CopyPath $forbiddenInstructionPath -SkillRoot $skillRoot
    Assert-ErrorCode $forbiddenInstructionResult 'forbidden-block4-instruction-copy' "版4 rejects instruction term $forbiddenInstructionTerm"
  }

  foreach ($forbiddenBlock4Term in @(
      '分装', '装好', '切好', '整包', '配好', '备好', '预切', '切配',
      '预处理', '预制', '预装', '按包', '单包', '包装', '袋装', '盒装'
    )) {
    $forbiddenBlock4 = Copy-TestObject $validBlock4
    $forbiddenBlock4.textReplacements[0].text = "鱼丸$($forbiddenBlock4Term)吸汤挂汁"
    $forbiddenBlock4.textReplacements[0].lines[0].proposedSegments[1].text = $forbiddenBlock4Term
    $forbiddenBlock4Path = Write-TestCopy $forbiddenBlock4 "forbidden-block4-$forbiddenBlock4Term"
    $forbiddenBlock4Result = Test-DingdongCopyCompliance -CopyPath $forbiddenBlock4Path -SkillRoot $skillRoot
    Assert-ErrorCode $forbiddenBlock4Result 'forbidden-block4-prep-packaging-copy' "版4 rejects prep or packaging term $forbiddenBlock4Term"
  }

  $splitForbiddenBlock4 = Copy-TestObject $validBlock4
  $splitForbiddenBlock4.textReplacements[0].text = '鱼丸分装吸汤挂汁'
  $splitForbiddenBlock4.textReplacements[0].lines[0].proposedSegments[1].text = '分'
  $splitForbiddenBlock4.textReplacements[0].lines[0].proposedSegments[2].text = '装吸汤'
  $splitForbiddenBlock4Path = Write-TestCopy $splitForbiddenBlock4 'split-forbidden-block4'
  $splitForbiddenBlock4Result = Test-DingdongCopyCompliance -CopyPath $splitForbiddenBlock4Path -SkillRoot $skillRoot
  Assert-ErrorCode $splitForbiddenBlock4Result 'forbidden-block4-prep-packaging-copy' '版4 cannot split a forbidden term across proposed segments'

  $block4TasteLayer = $layers['2687']
  $validBlock4Taste = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @($validBlock4.facts)
    terminologyDecisions = @()
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '版4口感信息'
        id = 2687
        path = [string]$block4TasteLayer.path
        oldText = [string]$block4TasteLayer.text
        text = "鱼丸圆润饱满 色泽红亮`r"
        mode = 'structure-adapted'
        lines = @(
          [ordered]@{
            sourceSegments = @(
              [ordered]@{ text = '虾肉'; pos = 'noun'; role = 'ingredient'; separatorAfter = '' }
              [ordered]@{ text = '紧实饱满'; pos = 'fixed'; role = 'product-quality'; separatorAfter = ' ' }
              [ordered]@{ text = 'Q弹鲜甜'; pos = 'fixed'; role = 'flavour-texture'; separatorAfter = '' }
            )
            proposedSegments = @(
              [ordered]@{ text = '鱼丸'; pos = 'noun'; role = 'ingredient'; separatorAfter = '' }
              [ordered]@{ text = '圆润饱满'; pos = 'fixed'; role = 'product-quality'; separatorAfter = ' ' }
              [ordered]@{ text = '色泽红亮'; pos = 'fixed'; role = 'flavour-texture'; separatorAfter = '' }
            )
          }
        )
        evidenceIds = @('fact-block4')
      }
    )
  }
  $validBlock4TastePath = Write-TestCopy $validBlock4Taste 'valid-block4-taste'
  $validBlock4TasteResult = Test-DingdongCopyCompliance -CopyPath $validBlock4TastePath -SkillRoot $skillRoot
  Assert-True $validBlock4TasteResult.ok '版4口感目标 accepts food appearance copy'

  $forbiddenBlock4Taste = Copy-TestObject $validBlock4Taste
  $forbiddenBlock4Taste.textReplacements[0].text = "鱼丸整包到家 汤煮熟透`r"
  $forbiddenBlock4Taste.textReplacements[0].lines[0].proposedSegments[1].text = '整包到家'
  $forbiddenBlock4TastePath = Write-TestCopy $forbiddenBlock4Taste 'forbidden-block4-taste'
  $forbiddenBlock4TasteResult = Test-DingdongCopyCompliance -CopyPath $forbiddenBlock4TastePath -SkillRoot $skillRoot
  Assert-ErrorCode $forbiddenBlock4TasteResult 'forbidden-block4-prep-packaging-copy' '版4口感目标 also rejects prep or packaging descriptions'

  $nonBlock4Packaging = Copy-TestObject $valid
  $nonBlock4Packaging.textReplacements[0].text = "酸香浓郁 分装醇厚`r宅家轻松解锁酸菜米粉"
  $nonBlock4Packaging.textReplacements[0].lines[0].proposedSegments[2].text = '分装'
  $nonBlock4PackagingPath = Write-TestCopy $nonBlock4Packaging 'non-block4-packaging'
  $nonBlock4PackagingResult = Test-DingdongCopyCompliance -CopyPath $nonBlock4PackagingPath -SkillRoot $skillRoot
  Assert-True (@($nonBlock4PackagingResult.errors | Where-Object {
      [string]$_.code -ceq 'forbidden-block4-prep-packaging-copy'
    }).Count -eq 0) 'block-4 prep and packaging rule does not leak into other boards'

  $board6OnionLayer = $layers['4811']
  $board6SproutLayer = $layers['4819']
  $validBoard6SideDishes = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @(
      [ordered]@{
        id = 'fact-onion'; kind = 'document'; category = 'side-dish'; terms = @('洋葱', '洋葱丝')
        statement = '当前产品配菜含洋葱丝。'; source = '测试产品资料'
      }
      [ordered]@{
        id = 'fact-sprout'; kind = 'document'; category = 'side-dish'; terms = @('豆芽', '绿豆芽')
        statement = '当前产品配菜含绿豆芽。'; source = '测试产品资料'
      }
    )
    terminologyDecisions = @()
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '版6洋葱说明'; id = 4811; path = [string]$board6OnionLayer.path; oldText = [string]$board6OnionLayer.text
        text = "洋葱：炒制后清甜爽脆，增添香气`r"; mode = 'structure-adapted'; evidenceIds = @('fact-onion')
        lines = @([ordered]@{
          sourceSegments = @(
            [ordered]@{ text = '金蒜'; pos = 'noun'; role = 'ingredient'; separatorAfter = '：' }
            [ordered]@{ text = '油炸至'; pos = 'verb'; role = 'method'; separatorAfter = '' }
            [ordered]@{ text = '金黄酥脆'; pos = 'fixed'; role = 'result'; separatorAfter = '，' }
            [ordered]@{ text = '满口焦香'; pos = 'fixed'; role = 'flavour'; separatorAfter = '' }
          )
          proposedSegments = @(
            [ordered]@{ text = '洋葱'; pos = 'noun'; role = 'ingredient'; separatorAfter = '：' }
            [ordered]@{ text = '炒制后'; pos = 'verb'; role = 'method'; separatorAfter = '' }
            [ordered]@{ text = '清甜爽脆'; pos = 'fixed'; role = 'result'; separatorAfter = '，' }
            [ordered]@{ text = '增添香气'; pos = 'fixed'; role = 'flavour'; separatorAfter = '' }
          )
        })
      }
      [ordered]@{
        label = '版6豆芽说明'; id = 4819; path = [string]$board6SproutLayer.path; oldText = [string]$board6SproutLayer.text
        text = "豆芽：保持根根口感脆嫩，提鲜解腻`r`r"; mode = 'structure-adapted'; evidenceIds = @('fact-sprout')
        lines = @([ordered]@{
          sourceSegments = @(
            [ordered]@{ text = '银蒜'; pos = 'noun'; role = 'ingredient'; separatorAfter = '：' }
            [ordered]@{ text = '保留'; pos = 'verb'; role = 'action'; separatorAfter = '' }
            [ordered]@{ text = '生蒜原汁'; pos = 'noun'; role = 'flavour-base'; separatorAfter = '' }
            [ordered]@{ text = '辛辣'; pos = 'adjective'; role = 'flavour'; separatorAfter = '，' }
            [ordered]@{ text = '提鲜'; pos = 'verb'; role = 'benefit'; separatorAfter = '' }
            [ordered]@{ text = '去腥'; pos = 'verb'; role = 'benefit'; separatorAfter = '' }
          )
          proposedSegments = @(
            [ordered]@{ text = '豆芽'; pos = 'noun'; role = 'ingredient'; separatorAfter = '：' }
            [ordered]@{ text = '保持'; pos = 'verb'; role = 'action'; separatorAfter = '' }
            [ordered]@{ text = '根根口感'; pos = 'noun'; role = 'flavour-base'; separatorAfter = '' }
            [ordered]@{ text = '脆嫩'; pos = 'adjective'; role = 'flavour'; separatorAfter = '，' }
            [ordered]@{ text = '提鲜'; pos = 'verb'; role = 'benefit'; separatorAfter = '' }
            [ordered]@{ text = '解腻'; pos = 'verb'; role = 'benefit'; separatorAfter = '' }
          )
        })
      }
    )
  }
  $validBoard6SideDishesResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $validBoard6SideDishes 'valid-board6-side-dishes') -SkillRoot $skillRoot
  Assert-True $validBoard6SideDishesResult.ok '版6 two descriptions accept two distinct side dishes with bound facts'

  $missingBoard6SideDishEvidence = Copy-TestObject $validBoard6SideDishes
  $missingBoard6SideDishEvidence.facts[0].category = 'ingredient'
  $missingBoard6SideDishEvidenceResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $missingBoard6SideDishEvidence 'missing-board6-side-dish-evidence') -SkillRoot $skillRoot
  Assert-ErrorCode $missingBoard6SideDishEvidenceResult 'missing-board6-side-dish-evidence' '版6 description rejects a non-side-dish fact'

  $duplicateBoard6SideDish = Copy-TestObject $validBoard6SideDishes
  $duplicateBoard6SideDish.textReplacements[1].text = "洋葱：保持根根口感脆嫩，提鲜解腻`r`r"
  $duplicateBoard6SideDish.textReplacements[1].lines[0].proposedSegments[0].text = '洋葱'
  $duplicateBoard6SideDish.textReplacements[1].evidenceIds = @('fact-onion')
  $duplicateBoard6SideDishResult = Test-DingdongCopyCompliance -CopyPath (Write-TestCopy $duplicateBoard6SideDish 'duplicate-board6-side-dish') -SkillRoot $skillRoot
  Assert-ErrorCode $duplicateBoard6SideDishResult 'duplicate-board6-side-dish-copy' '版6 two descriptions reject the same side dish twice'

  $badLineCount = Copy-TestObject $valid
  $badLineCount.textReplacements[0].text = '酸香浓郁 肉香醇厚'
  $badLineCount.textReplacements[0].lines = @($badLineCount.textReplacements[0].lines[0])
  $badLineCountPath = Write-TestCopy $badLineCount 'bad-line-count'
  $badLineCountResult = Test-DingdongCopyCompliance -CopyPath $badLineCountPath -SkillRoot $skillRoot
  Assert-ErrorCode $badLineCountResult 'line-count-mismatch' 'line-count change fails'

  $stepTitleLayer = $layers['1118']
  $trailingLineBreaks = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @($valid.facts)
    terminologyDecisions = @()
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '步骤数量关联标题'
        id = 1118
        path = [string]$stepTitleLayer.path
        oldText = [string]$stepTitleLayer.text
        text = "开盒即烹`r2步即烹 轻松到胃`r`r"
        mode = 'structure-adapted'
        lines = @(
          [ordered]@{
            sourceSegments = @(
              [ordered]@{ text = '开盒'; pos = 'verb'; role = 'action'; separatorAfter = '' }
              [ordered]@{ text = '即烹'; pos = 'fixed'; role = 'state'; separatorAfter = '' }
            )
            proposedSegments = @(
              [ordered]@{ text = '开盒'; pos = 'verb'; role = 'action'; separatorAfter = '' }
              [ordered]@{ text = '即烹'; pos = 'fixed'; role = 'state'; separatorAfter = '' }
            )
          }
          [ordered]@{
            sourceSegments = @(
              [ordered]@{ text = '3'; pos = 'number'; role = 'step-count'; separatorAfter = '' }
              [ordered]@{ text = '步'; pos = 'unit'; role = 'step-unit'; separatorAfter = '' }
              [ordered]@{ text = '即烹'; pos = 'fixed'; role = 'state'; separatorAfter = ' ' }
              [ordered]@{ text = '轻松'; pos = 'adverb'; role = 'state'; separatorAfter = '' }
              [ordered]@{ text = '到胃'; pos = 'verb'; role = 'result'; separatorAfter = '' }
            )
            proposedSegments = @(
              [ordered]@{ text = '2'; pos = 'number'; role = 'step-count'; separatorAfter = '' }
              [ordered]@{ text = '步'; pos = 'unit'; role = 'step-unit'; separatorAfter = '' }
              [ordered]@{ text = '即烹'; pos = 'fixed'; role = 'state'; separatorAfter = ' ' }
              [ordered]@{ text = '轻松'; pos = 'adverb'; role = 'state'; separatorAfter = '' }
              [ordered]@{ text = '到胃'; pos = 'verb'; role = 'result'; separatorAfter = '' }
            )
          }
        )
        evidenceIds = @('fact-product')
      }
    )
  }
  $trailingLineBreaksPath = Write-TestCopy $trailingLineBreaks 'trailing-line-breaks'
  $trailingLineBreaksResult = Test-DingdongCopyCompliance -CopyPath $trailingLineBreaksPath -SkillRoot $skillRoot
  Assert-True $trailingLineBreaksResult.ok 'matching trailing line breaks need no fake segments or verbatim workaround'

  $badTrailingLineBreaks = Copy-TestObject $trailingLineBreaks
  $badTrailingLineBreaks.textReplacements[0].text = "开盒即烹`r2步即烹 轻松到胃`r"
  $badTrailingLineBreaksPath = Write-TestCopy $badTrailingLineBreaks 'bad-trailing-line-breaks'
  $badTrailingLineBreaksResult = Test-DingdongCopyCompliance -CopyPath $badTrailingLineBreaksPath -SkillRoot $skillRoot
  Assert-ErrorCode $badTrailingLineBreaksResult 'trailing-line-break-mismatch' 'changed trailing line-break count fails directly'

  $badLayout = Copy-TestObject $valid
  $badLayout.textReplacements[0].text = "酸香浓郁肉香醇厚`r宅家轻松解锁酸菜米粉"
  $badLayout.textReplacements[0].lines[0].proposedSegments[1].separatorAfter = ''
  $badLayoutPath = Write-TestCopy $badLayout 'bad-layout'
  $badLayoutResult = Test-DingdongCopyCompliance -CopyPath $badLayoutPath -SkillRoot $skillRoot
  Assert-ErrorCode $badLayoutResult 'separator-mismatch' 'space and punctuation structure mismatch fails'

  $missingEvidence = Copy-TestObject $valid
  $missingEvidence.textReplacements[0].evidenceIds = @()
  $missingEvidencePath = Write-TestCopy $missingEvidence 'missing-evidence'
  $missingEvidenceResult = Test-DingdongCopyCompliance -CopyPath $missingEvidencePath -SkillRoot $skillRoot
  Assert-ErrorCode $missingEvidenceResult 'missing-evidence' 'missing current-product evidence fails'

  $legacy = Copy-TestObject $valid
  $legacy.textReplacements[0].text = "虾仁浓郁 肉香醇厚`r宅家轻松解锁酸菜米粉"
  $legacy.textReplacements[0].lines[0].proposedSegments[0].text = '虾仁'
  $legacyPath = Write-TestCopy $legacy 'legacy'
  $legacyResult = Test-DingdongCopyCompliance -CopyPath $legacyPath -SkillRoot $skillRoot
  Assert-ErrorCode $legacyResult 'unsupported-legacy-term' 'unsupported legacy product term fails'

  $protectedLayer = $layers['20']
  $protected = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @($valid.facts)
    terminologyDecisions = @()
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '版2说明'
        id = 20
        path = [string]$protectedLayer.path
        oldText = [string]$protectedLayer.text
        text = [string]$protectedLayer.text
        sourceText = [string]$protectedLayer.text
        mode = 'verbatim'
        evidenceIds = @('fact-product')
      }
    )
  }
  $protectedPath = Write-TestCopy $protected 'protected'
  $protectedResult = Test-DingdongCopyCompliance -CopyPath $protectedPath -SkillRoot $skillRoot
  Assert-True $protectedResult.ok 'an unchanged protected target is a no-op'

  $protectedChanged = Copy-TestObject $protected
  $protectedChanged.textReplacements[0].text = '不得修改版2说明'
  $protectedChanged.textReplacements[0].sourceText = '不得修改版2说明'
  $protectedChangedPath = Write-TestCopy $protectedChanged 'protected-changed'
  $protectedChangedResult = Test-DingdongCopyCompliance -CopyPath $protectedChangedPath -SkillRoot $skillRoot
  Assert-ErrorCode $protectedChangedResult 'immutable-protected-target' 'page 2 text cannot be changed'

  $protectedAllowed = Copy-TestObject $protected
  $protectedAllowed.protectedOverrides = @(
    [ordered]@{
      id = 20
      path = [string]$protectedLayer.path
      approvedText = [string]$protectedLayer.text
      userInstruction = '本次只解锁版2说明'
    }
  )
  $protectedAllowedPath = Write-TestCopy $protectedAllowed 'protected-allowed'
  $protectedAllowedResult = Test-DingdongCopyCompliance -CopyPath $protectedAllowedPath -SkillRoot $skillRoot
  Assert-ErrorCode $protectedAllowedResult 'protected-overrides-forbidden' 'an exact user-authorized override cannot unlock page 2'

  $broadOverride = Copy-TestObject $protected
  $broadOverride.protectedOverrides = @(
    [ordered]@{
      id = 20
      path = '版2'
      approvedText = [string]$protectedLayer.text
      userInstruction = '解锁版2'
    }
  )
  $broadOverridePath = Write-TestCopy $broadOverride 'broad-override'
  $broadOverrideResult = Test-DingdongCopyCompliance -CopyPath $broadOverridePath -SkillRoot $skillRoot
  Assert-ErrorCode $broadOverrideResult 'protected-overrides-forbidden' 'a broad override is forbidden instead of unlocking a protected path'

  $tailLayer = $layers['69']
  $protectedTail = Copy-TestObject $protected
  $protectedTail.textReplacements[0].label = '尾版说明'
  $protectedTail.textReplacements[0].id = 69
  $protectedTail.textReplacements[0].path = [string]$tailLayer.path
  $protectedTail.textReplacements[0].oldText = [string]$tailLayer.text
  $protectedTail.textReplacements[0].text = '尾版也不允许由脚本修改'
  $protectedTail.textReplacements[0].sourceText = '尾版也不允许由脚本修改'
  $protectedTailPath = Write-TestCopy $protectedTail 'protected-tail'
  $protectedTailResult = Test-DingdongCopyCompliance -CopyPath $protectedTailPath -SkillRoot $skillRoot
  Assert-ErrorCode $protectedTailResult 'immutable-protected-target' 'protectedTextTargets outside page 2 are also immutable'

  $titleLayer = $layers['10']
  $verbatimRu = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @($valid.facts)
    terminologyDecisions = @()
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '逐字来源含入字'
        id = 10
        path = [string]$titleLayer.path
        oldText = [string]$titleLayer.text
        text = '加入香菜'
        sourceText = '加入香菜'
        mode = 'verbatim'
        evidenceIds = @('fact-product')
      }
    )
  }
  $verbatimRuPath = Write-TestCopy $verbatimRu 'verbatim-ru'
  $verbatimRuResult = Test-DingdongCopyCompliance -CopyPath $verbatimRuPath -SkillRoot $skillRoot
  Assert-True $verbatimRuResult.ok 'verbatim user text is exempt from the generated-copy ru-plus-noun rule'

  $verbatim = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @($valid.facts)
    terminologyDecisions = @(
      [ordered]@{
        terms = @('肉末', '肉沫')
        allowedByMode = [ordered]@{ 'structure-adapted' = '肉末'; verbatim = '肉末' }
        evidenceIds = @('fact-product')
      }
    )
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '产品名称'
        id = 10
        path = [string]$titleLayer.path
        oldText = [string]$titleLayer.text
        text = '酸菜肉沫米粉'
        sourceText = '酸菜肉末米粉'
        mode = 'verbatim'
        evidenceIds = @('fact-product')
      }
    )
  }
  $verbatimPath = Write-TestCopy $verbatim 'verbatim'
  $verbatimResult = Test-DingdongCopyCompliance -CopyPath $verbatimPath -SkillRoot $skillRoot
  Assert-ErrorCode $verbatimResult 'verbatim-mismatch' 'one-character verbatim change fails'

  $unresolvedTerms = Copy-TestObject $verbatim
  $unresolvedTerms.terminologyDecisions = @()
  $unresolvedTerms.textReplacements[0].text = '酸菜肉沫米粉'
  $unresolvedTerms.textReplacements[0].sourceText = '酸菜肉沫米粉'
  $unresolvedTermsPath = Write-TestCopy $unresolvedTerms 'unresolved-terms'
  $unresolvedTermsResult = Test-DingdongCopyCompliance -CopyPath $unresolvedTermsPath -SkillRoot $skillRoot
  Assert-ErrorCode $unresolvedTermsResult 'unresolved-terminology-conflict' '肉末／肉沫 conflict requires an explicit decision'

  $stepOneLayer = $layers['5631']
  $perTargetTerminology = [ordered]@{
    copyVersion = 2
    templateId = 'dingdong-haoshiguang-detail-2step'
    facts = @(
      [ordered]@{
        id = 'fact-conflicting-verbatim'
        kind = 'user'
        statement = '用户确认标题逐字保留“肉沫”，步骤逐字保留“肉末”。'
        source = '用户本次确认'
      }
    )
    terminologyDecisions = @(
      [ordered]@{
        terms = @('肉末', '肉沫')
        allowedByMode = [ordered]@{ 'structure-adapted' = '肉末' }
        allowedByReplacement = @(
          [ordered]@{
            id = 10
            path = [string]$titleLayer.path
            allowedTerm = '肉沫'
            evidenceIds = @('fact-conflicting-verbatim')
            userInstruction = '标题逐字保留肉沫'
          }
          [ordered]@{
            id = 5631
            path = [string]$stepOneLayer.path
            allowedTerm = '肉末'
            evidenceIds = @('fact-conflicting-verbatim')
            userInstruction = '步骤逐字保留肉末'
          }
        )
        evidenceIds = @('fact-conflicting-verbatim')
      }
    )
    protectedOverrides = @()
    textReplacements = @(
      [ordered]@{
        label = '用户逐字标题'
        id = 10
        path = [string]$titleLayer.path
        oldText = [string]$titleLayer.text
        text = '酸菜肉沫米粉'
        sourceText = '酸菜肉沫米粉'
        mode = 'verbatim'
        evidenceIds = @('fact-conflicting-verbatim')
      }
      [ordered]@{
        label = '用户逐字步骤'
        id = 5631
        path = [string]$stepOneLayer.path
        oldText = [string]$stepOneLayer.text
        text = '步骤使用肉末'
        sourceText = '步骤使用肉末'
        mode = 'verbatim'
        evidenceIds = @('fact-conflicting-verbatim')
      }
    )
  }
  $perTargetTerminologyPath = Write-TestCopy $perTargetTerminology 'per-target-terminology'
  $perTargetTerminologyResult = Test-DingdongCopyCompliance -CopyPath $perTargetTerminologyPath -SkillRoot $skillRoot
  Assert-True $perTargetTerminologyResult.ok 'user-confirmed conflicting verbatim sources bind to exact targets'

  $hashResult = Test-DingdongCopyCompliance -CopyPath $validPath -SkillRoot $skillRoot -ExpectedSha256 ('0' * 64)
  Assert-ErrorCode $hashResult 'approved-hash-mismatch' 'approved hash change fails'

  $tamperedTask = @(Copy-TestObject $valid.textReplacements)
  $tamperedTask[0].text = '已篡改'
  $bindingResult = Test-DingdongCopyCompliance -CopyPath $validPath -SkillRoot $skillRoot -TaskReplacements $tamperedTask
  Assert-ErrorCode $bindingResult 'task-copy-mismatch' 'embedded task copy cannot differ from approved copy'

  $reviewPath = Join-Path $tempRoot 'review.md'
  $reviewOutput = & (Join-Path $PSScriptRoot 'new-dingdong-copy-review.ps1') -CopyPath $validPath -OutputPath $reviewPath | ConvertFrom-Json
  Assert-True ($reviewOutput.ok -and (Test-Path -LiteralPath $reviewPath)) 'review generator writes a valid review'
  $reviewText = [IO.File]::ReadAllText($reviewPath, (New-Object Text.UTF8Encoding($false)))
  Assert-True ($reviewText.Contains('原语法') -and $reviewText.Contains('保留不改') -and $reviewText.Contains($validResult.copySha256)) 'review shows grammar, retained copy, and hash'
  Assert-True ($reviewText.Contains('| 版2 |') -and
    $reviewText.Contains('| 尾版 |') -and
    -not $reviewText.Contains('| 保留：版2/')) 'review merges retained template text into one row per board'
  $groupedReviewCopy = Copy-TestObject $validBlock4
  $groupedReviewCopy.textReplacements = @($groupedReviewCopy.textReplacements) + @((Copy-TestObject $validBlock4Taste.textReplacements[0]))
  $groupedReviewCopyPath = Write-TestCopy $groupedReviewCopy 'grouped-review'
  $groupedReviewPath = Join-Path $tempRoot 'grouped-review.md'
  & (Join-Path $PSScriptRoot 'new-dingdong-copy-review.ps1') -CopyPath $groupedReviewCopyPath -OutputPath $groupedReviewPath | Out-Null
  $groupedReviewText = [IO.File]::ReadAllText($groupedReviewPath, (New-Object Text.UTF8Encoding($false)))
  Assert-True ($groupedReviewText.Contains('| 版4 |') -and
    -not $groupedReviewText.Contains('| 版4主料信息 |') -and
    -not $groupedReviewText.Contains('| 版4口感信息 |') -and
    $groupedReviewText.Contains('鱼丸颗颗圆润饱满<br>鱼丸圆润饱满 色泽红亮')) 'review merges title and description targets into one row per board'

  $jobPath = Join-Path $tempRoot 'detail-job.json'
  & (Join-Path $PSScriptRoot 'new-dingdong-detail-job.ps1') `
    -TemplateId 'dingdong-haoshiguang-detail-2step' `
    -CopyPath $validPath `
    -ApprovedCopySha256 $validResult.copySha256 `
    -TargetPsdPath (Join-Path $tempRoot 'detail.psd') `
    -OutputPath $jobPath | Out-Null
  $job = Read-Utf8Json $jobPath
  Assert-True ([string]$job.copyReview.copySha256 -ceq [string]$validResult.copySha256) 'job binds approved copy hash'

  [IO.File]::AppendAllText($validPath, "`n", (New-Object Text.UTF8Encoding($false)))
  $runPath = Join-Path $tempRoot 'stale-run.json'
  $prepareFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $jobPath -RunPath $runPath | Out-Null
  } catch {
    $prepareFailed = $_.Exception.Message -like '*changed after approval*'
  }
  Assert-True $prepareFailed 'prepare blocks stale copy before Photoshop'
  Assert-True (-not (Test-Path -LiteralPath $runPath) -and -not (Test-Path -LiteralPath (Join-Path $tempRoot 'stale-run.working.psd'))) 'stale copy creates no run or working PSD'

  $genericTask = [pscustomobject][ordered]@{
    jobVersion = 1
    workflow = 'generic'
    source = [pscustomobject][ordered]@{ templateId = 'dingdong-haoshiguang-detail-2step' }
    targetPsdPath = (Join-Path $tempRoot 'generic.psd')
    textReplacements = @()
    imageTransfers = @()
    outputs = [pscustomobject][ordered]@{ preview = $false; final = $null }
    organizeUsedAssets = $false
  }
  $genericTaskPath = Join-Path $tempRoot 'generic-job.json'
  Write-Utf8Json -Path $genericTaskPath -Value $genericTask | Out-Null
  $genericResolved = Resolve-PsdJob -Task $genericTask -TaskPath $genericTaskPath -SkillRoot $skillRoot -RunPath (Join-Path $tempRoot 'generic-run.json')
  Assert-True ([string]$genericResolved.workflow -ceq 'generic') 'generic PSD job resolution remains unchanged'

  $handRuNounTask = Copy-TestObject $genericTask
  $handRuNounTask.textReplacements = @(
    [ordered]@{
      id = 3886
      text = '入味'
      mode = 'structure-adapted'
      lines = @([ordered]@{
        proposedSegments = @([ordered]@{ text = '入味'; pos = 'verb'; role = 'result'; separatorAfter = '' })
      })
    }
  )
  $handRuNounTaskPath = Join-Path $tempRoot 'hand-ru-noun-job.json'
  Write-Utf8Json -Path $handRuNounTaskPath -Value $handRuNounTask | Out-Null
  $handRuNounRunPath = Join-Path $tempRoot 'hand-ru-noun-run.json'
  $handRuNounFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $handRuNounTaskPath -RunPath $handRuNounRunPath | Out-Null
  } catch {
    $handRuNounFailed = $_.Exception.Message -like '*forbidden-ru-noun-pattern*'
  }
  Assert-True ($handRuNounFailed -and
    -not (Test-Path -LiteralPath $handRuNounRunPath) -and
    -not (Test-Path -LiteralPath (Join-Path $tempRoot 'hand-ru-noun-run.working.psd'))) 'handwritten jobs cannot bypass the exact two-character ru-plus-noun detector'

  $handBlock4Task = Copy-TestObject $genericTask
  $handBlock4Task.textReplacements = @(
    [ordered]@{
      id = 2689
      text = '鱼丸分装吸汤熟透'
      mode = 'structure-adapted'
      lines = @([ordered]@{
        proposedSegments = @(
          [ordered]@{ text = '鱼丸'; pos = 'noun'; role = 'ingredient'; separatorAfter = '' }
          [ordered]@{ text = '分装'; pos = 'adverb'; role = 'method'; separatorAfter = '' }
          [ordered]@{ text = '吸汤'; pos = 'verb'; role = 'action'; separatorAfter = '' }
          [ordered]@{ text = '熟透'; pos = 'verb'; role = 'result'; separatorAfter = '' }
        )
      })
    }
  )
  $handBlock4TaskPath = Join-Path $tempRoot 'hand-block4-job.json'
  Write-Utf8Json -Path $handBlock4TaskPath -Value $handBlock4Task | Out-Null
  $handBlock4RunPath = Join-Path $tempRoot 'hand-block4-run.json'
  $handBlock4Failed = $false
  try {
    & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $handBlock4TaskPath -RunPath $handBlock4RunPath | Out-Null
  } catch {
    $handBlock4Failed = $_.Exception.Message -like '*forbidden-block4-prep-packaging-copy*'
  }
  Assert-True ($handBlock4Failed -and
    -not (Test-Path -LiteralPath $handBlock4RunPath) -and
    -not (Test-Path -LiteralPath (Join-Path $tempRoot 'hand-block4-run.working.psd'))) 'handwritten jobs cannot bypass the block-4 prep and packaging detector'

  $handPrefixTask = Copy-TestObject $genericTask
  $handPrefixTask.textReplacements = @(
    [ordered]@{
      id = 3899
      text = "秘制酱香拌面调味酱`r酱香浓郁均匀挂汁 浓而油亮`r"
      mode = 'structure-adapted'
    }
  )
  $handPrefixTaskPath = Join-Path $tempRoot 'hand-board6-prefix-job.json'
  Write-Utf8Json -Path $handPrefixTaskPath -Value $handPrefixTask | Out-Null
  $handPrefixRunPath = Join-Path $tempRoot 'hand-board6-prefix-run.json'
  $handPrefixFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $handPrefixTaskPath -RunPath $handPrefixRunPath | Out-Null
  } catch {
    $handPrefixFailed = $_.Exception.Message -like '*required-copy-prefix*'
  }
  Assert-True ($handPrefixFailed -and
    -not (Test-Path -LiteralPath $handPrefixRunPath) -and
    -not (Test-Path -LiteralPath (Join-Path $tempRoot 'hand-board6-prefix-run.working.psd'))) 'handwritten jobs cannot bypass the board 6 TeDiao prefix requirement'

  $handBoard8Task = Copy-TestObject $genericTask
  $handBoard8Task.textReplacements = @(
    [ordered]@{
      id = 4076
      text = "下班回家轻松煮`r5分钟热乎上桌`r"
      mode = 'structure-adapted'
    }
  )
  $handBoard8TaskPath = Join-Path $tempRoot 'hand-board8-exact-copy-job.json'
  Write-Utf8Json -Path $handBoard8TaskPath -Value $handBoard8Task | Out-Null
  $handBoard8RunPath = Join-Path $tempRoot 'hand-board8-exact-copy-run.json'
  $handBoard8Failed = $false
  try {
    & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $handBoard8TaskPath -RunPath $handBoard8RunPath | Out-Null
  } catch {
    $handBoard8Failed = $_.Exception.Message -like '*required-exact-copy*'
  }
  Assert-True ($handBoard8Failed -and
    -not (Test-Path -LiteralPath $handBoard8RunPath) -and
    -not (Test-Path -LiteralPath (Join-Path $tempRoot 'hand-board8-exact-copy-run.working.psd'))) 'handwritten jobs cannot bypass the board 8 exact-copy requirement'

  $mainTask = [pscustomobject][ordered]@{
    jobVersion = 1
    workflow = 'dingdong-main'
    source = [pscustomobject][ordered]@{ templateId = 'dingdong-haoshiguang-main-7board' }
    targetPsdPath = (Join-Path $tempRoot 'main.psd')
    textReplacements = @()
    imageTransfers = @()
    outputs = [pscustomobject][ordered]@{ preview = $false; final = $null }
    organizeUsedAssets = $false
  }
  $mainTaskPath = Join-Path $tempRoot 'main-job.json'
  Write-Utf8Json -Path $mainTaskPath -Value $mainTask | Out-Null
  $mainResolved = Resolve-PsdJob -Task $mainTask -TaskPath $mainTaskPath -SkillRoot $skillRoot -RunPath (Join-Path $tempRoot 'main-run.json')
  Assert-True ([string]$mainResolved.workflow -ceq 'dingdong-main') 'Dingdong main-image job resolution remains unchanged'

  $legacyFilteredMainRun = [pscustomobject][ordered]@{
    workflow = 'dingdong-main'
    organizeUsedAssets = [pscustomobject][ordered]@{ sourceLayerIds = @(7001, 7002, 7003, 7004, 7005, 7006, 7007) }
  }
  $genericFilteredRun = [pscustomobject][ordered]@{
    workflow = 'generic'
    organizeUsedAssets = [pscustomobject][ordered]@{ sourceLayerIds = @(81, 82) }
  }
  Assert-True (@(Get-UsedAssetSourceLayerIdsForCompletion -Run $legacyFilteredMainRun).Count -eq 0) 'Dingdong main completion ignores legacy seven-source filters and scans the whole detail PSD'
  Assert-True ((@(Get-UsedAssetSourceLayerIdsForCompletion -Run $genericFilteredRun) -join ',') -ceq '81,82') 'generic asset organization preserves an explicit source-layer filter'

  $directImageMappings = @()
  $directApprovalItems = @()
  $mainTargetIds = @(2972, 1400, 1586, 2973, 2971, 2969, 2970)
  for ($imageIndex = 0; $imageIndex -lt 7; $imageIndex++) {
    $imagePath = Join-Path $tempRoot "direct-main-$($imageIndex + 1).jpg"
    [IO.File]::WriteAllBytes($imagePath, [byte[]]@(255, 216, 255, 217))
    $directImageMappings += [ordered]@{
      imagePath = $imagePath
      target = [ordered]@{ id = $mainTargetIds[$imageIndex] }
      name = "direct-main-$($imageIndex + 1)"
      fit = 'cover'
    }
    $directApprovalItems += [ordered]@{
      targetId = $mainTargetIds[$imageIndex]
      imagePath = $imagePath
    }
  }
  $directMainMapping = [ordered]@{
    textReplacements = @()
    imageSelectionApproval = [ordered]@{
      userInstruction = '确认图片映射，按刚才展示的七画板图片制作'
      items = $directApprovalItems
    }
    imageMappings = $directImageMappings
  }
  $directMainMappingPath = Join-Path $tempRoot 'direct-main-mapping.json'
  Write-Utf8Json -Path $directMainMappingPath -Value $directMainMapping | Out-Null
  $directMainJobPath = Join-Path $tempRoot 'direct-main-job.json'
  & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') `
    -MappingPath $directMainMappingPath `
    -TargetPsdPath (Join-Path $tempRoot 'direct-main.psd') `
    -OutputPath $directMainJobPath | Out-Null
  $directMainJob = Read-Utf8Json $directMainJobPath
  Assert-True (@($directMainJob.imageTransfers).Count -eq 7 -and
    @($directMainJob.imageTransfers | Where-Object { Test-ObjectProperty $_ 'imagePath' }).Count -eq 7 -and
    @($directMainJob.imageTransfers | Where-Object { Test-ObjectProperty $_ 'sourcePsdPath' }).Count -eq 0 -and
    $directMainJob.organizeUsedAssets -eq $false) 'main-image job accepts seven direct image files without scheduling detail-image organization'
  $directMainResolved = Resolve-PsdJob `
    -Task $directMainJob `
    -TaskPath $directMainJobPath `
    -SkillRoot $skillRoot `
    -RunPath (Join-Path $tempRoot 'direct-main-run.json')
  Assert-True (@($directMainResolved.imageTransfers).Count -eq 7 -and
    @($directMainResolved.imageTransfers | Where-Object { Test-ObjectProperty $_ 'imageSha256' }).Count -eq 7) 'direct main-image files resolve and bind hashes in one job'

  $protectedMainMapping = Copy-TestObject $directMainMapping
  $protectedMainMapping.textReplacements = @(
    [ordered]@{
      id = 309
      text = '不得写入画板2'
      mode = 'verbatim'
    }
  )
  $protectedMainMappingPath = Join-Path $tempRoot 'protected-main-mapping.json'
  Write-Utf8Json -Path $protectedMainMappingPath -Value $protectedMainMapping | Out-Null
  $protectedMainFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') `
      -MappingPath $protectedMainMappingPath `
      -TargetPsdPath (Join-Path $tempRoot 'protected-main.psd') `
      -OutputPath (Join-Path $tempRoot 'protected-main-job.json') | Out-Null
  } catch {
    $protectedMainFailed = $_.Exception.Message -like '*immutable-protected-target*'
  }
  Assert-True $protectedMainFailed 'board 2 text replacement is blocked before Photoshop'

  $handProtectedTask = Copy-TestObject $mainTask
  $handProtectedTask.textReplacements = @([ordered]@{ id = 309; text = '手写任务也不能修改画板2'; mode = 'verbatim' })
  $handProtectedTaskPath = Join-Path $tempRoot 'hand-protected-main-job.json'
  Write-Utf8Json -Path $handProtectedTaskPath -Value $handProtectedTask | Out-Null
  $handProtectedRunPath = Join-Path $tempRoot 'hand-protected-main-run.json'
  $handProtectedFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $handProtectedTaskPath -RunPath $handProtectedRunPath | Out-Null
  } catch {
    $handProtectedFailed = $_.Exception.Message -like '*immutable-protected-target*'
  }
  Assert-True ($handProtectedFailed -and
    -not (Test-Path -LiteralPath $handProtectedRunPath) -and
    -not (Test-Path -LiteralPath (Join-Path $tempRoot 'hand-protected-main-run.working.psd'))) 'handwritten jobs are blocked before a working copy is created'

  $handCurrentTask = Copy-TestObject $mainTask
  $handCurrentTask.textReplacements = @([ordered]@{ id = 1569; text = 'sync-detail-current 也不能修改'; mode = 'verbatim' })
  $handCurrentTaskPath = Join-Path $tempRoot 'hand-current-main-job.json'
  Write-Utf8Json -Path $handCurrentTaskPath -Value $handCurrentTask | Out-Null
  $handCurrentFailed = $false
  $handCurrentError = ''
  try {
    & (Join-Path $PSScriptRoot 'prepare-psd-job.ps1') -TaskPath $handCurrentTaskPath -RunPath (Join-Path $tempRoot 'hand-current-run.json') | Out-Null
  } catch {
    $handCurrentError = $_.Exception.Message
    $handCurrentFailed = $_.Exception.Message -like '*immutable-protected-target*'
  }
  Assert-True $handCurrentFailed "sync-detail-current targets are immutable in handwritten jobs (error: $handCurrentError)"

  $genericImageApproval = Copy-TestObject $directMainMapping
  $genericImageApproval.imageSelectionApproval.userInstruction = '重新用新skill制作主图'
  $genericImageApprovalPath = Join-Path $tempRoot 'generic-image-approval.json'
  Write-Utf8Json -Path $genericImageApprovalPath -Value $genericImageApproval | Out-Null
  $genericImageApprovalFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') `
      -MappingPath $genericImageApprovalPath `
      -TargetPsdPath (Join-Path $tempRoot 'generic-image-approval.psd') `
      -OutputPath (Join-Path $tempRoot 'generic-image-approval-job.json') | Out-Null
  } catch {
    $genericImageApprovalFailed = $_.Exception.Message -like '*generic request to make or remake*'
  }
  Assert-True $genericImageApprovalFailed 'generic remake instruction cannot approve a seven-image mapping'

  $detailSourcePsdPath = Join-Path $tempRoot 'formal-detail.psd'
  [IO.File]::WriteAllBytes($detailSourcePsdPath, [byte[]]@(56, 66, 80, 83))
  $detailSourceMappings = @()
  for ($imageIndex = 0; $imageIndex -lt 7; $imageIndex++) {
    $detailSourceMappings += [ordered]@{
      source = [ordered]@{ id = 7000 + $imageIndex; name = "formal-detail-source-$($imageIndex + 1)" }
      target = [ordered]@{ id = $mainTargetIds[$imageIndex] }
      name = "detail-main-$($imageIndex + 1)"
      fit = 'cover'
    }
  }
  $detailSourceMapping = [ordered]@{
    textReplacements = @()
    imageMappings = $detailSourceMappings
  }
  $detailSourceMappingPath = Join-Path $tempRoot 'detail-source-mapping.json'
  Write-Utf8Json -Path $detailSourceMappingPath -Value $detailSourceMapping | Out-Null
  $detailSourceJobPath = Join-Path $tempRoot 'detail-source-job.json'
  & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') `
    -DetailPsdPath $detailSourcePsdPath `
    -MappingPath $detailSourceMappingPath `
    -TargetPsdPath (Join-Path $tempRoot 'detail-source-main.psd') `
    -OutputPath $detailSourceJobPath | Out-Null
  $detailSourceJob = Read-Utf8Json $detailSourceJobPath
  Assert-True (@($detailSourceJob.imageTransfers | Where-Object {
      (Test-ObjectProperty $_ 'sourcePsdPath') -and -not (Test-ObjectProperty $_ 'imagePath')
    }).Count -eq 7 -and
    $detailSourceJob.organizeUsedAssets -ne $false -and
    [string]$detailSourceJob.organizeUsedAssets.psdPath -ceq [IO.Path]::GetFullPath($detailSourcePsdPath) -and
    [string]$detailSourceJob.organizeUsedAssets.workDir -ceq [IO.Path]::GetFullPath($tempRoot) -and
    -not (Test-ObjectProperty $detailSourceJob.organizeUsedAssets 'sourceLayerIds')) 'formal detail PSD supplies all seven main sources but schedules unfiltered whole-detail used-image organization'

  $mixedSourceMapping = Copy-TestObject $detailSourceMapping
  $mixedSourceMapping.imageMappings[0].PSObject.Properties.Remove('source')
  $mixedSourceMapping.imageMappings[0] | Add-Member -NotePropertyName imagePath -NotePropertyValue $directImageMappings[0].imagePath
  $mixedSourceMappingPath = Join-Path $tempRoot 'mixed-source-mapping.json'
  Write-Utf8Json -Path $mixedSourceMappingPath -Value $mixedSourceMapping | Out-Null
  $mixedSourceFailed = $false
  try {
    & (Join-Path $PSScriptRoot 'new-dingdong-main-job.ps1') `
      -DetailPsdPath $detailSourcePsdPath `
      -MappingPath $mixedSourceMappingPath `
      -TargetPsdPath (Join-Path $tempRoot 'mixed-source-main.psd') `
      -OutputPath (Join-Path $tempRoot 'mixed-source-job.json') | Out-Null
  } catch {
    $mixedSourceFailed = $_.Exception.Message -like '*cannot mix direct image files*'
  }
  Assert-True $mixedSourceFailed 'main-image mappings cannot mix detail PSD sources with direct files'
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedTemp).StartsWith('codex-dingdong-copy-tests-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
