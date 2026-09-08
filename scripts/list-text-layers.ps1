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
  try { return Number(v.value); } catch (e) {}
  try { return Number(v); } catch (e2) {}
  return 0;
}

function textValue(layer) {
  try { return layer.textItem.contents; } catch (e) { return ''; }
}

function textSize(layer) {
  try { return n(layer.textItem.size); } catch (e) { return 0; }
}

var rows = [];

function walk(container, path) {
  for (var i = 0; i < container.layers.length; i++) {
    var layer = container.layers[i];
    var currentPath = path ? path + '/' + layer.name : layer.name;

    if (layer.typename == 'ArtLayer' && layer.kind == LayerKind.TEXT) {
      var b = layer.bounds;
      rows.push(
        '{' +
          '"index":' + rows.length + ',' +
          '"id":' + layer.id + ',' +
          '"name":' + q(layer.name) + ',' +
          '"path":' + q(currentPath) + ',' +
          '"visible":' + layer.visible + ',' +
          '"text":' + q(textValue(layer)) + ',' +
          '"size":' + textSize(layer) + ',' +
          '"bounds":[' + [n(b[0]), n(b[1]), n(b[2]), n(b[3])].join(',') + ']' +
        '}'
      );
    } else if (layer.typename == 'LayerSet') {
      walk(layer, currentPath);
    }
  }
}

walk(app.activeDocument, '');
'[' + rows.join(',') + ']';
'@

$app.DoJavaScript($jsx)
