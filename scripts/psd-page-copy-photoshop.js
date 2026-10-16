/* 从真实文档读取全部文字及父组，不能用待改列表代替整页内容。 */
function inspectPsdPageCopy(doc, plan) {
  var layers = [];
  function collect(container, parentId, prefix) {
    for (var i = 0; i < container.layers.length; i++) {
      var layer = container.layers[i];
      var path = prefix ? prefix + '/' + layer.name : layer.name;
      var kind = '', text = '', opacity = 100;
      try { kind = String(layer.kind); } catch (ignoreKind) {}
      if (kind === 'LayerKind.TEXT') text = String(layer.textItem.contents);
      try { opacity = Number(layer.opacity); } catch (ignoreOpacity) {}
      layers.push({ id: layer.id, parentId: parentId, name: String(layer.name), path: path,
        typename: String(layer.typename), kind: kind, text: text,
        visible: Boolean(layer.visible), opacity: opacity });
      if (layer.typename === 'LayerSet') collect(layer, layer.id, path);
    }
  }
  collect(doc, null, '');
  return DingdongPageCopy.inspect(layers, plan);
}
function assertPsdPageCopy(doc, plan) {
  var report = inspectPsdPageCopy(doc, plan);
  if (!report.ok) {
    var messages = [];
    for (var i = 0; i < report.errors.length; i++) {
      var issue = report.errors[i];
      messages.push(issue.first.board + ' [ID ' + issue.first.id + '] 与 ' + issue.second.board +
        ' [ID ' + issue.second.id + '] 重复：' + issue.text);
    }
    throw new Error('duplicate-page-copy: 整页文案重复，尚未写入。请保留受保护文字，处理可改候选并重新确认：' + messages.join(' | '));
  }
  return report;
}
function pageCopyJson(value) {
  // ExtendScript 某些版本没有原生 JSON；仅序列化检查结果，不执行外部内容。
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'string') return '"' + value.replace(/["\\\u0000-\u001f]/g, function (c) {
    var hex = c.charCodeAt(0).toString(16);
    return '\\u' + ('0000' + hex).slice(-4);
  }) + '"';
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  var parts = [], i;
  if (Object.prototype.toString.call(value) === '[object Array]') {
    for (i = 0; i < value.length; i++) parts.push(pageCopyJson(value[i]));
    return '[' + parts.join(',') + ']';
  }
  for (i in value) if (Object.prototype.hasOwnProperty.call(value, i)) parts.push(pageCopyJson(i) + ':' + pageCopyJson(value[i]));
  return '{' + parts.join(',') + '}';
}
