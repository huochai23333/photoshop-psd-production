param(
  [Parameter(Mandatory = $true)]
  [string]$SourcePsdPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [ValidateSet('jpg', 'png')]
  [string]$Format = 'jpg',

  [ValidateRange(1, 10000)]
  [int]$StartArtboardNumber = 1,

  [ValidateRange(0, 10000)]
  [int]$EndArtboardNumber = 0,

  [ValidateRange(0, 30000)]
  [int]$MaxWidth = 0,

  [ValidateRange(1, 12)]
  [int]$Quality = 10,

  [ValidateSet('position', 'panel')]
  [string]$OrderMode = 'position',

  [string[]]$ArtboardNames = @(),

  [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'psd-job-common.ps1')
if ($EndArtboardNumber -ne 0 -and $EndArtboardNumber -lt $StartArtboardNumber) { throw 'EndArtboardNumber must be zero (all) or greater than or equal to StartArtboardNumber.' }
if (@($ArtboardNames).Count -gt 0) {
  $duplicates = @($ArtboardNames | Group-Object -CaseSensitive | Where-Object Count -gt 1)
  if ($duplicates.Count -gt 0) { throw 'ArtboardNames must be unique and explicitly ordered.' }
  foreach ($name in $ArtboardNames) { if ([string]$name -cnotmatch '^[A-Za-z0-9_-]+$') { throw "Unsafe exact artboard export name: $name" } }
}

function ConvertTo-JsString {
  param([string]$Value)
  $text = $Value -replace '\\', '\\\\'
  $text = $text -replace '"', '\"'
  return '"' + $text + '"'
}

$sourcePath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourcePsdPath).Path)
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Source PSD/PSB is missing: $sourcePath" }
if ([IO.Path]::GetExtension($sourcePath).ToLowerInvariant() -notin @('.psd', '.psb')) { throw 'Source file must be a PSD or PSB.' }
$fullOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $fullOutputDirectory | Out-Null

$sourceFile = Get-Item -LiteralPath $sourcePath
$sourceHashBefore = Get-Sha256 $sourcePath
$tempId = [guid]::NewGuid().ToString('N')
$tempSettingsPath = Join-Path $env:TEMP "codex_artboard_pages_settings_$tempId.json"
$tempJsResultPath = Join-Path $env:TEMP "codex_artboard_pages_result_$tempId.json"
[ordered]@{
  sourcePsdPath = $sourcePath
  outputDirectory = $fullOutputDirectory
  resultPath = $tempJsResultPath
  format = $Format
  startArtboardNumber = $StartArtboardNumber
  endArtboardNumber = $EndArtboardNumber
  maxWidth = $MaxWidth
  quality = $Quality
  orderMode = $OrderMode
  artboardNames = @($ArtboardNames)
  overwrite = [bool]$Overwrite
} | ForEach-Object { Write-Utf8Json -Path $tempSettingsPath -Value $_ | Out-Null }

$result = [ordered]@{
  jobVersion = 1
  type = 'artboards'
  ok = $false
  stage = 'page-export'
  sourcePsdPath = $sourcePath
  sourceHash = $sourceHashBefore
  sourceUnchanged = $false
  sourceSaved = $false
  sourceReopened = $false
  largePsb = $false
  largePsbReasons = @()
  artboardCount = 0
  pageCount = 0
  orderMode = $OrderMode
  format = $Format
  outputDirectory = $fullOutputDirectory
  pages = @()
  requestedArtboardNames = @($ArtboardNames)
  error = $null
}

try {
  $settingsPathJs = ConvertTo-JsString ($tempSettingsPath -replace '\\', '/')
  $jsx = @"
var settingsPath = $settingsPathJs;
function q(s) { return '"' + String(s).replace(/\\/g, '\\\\').replace(/\r/g, '\\r').replace(/\n/g, '\\n').replace(/"/g, '\\"') + '"'; }
function readUtf8(path) { var f = new File(path); f.encoding = "UTF8"; if (!f.open("r")) throw new Error("Unable to read export settings"); var text = f.read(); f.close(); return text; }
function writeUtf8(path, text) { var f = new File(path); f.encoding = "UTF8"; if (!f.open("w")) throw new Error("Unable to write export result"); f.write(text); f.close(); }
function parseJson(text) { if (typeof JSON != "undefined" && JSON.parse) return JSON.parse(text); return eval("(" + text + ")"); }
function norm(path) { return String(path || "").replace(/\\/g, "/").replace(/\/$/, "").toLowerCase(); }
function n(v) { try { return Number(v.as("px")); } catch (e) {} try { return Number(v.value); } catch (e2) {} try { return Number(v); } catch (e3) {} return 0; }
function descriptorNumber(desc, key) {
  var type = desc.getType(key);
  if (type == DescValueType.UNITDOUBLE) return desc.getUnitDoubleValue(key);
  if (type == DescValueType.DOUBLETYPE) return desc.getDouble(key);
  if (type == DescValueType.INTEGERTYPE) return desc.getInteger(key);
  throw new Error("Unsupported descriptor number type");
}
function artboardRect(doc, layer) {
  doc.activeLayer = layer;
  var ref = new ActionReference(); ref.putEnumerated(charIDToTypeID("Lyr "), charIDToTypeID("Ordn"), charIDToTypeID("Trgt"));
  var desc = executeActionGet(ref), artboardKey = stringIDToTypeID("artboard"); if (!desc.hasKey(artboardKey)) return null;
  var artboard = desc.getObjectValue(artboardKey), rect = artboard.getObjectValue(stringIDToTypeID("artboardRect"));
  return [descriptorNumber(rect, stringIDToTypeID("left")), descriptorNumber(rect, stringIDToTypeID("top")), descriptorNumber(rect, stringIDToTypeID("right")), descriptorNumber(rect, stringIDToTypeID("bottom"))];
}
function pageMode(source) {
  if (source.mode == DocumentMode.CMYK) return NewDocumentMode.CMYK;
  if (source.mode == DocumentMode.GRAYSCALE) return NewDocumentMode.GRAYSCALE;
  if (source.mode == DocumentMode.LAB) return NewDocumentMode.LAB;
  return NewDocumentMode.RGB;
}
function pad4(value) { var text = String(value); while (text.length < 4) text = "0" + text; return text; }

var settings = parseJson(readUtf8(settingsPath)), source = null, pageDoc = null, response = "", sourceReopened = false, sourceOpenedHere = false;
var oldUnits = app.preferences.rulerUnits, oldDialogs = app.displayDialogs, baseHistory = null, previousLayer = null;
try {
  var matches = [], openPaths = [];
  for (var d = 0; d < app.documents.length; d++) { var docPath = ""; try { docPath = app.documents[d].fullName.fsName; } catch (pathError) {} openPaths.push(norm(docPath)); if (norm(docPath) == norm(settings.sourcePsdPath)) matches.push(app.documents[d]); }
  if (matches.length > 1) throw new Error("Source document is open more than once");
  source = matches.length == 1 ? matches[0] : app.open(new File(settings.sourcePsdPath)); sourceOpenedHere = matches.length == 0; app.activeDocument = source;
  if (!source.saved) throw new Error("Source document has unsaved changes");
  app.preferences.rulerUnits = Units.PIXELS; app.displayDialogs = DialogModes.NO;
  baseHistory = source.activeHistoryState; try { previousLayer = source.activeLayer; } catch (activeLayerError) {}

  var boards = [];
  for (var i = 0; i < source.layerSets.length; i++) { var rect = null; try { rect = artboardRect(source, source.layerSets[i]); } catch (notArtboard) {} if (rect) boards.push({ layer: source.layerSets[i], rect: rect, panelIndex: i }); }
  if (settings.orderMode == "position") boards.sort(function(a, b) { var top = a.rect[1] - b.rect[1]; return Math.abs(top) > 1 ? top : a.rect[0] - b.rect[0]; });
  else boards.sort(function(a, b) { return a.panelIndex - b.panelIndex; });
  var selected = [], requestedNames = settings.artboardNames || [];
  if (requestedNames.length > 0) {
    for (var rn = 0; rn < requestedNames.length; rn++) {
      var found = [];
      for (var bi = 0; bi < boards.length; bi++) if (String(boards[bi].layer.name) == String(requestedNames[rn])) found.push(boards[bi]);
      if (found.length != 1) throw new Error("Expected exactly one artboard named " + requestedNames[rn] + "; found " + found.length);
      selected.push(found[0]);
    }
  } else {
    var start = Number(settings.startArtboardNumber), end = Number(settings.endArtboardNumber); if (end == 0) end = boards.length;
    if (start < 1 || end > boards.length) throw new Error("Requested range exceeds the " + boards.length + " available artboards");
    for (var selectedNumber = start; selectedNumber <= end; selectedNumber++) selected.push(boards[selectedNumber - 1]);
  }

  var outputs = [];
  for (var selectedIndex = 0; selectedIndex < selected.length; selectedIndex++) {
    var number = selectedIndex + 1, board = selected[selectedIndex], rect = board.rect, width = Math.round(rect[2] - rect[0]), height = Math.round(rect[3] - rect[1]);
    if (width <= 0 || height <= 0) throw new Error("Invalid artboard rectangle for page " + number);
    var extension = settings.format == "png" ? ".png" : ".jpg";
    var fileStem = requestedNames.length > 0 ? String(board.layer.name) : "page-" + pad4(number);
    var outFile = new File(String(settings.outputDirectory).replace(/\/$/, "") + "/" + fileStem + extension);
    if (outFile.exists && settings.overwrite !== true) throw new Error("Output already exists: " + outFile.fsName);

    app.activeDocument = source; source.activeHistoryState = baseHistory;
    source.selection.select([[rect[0], rect[1]], [rect[2], rect[1]], [rect[2], rect[3]], [rect[0], rect[3]]]);
    var copiedPixels = true; try { source.selection.copy(true); } catch (copyError) { copiedPixels = false; }
    var fill = settings.format == "jpg" ? DocumentFill.WHITE : DocumentFill.TRANSPARENT;
    var mode = settings.format == "png" ? NewDocumentMode.RGB : pageMode(source);
    pageDoc = app.documents.add(width, height, Number(source.resolution), "codex_page_" + pad4(number), mode, fill);
    if (copiedPixels) pageDoc.paste();
    if (Number(settings.maxWidth) > 0 && pageDoc.width.as("px") > Number(settings.maxWidth)) {
      var ratio = Number(settings.maxWidth) / pageDoc.width.as("px");
      pageDoc.resizeImage(UnitValue(Number(settings.maxWidth), "px"), UnitValue(pageDoc.height.as("px") * ratio, "px"), null, ResampleMethod.BICUBICSHARPER);
    }
    if (settings.format == "jpg") {
      pageDoc.flatten(); var jpg = new JPEGSaveOptions(); jpg.quality = Number(settings.quality); pageDoc.saveAs(outFile, jpg, true, Extension.LOWERCASE);
    } else {
      var png = new PNGSaveOptions(); png.interlaced = false; pageDoc.saveAs(outFile, png, true, Extension.LOWERCASE);
    }
    pageDoc.close(SaveOptions.DONOTSAVECHANGES); pageDoc = null;
    outputs.push('{"number":' + number + ',"artboard":' + q(board.layer.name) + ',"file":' + q(outFile.fsName) + ',"sourceRect":[' + rect.join(',') + ']}');
  }
  app.activeDocument = source; source.activeHistoryState = baseHistory; if (previousLayer) try { source.activeLayer = previousLayer; } catch (restoreLayerError) {}
  if (!source.saved) {
    source.close(SaveOptions.DONOTSAVECHANGES); source = app.open(new File(settings.sourcePsdPath)); sourceReopened = true; app.activeDocument = source;
  }
  if (!source.saved) throw new Error("Source document did not return to a saved state after discard/reopen");
  response = '{"ok":true,"stage":"page-export","sourceSaved":true,"sourceReopened":' + sourceReopened + ',"canvas":{"width":' + n(source.width) + ',"height":' + n(source.height) + '},"artboardCount":' + boards.length + ',"pageCount":' + outputs.length + ',"pages":[' + outputs.join(',') + ']}';
  writeUtf8(settings.resultPath, response);
  if (sourceOpenedHere) source.close(SaveOptions.DONOTSAVECHANGES);
} catch (e) {
  var failureMessage = String(e.message || e.toString());
  if (pageDoc) try { pageDoc.close(SaveOptions.DONOTSAVECHANGES); } catch (pageCloseError) {}
  if (source && baseHistory) try { app.activeDocument = source; source.activeHistoryState = baseHistory; } catch (historyError) {}
  if (sourceOpenedHere && source) try { source.close(SaveOptions.DONOTSAVECHANGES); } catch (closeSourceError) {}
  else if (source && !source.saved) try { source.close(SaveOptions.DONOTSAVECHANGES); source = app.open(new File(settings.sourcePsdPath)); sourceReopened = true; } catch (reopenError) { failureMessage += "; source recovery failed: " + String(reopenError.message || reopenError.toString()); }
  response = '{"ok":false,"stage":"page-export","sourceReopened":' + sourceReopened + ',"error":' + q(failureMessage) + '}'; try { writeUtf8(settings.resultPath, response); } catch (writeError) {}
} finally {
  try { app.preferences.rulerUnits = oldUnits; } catch (unitsError) {}
  try { app.displayDialogs = oldDialogs; } catch (dialogsError) {}
}
response;
"@

  $null = Invoke-PhotoshopJavaScript -Script $jsx
  if (-not (Test-Path -LiteralPath $tempJsResultPath -PathType Leaf)) { throw 'Photoshop did not write a page-export result.' }
  $photoshopResult = Get-Content -LiteralPath $tempJsResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($photoshopResult.PSObject.Properties['sourceReopened']) { $result.sourceReopened = [bool]$photoshopResult.sourceReopened }
  if ($photoshopResult.ok -ne $true) { throw "Artboard page export failed: $($photoshopResult.error)" }

  foreach ($page in @($photoshopResult.pages)) {
    if (-not (Test-Path -LiteralPath ([string]$page.file) -PathType Leaf)) { throw "Exported page is missing: $($page.file)" }
    if ((Get-Item -LiteralPath ([string]$page.file)).Length -le 0) { throw "Exported page is empty: $($page.file)" }
  }
  $numbers = @($photoshopResult.pages | ForEach-Object { [int]$_.number })
  for ($i = 1; $i -lt $numbers.Count; $i++) { if ($numbers[$i] -ne $numbers[$i - 1] + 1) { throw 'Exported page numbering is not contiguous.' } }
  if (@($ArtboardNames).Count -gt 0) {
    $actualNames = @($photoshopResult.pages | ForEach-Object { [string]$_.artboard })
      if (($actualNames -join '|') -cne (@($ArtboardNames) -join '|')) { throw 'Exported artboard names or order differ from the requested order.' }
  }

  $sourceHashAfter = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
  $result.sourceUnchanged = $sourceHashAfter -eq $sourceHashBefore
  if (-not $result.sourceUnchanged) { throw 'Source PSD/PSB changed during page export.' }
  $result.sourceSaved = [bool]$photoshopResult.sourceSaved
  $result.sourceReopened = [bool]$photoshopResult.sourceReopened
  $result.artboardCount = [int]$photoshopResult.artboardCount
  $result.pageCount = [int]$photoshopResult.pageCount
  $result.pages = @($photoshopResult.pages | ForEach-Object {
    $_ | Add-Member -NotePropertyName sha256 -NotePropertyValue (Get-Sha256 ([string]$_.file)) -Force
    $_ | Add-Member -NotePropertyName bytes -NotePropertyValue ((Get-Item -LiteralPath ([string]$_.file)).Length) -Force
    $_
  })
  $largeReasons = [System.Collections.Generic.List[string]]::new()
  if ($sourceFile.Extension -ieq '.psb') { $largeReasons.Add('format-is-psb') }
  if ($sourceFile.Length -gt 1GB) { $largeReasons.Add('file-over-1gb') }
  if ($result.artboardCount -gt 20) { $largeReasons.Add('artboards-over-20') }
  if ([double]$photoshopResult.canvas.width -gt 100000 -or [double]$photoshopResult.canvas.height -gt 100000 -or ([double]$photoshopResult.canvas.width * [double]$photoshopResult.canvas.height) -gt 500000000) { $largeReasons.Add('extremely-large-canvas') }
  $result.largePsbReasons = @($largeReasons)
  $result.largePsb = $largeReasons.Count -gt 0
  $result.ok = $true
} catch {
  $result.error = $_.Exception.Message
} finally {
  Remove-Item -LiteralPath $tempSettingsPath, $tempJsResultPath -Force -ErrorAction SilentlyContinue
}

$result | ConvertTo-Json -Depth 10 -Compress
if (-not $result.ok) { throw "Artboard page export failed: $($result.error)" }
