param(
  [string]$ResultPath,

  [string]$CacheDirectory = (Join-Path $env:LOCALAPPDATA 'Codex\PhotoshopCapabilityCache'),

  [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

function Write-ResultJson {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [string]$Path
  )
  $json = $Value | ConvertTo-Json -Depth 8
  if ($Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $json | Set-Content -LiteralPath $fullPath -Encoding UTF8
  }
  return $json
}

$app = Get-RunningPhotoshopApplication
$version = [string]$app.Version
$safeVersion = $version -replace '[^0-9A-Za-z._-]', '_'
$fullCacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
$cachePath = Join-Path $fullCacheDirectory "photoshop-$safeVersion.json"

if (-not $Force -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
  try {
    $cached = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$cached.schemaVersion -eq 1 -and [string]$cached.photoshopVersion -eq $version) {
      $cached.cached = $true
      $cached.cachePath = $cachePath
      Write-ResultJson -Value $cached -Path $ResultPath
      return
    }
  } catch {
    # Ignore an unreadable or obsolete cache and rebuild it with the disposable probe.
  }
}

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
function bounds(layer) {
  var b = layer.bounds;
  return [n(b[0]), n(b[1]), n(b[2]), n(b[3])];
}
function fillRect(doc, layer, left, top, right, bottom, red, green, blue) {
  doc.activeLayer = layer;
  doc.selection.select([[left, top], [right, top], [right, bottom], [left, bottom]]);
  var color = new SolidColor();
  color.rgb.red = red; color.rgb.green = green; color.rgb.blue = blue;
  doc.selection.fill(color); doc.selection.deselect();
}

var previousDoc = null, doc = null, oldUnits = app.preferences.rulerUnits;
var results = {}, errors = {};
function test(name, fn) {
  try { results[name] = fn() === true; if (!results[name]) errors[name] = "probe returned false"; }
  catch (e) { results[name] = false; errors[name] = String(e.message || e.toString()); }
}
function testJson(name) {
  return q(name) + ':{"supported":' + (results[name] === true) + ',"error":' + (errors[name] ? q(errors[name]) : 'null') + '}';
}

try {
  try { previousDoc = app.activeDocument; } catch (noPrevious) {}
  app.preferences.rulerUnits = Units.PIXELS;
  doc = app.documents.add(320, 220, 72, "codex_capability_probe", NewDocumentMode.RGB, DocumentFill.TRANSPARENT);

  var parentGroup = null, nestedGroup = null, targetGroup = null;
  test("nestedGroupCreation", function() {
    parentGroup = doc.layerSets.add(); parentGroup.name = "probe_parent";
    nestedGroup = parentGroup.layerSets.add(); nestedGroup.name = "probe_nested";
    return nestedGroup.parent.id == parentGroup.id;
  });

  targetGroup = doc.layerSets.add(); targetGroup.name = "probe_target";
  test("artLayerDuplicateIntoGroup", function() {
    var layer = doc.artLayers.add(); layer.name = "probe_pixel";
    fillRect(doc, layer, 20, 20, 60, 60, 240, 40, 40);
    var copy = layer.duplicate(targetGroup, ElementPlacement.PLACEATBEGINNING);
    return copy.parent.id == targetGroup.id;
  });

  test("smartObjectDuplicateIntoGroup", function() {
    var layer = doc.artLayers.add(); layer.name = "probe_smart_source";
    fillRect(doc, layer, 80, 30, 130, 80, 40, 100, 240);
    doc.activeLayer = layer;
    executeAction(stringIDToTypeID("newPlacedLayer"), undefined, DialogModes.NO);
    var smart = doc.activeLayer;
    if (smart.kind != LayerKind.SMARTOBJECT) throw new Error("conversion did not create a smart object");
    var copy = smart.duplicate(targetGroup, ElementPlacement.PLACEATBEGINNING);
    return copy.parent.id == targetGroup.id && copy.kind == LayerKind.SMARTOBJECT;
  });

  test("groupTranslation", function() {
    var before = bounds(targetGroup);
    targetGroup.translate(17, 23);
    var after = bounds(targetGroup);
    return Math.abs((after[0] - before[0]) - 17) < 0.1 && Math.abs((after[1] - before[1]) - 23) < 0.1;
  });

  test("largeDocumentFormatSaveOptions", function() {
    if (typeof LargeDocumentFormatSaveOptions == "undefined") return false;
    var options = new LargeDocumentFormatSaveOptions();
    return options != null;
  });

  test("pdfPresentation", function() {
    return typeof app.makePDFPresentation == "function";
  });
} catch (fatal) {
  errors.fatal = String(fatal.message || fatal.toString());
} finally {
  if (doc) try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (closeError) { errors.close = String(closeError.message || closeError.toString()); }
  try { app.preferences.rulerUnits = oldUnits; } catch (unitsError) {}
  if (previousDoc) try { app.activeDocument = previousDoc; } catch (restoreError) {}
}

var ready = results.nestedGroupCreation === true &&
  results.artLayerDuplicateIntoGroup === true &&
  results.smartObjectDuplicateIntoGroup === true &&
  results.groupTranslation === true;

'{' +
  '"ok":' + (!errors.fatal) + ',' +
  '"groupCopyReady":' + ready + ',' +
  '"tests":{' +
    testJson("nestedGroupCreation") + ',' +
    testJson("artLayerDuplicateIntoGroup") + ',' +
    testJson("smartObjectDuplicateIntoGroup") + ',' +
    testJson("groupTranslation") + ',' +
    testJson("largeDocumentFormatSaveOptions") + ',' +
    testJson("pdfPresentation") +
  '},' +
  '"largePsbPolicy":{"documentDuplicateAllowed":false,"pdfPresentationAllowed":false},' +
  '"fatalError":' + (errors.fatal ? q(errors.fatal) : 'null') + ',' +
  '"closeError":' + (errors.close ? q(errors.close) : 'null') +
'}';
'@

$probe = $app.DoJavaScript($jsx) | ConvertFrom-Json
$report = [ordered]@{
  schemaVersion = 1
  ok = [bool]$probe.ok
  testedAtUtc = [DateTime]::UtcNow.ToString('o')
  photoshopVersion = $version
  cached = $false
  cachePath = $cachePath
  groupCopyReady = [bool]$probe.groupCopyReady
  tests = $probe.tests
  largePsbPolicy = $probe.largePsbPolicy
  fatalError = $probe.fatalError
  closeError = $probe.closeError
}

New-Item -ItemType Directory -Force -Path $fullCacheDirectory | Out-Null
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cachePath -Encoding UTF8
Write-ResultJson -Value $report -Path $ResultPath

if (-not $report.ok) { throw "Photoshop capability probe failed: $($report.fatalError)" }
