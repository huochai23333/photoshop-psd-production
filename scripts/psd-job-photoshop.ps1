. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

function Invoke-PsdJobApply {
  param(
    [Parameter(Mandatory = $true)]$Job,
    [Parameter(Mandatory = $true)][string]$ResultPath
  )

  $tempId = [guid]::NewGuid().ToString('N')
  $tempJobPath = Join-Path $env:TEMP "codex-psd-job-$tempId.json"
  $tempResultPath = Join-Path $env:TEMP "codex-psd-job-result-$tempId.json"
  Write-Utf8Json -Path $tempJobPath -Value $Job | Out-Null
  $jobJsPath = ConvertTo-JsString ($tempJobPath -replace '\\', '/')
  $resultJsPath = ConvertTo-JsString ($tempResultPath -replace '\\', '/')

  $jsx = @"
var jobPath = $jobJsPath;
var resultPath = $resultJsPath;

function q(s) {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/\r/g, '\\r').replace(/\n/g, '\\n').replace(/"/g, '\\"') + '"';
}
function n(v) {
  try { return Number(v.value); } catch (e) {}
  try { return Number(v); } catch (e2) {}
  return 0;
}
function readUtf8(path) {
  var f = new File(path); f.encoding = "UTF8";
  if (!f.open("r")) throw new Error("Unable to open job JSON: " + path);
  var text = f.read(); f.close(); return text;
}
function writeUtf8(path, text) {
  var f = new File(path); f.encoding = "UTF8";
  if (!f.open("w")) throw new Error("Unable to write result JSON: " + path);
  f.write(text); f.close();
}
function parseJson(text) {
  if (typeof JSON != "undefined" && JSON.parse) return JSON.parse(text);
  return eval("(" + text + ")");
}
function bounds(layer) {
  try {
    var b = layer.bounds;
    return [n(b[0]), n(b[1]), n(b[2]), n(b[3])];
  } catch (e) { return [0, 0, 0, 0]; }
}
function textSize(layer) {
  try { return n(layer.textItem.size); } catch (e) { return 0; }
}
function selectorMatches(layer, selector, path) {
  var constrained = false, match = true;
  if (selector.id !== undefined && selector.id !== null && Number(selector.id) !== 0) {
    constrained = true; match = match && layer.id == Number(selector.id);
  }
  if (selector.path) { constrained = true; match = match && path == selector.path; }
  if (selector.name) { constrained = true; match = match && layer.name == selector.name; }
  if (selector.oldText !== undefined && selector.oldText !== null) {
    constrained = true;
    var current = "";
    try { if (layer.kind == LayerKind.TEXT) current = layer.textItem.contents; } catch (e) {}
    match = match && current == selector.oldText;
  }
  return constrained && match;
}
function collectLayers(container, selector, path, output) {
  path = path || "";
  for (var i = 0; i < container.layers.length; i++) {
    var layer = container.layers[i];
    var currentPath = path ? path + "/" + layer.name : layer.name;
    if (selectorMatches(layer, selector, currentPath)) output.push({ layer: layer, path: currentPath });
    if (layer.typename == "LayerSet") collectLayers(layer, selector, currentPath, output);
  }
}
function findUnique(container, selector, label) {
  var matches = [];
  collectLayers(container, selector || {}, "", matches);
  if (matches.length !== 1) throw new Error(label + " matched " + matches.length + " layers; expected exactly one.");
  return matches[0];
}
function fitLayerToTarget(layer, targetLayer, mode) {
  if (!mode || mode == "none" || mode == "original-size") return;
  var tb = bounds(targetLayer), lb = bounds(layer);
  var tw = tb[2] - tb[0], th = tb[3] - tb[1], lw = lb[2] - lb[0], lh = lb[3] - lb[1];
  if (tw <= 0 || th <= 0 || lw <= 0 || lh <= 0) throw new Error("Invalid bounds while fitting " + layer.name);
  var ratio = mode == "contain" ? Math.min(tw / lw, th / lh) : Math.max(tw / lw, th / lh);
  if (mode == "cover") ratio *= 1.005;
  layer.resize(ratio * 100, ratio * 100, AnchorPosition.MIDDLECENTER);
  lb = bounds(layer);
  layer.translate((tb[0] + tb[2] - lb[0] - lb[2]) / 2, (tb[1] + tb[3] - lb[1] - lb[3]) / 2);
}
function placeEmbedded(path) {
  var file = new File(path);
  if (!file.exists) throw new Error("Image file does not exist: " + path);
  var desc = new ActionDescriptor();
  desc.putPath(charIDToTypeID("null"), file);
  desc.putEnumerated(charIDToTypeID("FTcs"), charIDToTypeID("QCSt"), charIDToTypeID("Qcsa"));
  executeAction(charIDToTypeID("Plc "), desc, DialogModes.NO);
  return app.activeDocument.activeLayer;
}
function getOpenDocument(path) {
  var normalized = String(path).replace(/\\/g, '/').toLowerCase();
  for (var i = 0; i < app.documents.length; i++) {
    var full = "";
    try { full = app.documents[i].fullName.fsName.replace(/\\/g, '/').toLowerCase(); } catch (e) {}
    if (full == normalized) return { doc: app.documents[i], openedHere: false };
  }
  return { doc: app.open(new File(path)), openedHere: true };
}
function savePreview(doc, plan) {
  if (!plan || plan.enabled === false || !plan.path) return "";
  var dup = doc.duplicate("codex-psd-job-preview", true);
  if (plan.maxWidth && dup.width.value > Number(plan.maxWidth)) {
    var ratio = Number(plan.maxWidth) / dup.width.value;
    dup.resizeImage(UnitValue(Number(plan.maxWidth), "px"), UnitValue(dup.height.value * ratio, "px"), null, ResampleMethod.BICUBICSHARPER);
  }
  var options = new JPEGSaveOptions();
  options.quality = Number(plan.quality || 9);
  var output = new File(plan.path);
  dup.saveAs(output, options, true, Extension.LOWERCASE);
  dup.close(SaveOptions.DONOTSAVECHANGES);
  return output.fsName;
}
function outside(inner, outer, tolerance) {
  tolerance = tolerance || 1;
  return inner[0] < outer[0] - tolerance || inner[1] < outer[1] - tolerance ||
         inner[2] > outer[2] + tolerance || inner[3] > outer[3] + tolerance;
}
function covers(cover, target, tolerance) {
  tolerance = tolerance || 1;
  return cover[0] <= target[0] + tolerance && cover[1] <= target[1] + tolerance &&
         cover[2] >= target[2] - tolerance && cover[3] >= target[3] - tolerance;
}

var job = parseJson(readUtf8(jobPath));
var opened = getOpenDocument(job.workingPsdPath);
var doc = opened.doc;
if (!doc.saved) throw new Error("Working document has unsaved changes before the job starts.");
app.activeDocument = doc;

var textResults = [], visibilityResults = [], protectedResults = [], imageResults = [], warnings = [], openedSources = [];
var protectedTargets = job.protectedTextTargets || [];
for (var p = 0; p < protectedTargets.length; p++) {
  var protectedInfo = findUnique(doc, protectedTargets[p], "Protected text target " + p);
  if (protectedInfo.layer.kind != LayerKind.TEXT) throw new Error("Protected text target " + p + " is not a text layer.");
  protectedResults.push('{"index":' + p + ',"id":' + protectedInfo.layer.id + ',"path":' + q(protectedInfo.path) +
    ',"text":' + q(protectedInfo.layer.textItem.contents) + ',"fontSize":' + textSize(protectedInfo.layer) +
    ',"visible":' + (protectedInfo.layer.visible ? 'true' : 'false') + '}');
}
var visibilityChanges = job.visibilityChanges || [];
for (var v = 0; v < visibilityChanges.length; v++) {
  // 临时兼容任务会隐藏完整标签组；这里记录前后状态，供提交后重开复验。
  var visibilityItem = visibilityChanges[v];
  var visibilityInfo = findUnique(doc, visibilityItem, "Visibility change " + v);
  var visibleBefore = Boolean(visibilityInfo.layer.visible);
  visibilityInfo.layer.visible = Boolean(visibilityItem.visible);
  var visibleAfter = Boolean(visibilityInfo.layer.visible);
  if (visibleAfter !== Boolean(visibilityItem.visible)) throw new Error("Visibility change " + v + " was not applied exactly.");
  visibilityResults.push('{"index":' + v + ',"id":' + visibilityInfo.layer.id + ',"path":' + q(visibilityInfo.path) +
    ',"before":' + (visibleBefore ? 'true' : 'false') + ',"after":' + (visibleAfter ? 'true' : 'false') + '}');
}
var replacements = job.textReplacements || [];
for (var i = 0; i < replacements.length; i++) {
  var item = replacements[i];
  var info = findUnique(doc, item, "Text replacement " + i);
  if (info.layer.kind != LayerKind.TEXT) throw new Error("Text replacement " + i + " is not a text layer.");
  var before = info.layer.textItem.contents;
  var beforeSize = textSize(info.layer);
  info.layer.textItem.contents = String(item.text);
  var after = info.layer.textItem.contents;
  var afterSize = textSize(info.layer);
  if (after !== String(item.text)) throw new Error("Text replacement " + i + " was not written exactly.");
  if (beforeSize && afterSize && Math.abs(beforeSize - afterSize) > 0.001) throw new Error("Text replacement " + i + " changed font size.");
  var afterBounds = bounds(info.layer);
  if (item.allowedBounds && outside(afterBounds, item.allowedBounds, 1)) {
    warnings.push("文字可能超出允许区域：" + info.path);
  }
  textResults.push('{"index":' + i + ',"id":' + info.layer.id + ',"path":' + q(info.path) +
    ',"before":' + q(before) + ',"after":' + q(after) +
    ',"fontSizeBefore":' + beforeSize + ',"fontSizeAfter":' + afterSize +
    ',"bounds":[' + afterBounds.join(',') + ']}');
}

var transfers = job.imageTransfers || [];
for (var j = 0; j < transfers.length; j++) {
  var transfer = transfers[j];
  var targetInfo = findUnique(doc, transfer.target || {}, "Image target " + j);
  var removeInfo = transfer.remove ? findUnique(doc, transfer.remove, "Old image " + j) : null;
  if (removeInfo && (removeInfo.layer.id == targetInfo.layer.id || removeInfo.layer.parent != targetInfo.layer.parent)) {
    throw new Error("Unsafe old-image selector at transfer " + j);
  }
  var image = null, sourceId = 0, sourceKind = "file";
  if (transfer.imagePath) {
    app.activeDocument = doc;
    image = placeEmbedded(transfer.imagePath);
  } else {
    if (!transfer.sourcePsdPath || !transfer.source) throw new Error("Image transfer " + j + " needs imagePath or sourcePsdPath plus source.");
    var sourceOpen = getOpenDocument(transfer.sourcePsdPath);
    if (sourceOpen.openedHere) openedSources.push(sourceOpen.doc);
    if (!sourceOpen.doc.saved) throw new Error("Image source PSD has unsaved changes: " + transfer.sourcePsdPath);
    var sourceInfo = findUnique(sourceOpen.doc, transfer.source, "Image source " + j);
    sourceId = sourceInfo.layer.id;
    sourceKind = "layer";
    app.activeDocument = sourceOpen.doc;
    image = sourceInfo.layer.duplicate(doc, ElementPlacement.PLACEATBEGINNING);
    app.activeDocument = doc;
  }
  image.name = transfer.name || ("图片-" + (j + 1));
  var insertionLayer = removeInfo ? removeInfo.layer : targetInfo.layer;
  image.move(insertionLayer, transfer.placement == "after" ? ElementPlacement.PLACEAFTER : ElementPlacement.PLACEBEFORE);
  fitLayerToTarget(image, targetInfo.layer, transfer.fit || "cover");
  if (transfer.clip !== false) image.grouped = true;
  if (image.parent != targetInfo.layer.parent) throw new Error("Image transfer " + j + " ended in the wrong parent.");
  if (transfer.clip !== false && image.grouped !== true) throw new Error("Image transfer " + j + " is not clipped.");
  var imageBounds = bounds(image), targetBounds = bounds(targetInfo.layer);
  if ((transfer.fit || "cover") == "cover" && !covers(imageBounds, targetBounds, 1.5)) {
    throw new Error("Image transfer " + j + " does not cover its target.");
  }
  if ((transfer.fit || "cover") == "contain" && outside(imageBounds, targetBounds, 1.5)) {
    warnings.push("图片 contain 后超出目标：" + image.name);
  }
  if (removeInfo) {
    if (removeInfo.layer.id == image.id) throw new Error("Unsafe old-image selector at transfer " + j);
    removeInfo.layer.remove();
    if (transfer.clip !== false && image.grouped !== true) {
      throw new Error("Image transfer " + j + " lost its clipping relationship after old-image removal.");
    }
  }
  imageResults.push('{"index":' + j + ',"id":' + image.id + ',"name":' + q(image.name) +
    ',"sourceType":' + q(sourceKind) + ',"sourceId":' + sourceId +
    ',"targetId":' + targetInfo.layer.id + ',"clipped":' + (image.grouped ? 'true' : 'false') +
    ',"targetBounds":[' + targetBounds.join(',') + '],"imageBounds":[' + imageBounds.join(',') + ']}');
}

app.activeDocument = doc;
doc.save();
if (!doc.saved) throw new Error("Photoshop did not report the working document as saved.");
var previewPath = savePreview(doc, job.preview);
var workingPath = doc.fullName.fsName;
doc.close(SaveOptions.DONOTSAVECHANGES);
for (var s = 0; s < openedSources.length; s++) {
  try { openedSources[s].close(SaveOptions.DONOTSAVECHANGES); } catch (ignore) {}
}
var warningJson = [];
for (var w = 0; w < warnings.length; w++) warningJson.push(q(warnings[w]));
var result = '{"ok":true,"saved":true,"workingPsdPath":' + q(workingPath) +
  ',"previewPath":' + q(previewPath) +
  ',"textChangedCount":' + textResults.length +
  ',"visibilityChangedCount":' + visibilityResults.length +
  ',"imageChangedCount":' + imageResults.length +
  ',"texts":[' + textResults.join(',') + '],"visibilityChanges":[' + visibilityResults.join(',') + '],"protectedTexts":[' + protectedResults.join(',') + '],"images":[' + imageResults.join(',') + ']' +
  ',"warnings":[' + warningJson.join(',') + '],"errors":[]}';
writeUtf8(resultPath, result);
result;
"@

  try {
    $raw = Invoke-PhotoshopJavaScript -Script $jsx
    if (Test-Path -LiteralPath $tempResultPath -PathType Leaf) {
      $raw = [IO.File]::ReadAllText($tempResultPath, $script:PsdJobUtf8NoBom)
    }
    $parsed = $raw | ConvertFrom-Json
    Write-Utf8Json -Path $ResultPath -Value $parsed | Out-Null
    return $parsed
  } catch {
    $workingPathJs = ConvertTo-JsString (([IO.Path]::GetFullPath([string]$Job.workingPsdPath)) -replace '\\', '/')
    $workingNameJs = ConvertTo-JsString ([IO.Path]::GetFileName([string]$Job.workingPsdPath))
    $cleanupJsx = @"
var target=$workingPathJs,targetName=$workingNameJs;
function norm(value){return String(value||'').replace(/\\/g,'/').toLowerCase();}
for(var index=app.documents.length-1;index>=0;index--){
  var document=app.documents[index],path='';
  try{path=document.fullName.fsName;}catch(ignore){}
  if(norm(path)==norm(target)||String(document.name).toLowerCase()==String(targetName).toLowerCase()){
    document.close(SaveOptions.DONOTSAVECHANGES);
  }
}
'cleaned';
"@
    for ($cleanupAttempt = 1; $cleanupAttempt -le 3; $cleanupAttempt++) {
      try {
        Invoke-PhotoshopJavaScript -Script $cleanupJsx | Out-Null
        break
      } catch {
        if ($cleanupAttempt -lt 3) { Start-Sleep -Milliseconds 500 }
      }
    }
    throw
  } finally {
    Remove-Item -LiteralPath $tempJobPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempResultPath -Force -ErrorAction SilentlyContinue
  }
}

function Test-PsdJobSavedTargets {
  param(
    [Parameter(Mandatory = $true)]$Job,
    [Parameter(Mandatory = $true)][string]$DocumentPath
  )

  $tempId = [guid]::NewGuid().ToString('N')
  $tempJobPath = Join-Path $env:TEMP "codex-psd-verify-$tempId.json"
  $tempResultPath = Join-Path $env:TEMP "codex-psd-verify-result-$tempId.json"
  $verifyJob = [pscustomobject]@{
    documentPath = [IO.Path]::GetFullPath($DocumentPath)
    textResults = @($Job.preparedResult.texts | Where-Object { $null -ne $_ })
    visibilityResults = @($Job.preparedResult.visibilityChanges | Where-Object { $null -ne $_ })
    protectedTextResults = @($Job.preparedResult.protectedTexts | Where-Object { $null -ne $_ })
    imageResults = @($Job.preparedResult.images | Where-Object { $null -ne $_ })
    catalogItems = @($Job.preparedResult.catalogItems | Where-Object { $null -ne $_ })
  }
  Write-Utf8Json -Path $tempJobPath -Value $verifyJob | Out-Null
  $jobJsPath = ConvertTo-JsString ($tempJobPath -replace '\\', '/')
  $resultJsPath = ConvertTo-JsString ($tempResultPath -replace '\\', '/')
  $jsx = @"
var jobPath = $jobJsPath, resultPath = $resultJsPath;
function q(s) { return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; }
function readUtf8(path) { var f=new File(path); f.encoding="UTF8"; if(!f.open("r"))throw new Error("read failed"); var t=f.read(); f.close(); return t; }
function writeUtf8(path,text) { var f=new File(path); f.encoding="UTF8"; if(!f.open("w"))throw new Error("write failed"); f.write(text); f.close(); }
function parseJson(text) { if(typeof JSON!="undefined"&&JSON.parse)return JSON.parse(text); return eval("("+text+")"); }
function matches(layer, selector, path) {
  var constrained=false, ok=true;
  if(selector.id!==undefined&&selector.id!==null&&Number(selector.id)!==0){constrained=true;ok=ok&&layer.id==Number(selector.id);}
  if(selector.path){constrained=true;ok=ok&&path==selector.path;}
  if(selector.name){constrained=true;ok=ok&&layer.name==selector.name;}
  if(selector.oldText!==undefined&&selector.oldText!==null){constrained=true;var t="";try{if(layer.kind==LayerKind.TEXT)t=layer.textItem.contents;}catch(e){}ok=ok&&t==selector.oldText;}
  return constrained&&ok;
}
function collect(container, selector, path, out) {
  path=path||"";
  for(var i=0;i<container.layers.length;i++){var layer=container.layers[i],p=path?path+"/"+layer.name:layer.name;if(matches(layer,selector,p))out.push(layer);if(layer.typename=="LayerSet")collect(layer,selector,p,out);}
}
function findUnique(container, selector) { var out=[]; collect(container,selector,"",out); if(out.length!==1)throw new Error("target matched "+out.length); return out[0]; }
function textSize(layer){try{return Number(layer.textItem.size.value);}catch(e){try{return Number(layer.textItem.size);}catch(e2){return 0;}}}
function norm(path){return String(path||"").replace(/\\/g,"/").replace(/\/$/,"").toLowerCase();}
function docPath(doc){try{return doc.fullName.fsName;}catch(e){return "";}}
var job=parseJson(readUtf8(jobPath)), doc=null, opened=false, errors=[], openMatches=[];
for(var d=0;d<app.documents.length;d++)if(norm(docPath(app.documents[d]))==norm(job.documentPath))openMatches.push(app.documents[d]);
if(openMatches.length>1)throw new Error("Verification PSD is open more than once");
if(openMatches.length==1)doc=openMatches[0];
else{doc=app.open(new File(job.documentPath));opened=true;if(!doc&&app.documents.length>0)doc=app.activeDocument;}
if(!doc)throw new Error("Photoshop did not return the verification document");
if(!doc.saved)throw new Error("Verification PSD has unsaved changes");
try {
  var texts=job.textResults||[];
  for(var i=0;i<texts.length;i++){var layer=findUnique(doc,{id:texts[i].id});if(layer.kind!=LayerKind.TEXT||layer.textItem.contents!==String(texts[i].after))errors.push("text "+i);}
  var visibility=job.visibilityResults||[];
  for(var v=0;v<visibility.length;v++){
    var visibilityLayer=findUnique(doc,{id:visibility[v].id});
    if(Boolean(visibilityLayer.visible)!==Boolean(visibility[v].after))errors.push("visibility "+v);
  }
  var protectedTexts=job.protectedTextResults||[];
  for(var p=0;p<protectedTexts.length;p++){
    var locked=findUnique(doc,{id:protectedTexts[p].id,path:protectedTexts[p].path});
    if(locked.kind!=LayerKind.TEXT)errors.push("protected text kind "+p);
    else {
      if(locked.textItem.contents!==String(protectedTexts[p].text))errors.push("protected text content "+p);
      if(Math.abs(textSize(locked)-Number(protectedTexts[p].fontSize))>0.001)errors.push("protected text font size "+p);
      if(Boolean(locked.visible)!==Boolean(protectedTexts[p].visible))errors.push("protected text visibility "+p);
    }
  }
  var images=job.imageResults||[];
  for(var j=0;j<images.length;j++){
    var found=[];collect(doc,{id:images[j].id},"",found);
    if(found.length!==1){errors.push("image "+j+" matched "+found.length);continue;}
    if(images[j].clipped===true&&found[0].grouped!==true)errors.push("image "+j+" is not clipped");
  }
  var catalog=job.catalogItems||[];
  for(var c=0;c<catalog.length;c++){
    var nameLayer=findUnique(doc,{id:catalog[c].nameLayerId});
    var englishLayer=findUnique(doc,{id:catalog[c].englishLayerId});
    var descriptionLayer=findUnique(doc,{id:catalog[c].descriptionLayerId});
    if(nameLayer.kind!=LayerKind.TEXT)errors.push("catalog name layer is not text "+c);
    else if(nameLayer.textItem.contents!==String(catalog[c].nameZh))errors.push("catalog name "+c);
    if(englishLayer.kind!=LayerKind.TEXT)errors.push("catalog english layer is not text "+c);
    else if(englishLayer.textItem.contents!==String(catalog[c].nameEn))errors.push("catalog english "+c);
    if(descriptionLayer.kind!=LayerKind.TEXT)errors.push("catalog description layer is not text "+c);
    else if(descriptionLayer.textItem.contents!==String(catalog[c].description))errors.push("catalog description "+c);
  }
} catch(verifyError) {
  errors.push("verification exception: "+String(verifyError.message||verifyError.toString()));
} finally { if(opened&&doc)doc.close(SaveOptions.DONOTSAVECHANGES); }
var out='{"ok":'+(errors.length?'false':'true')+',"errorCount":'+errors.length+',"errors":[';
for(var e=0;e<errors.length;e++){if(e)out+=",";out+=q(errors[e]);}
out+=']}'; writeUtf8(resultPath,out); out;
"@
  try {
    $raw = Invoke-PhotoshopJavaScript -Script $jsx
    if (Test-Path -LiteralPath $tempResultPath -PathType Leaf) {
      $raw = [IO.File]::ReadAllText($tempResultPath, $script:PsdJobUtf8NoBom)
    }
    return $raw | ConvertFrom-Json
  } finally {
    Remove-Item -LiteralPath $tempJobPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempResultPath -Force -ErrorAction SilentlyContinue
  }
}
