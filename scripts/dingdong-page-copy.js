/* 整页检查只计算计划结果，不修改传入图层；同一实现供 Photoshop 与自动测试使用。 */
var DingdongPageCopy = (function () {
  function normalized(text) {
    // 忽略排版换行、空白及标点，避免通过换行或引号掩盖相同文案。
    return String(text || '').replace(/[\s\u3000\u200b-\u200d\ufeff]/g, '')
      .replace(/[^a-zA-Z0-9\u3400-\u9fff]/g, '').toLowerCase();
  }
  function meaningful(text) {
    // 短卖点可按原规则间隔复用；机器只硬拦截完整长句，不机械禁止品牌装饰。
    var chinese = text.match(/[\u3400-\u9fff]/g);
    return text.length >= 8 && chinese && chinese.length >= 6;
  }
  function matches(layer, selector) {
    var constrained = false, ok = true;
    if (selector.id !== undefined && selector.id !== null && Number(selector.id) !== 0) {
      constrained = true; ok = ok && String(layer.id) === String(selector.id);
    }
    if (selector.path) { constrained = true; ok = ok && layer.path === selector.path; }
    if (selector.name) { constrained = true; ok = ok && layer.name === selector.name; }
    if (selector.oldText !== undefined && selector.oldText !== null) {
      constrained = true; ok = ok && String(layer.text || '') === String(selector.oldText);
    }
    return constrained && ok;
  }
  function inspect(layers, plan) {
    plan = plan || {};
    var byId = {}, states = {}, resolved = {}, boardIds = {}, errors = [], records = [];
    var boardCount = 0, i, j, key;
    for (i = 0; i < layers.length; i++) {
      key = '$' + layers[i].id;
      if (byId[key]) throw new Error('page-copy-invalid-index: 图层 ID 重复。');
      byId[key] = layers[i];
      states[key] = { visible: layers[i].visible !== false, text: String(layers[i].text || '') };
      if (layers[i].typename === 'LayerSet' && /^(头版|版[0-9]+|尾版)$/.test(layers[i].name)) {
        boardIds[key] = layers[i]; boardCount++;
      }
    }
    var applicable = boardCount >= 2;
    if (!applicable && plan.workflow !== 'dingdong-detail') {
      return { ok: true, applicable: false, checkedTextCount: 0, boardCount: 0, errors: [] };
    }
    if (!applicable) throw new Error('page-copy-missing-boards: 无法识别详情页板块，不能宣称整页检查通过。');

    function target(selector) {
      var found = [];
      for (var index = 0; index < layers.length; index++) {
        if (matches(layers[index], selector)) found.push(layers[index]);
      }
      if (found.length !== 1) throw new Error('page-copy-selector: 目标必须唯一匹配实际图层。');
      return found[0];
    }
    var replacements = plan.textReplacements || [], changes = plan.visibilityChanges || [];
    for (i = 0; i < replacements.length; i++) {
      var changed = target(replacements[i]);
      if (changed.kind !== 'LayerKind.TEXT') throw new Error('page-copy-selector: 替换目标不是文字。');
      if (resolved['$' + changed.id]) throw new Error('page-copy-selector: 同一文字目标出现多次。');
      resolved['$' + changed.id] = true;
      states['$' + changed.id].text = String(replacements[i].text);
    }
    for (i = 0; i < changes.length; i++) {
      var visibleTarget = target(changes[i]);
      states['$' + visibleTarget.id].visible = Boolean(changes[i].visible);
    }
    function ancestry(layer) {
      var current = layer, board = null, visible = true, visited = {};
      while (current) {
        var id = '$' + current.id;
        if (visited[id]) throw new Error('page-copy-invalid-index: 图层父子关系成环。');
        visited[id] = true;
        visible = visible && states[id].visible && current.opacity !== 0;
        if (!board && boardIds[id]) board = current;
        if (current.parentId === null || current.parentId === undefined) break;
        current = byId['$' + current.parentId];
        if (!current) throw new Error('page-copy-invalid-index: 缺少父组，无法判断可见性。');
      }
      return { board: board, visible: visible };
    }
    var formalNames = {};
    // 现行详情模板 ID 10 是正式品名：按替换后的完整品名排除精确名称复现，不排除卖点句。
    if (byId.$10 && byId.$10.kind === 'LayerKind.TEXT') {
      var nameContext = ancestry(byId.$10);
      if (nameContext.board && nameContext.board.name === '头版') formalNames['$' + normalized(states.$10.text)] = true;
    }
    var occurrences = {}, emitted = {};
    for (i = 0; i < layers.length; i++) {
      var layer = layers[i];
      if (layer.kind !== 'LayerKind.TEXT') continue;
      var context = ancestry(layer);
      if (!context.visible || !context.board || !normalized(states['$' + layer.id].text)) continue;
      records.push({ id: layer.id, path: layer.path, board: context.board.name, text: states['$' + layer.id].text });
      var text = states['$' + layer.id].text;
      var candidates = [text].concat(text.split(/[\r\n]+/), text.split(/[。！？；!?;]+/));
      var local = {};
      for (j = 0; j < candidates.length; j++) {
        var phrase = normalized(candidates[j]);
        key = '$' + phrase;
        if (!meaningful(phrase) || formalNames[key] || local[key]) continue;
        local[key] = true;
        var previous = occurrences[key] || [];
        for (var k = 0; k < previous.length; k++) {
          var other = previous[k];
          if (other.boardId === context.board.id) continue;
          var pair = [String(other.id), String(layer.id)].sort().join(':');
          if (emitted[pair]) continue;
          emitted[pair] = true;
          errors.push({ code: 'duplicate-page-copy', text: candidates[j], normalizedText: phrase,
            first: other, second: { id: layer.id, path: layer.path, board: context.board.name,
              boardId: context.board.id, changed: Boolean(resolved['$' + layer.id]) } });
        }
        previous.push({ id: layer.id, path: layer.path, board: context.board.name,
          boardId: context.board.id, changed: Boolean(resolved['$' + layer.id]) });
        occurrences[key] = previous;
      }
    }
    return { ok: errors.length === 0, applicable: true, checkedTextCount: records.length,
      boardCount: boardCount, errors: errors };
  }
  return { inspect: inspect };
}());
if (typeof module !== 'undefined' && module.exports) module.exports = DingdongPageCopy;
