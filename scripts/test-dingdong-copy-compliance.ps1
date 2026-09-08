param(
  [Parameter(Mandatory = $true)]
  [Alias('OperationPath')]
  [string]$CopyPath,

  [string]$ExpectedSha256,

  [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$result = Test-DingdongCopyCompliance `
  -CopyPath $CopyPath `
  -SkillRoot $skillRoot `
  -ExpectedSha256 $ExpectedSha256

if ($ResultPath) {
  Write-Utf8Json -Path $ResultPath -Value $result | Out-Null
}
$result | ConvertTo-Json -Depth 30
if (-not $result.ok) { exit 2 }
