param(
  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [string]$DocumentPath,

  [int]$MaxDepth = 30
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

$directory = Split-Path -Parent $OutputPath
if ($directory) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

function Invoke-WithPhotoshopRetry {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Action,

    [int]$Retries = 12,

    [int]$DelayMilliseconds = 1000
  )

  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    try {
      return & $Action
    } catch {
      $message = $_.Exception.Message
      $busy = $message -match 'RPC_E_SERVERCALL_RETRYLATER|application is busy|应用程序.*忙|应用.*忙|message filter'
      if (-not $busy -or $attempt -eq $Retries) {
        throw
      }
      Start-Sleep -Milliseconds $DelayMilliseconds
    }
  }
}

$app = Invoke-WithPhotoshopRetry {
  Get-RunningPhotoshopApplication
}

$createdAt = (Get-Date).ToString('o')
$createdAtJs = '"' + ($createdAt -replace '\\', '\\' -replace '"', '\"') + '"'
$targetDocumentPath = $null
if (-not [string]::IsNullOrWhiteSpace($DocumentPath)) {
  $targetDocumentPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DocumentPath).Path)
  if ([IO.Path]::GetExtension($targetDocumentPath) -notin @('.psd', '.psb')) {
    throw 'DocumentPath must be a saved PSD or PSB file.'
  }
}
$targetDocumentPathJs = ConvertTo-JsString $(if ($targetDocumentPath) { $targetDocumentPath -replace '\\', '/' } else { $null })

$jsx = @"
var createdAt = $createdAtJs;
var wantedPath = $targetDocumentPathJs;

function q(s) {
  return '"' + String(s)
    .replace(/\\/g, '\\\\')
    .replace(/\r/g, '\\r')
    .replace(/\n/g, '\\n')
    .replace(/"/g, '\\"') + '"';
}

function n(v) {
  try {
    var unitValue = Number(v.value);
    if (!isNaN(unitValue) && isFinite(unitValue)) return unitValue;
  } catch (e) {}
  try {
    var directValue = Number(v);
    if (!isNaN(directValue) && isFinite(directValue)) return directValue;
  } catch (e2) {}
  return 0;
}

function layerKind(layer) {
  try { return String(layer.kind); } catch (e) { return ""; }
}

function layerText(layer) {
  try {
    if (layer.kind == LayerKind.TEXT) return layer.textItem.contents;
  } catch (e) {}
  return "";
}

function layerBounds(layer) {
  try {
    var b = layer.bounds;
    return [n(b[0]), n(b[1]), n(b[2]), n(b[3])];
  } catch (e) {
    return [0, 0, 0, 0];
  }
}

function layerGroupedJson(layer) {
  try { return layer.grouped === true ? "true" : "false"; } catch (e) {}
  return "null";
}

function textFontSizeSignatureJson(layer) {
  try {
    if (layer.typename != "ArtLayer" || layer.kind != LayerKind.TEXT) return "null";
    var ref = new ActionReference();
    ref.putIdentifier(charIDToTypeID("Lyr "), layer.id);
    var desc = executeActionGet(ref);
    var textKey = stringIDToTypeID("textKey");
    var rangesKey = stringIDToTypeID("textStyleRange");
    var fromKey = stringIDToTypeID("from");
    var toKey = stringIDToTypeID("to");
    var styleKey = stringIDToTypeID("textStyle");
    var sizeKey = stringIDToTypeID("size");
    if (desc.hasKey(textKey)) {
      var textDesc = desc.getObjectValue(textKey);
      if (textDesc.hasKey(rangesKey)) {
        var ranges = textDesc.getList(rangesKey);
        var records = [];
        for (var i = 0; i < ranges.count; i++) {
          var range = ranges.getObjectValue(i);
          var from = range.hasKey(fromKey) ? range.getInteger(fromKey) : 0;
          var to = range.hasKey(toKey) ? range.getInteger(toKey) : 0;
          var size = null;
          if (range.hasKey(styleKey)) {
            var style = range.getObjectValue(styleKey);
            if (style.hasKey(sizeKey)) size = descriptorNumber(style, sizeKey);
          }
          records.push('{"from":' + from + ',"to":' + to + ',"size":' + (size === null ? "null" : size) + '}');
        }
        return "[" + records.join(",") + "]";
      }
    }
  } catch (e) {}
  try {
    var fallbackSize = n(layer.textItem.size);
    return '[{"from":0,"to":' + layerText(layer).length + ',"size":' + fallbackSize + '}]';
  } catch (fallbackError) {}
  return "null";
}

function descriptorNumber(desc, key) {
  var type = desc.getType(key);
  if (type == DescValueType.UNITDOUBLE) return desc.getUnitDoubleValue(key);
  if (type == DescValueType.DOUBLETYPE) return desc.getDouble(key);
  if (type == DescValueType.INTEGERTYPE) return desc.getInteger(key);
  throw new Error("Unsupported descriptor number type");
}

function artboardRectJson(layer, depth) {
  if (depth != 0 || layer.typename != "LayerSet") return "null";
  try {
    var ref = new ActionReference();
    ref.putIdentifier(charIDToTypeID("Lyr "), layer.id);
    var desc = executeActionGet(ref);
    var artboardKey = stringIDToTypeID("artboard");
    if (!desc.hasKey(artboardKey)) return "null";
    var artboard = desc.getObjectValue(artboardKey);
    var rect = artboard.getObjectValue(stringIDToTypeID("artboardRect"));
    return "[" + [
      descriptorNumber(rect, stringIDToTypeID("left")),
      descriptorNumber(rect, stringIDToTypeID("top")),
      descriptorNumber(rect, stringIDToTypeID("right")),
      descriptorNumber(rect, stringIDToTypeID("bottom"))
    ].join(",") + "]";
  } catch (e) {}
  return "null";
}

function layerRecord(layer, path, parentPath, idPath, parentId, siblingIndex, depth) {
  var b = layerBounds(layer);
  var artboardRect = artboardRectJson(layer, depth);
  var fontSizeSignature = textFontSizeSignatureJson(layer);
  return '{' +
    '"id":' + layer.id + ',' +
    '"parentId":' + (parentId === null ? "null" : parentId) + ',' +
    '"siblingIndex":' + siblingIndex + ',' +
    '"depth":' + depth + ',' +
    '"name":' + q(layer.name) + ',' +
    '"path":' + q(path) + ',' +
    '"parentPath":' + q(parentPath) + ',' +
    '"idPath":' + q(idPath) + ',' +
    '"typename":' + q(layer.typename) + ',' +
    '"kind":' + q(layerKind(layer)) + ',' +
    '"visible":' + layer.visible + ',' +
    '"grouped":' + layerGroupedJson(layer) + ',' +
    '"isArtboard":' + (artboardRect == "null" ? "false" : "true") + ',' +
    '"artboardRect":' + artboardRect + ',' +
    '"bounds":[' + b.join(',') + '],' +
    '"fontSizeSignature":' + fontSizeSignature + ',' +
    '"text":' + q(layerText(layer)) +
  '}';
}

function walk(container, path, depth, out, parentId, parentIdPath) {
  if (depth > $MaxDepth) return;
  for (var i = 0; i < container.layers.length; i++) {
    var layer = container.layers[i];
    var currentPath = path ? path + "/" + layer.name : layer.name;
    var currentIdPath = parentIdPath ? parentIdPath + "/" + layer.id : String(layer.id);
    out.push(layerRecord(layer, currentPath, path, currentIdPath, parentId, i, depth));
    if (layer.typename == "LayerSet") {
      walk(layer, currentPath, depth + 1, out, layer.id, currentIdPath);
    }
  }
}

var previousDoc = null;
try { previousDoc = app.activeDocument; } catch (noActiveDocument) {}
var docs = [];
var selectedDocs = [];
var openedForIndexing = null;
try {
  if (wantedPath !== null && wantedPath !== "") {
    var wantedLower = wantedPath.toLowerCase();
    for (var openIndex = 0; openIndex < app.documents.length; openIndex++) {
      var openDoc = app.documents[openIndex], openPath = "";
      try { openPath = openDoc.fullName.fsName.replace(/\\/g, "/"); } catch (openPathError) {}
      if (openPath.toLowerCase() == wantedLower) selectedDocs.push(openDoc);
    }
    if (selectedDocs.length > 1) throw new Error("Target PSD is open more than once: " + wantedPath);
    if (selectedDocs.length == 1 && selectedDocs[0].saved !== true) {
      throw new Error("Target PSD has unsaved changes; save it before indexing: " + wantedPath);
    }
    if (selectedDocs.length == 0) {
      openedForIndexing = app.open(new File(wantedPath));
      selectedDocs.push(openedForIndexing);
    }
  } else {
    for (var allIndex = 0; allIndex < app.documents.length; allIndex++) selectedDocs.push(app.documents[allIndex]);
  }

for (var d = 0; d < selectedDocs.length; d++) {
  var doc = selectedDocs[d];
  app.activeDocument = doc;

  var fullName = "";
  try { fullName = doc.fullName.fsName; } catch (e) {}

  var layers = [];
  walk(doc, "", 0, layers, null, "");

  docs.push(
    '{' +
      '"index":' + d + ',' +
      '"name":' + q(doc.name) + ',' +
      '"path":' + q(fullName) + ',' +
      '"width":' + n(doc.width) + ',' +
      '"height":' + n(doc.height) + ',' +
      '"widthPx":' + doc.width.as("px") + ',' +
      '"heightPx":' + doc.height.as("px") + ',' +
      '"resolution":' + n(doc.resolution) + ',' +
      '"saved":' + doc.saved + ',' +
      '"layerCount":' + layers.length + ',' +
      '"layers":[' + layers.join(',') + ']' +
    '}'
  );
}

var result = '{' +
  '"indexVersion":1,' +
  '"createdAt":' + q(createdAt) + ',' +
  '"documents":[' + docs.join(',') + ']' +
'}';
} finally {
  if (openedForIndexing) try { openedForIndexing.close(SaveOptions.DONOTSAVECHANGES); } catch (closeError) {}
  try { if (previousDoc) app.activeDocument = previousDoc; } catch (restoreError) {}
}
result;
"@

$json = Invoke-WithPhotoshopRetry {
  $app.DoJavaScript($jsx)
}
$index = $json | ConvertFrom-Json
if ($targetDocumentPath) {
  $sourceFile = Get-Item -LiteralPath $targetDocumentPath
  $index | Add-Member -NotePropertyName sourcePsd -NotePropertyValue ([pscustomobject][ordered]@{
    path = $targetDocumentPath
    sha256 = Get-Sha256 $targetDocumentPath
    lastWriteTimeUtc = $sourceFile.LastWriteTimeUtc.ToString('o')
    lengthBytes = [int64]$sourceFile.Length
  }) -Force
}
Write-Utf8Json -Path $OutputPath -Value $index | Out-Null

$OutputPath
