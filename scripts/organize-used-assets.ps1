param(
  [Parameter(Mandatory = $true)][string]$PsdPath,
  [Parameter(Mandatory = $true)][string]$WorkDir,
  [string]$JournalPath,
  [string]$UsedFolderName = '已使用',
  [int[]]$SourceLayerIds = @(),
  [string[]]$Extensions = @('.jpg', '.jpeg', '.png', '.webp', '.tif', '.tiff', '.bmp')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$resolvedPsdPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $PsdPath).Path)
$resolvedWorkDir = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkDir).Path).TrimEnd('\')
$usedDir = [IO.Path]::GetFullPath((Join-Path $resolvedWorkDir $UsedFolderName))
if (-not $JournalPath) { $JournalPath = Join-Path $resolvedWorkDir '.used-assets-journal.json' }
$resolvedJournalPath = [IO.Path]::GetFullPath($JournalPath)

function Test-IsWithinRoot {
  param([string]$Path, [string]$Root)
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  return $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
    $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-UniqueDestination {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $Path }
  $directory = Split-Path -Parent $Path
  $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
  $extension = [IO.Path]::GetExtension($Path)
  for ($number = 2; $number -le 999; $number++) {
    $candidate = Join-Path $directory "$stem-$number$extension"
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  throw "Unable to create a unique used-asset filename for $Path"
}

function Get-LayerSelectionKey {
  param([AllowNull()][object[]]$Values)

  return (@($Values | ForEach-Object { [int]$_ } | Sort-Object -Unique) -join ',')
}

function Get-UniqueJournalArchivePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$PsdSha256
  )

  $directory = Split-Path -Parent $Path
  $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
  $hashPrefix = $PsdSha256.Substring(0, 12)
  for ($number = 1; $number -le 999; $number++) {
    $suffix = if ($number -eq 1) { '' } else { "-$number" }
    $candidate = Join-Path $directory "$stem.$hashPrefix.complete$suffix.json"
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  throw "Unable to create a unique used-assets journal archive for $Path"
}

if (-not (Test-IsWithinRoot -Path $usedDir -Root $resolvedWorkDir)) {
  throw "Used-assets folder must stay inside the work directory: $usedDir"
}

$reuseJournal = $false
if (Test-Path -LiteralPath $resolvedJournalPath -PathType Leaf) {
  $journal = Read-Utf8Json $resolvedJournalPath
  if ([string]$journal.psdPath -cne $resolvedPsdPath -or [string]$journal.workDir -cne $resolvedWorkDir) {
    throw 'Existing used-assets journal belongs to another task.'
  }
  $currentPsdSha256 = Get-Sha256 $resolvedPsdPath
  $journalSelection = if (Test-ObjectProperty $journal 'sourceLayerIds') { @($journal.sourceLayerIds) } else { @() }
  $selectionMatches = (Get-LayerSelectionKey $journalSelection) -ceq (Get-LayerSelectionKey $SourceLayerIds)
  $journalLooksEmpty = -not (Test-ObjectProperty $journal 'smartObjectCount') -or [int]$journal.smartObjectCount -le 0
  if ($currentPsdSha256 -cne [string]$journal.psdSha256 -or -not $selectionMatches -or $journalLooksEmpty) {
    if ([string]$journal.state -ne 'complete') {
      $reason = if ($journalLooksEmpty) { 'journal contains no smart-object scan' } elseif (-not $selectionMatches) { 'selection scope changed' } else { 'PSD changed' }
      throw "$reason while an incomplete used-assets journal exists."
    }
    $archivePath = Get-UniqueJournalArchivePath -Path $resolvedJournalPath -PsdSha256 ([string]$journal.psdSha256)
    Move-Item -LiteralPath $resolvedJournalPath -Destination $archivePath
  } else {
    $reuseJournal = $true
  }
}
if (-not $reuseJournal) {
  $psdState = Get-OpenPhotoshopDocumentState -Path $resolvedPsdPath
  if ($psdState.count -gt 1 -or ($psdState.count -eq 1 -and $psdState.documents[0].saved -ne $true)) {
    throw 'PSD is open with an unsafe unsaved state.'
  }
  $tempResultPath = Join-Path $env:TEMP "codex-used-assets-$([guid]::NewGuid().ToString('N')).json"
  $psdJs = ConvertTo-JsString ($resolvedPsdPath -replace '\\', '/')
  $resultJs = ConvertTo-JsString ($tempResultPath -replace '\\', '/')
  $jsx = @"
var psdPath=$psdJs,resultPath=$resultJs;
function q(s){return '"'+String(s).replace(/\\/g,'\\\\').replace(/\r/g,'\\r').replace(/\n/g,'\\n').replace(/"/g,'\\"')+'"';}
function writeUtf8(p,t){var f=new File(p);f.encoding='UTF8';if(!f.open('w'))throw new Error('Unable to write asset scan');f.write(t);f.close();}
function norm(p){return String(p||'').replace(/\\/g,'/').replace(/\/$/,'').toLowerCase();}
function docPath(d){try{return d.fullName.fsName;}catch(e){return '';}}
function smartObjectReference(layer){
  try{
    if(layer.kind!=LayerKind.SMARTOBJECT)return '';
    var ref=new ActionReference();ref.putIdentifier(charIDToTypeID('Lyr '),layer.id);
    var desc=executeActionGet(ref),key=stringIDToTypeID('smartObject');if(!desc.hasKey(key))return '';
    var so=desc.getObjectValue(key),fileKey=stringIDToTypeID('fileReference');if(!so.hasKey(fileKey))return '';
    var type=so.getType(fileKey);if(type==DescValueType.STRINGTYPE)return so.getString(fileKey);if(type==DescValueType.ALIASTYPE)return so.getPath(fileKey).fsName;
  }catch(e){}return '';
}
function effectiveVisible(layer){var current=layer;while(current&&current.typename!='Document'){if(current.visible!==true)return false;try{current=current.parent;}catch(e){break;}}return true;}
function walk(container,path,rows){
  for(var i=0;i<container.layers.length;i++){var layer=container.layers[i],current=path?path+'/'+layer.name:layer.name;
    if(layer.typename=='ArtLayer'){var file=smartObjectReference(layer);if(file&&effectiveVisible(layer))rows.push('{"id":'+layer.id+',"name":'+q(layer.name)+',"path":'+q(current)+',"fileReference":'+q(file)+'}');}
    else if(layer.typename=='LayerSet')walk(layer,current,rows);
  }
}
var matches=[],doc=null,opened=false,rows=[],priorActive=null;
try{if(app.documents.length>0)priorActive=app.activeDocument;}catch(e){}
for(var i=0;i<app.documents.length;i++)if(norm(docPath(app.documents[i]))==norm(psdPath))matches.push(app.documents[i]);
if(matches.length>1)throw new Error('PSD is open more than once');
doc=matches.length==1?matches[0]:app.open(new File(psdPath));opened=matches.length==0;
try{
  app.activeDocument=doc;
  if(!doc.saved)throw new Error('PSD has unsaved changes');
  walk(doc,'',rows);
}finally{
  if(opened)try{doc.close(SaveOptions.DONOTSAVECHANGES);}catch(e){}
  if(priorActive)try{app.activeDocument=priorActive;}catch(e){}
}
var result='{"smartObjectCount":'+rows.length+',"smartObjects":['+rows.join(',')+']}';writeUtf8(resultPath,result);result;
"@
  try {
    $raw = Invoke-PhotoshopJavaScript -Script $jsx
    if (Test-Path -LiteralPath $tempResultPath -PathType Leaf) {
      $raw = [IO.File]::ReadAllText($tempResultPath, $script:PsdJobUtf8NoBom)
    }
    $scan = $raw | ConvertFrom-Json
    if ([int]$scan.smartObjectCount -le 0) {
      throw 'No visible smart objects were found in the target PSD; refusing to create an empty complete journal.'
    }
  } finally {
    Remove-Item -LiteralPath $tempResultPath -Force -ErrorAction SilentlyContinue
  }

  $extensionSet = @{}
  foreach ($extension in $Extensions) {
    $normalized = $extension.ToLowerInvariant()
    if (-not $normalized.StartsWith('.')) { $normalized = ".$normalized" }
    $extensionSet[$normalized] = $true
  }
  $seen = @{}
  $items = @()
  $sourceLayerIdSet = @{}
  foreach ($sourceLayerId in $SourceLayerIds) { $sourceLayerIdSet[[string]$sourceLayerId] = $true }
  foreach ($smartObject in @($scan.smartObjects)) {
    if ($sourceLayerIdSet.Count -gt 0 -and -not $sourceLayerIdSet.ContainsKey([string]$smartObject.id)) { continue }
    $reference = [string]$smartObject.fileReference
    $name = [IO.Path]::GetFileName($reference.Replace('/', '\'))
    if (-not $name) { continue }
    $key = $name.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    if (-not $extensionSet.ContainsKey($extension)) {
      $items += [pscustomobject]@{ state = 'skipped'; action = 'unsupported-extension'; name = $name; source = ''; destination = '' }
      continue
    }
    $referenceCandidate = $reference.Replace('/', '\')
    $source = if ([IO.Path]::IsPathRooted($referenceCandidate)) { [IO.Path]::GetFullPath($referenceCandidate) } else { [IO.Path]::GetFullPath((Join-Path $resolvedWorkDir $name)) }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $source = [IO.Path]::GetFullPath((Join-Path $resolvedWorkDir $name)) }
    $destination = [IO.Path]::GetFullPath((Join-Path $usedDir $name))
    if (-not (Test-IsWithinRoot -Path $source -Root $resolvedWorkDir) -or (Split-Path -Parent $source) -cne $resolvedWorkDir) {
      throw "Asset source must be a root-level file in the work directory: $source"
    }
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      $sourceHash = Get-Sha256 $source
      if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $destinationHash = Get-Sha256 $destination
        if ($sourceHash -ceq $destinationHash) {
        $items += [pscustomobject]@{ state = 'pending'; action = 'remove-duplicate'; layerId = [int]$smartObject.id; reference = $reference; name = $name; source = $source; destination = $destination; sourceSha256 = $sourceHash }
        } else {
          $items += [pscustomobject]@{ state = 'pending'; action = 'move'; layerId = [int]$smartObject.id; reference = $reference; name = $name; source = $source; destination = [IO.Path]::GetFullPath((Get-UniqueDestination $destination)); sourceSha256 = $sourceHash }
        }
      } else {
        $items += [pscustomobject]@{ state = 'pending'; action = 'move'; layerId = [int]$smartObject.id; reference = $reference; name = $name; source = $source; destination = $destination; sourceSha256 = $sourceHash }
      }
    } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
      $items += [pscustomobject]@{ state = 'complete'; action = 'already-organized'; name = $name; source = ''; destination = $destination; destinationSha256 = Get-Sha256 $destination }
    } else {
      $items += [pscustomobject]@{ state = 'skipped'; action = 'not-in-workdir'; name = $name; source = $source; destination = $destination }
    }
  }
  $journal = [pscustomobject]@{
    journalVersion = 2
    state = 'prepared'
    psdPath = $resolvedPsdPath
    psdSha256 = Get-Sha256 $resolvedPsdPath
    workDir = $resolvedWorkDir
    usedDir = $usedDir
    smartObjectCount = [int]$scan.smartObjectCount
    sourceLayerIds = @($SourceLayerIds)
    items = @($items)
  }
  Write-Utf8Json -Path $resolvedJournalPath -Value $journal | Out-Null
}

New-Item -ItemType Directory -Force -Path $journal.usedDir | Out-Null
for ($index = 0; $index -lt @($journal.items).Count; $index++) {
  $item = $journal.items[$index]
  if ([string]$item.state -ne 'pending') { continue }
  if (-not (Test-Path -LiteralPath $item.source -PathType Leaf)) { throw "Pending asset source is missing: $($item.source)" }
  if ((Get-Sha256 $item.source) -cne [string]$item.sourceSha256) { throw "Pending asset changed: $($item.source)" }
  if ([string]$item.action -eq 'remove-duplicate') {
    if (-not (Test-Path -LiteralPath $item.destination -PathType Leaf) -or
        (Get-Sha256 $item.destination) -cne [string]$item.sourceSha256) {
      throw "Duplicate destination is missing or different: $($item.destination)"
    }
    Remove-Item -LiteralPath $item.source -Force
  } elseif ([string]$item.action -eq 'move') {
    if (Test-Path -LiteralPath $item.destination) { throw "Asset destination appeared during organization: $($item.destination)" }
    Move-Item -LiteralPath $item.source -Destination $item.destination
    if ((Get-Sha256 $item.destination) -cne [string]$item.sourceSha256) { throw "Moved asset hash mismatch: $($item.destination)" }
  } else {
    throw "Unsupported pending asset action: $($item.action)"
  }
  $item.state = 'complete'
  $item | Add-Member -NotePropertyName completedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('o')) -Force
  Write-Utf8Json -Path $resolvedJournalPath -Value $journal | Out-Null
}

$journal.state = 'complete'
Write-Utf8Json -Path $resolvedJournalPath -Value $journal | Out-Null
$journal | ConvertTo-Json -Depth 20 -Compress
