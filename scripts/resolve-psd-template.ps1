param(
  [Parameter(Mandatory = $true)][string]$TemplateId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$registryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\templates\registry.json'
$registry = Read-Utf8Json $registryPath
$matches = @($registry.templates | Where-Object { [string]$_.templateId -ceq $TemplateId })
if ($matches.Count -ne 1) { throw "Template id must resolve exactly once: $TemplateId" }
$template = $matches[0]
$psdPath = [IO.Path]::GetFullPath([string]$template.psdPath)
if (-not (Test-Path -LiteralPath $psdPath -PathType Leaf)) { throw "Template PSD is missing: $psdPath" }
$result = [ordered]@{
  ok = $true
  templateId = $TemplateId
  displayName = [string]$template.displayName
  workflow = [string]$template.workflow
  psdPath = $psdPath
  psdSha256 = Get-Sha256 $psdPath
  definitionPath = if (Test-ObjectProperty $template 'definitionPath') { Join-Path (Split-Path -Parent $registryPath) ([string]$template.definitionPath) } else { $null }
  indexPath = if (Test-ObjectProperty $template 'indexPath') { Join-Path (Split-Path -Parent $registryPath) ([string]$template.indexPath) } else { $null }
  warnings = @()
}
$result | ConvertTo-Json -Depth 12 -Compress
