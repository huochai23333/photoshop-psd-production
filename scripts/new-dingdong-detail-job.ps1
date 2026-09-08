param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('dingdong-haoshiguang-detail-1step', 'dingdong-haoshiguang-detail-2step', 'dingdong-haoshiguang-detail-3step', 'dingdong-haoshiguang-detail-4step')]
  [string]$TemplateId,
  [Parameter(Mandatory = $true)][string]$CopyPath,
  [Parameter(Mandatory = $true)][string]$ApprovedCopySha256,
  [Parameter(Mandatory = $true)][string]$TargetPsdPath,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [string]$FinalJpgPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
. (Join-Path $PSScriptRoot 'dingdong-copy-common.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$copyFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CopyPath).Path)
$compliance = Test-DingdongCopyCompliance `
  -CopyPath $copyFullPath `
  -SkillRoot $skillRoot `
  -ExpectedSha256 $ApprovedCopySha256
if (-not $compliance.ok) {
  $messages = @($compliance.errors | ForEach-Object { "$([string]$_.code): $([string]$_.message)" })
  throw "Dingdong copy validation failed before job creation: $($messages -join ' | ')"
}
if ([string]$compliance.templateId -cne $TemplateId) {
  throw "copy.json templateId does not match -TemplateId: $($compliance.templateId)"
}
$copy = Read-Utf8Json $copyFullPath
$copyReplacements = [object[]]::new(0)
if (@($copy.textReplacements).Count -gt 0) { $copyReplacements = [object[]]@($copy.textReplacements) }
$final = if ($FinalJpgPath) {
  [pscustomobject]@{ type = 'document-jpg'; path = [IO.Path]::GetFullPath($FinalJpgPath); maxWidth = 750; quality = 12 }
} else {
  $null
}
$job = [ordered]@{
  jobVersion = 1
  workflow = 'dingdong-detail'
  source = [ordered]@{ templateId = $TemplateId }
  targetPsdPath = [IO.Path]::GetFullPath($TargetPsdPath)
  copyReview = [ordered]@{
    copyPath = $copyFullPath
    copySha256 = $compliance.copySha256
    copyVersion = 2
  }
  textReplacements = $copyReplacements
  imageTransfers = @()
  outputs = [ordered]@{
    preview = [ordered]@{ enabled = $true; maxWidth = 1500; quality = 10 }
    final = $final
  }
  organizeUsedAssets = $false
}
Write-Utf8Json -Path $OutputPath -Value $job | Out-Null
Get-Content -LiteralPath $OutputPath -Encoding UTF8 -Raw
