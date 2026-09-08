param(
  [Parameter(Mandatory = $true)][string]$SourcePsdPath,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [int]$MaxWidth = 0,
  [ValidateRange(1, 12)][int]$Quality = 10,
  [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$sourcePath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourcePsdPath).Path)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($sourcePath).ToLowerInvariant() -notin @('.psd', '.psb')) { throw 'Source must be a PSD or PSB.' }
if ([IO.Path]::GetExtension($outputFullPath).ToLowerInvariant() -notin @('.jpg', '.jpeg')) { throw 'Output must use .jpg or .jpeg.' }
if ($MaxWidth -lt 0 -or $MaxWidth -gt 30000) { throw 'MaxWidth must be between 0 and 30000.' }
if ((Test-Path -LiteralPath $outputFullPath) -and -not $Overwrite) { throw "Output already exists: $outputFullPath" }
$outputDirectory = Split-Path -Parent $outputFullPath
if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
$sourceHashBefore = Get-Sha256 $sourcePath

$settingsPath = Join-Path $env:TEMP "codex-psd-jpg-$([guid]::NewGuid().ToString('N')).json"
$resultPath = Join-Path $env:TEMP "codex-psd-jpg-result-$([guid]::NewGuid().ToString('N')).json"
Write-Utf8Json -Path $settingsPath -Value ([ordered]@{
  sourcePsdPath = $sourcePath
  outputPath = $outputFullPath
  maxWidth = $MaxWidth
  quality = $Quality
}) | Out-Null
$settingsJs = ConvertTo-JsString ($settingsPath -replace '\\', '/')
$resultJs = ConvertTo-JsString ($resultPath -replace '\\', '/')
$jsx = @"
var settingsPath=$settingsJs,resultPath=$resultJs;
function q(s){return '"'+String(s).replace(/\\/g,'\\\\').replace(/\r/g,'\\r').replace(/\n/g,'\\n').replace(/"/g,'\\"')+'"';}
function readUtf8(p){var f=new File(p);f.encoding='UTF8';if(!f.open('r'))throw new Error('Unable to read export settings');var t=f.read();f.close();return t;}
function writeUtf8(p,t){var f=new File(p);f.encoding='UTF8';if(!f.open('w'))throw new Error('Unable to write export result');f.write(t);f.close();}
function parseJson(t){if(typeof JSON!='undefined'&&JSON.parse)return JSON.parse(t);return eval('('+t+')');}
function norm(p){return String(p||'').replace(/\\/g,'/').replace(/\/$/,'').toLowerCase();}
function docPath(d){try{return d.fullName.fsName;}catch(e){return '';}}
var s=parseJson(readUtf8(settingsPath)),matches=[],doc=null,opened=false,dup=null,response='';
try{
  for(var i=0;i<app.documents.length;i++)if(norm(docPath(app.documents[i]))==norm(s.sourcePsdPath))matches.push(app.documents[i]);
  if(matches.length>1)throw new Error('PSD is open more than once');
  doc=matches.length==1?matches[0]:app.open(new File(s.sourcePsdPath));opened=matches.length==0;
  if(!doc.saved)throw new Error('PSD has unsaved changes');
  app.activeDocument=doc;dup=doc.duplicate('codex-psd-jpg-export',true);app.activeDocument=dup;
  var width=dup.width.as('px'),height=dup.height.as('px');
  if(Number(s.maxWidth)>0&&width>Number(s.maxWidth)){var ratio=Number(s.maxWidth)/width;dup.resizeImage(UnitValue(Number(s.maxWidth),'px'),UnitValue(height*ratio,'px'),null,ResampleMethod.BICUBICSHARPER);}
  var options=new JPEGSaveOptions();options.quality=Number(s.quality);dup.saveAs(new File(s.outputPath),options,true,Extension.LOWERCASE);
  var outWidth=Math.round(dup.width.as('px')),outHeight=Math.round(dup.height.as('px'));dup.close(SaveOptions.DONOTSAVECHANGES);dup=null;
  if(opened)doc.close(SaveOptions.DONOTSAVECHANGES);
  response='{"ok":true,"type":"document-jpg","outputPath":'+q(new File(s.outputPath).fsName)+',"widthPx":'+outWidth+',"heightPx":'+outHeight+',"quality":'+Number(s.quality)+'}';
  writeUtf8(resultPath,response);
}catch(e){
  try{if(dup)dup.close(SaveOptions.DONOTSAVECHANGES);}catch(ignore){}
  try{if(opened&&doc)doc.close(SaveOptions.DONOTSAVECHANGES);}catch(ignore2){}
  response='{"ok":false,"error":'+q(e.message||e.toString())+'}';
  try{writeUtf8(resultPath,response);}catch(ignore3){}
}
response;
"@

try {
  $raw = Invoke-PhotoshopJavaScript -Script $jsx
  if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
    $raw = [IO.File]::ReadAllText($resultPath, $script:PsdJobUtf8NoBom)
  }
  $result = $raw | ConvertFrom-Json
  if ($result.ok -ne $true) { throw "JPG export failed: $($result.error)" }
  if (-not (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) { throw 'JPG output was not created.' }
  if ((Get-Sha256 $sourcePath) -cne $sourceHashBefore) { throw 'Source PSD changed during JPG export.' }
  $result | Add-Member -NotePropertyName outputSha256 -NotePropertyValue (Get-Sha256 $outputFullPath) -Force
  $result | Add-Member -NotePropertyName outputBytes -NotePropertyValue ((Get-Item -LiteralPath $outputFullPath).Length) -Force
  $result | ConvertTo-Json -Depth 10 -Compress
} finally {
  Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
}
