param(
  [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$app = Get-RunningPhotoshopApplication

$jsx = @'
function q(s) {
  return '"' + String(s)
    .replace(/\\/g, '\\\\')
    .replace(/\r/g, '\\r')
    .replace(/\n/g, '\\n')
    .replace(/"/g, '\\"') + '"';
}

function n(v) {
  try { return Number(v.as("px")); } catch (e) {}
  try { return Number(v.value); } catch (e2) {}
  try { return Number(v); } catch (e3) {}
  return 0;
}

function descriptorNumber(desc, key) {
  var type = desc.getType(key);
  if (type == DescValueType.UNITDOUBLE) return desc.getUnitDoubleValue(key);
  if (type == DescValueType.DOUBLETYPE) return desc.getDouble(key);
  if (type == DescValueType.INTEGERTYPE) return desc.getInteger(key);
  return 0;
}

function artboardRect(doc, layer) {
  doc.activeLayer = layer;
  var ref = new ActionReference();
  ref.putEnumerated(charIDToTypeID("Lyr "), charIDToTypeID("Ordn"), charIDToTypeID("Trgt"));
  var desc = executeActionGet(ref);
  var artboardKey = stringIDToTypeID("artboard");
  if (!desc.hasKey(artboardKey)) return null;
  var artboard = desc.getObjectValue(artboardKey);
  var rect = artboard.getObjectValue(stringIDToTypeID("artboardRect"));
  return [
    descriptorNumber(rect, stringIDToTypeID("left")),
    descriptorNumber(rect, stringIDToTypeID("top")),
    descriptorNumber(rect, stringIDToTypeID("right")),
    descriptorNumber(rect, stringIDToTypeID("bottom"))
  ];
}

var doc = app.activeDocument;
var activeLayer = null;
try { activeLayer = doc.activeLayer; } catch (activeLayerError) {}
var fullName = '';
try { fullName = doc.fullName.fsName; } catch (pathError) {}
var artboardCount = 0;
for (var i = 0; i < doc.layerSets.length; i++) {
  try { if (artboardRect(doc, doc.layerSets[i])) artboardCount++; } catch (notArtboard) {}
}
if (activeLayer) try { doc.activeLayer = activeLayer; } catch (restoreLayerError) {}

'{' +
  '"name":' + q(doc.name) + ',' +
  '"path":' + q(fullName) + ',' +
  '"saved":' + (doc.saved === true) + ',' +
  '"width":' + n(doc.width) + ',' +
  '"height":' + n(doc.height) + ',' +
  '"artboardCount":' + artboardCount + ',' +
  '"openDocumentCount":' + app.documents.length + ',' +
  '"photoshopVersion":' + q(app.version) +
'}';
'@

$photoshopInfo = $app.DoJavaScript($jsx) | ConvertFrom-Json
$documentPath = [string]$photoshopInfo.path
$file = $null
$fileSizeBytes = $null
$format = $null
$freeDiskBytes = $null

if ($documentPath -and (Test-Path -LiteralPath $documentPath -PathType Leaf)) {
  $file = Get-Item -LiteralPath $documentPath
  $fileSizeBytes = [int64]$file.Length
  $format = $file.Extension.TrimStart('.').ToUpperInvariant()
  $root = [IO.Path]::GetPathRoot($file.FullName)
  if ($root) {
    $drive = [IO.DriveInfo]::new($root)
    if ($drive.IsReady) { $freeDiskBytes = [int64]$drive.AvailableFreeSpace }
  }
} elseif ($photoshopInfo.name) {
  $format = [IO.Path]::GetExtension([string]$photoshopInfo.name).TrimStart('.').ToUpperInvariant()
}

$width = [double]$photoshopInfo.width
$height = [double]$photoshopInfo.height
$pixelCount = $width * $height
$reasons = [System.Collections.Generic.List[string]]::new()
if ($format -eq 'PSB') { $reasons.Add('format-is-psb') }
if ($null -ne $fileSizeBytes -and $fileSizeBytes -gt 1GB) { $reasons.Add('file-over-1gb') }
if ([int]$photoshopInfo.artboardCount -gt 20) { $reasons.Add('artboards-over-20') }
if ($width -gt 100000 -or $height -gt 100000 -or $pixelCount -gt 500000000) { $reasons.Add('extremely-large-canvas') }

$result = [ordered]@{
  ok = $true
  name = [string]$photoshopInfo.name
  path = $documentPath
  format = $format
  saved = [bool]$photoshopInfo.saved
  fileSizeBytes = $fileSizeBytes
  fileSizeGB = if ($null -eq $fileSizeBytes) { $null } else { [math]::Round($fileSizeBytes / 1GB, 3) }
  canvas = [ordered]@{
    width = $width
    height = $height
    pixelCount = [int64]$pixelCount
  }
  artboardCount = [int]$photoshopInfo.artboardCount
  openDocumentCount = [int]$photoshopInfo.openDocumentCount
  photoshopVersion = [string]$photoshopInfo.photoshopVersion
  freeDiskBytes = $freeDiskBytes
  freeDiskGB = if ($null -eq $freeDiskBytes) { $null } else { [math]::Round($freeDiskBytes / 1GB, 2) }
  largePsb = ($reasons.Count -gt 0)
  largePsbReasons = @($reasons)
  thresholds = [ordered]@{
    psbAlwaysLarge = $true
    fileBytes = 1GB
    artboards = 20
    maxCanvasDimension = 100000
    canvasPixels = 500000000
  }
}

$json = $result | ConvertTo-Json -Depth 6
if ($ResultPath) {
  $fullResultPath = [IO.Path]::GetFullPath($ResultPath)
  $resultDirectory = Split-Path -Parent $fullResultPath
  if ($resultDirectory) { New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null }
  $json | Set-Content -LiteralPath $fullResultPath -Encoding UTF8
}
$json
