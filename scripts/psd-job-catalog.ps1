. (Join-Path $PSScriptRoot 'psd-job-common.ps1')

function Invoke-PsdCatalogJobApply {
  param(
    [Parameter(Mandatory = $true)]$Job,
    [Parameter(Mandatory = $true)][string]$ResultPath
  )

  if (-not (Test-ObjectProperty $Job 'catalog') -or -not $Job.catalog) { throw 'Catalog job requires catalog settings.' }
  $catalog = $Job.catalog
  foreach ($field in @('imageDirectory', 'layout', 'items')) {
    if (-not (Test-ObjectProperty $catalog $field) -or $null -eq $catalog.$field) { throw "Catalog job is missing $field." }
  }
  $imageDirectory = [IO.Path]::GetFullPath([string]$catalog.imageDirectory)
  if (-not (Test-Path -LiteralPath $imageDirectory -PathType Container)) { throw "Catalog image directory is missing: $imageDirectory" }
  $items = @($catalog.items)
  if ($items.Count -eq 0) { throw 'Catalog item list is empty.' }
  foreach ($item in $items) {
    foreach ($field in @('nameZh', 'nameEn', 'image', 'category')) {
      if (-not (Test-ObjectProperty $item $field) -or [string]::IsNullOrWhiteSpace([string]$item.$field)) { throw "Catalog item is missing $field." }
    }
    $imagePath = Join-Path $imageDirectory ([string]$item.image)
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { throw "Catalog image is missing: $imagePath" }
  }

  $itemsPerArtboard = [int]$catalog.layout.itemsPerArtboard
  if ($itemsPerArtboard -lt 1) { throw 'catalog.layout.itemsPerArtboard must be positive.' }
  $settings = [ordered]@{
    workingPsdPath = [IO.Path]::GetFullPath([string]$Job.workingPsdPath)
    imageDirectory = $imageDirectory
    items = $items
    layout = [ordered]@{
      templateArtboard = [string]$catalog.layout.templateArtboard
      startArtboardNumber = [int]$catalog.layout.startArtboardNumber
      itemsPerArtboard = $itemsPerArtboard
      expectedExistingProductArtboards = [int]$catalog.layout.expectedExistingProductArtboards
      requiredProductArtboards = [int][Math]::Ceiling($items.Count / [double]$itemsPerArtboard)
    }
    imagePlacement = if (Test-ObjectProperty $catalog 'imagePlacement') { $catalog.imagePlacement } else { [pscustomobject]@{ mode = 'cover-mask'; edgeOverscanPercent = 0.3 } }
    preview = $Job.preview
  }

  $tempId = [guid]::NewGuid().ToString('N')
  $settingsPath = Join-Path $env:TEMP "codex-catalog-$tempId.json"
  $temporaryResultPath = Join-Path $env:TEMP "codex-catalog-result-$tempId.json"
  Write-Utf8Json -Path $settingsPath -Value $settings | Out-Null
  $settingsJs = ConvertTo-JsString ($settingsPath -replace '\\', '/')
  $resultJs = ConvertTo-JsString ($temporaryResultPath -replace '\\', '/')
  $jsx = @"
var settingsPath=$settingsJs,resultPath=$resultJs;
function q(s){return '"'+String(s).replace(/\\/g,'\\\\').replace(/\r/g,'\\r').replace(/\n/g,'\\n').replace(/"/g,'\\"')+'"';}
function n(v){try{return Number(v.value);}catch(e){}try{return Number(v);}catch(e2){}return 0;}
function readUtf8(p){var f=new File(p);f.encoding='UTF8';if(!f.open('r'))throw new Error('Unable to read catalog job');var t=f.read();f.close();return t;}
function writeUtf8(p,t){var f=new File(p);f.encoding='UTF8';if(!f.open('w'))throw new Error('Unable to write catalog result');f.write(t);f.close();}
function parseJson(t){if(typeof JSON!='undefined'&&JSON.parse)return JSON.parse(t);return eval('('+t+')');}
function bounds(layer){var b=layer.bounds;return[n(b[0]),n(b[1]),n(b[2]),n(b[3])];}
function textSize(layer){try{return n(layer.textItem.size);}catch(e){return 0;}}
function descriptorNumber(desc,key){var type=desc.getType(key);if(type==DescValueType.UNITDOUBLE)return desc.getUnitDoubleValue(key);if(type==DescValueType.DOUBLETYPE)return desc.getDouble(key);if(type==DescValueType.INTEGERTYPE)return desc.getInteger(key);throw new Error('Unsupported descriptor number');}
function artboardRect(doc,layer){doc.activeLayer=layer;var ref=new ActionReference();ref.putEnumerated(charIDToTypeID('Lyr '),charIDToTypeID('Ordn'),charIDToTypeID('Trgt'));var desc=executeActionGet(ref),key=stringIDToTypeID('artboard');if(!desc.hasKey(key))return null;var board=desc.getObjectValue(key),rect=board.getObjectValue(stringIDToTypeID('artboardRect'));return[descriptorNumber(rect,stringIDToTypeID('left')),descriptorNumber(rect,stringIDToTypeID('top')),descriptorNumber(rect,stringIDToTypeID('right')),descriptorNumber(rect,stringIDToTypeID('bottom'))];}
function placeEmbedded(path){var file=new File(path);if(!file.exists)throw new Error('Product image does not exist: '+path);var desc=new ActionDescriptor();desc.putPath(charIDToTypeID('null'),file);desc.putEnumerated(charIDToTypeID('FTcs'),charIDToTypeID('QCSt'),charIDToTypeID('Qcsa'));executeAction(charIDToTypeID('Plc '),desc,DialogModes.NO);return app.activeDocument.activeLayer;}
function center(layer,target){var tb=bounds(target),lb=bounds(layer);layer.translate((tb[0]+tb[2]-lb[0]-lb[2])/2,(tb[1]+tb[3]-lb[1]-lb[3])/2);}
function fit(layer,target,placement){var tb=bounds(target),lb=bounds(layer),tw=tb[2]-tb[0],th=tb[3]-tb[1],lw=lb[2]-lb[0],lh=lb[3]-lb[1];if(!(tw>0&&th>0&&lw>0&&lh>0))throw new Error('Invalid image or placeholder bounds');if(placement.mode!='original-size'){var ratio=placement.mode=='contain'?Math.min(tw/lw,th/lh):Math.max(tw/lw,th/lh);var overscan=placement.mode=='cover-mask'?Number(placement.edgeOverscanPercent||0):0;layer.resize(ratio*(100+overscan),ratio*(100+overscan),AnchorPosition.MIDDLECENTER);}center(layer,target);}
function productGroups(board,count){var groups=[];for(var i=0;i<board.layerSets.length;i++)groups.push(board.layerSets[i]);groups.sort(function(a,b){return bounds(a)[0]-bounds(b)[0];});if(groups.length!=count)throw new Error('Expected '+count+' product groups in '+board.name+'; found '+groups.length);return groups;}
function textCapacity(layer){var b=bounds(layer),area=Math.max(0,b[2]-b[0])*Math.max(0,b[3]-b[1]);try{area=Math.max(area,n(layer.textItem.width)*n(layer.textItem.height));}catch(e){}return area;}
function roles(group){var placeholder=null,placeholderArea=-1,texts=[];for(var i=0;i<group.artLayers.length;i++){var layer=group.artLayers[i];if(layer.kind==LayerKind.SOLIDFILL){var b=bounds(layer),area=Math.max(0,b[2]-b[0])*Math.max(0,b[3]-b[1]);if(area>placeholderArea){placeholder=layer;placeholderArea=area;}}if(layer.kind==LayerKind.TEXT)texts.push(layer);}if(!placeholder)throw new Error('Product image placeholder was not found');if(texts.length!=3)throw new Error('Expected three direct product text layers; found '+texts.length);var description=texts[0];for(var t=1;t<texts.length;t++)if(textCapacity(texts[t])>textCapacity(description))description=texts[t];var remaining=[];for(var r=0;r<texts.length;r++)if(texts[r].id!=description.id)remaining.push(texts[r]);remaining.sort(function(a,b){return textSize(b)-textSize(a);});return{placeholder:placeholder,description:description,name:remaining[0],english:remaining[1]};}
function directIndex(group,layer){for(var i=0;i<group.layers.length;i++)if(group.layers[i].id==layer.id)return i;return-1;}
function savePreview(doc,plan){if(!plan||plan.enabled===false||!plan.path)return'';var dup=doc.duplicate('codex-catalog-preview',true);if(plan.maxWidth&&dup.width.value>Number(plan.maxWidth)){var ratio=Number(plan.maxWidth)/dup.width.value;dup.resizeImage(UnitValue(Number(plan.maxWidth),'px'),UnitValue(dup.height.value*ratio,'px'),null,ResampleMethod.BICUBICSHARPER);}var options=new JPEGSaveOptions();options.quality=Number(plan.quality||9);var out=new File(plan.path);dup.saveAs(out,options,true,Extension.LOWERCASE);dup.close(SaveOptions.DONOTSAVECHANGES);return out.fsName;}

var s=parseJson(readUtf8(settingsPath)),doc=null,saved=false,response='',oldUnits=app.preferences.rulerUnits;
try{
  doc=app.open(new File(s.workingPsdPath));app.activeDocument=doc;app.preferences.rulerUnits=Units.PIXELS;
  var boards=[];for(var i=0;i<doc.layerSets.length;i++){try{var rect=artboardRect(doc,doc.layerSets[i]);if(rect)boards.push({layer:doc.layerSets[i],rect:rect});}catch(ignore){}}
  boards.sort(function(a,b){return a.rect[0]-b.rect[0];});
  var templateIndex=-1;for(var b=0;b<boards.length;b++)if(boards[b].layer.name==String(s.layout.templateArtboard))templateIndex=b;
  if(templateIndex<0)throw new Error('Template artboard was not found');
  var productBoards=[],existing=Number(s.layout.expectedExistingProductArtboards);
  if(templateIndex+existing>boards.length)throw new Error('Existing product-artboard count exceeds available artboards');
  for(var eb=0;eb<existing;eb++)productBoards.push(boards[templateIndex+eb].layer);
  if(Number(s.layout.requiredProductArtboards)<productBoards.length)throw new Error('Job would require deleting existing product artboards');
  while(productBoards.length<Number(s.layout.requiredProductArtboards)){var duplicate=productBoards[productBoards.length-1].duplicate();if(!artboardRect(doc,duplicate))throw new Error('Duplicated layer is not an artboard');productGroups(duplicate,Number(s.layout.itemsPerArtboard));productBoards.push(duplicate);}
  productBoards.sort(function(a,b){return artboardRect(doc,a)[0]-artboardRect(doc,b)[0];});
  var prefix=String(s.layout.templateArtboard).replace(/\d+\s*$/,'');
  for(var bn=0;bn<productBoards.length;bn++)productBoards[bn].name=prefix+(Number(s.layout.startArtboardNumber)+bn);
  var results=[],images=[];
  for(var index=0;index<s.items.length;index++){
    var item=s.items[index],board=productBoards[Math.floor(index/Number(s.layout.itemsPerArtboard))],groupIndex=index%Number(s.layout.itemsPerArtboard),group=productGroups(board,Number(s.layout.itemsPerArtboard))[groupIndex],r=roles(group);
    var nameSize=textSize(r.name),englishSize=textSize(r.english),descriptionSize=textSize(r.description),description=item.description?String(item.description).replace(/\n/g,'\r'):' ';
    r.name.textItem.contents=String(item.nameZh);r.english.textItem.contents=String(item.nameEn);r.description.textItem.contents=description;
    if(Math.abs(textSize(r.name)-nameSize)>0.01||Math.abs(textSize(r.english)-englishSize)>0.01||Math.abs(textSize(r.description)-descriptionSize)>0.01)throw new Error('Font size changed for '+item.nameZh);
    doc.activeLayer=r.placeholder;var placed=placeEmbedded(String(s.imageDirectory).replace(/\/$/,'')+'/'+item.image);placed.name=item.nameZh+'_image';placed.move(r.placeholder,ElementPlacement.PLACEBEFORE);fit(placed,r.placeholder,s.imagePlacement);placed.grouped=true;
    var placedIndex=directIndex(group,placed),placeholderIndex=directIndex(group,r.placeholder),tb=bounds(r.placeholder),ib=bounds(placed),cover=ib[0]<=tb[0]+1&&ib[1]<=tb[1]+1&&ib[2]>=tb[2]-1&&ib[3]>=tb[3]-1;
    if(placed.grouped!==true||placed.parent.id!=group.id||placeholderIndex!=placedIndex+1||(s.imagePlacement.mode=='cover-mask'&&!cover))throw new Error('Image structure verification failed for '+item.nameZh);
    results.push('{"index":'+index+',"board":'+q(board.name)+',"nameZh":'+q(item.nameZh)+',"nameEn":'+q(item.nameEn)+',"description":'+q(description)+',"nameLayerId":'+r.name.id+',"englishLayerId":'+r.english.id+',"descriptionLayerId":'+r.description.id+',"imageLayerId":'+placed.id+'}');
    images.push('{"id":'+placed.id+',"name":'+q(placed.name)+',"clipped":true}');
  }
  doc.save();saved=true;var preview=savePreview(doc,s.preview);var working=doc.fullName.fsName;doc.close(SaveOptions.DONOTSAVECHANGES);doc=null;
  response='{"ok":true,"saved":true,"workingPsdPath":'+q(working)+',"previewPath":'+q(preview)+',"textChangedCount":'+(results.length*3)+',"imageChangedCount":'+results.length+',"catalogItems":['+results.join(',')+'],"images":['+images.join(',')+'],"warnings":[],"errors":[]}';
  writeUtf8(resultPath,response);
}catch(e){try{if(doc)doc.close(SaveOptions.DONOTSAVECHANGES);}catch(ignore2){}response='{"ok":false,"saved":'+(saved?'true':'false')+',"error":'+q(e.message||e.toString())+'}';try{writeUtf8(resultPath,response);}catch(ignore3){}}
try{app.preferences.rulerUnits=oldUnits;}catch(ignore4){}
response;
"@

  try {
    $raw = Invoke-PhotoshopJavaScript -Script $jsx
    if (Test-Path -LiteralPath $temporaryResultPath -PathType Leaf) {
      $raw = [IO.File]::ReadAllText($temporaryResultPath, $script:PsdJobUtf8NoBom)
    }
    $parsed = $raw | ConvertFrom-Json
    Write-Utf8Json -Path $ResultPath -Value $parsed | Out-Null
    if ($parsed.ok -ne $true) { throw "Catalog preparation failed: $($parsed.error)" }
    return $parsed
  } finally {
    Remove-Item -LiteralPath $settingsPath, $temporaryResultPath -Force -ErrorAction SilentlyContinue
  }
}
