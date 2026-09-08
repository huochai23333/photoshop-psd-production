param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$TemplateId,
  [Parameter(Mandatory = $true)][string]$DisplayName,
  [Parameter(Mandatory = $true)][string]$Workflow,
  [Parameter(Mandatory = $true)][string]$PsdPath,
  [string]$UsageScenario = '',
  [string]$DefinitionPath = '',
  [string]$IndexPath = '',
  [string]$TaskTemplatePath = '',
  [switch]$OverwriteRegistration
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$resolvedPsd = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $PsdPath).Path)
if ([IO.Path]::GetExtension($resolvedPsd).ToLowerInvariant() -notin @('.psd', '.psb')) { throw 'Template must be a PSD or PSB.' }
$registryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\templates\registry.json'
$registry = Read-Utf8Json $registryPath
$existing = @($registry.templates | Where-Object { [string]$_.templateId -ceq $TemplateId })
if ($existing.Count -gt 0 -and -not $OverwriteRegistration) {
  throw "Template already exists. Re-run with -OverwriteRegistration only when replacement was explicitly requested: $TemplateId"
}
$entry = [ordered]@{
  templateId = $TemplateId
  displayName = $DisplayName
  workflow = $Workflow
  usageScenario = $UsageScenario
  psdPath = $resolvedPsd -replace '\\', '/'
}
if ($DefinitionPath) { $entry.definitionPath = $DefinitionPath -replace '\\', '/' }
if ($IndexPath) { $entry.indexPath = $IndexPath -replace '\\', '/' }
if ($TaskTemplatePath) { $entry.taskTemplatePath = $TaskTemplatePath -replace '\\', '/' }
$remaining = @($registry.templates | Where-Object { [string]$_.templateId -cne $TemplateId })
$registry.templates = @($remaining) + @([pscustomobject]$entry)
Write-Utf8Json -Path $registryPath -Value $registry | Out-Null
[ordered]@{
  ok = $true
  templateId = $TemplateId
  overwritten = $existing.Count -gt 0
  psdPath = $resolvedPsd
  psdSha256 = Get-Sha256 $resolvedPsd
} | ConvertTo-Json -Compress
