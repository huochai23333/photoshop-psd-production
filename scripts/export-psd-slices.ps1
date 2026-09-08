param(
  [Parameter(Mandatory = $true)][string]$SourcePsdPath,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [ValidateSet('jpg', 'png')][string]$Format = 'jpg',
  [ValidateRange(0, 30000)][int]$MaxWidth = 0,
  [ValidateRange(1, 12)][int]$Quality = 10,
  [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$sourcePath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourcePsdPath).Path)
if ([IO.Path]::GetExtension($sourcePath).ToLowerInvariant() -notin @('.psd', '.psb')) {
  throw 'Source file must be a PSD or PSB.'
}
$outputFullDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputFullDirectory | Out-Null
$sourceHashBefore = Get-Sha256 $sourcePath

$tempId = [guid]::NewGuid().ToString('N')
$settingsPath = Join-Path ([IO.Path]::GetTempPath()) "codex-detail-slices-settings-$tempId.json"
$resultPath = Join-Path ([IO.Path]::GetTempPath()) "codex-detail-slices-result-$tempId.json"
Write-Utf8Json -Path $settingsPath -Value ([ordered]@{
  sourcePsdPath = $sourcePath
  outputDirectory = $outputFullDirectory
  resultPath = $resultPath
  format = $Format
  maxWidth = $MaxWidth
  quality = $Quality
  overwrite = [bool]$Overwrite
}) | Out-Null

$settingsJs = ConvertTo-JsString ($settingsPath -replace '\\', '/')
$jsx = @"
var settingsPath=$settingsJs;
function q(s){return '"'+String(s).replace(/\\/g,'\\\\').replace(/\r/g,'\\r').replace(/\n/g,'\\n').replace(/"/g,'\\"')+'"';}
function readUtf8(p){var f=new File(p);f.encoding='UTF8';if(!f.open('r'))throw new Error('Unable to read slice settings');var t=f.read();f.close();return t;}
function writeUtf8(p,t){var f=new File(p);f.encoding='UTF8';if(!f.open('w'))throw new Error('Unable to write slice result');f.write(t);f.close();}
function parseJson(t){if(typeof JSON!='undefined'&&JSON.parse)return JSON.parse(t);return eval('('+t+')');}
function norm(p){return String(p||'').replace(/\\/g,'/').replace(/\/$/,'').toLowerCase();}
function n(v){try{return Number(v.as('px'));}catch(e){}try{return Number(v.value);}catch(e2){}try{return Number(v);}catch(e3){}return 0;}
function pad4(v){var t=String(v);while(t.length<4)t='0'+t;return t;}
function pageMode(source){if(source.mode==DocumentMode.CMYK)return NewDocumentMode.CMYK;if(source.mode==DocumentMode.GRAYSCALE)return NewDocumentMode.GRAYSCALE;if(source.mode==DocumentMode.LAB)return NewDocumentMode.LAB;return NewDocumentMode.RGB;}

var s=parseJson(readUtf8(settingsPath)),source=null,pageDoc=null,opened=false,response='',baseHistory=null,previousLayer=null;
var oldUnits=app.preferences.rulerUnits,oldDialogs=app.displayDialogs;
try{
  var matches=[];
  for(var d=0;d<app.documents.length;d++){var dp='';try{dp=app.documents[d].fullName.fsName;}catch(pathError){}if(norm(dp)==norm(s.sourcePsdPath))matches.push(app.documents[d]);}
  if(matches.length>1)throw new Error('Detail PSD is open more than once');
  source=matches.length==1?matches[0]:app.open(new File(s.sourcePsdPath));opened=matches.length==0;app.activeDocument=source;
  if(!source.saved)throw new Error('Detail PSD has unsaved changes');
  app.preferences.rulerUnits=Units.PIXELS;app.displayDialogs=DialogModes.NO;baseHistory=source.activeHistoryState;try{previousLayer=source.activeLayer;}catch(activeLayerError){}

  var width=Math.round(n(source.width)),height=Math.round(n(source.height)),guidePositions=[];
  for(var g=0;g<source.guides.length;g++){
    if(source.guides[g].direction!=Direction.HORIZONTAL)continue;
    var coordinate=Math.round(n(source.guides[g].coordinate));
    if(coordinate>0&&coordinate<height)guidePositions.push(coordinate);
  }
  guidePositions.sort(function(a,b){return a-b;});
  var uniqueGuides=[];
  for(var u=0;u<guidePositions.length;u++){if(uniqueGuides.length==0||guidePositions[u]!=uniqueGuides[uniqueGuides.length-1])uniqueGuides.push(guidePositions[u]);}
  if(uniqueGuides.length<1)throw new Error('Current detail PSD has no valid interior horizontal guides; template or master guides are not allowed as a fallback');
  var boundaries=[0];for(var b=0;b<uniqueGuides.length;b++)boundaries.push(uniqueGuides[b]);boundaries.push(height);

  var outputs=[];
  for(var i=0;i<boundaries.length-1;i++){
    var top=boundaries[i],bottom=boundaries[i+1],sliceHeight=bottom-top;
    if(sliceHeight<=0)throw new Error('Current detail PSD contains a zero-height or reversed slice');
    var extension=s.format=='png'?'.png':'.jpg';
    var outFile=new File(String(s.outputDirectory).replace(/\/$/,'')+'/detail-'+pad4(i+1)+extension);
    if(outFile.exists&&s.overwrite!==true)throw new Error('Output already exists: '+outFile.fsName);

    app.activeDocument=source;source.activeHistoryState=baseHistory;
    source.selection.select([[0,top],[width,top],[width,bottom],[0,bottom]]);
    source.selection.copy(true);
    var fill=s.format=='jpg'?DocumentFill.WHITE:DocumentFill.TRANSPARENT;
    var mode=s.format=='png'?NewDocumentMode.RGB:pageMode(source);
    pageDoc=app.documents.add(width,sliceHeight,Number(source.resolution),'codex_detail_slice_'+pad4(i+1),mode,fill);
    pageDoc.paste();
    if(Number(s.maxWidth)>0&&pageDoc.width.as('px')>Number(s.maxWidth)){
      var ratio=Number(s.maxWidth)/pageDoc.width.as('px');
      pageDoc.resizeImage(UnitValue(Number(s.maxWidth),'px'),UnitValue(pageDoc.height.as('px')*ratio,'px'),null,ResampleMethod.BICUBICSHARPER);
    }
    if(s.format=='jpg'){pageDoc.flatten();var jpg=new JPEGSaveOptions();jpg.quality=Number(s.quality);pageDoc.saveAs(outFile,jpg,true,Extension.LOWERCASE);}
    else{var png=new PNGSaveOptions();png.interlaced=false;pageDoc.saveAs(outFile,png,true,Extension.LOWERCASE);}
    pageDoc.close(SaveOptions.DONOTSAVECHANGES);pageDoc=null;
    outputs.push('{"number":'+(i+1)+',"file":'+q(outFile.fsName)+',"sourceRect":[0,'+top+','+width+','+bottom+']}');
  }
  app.activeDocument=source;source.activeHistoryState=baseHistory;if(previousLayer)try{source.activeLayer=previousLayer;}catch(restoreLayerError){}
  if(opened)source.close(SaveOptions.DONOTSAVECHANGES);
  response='{"ok":true,"type":"current-detail-guides","sourceSaved":true,"canvas":{"width":'+width+',"height":'+height+'},"horizontalGuides":['+uniqueGuides.join(',')+'],"sliceCount":'+outputs.length+',"slices":['+outputs.join(',')+']}';
  writeUtf8(s.resultPath,response);
}catch(e){
  var message=String(e.message||e.toString());
  if(pageDoc)try{pageDoc.close(SaveOptions.DONOTSAVECHANGES);}catch(pageCloseError){}
  if(source&&baseHistory)try{app.activeDocument=source;source.activeHistoryState=baseHistory;}catch(historyError){}
  if(opened&&source)try{source.close(SaveOptions.DONOTSAVECHANGES);}catch(closeError){}
  response='{"ok":false,"error":'+q(message)+'}';try{writeUtf8(s.resultPath,response);}catch(writeError){}
}finally{
  try{app.preferences.rulerUnits=oldUnits;}catch(unitsError){}
  try{app.displayDialogs=oldDialogs;}catch(dialogError){}
}
response;
"@

try {
  $null = Invoke-PhotoshopJavaScript -Script $jsx
  if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Photoshop did not write a detail-slice result.' }
  $result = Read-Utf8Json $resultPath
  if ($result.ok -ne $true) { throw "Detail slice export failed: $($result.error)" }
  if ([int]$result.sliceCount -ne @($result.horizontalGuides).Count + 1) {
    throw 'Detail slice count does not match the current PSD horizontal guides.'
  }
  foreach ($slice in @($result.slices)) {
    $filePath = [string]$slice.file
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf) -or (Get-Item -LiteralPath $filePath).Length -le 0) {
      throw "Exported detail slice is missing or empty: $filePath"
    }
    $slice | Add-Member -NotePropertyName bytes -NotePropertyValue ((Get-Item -LiteralPath $filePath).Length) -Force
    $slice | Add-Member -NotePropertyName sha256 -NotePropertyValue (Get-Sha256 $filePath) -Force
  }
  if ((Get-Sha256 $sourcePath) -cne $sourceHashBefore) { throw 'Detail PSD changed during slice export.' }
  $result | Add-Member -NotePropertyName sourcePsdPath -NotePropertyValue $sourcePath -Force
  $result | Add-Member -NotePropertyName sourceSha256 -NotePropertyValue $sourceHashBefore -Force
  $result | Add-Member -NotePropertyName outputDirectory -NotePropertyValue $outputFullDirectory -Force
  $result | ConvertTo-Json -Depth 12 -Compress
} finally {
  Remove-Item -LiteralPath $settingsPath, $resultPath -Force -ErrorAction SilentlyContinue
}
