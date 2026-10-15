$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-dingdong-suite-' + [guid]::NewGuid().ToString('N'))
$isolatedSkill = Join-Path $testRoot 'skill'
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
  # 只在隔离副本中替换测试文件路径，实际登记、母版及产品文件均不改动。
  Copy-Item -LiteralPath $skillRoot -Destination $isolatedSkill -Recurse
  $registryPath = Join-Path $isolatedSkill 'assets/templates/registry.json'
  $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json
  $fixtureDirectory = Join-Path $testRoot 'fixtures'
  New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
  foreach ($template in @($registry.templates)) {
    $fixturePath = Join-Path $fixtureDirectory ($template.templateId + '.psd')
    # 这些字节仅供任务路径和哈希检查；绝不能当作真实 PSD 的渲染验证。
    [IO.File]::WriteAllBytes($fixturePath, [byte[]]@(56, 66, 80, 83))
    $template.psdPath = $fixturePath
  }
  [IO.File]::WriteAllText($registryPath, ($registry | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))

  # 测试覆盖自然改写、保护拒绝、确认绑定和主图映射；不启动 Photoshop。
  foreach ($name in @(
      'test-dingdong-natural-copy.tests.ps1',
      'test-dingdong-copy-compliance.tests.ps1',
      'test-dingdong-fast-pipeline.tests.ps1'
    )) {
    & (Join-Path $isolatedSkill "scripts/$name")
  }
  'PASS: isolated copy suite completed; Photoshop rendering remains untested'
} finally {
  # 删除前核对绝对路径与本脚本创建的唯一前缀，防止清理到用户资源。
  $absoluteRoot = [IO.Path]::GetFullPath($testRoot)
  $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($absoluteRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($absoluteRoot).StartsWith('codex-dingdong-suite-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $absoluteRoot -Recurse
    if (Test-Path -LiteralPath $absoluteRoot) { throw '隔离测试目录清理失败。' }
  }
}
