param(
  [Parameter(Mandatory = $true)][string]$ProductDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$productRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ProductDirectory).Path).TrimEnd('\')
if (-not (Test-Path -LiteralPath $productRoot -PathType Container)) { throw "Product directory is missing: $productRoot" }
$candidates = @(Get-ChildItem -LiteralPath $productRoot -File | Where-Object {
  $_.Extension.ToLowerInvariant() -in @('.psd', '.psb')
} | Sort-Object FullName)
if ($candidates.Count -lt 2) { throw 'The specified directory must contain the saved detail PSD and main-image PSD at its root.' }

$settingsPath = Join-Path ([IO.Path]::GetTempPath()) "codex-export-discovery-$([guid]::NewGuid().ToString('N')).json"
$resultPath = Join-Path ([IO.Path]::GetTempPath()) "codex-export-discovery-result-$([guid]::NewGuid().ToString('N')).json"
Write-Utf8Json -Path $settingsPath -Value ([ordered]@{
  paths = @($candidates.FullName)
  resultPath = $resultPath
}) | Out-Null
$settingsJs = ConvertTo-JsString ($settingsPath -replace '\\', '/')

$jsx = @"
var settingsPath=$settingsJs;
function q(s){return '"'+String(s).replace(/\\/g,'\\\\').replace(/\r/g,'\\r').replace(/\n/g,'\\n').replace(/"/g,'\\"')+'"';}
function readUtf8(p){var f=new File(p);f.encoding='UTF8';if(!f.open('r'))throw new Error('Unable to read discovery settings');var t=f.read();f.close();return t;}
function writeUtf8(p,t){var f=new File(p);f.encoding='UTF8';if(!f.open('w'))throw new Error('Unable to write discovery result');f.write(t);f.close();}
function parseJson(t){if(typeof JSON!='undefined'&&JSON.parse)return JSON.parse(t);return eval('('+t+')');}
function norm(p){return String(p||'').replace(/\\/g,'/').replace(/\/$/,'').toLowerCase();}
function n(v){try{return Number(v.as('px'));}catch(e){}try{return Number(v.value);}catch(e2){}try{return Number(v);}catch(e3){}return 0;}
function descriptorNumber(desc,key){var type=desc.getType(key);if(type==DescValueType.UNITDOUBLE)return desc.getUnitDoubleValue(key);if(type==DescValueType.DOUBLETYPE)return desc.getDouble(key);if(type==DescValueType.INTEGERTYPE)return desc.getInteger(key);throw new Error('Unsupported descriptor number type');}
function artboardRect(doc,layer){doc.activeLayer=layer;var ref=new ActionReference();ref.putEnumerated(charIDToTypeID('Lyr '),charIDToTypeID('Ordn'),charIDToTypeID('Trgt'));var desc=executeActionGet(ref),key=stringIDToTypeID('artboard');if(!desc.hasKey(key))return null;var board=desc.getObjectValue(key),rect=board.getObjectValue(stringIDToTypeID('artboardRect'));return[descriptorNumber(rect,stringIDToTypeID('left')),descriptorNumber(rect,stringIDToTypeID('top')),descriptorNumber(rect,stringIDToTypeID('right')),descriptorNumber(rect,stringIDToTypeID('bottom'))];}

var s=parseJson(readUtf8(settingsPath)),rows=[],prior=null,response='';try{if(app.documents.length)prior=app.activeDocument;}catch(noPrior){}
try{
  for(var p=0;p<s.paths.length;p++){
    var wanted=String(s.paths[p]),matches=[],doc=null,opened=false,previousLayer=null;
    for(var d=0;d<app.documents.length;d++){var dp='';try{dp=app.documents[d].fullName.fsName;}catch(pathError){}if(norm(dp)==norm(wanted))matches.push(app.documents[d]);}
    if(matches.length>1)throw new Error('PSD is open more than once: '+wanted);
    doc=matches.length==1?matches[0]:app.open(new File(wanted));opened=matches.length==0;app.activeDocument=doc;try{previousLayer=doc.activeLayer;}catch(activeLayerError){}
    try{
      var boards=[];
      for(var i=0;i<doc.layerSets.length;i++){var rect=null;try{rect=artboardRect(doc,doc.layerSets[i]);}catch(notArtboard){}if(rect)boards.push('{"name":'+q(doc.layerSets[i].name)+',"rect":['+rect.join(',')+']}');}
      var guides=[];
      for(var g=0;g<doc.guides.length;g++){if(doc.guides[g].direction==Direction.HORIZONTAL){var coordinate=Math.round(n(doc.guides[g].coordinate));if(coordinate>0&&coordinate<Math.round(n(doc.height)))guides.push(coordinate);}}
      guides.sort(function(a,b){return a-b;});var unique=[];for(var u=0;u<guides.length;u++){if(unique.length==0||guides[u]!=unique[unique.length-1])unique.push(guides[u]);}
      rows.push('{"path":'+q(wanted)+',"saved":'+(doc.saved===true)+',"width":'+Math.round(n(doc.width))+',"height":'+Math.round(n(doc.height))+',"artboardCount":'+boards.length+',"artboards":['+boards.join(',')+'],"horizontalGuides":['+unique.join(',')+']}');
      if(previousLayer)try{doc.activeLayer=previousLayer;}catch(restoreLayerError){}
    }finally{if(opened&&doc)doc.close(SaveOptions.DONOTSAVECHANGES);}
  }
  response='{"ok":true,"documents":['+rows.join(',')+']}';writeUtf8(s.resultPath,response);
}catch(e){response='{"ok":false,"error":'+q(e.message||e.toString())+'}';try{writeUtf8(s.resultPath,response);}catch(writeError){}
}finally{if(prior)try{app.activeDocument=prior;}catch(restoreDocumentError){}}
response;
"@

try {
  $null = Invoke-PhotoshopJavaScript -Script $jsx
  if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Photoshop did not write a PSD discovery result.' }
  $scan = Read-Utf8Json $resultPath
  if ($scan.ok -ne $true) { throw "PSD discovery failed: $($scan.error)" }
  $unsaved = @($scan.documents | Where-Object { $_.saved -ne $true })
  if ($unsaved.Count -gt 0) { throw "Export sources must be saved before discovery: $(@($unsaved.path) -join '; ')" }

  $expectedMainNames = @('0', '1', '2', '3', '4', '5', '6', '7')
  $mainCandidates = @($scan.documents | Where-Object {
    $names = @($_.artboards | ForEach-Object { [string]$_.name })
    [int]$_.artboardCount -eq 8 -and
      ((@($names | Sort-Object) -join '|') -ceq (@($expectedMainNames | Sort-Object) -join '|'))
  })
  $detailCandidates = @($scan.documents | Where-Object {
    [int]$_.artboardCount -eq 0 -and [int]$_.height -gt [int]$_.width -and @($_.horizontalGuides).Count -gt 0
  })

  if ($detailCandidates.Count -ne 1 -or $mainCandidates.Count -ne 1) {
    $summary = @($scan.documents | ForEach-Object {
      "$([IO.Path]::GetFileName([string]$_.path)): $($_.width)x$($_.height), artboards=$($_.artboardCount), horizontalGuides=$(@($_.horizontalGuides).Count)"
    }) -join '; '
    throw "Expected exactly one current detail PSD with its own horizontal guides and one main PSD with artboards 0-7. Found detail=$($detailCandidates.Count), main=$($mainCandidates.Count). $summary"
  }

  [pscustomobject][ordered]@{
    ok = $true
    productDirectory = $productRoot
    discoveryRule = 'current-product-psd-structure-only'
    detailPsdPath = [IO.Path]::GetFullPath([string]$detailCandidates[0].path)
    detailHorizontalGuides = @($detailCandidates[0].horizontalGuides | ForEach-Object { [int]$_ })
    detailCanvas = [pscustomobject]@{ width = [int]$detailCandidates[0].width; height = [int]$detailCandidates[0].height }
    mainPsdPath = [IO.Path]::GetFullPath([string]$mainCandidates[0].path)
    mainArtboardNames = @('0', '1', '2', '3', '4', '5', '6', '7')
  } | ConvertTo-Json -Depth 8 -Compress
} finally {
  Remove-Item -LiteralPath $settingsPath, $resultPath -Force -ErrorAction SilentlyContinue
}
