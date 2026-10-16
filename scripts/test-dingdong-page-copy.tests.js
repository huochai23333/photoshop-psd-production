/* 使用真实图层结构与计划新文验证行为，不通过匹配实现代码来假装检查有效。 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const checker = require('./dingdong-page-copy.js');
let checks = 0;
function check(name, action) { action(); checks++; process.stdout.write(`PASS: ${name}\n`); }
function group(id, name, parentId = null, visible = true) {
  return { id, name, path: name, parentId, visible, typename: 'LayerSet' };
}
function text(id, parentId, value, visible = true) {
  return { id, parentId, name: String(id), path: `${parentId}/${id}`, kind: 'LayerKind.TEXT',
    typename: 'ArtLayer', visible, text: value };
}
const title = '宅家开火 从容不匆忙\r陪你度过美味“好食光”\r';
const fixture = [group(7, '版7'), group(8, '版8'), group(80, '标题组', 8),
  text(71, 7, '另一个板块已有文案'), text(81, 80, '宅家开火 从容不匆忙\r'),
  text(82, 80, '陪你度过美味“好食光”\r')];
check('新文与未修改的可见标题重复时拒绝，保留双方位置及修改状态', () => {
  const report = checker.inspect(fixture, { textReplacements: [{ id: 71, text: title }] });
  assert.equal(report.ok, false);
  assert.equal(report.checkedTextCount, 3);
  assert(report.errors.some(x => x.first.id === 71 && x.second.id === 81));
  assert.equal(report.errors[0].first.changed, true);
  assert.equal(report.errors[0].second.changed, false);
});
check('消除重复后通过，不修改传入的原始图层', () => {
  const duplicate = fixture.map(x => ({ ...x })); duplicate[3].text = title;
  const before = JSON.stringify(duplicate);
  assert.equal(checker.inspect(duplicate, { textReplacements: [{ id: 71, text: '省去切配麻烦 下厨更省时' }] }).ok, true);
  assert.equal(JSON.stringify(duplicate), before);
});
check('无需本次替换也能发现原页面已有重复', () => {
  const duplicate = fixture.map(x => ({ ...x })); duplicate[3].text = title;
  assert.equal(checker.inspect(duplicate, {}).ok, false);
});
check('父组隐藏时不误报；计划显示该父组后必须拦截', () => {
  const hidden = fixture.map(x => ({ ...x })); hidden[2].visible = false;
  const plan = { textReplacements: [{ id: 71, text: title }] };
  assert.equal(checker.inspect(hidden, plan).ok, true);
  assert.equal(checker.inspect(hidden, { ...plan, visibilityChanges: [{ id: 80, visible: true }] }).ok, false);
});
check('显隐计划影响有效可见性，不将隐藏文字误算成页面输出', () => {
  assert.equal(checker.inspect(fixture, { textReplacements: [{ id: 71, text: title }],
    visibilityChanges: [{ id: 7, visible: false }] }).ok, true);
});
check('两个新目标之间重复也拒绝', () => {
  const value = '新鲜食材带来丰富滋味';
  assert.equal(checker.inspect(fixture, { textReplacements: [{ id: 71, text: value }, { id: 81, text: value }] }).ok, false);
});
check('标点、空白及换行的变化不能掩盖重复', () => {
  const report = checker.inspect(fixture, { textReplacements: [{ id: 71, text: '宅家开火，\n从容不匆忙！' }] });
  assert.equal(report.ok, false);
});
check('短词、装饰文字、普通名称不被机械禁止', () => {
  const short = [group(7, '版7'), group(8, '版8'), text(71, 7, '开盒即涮\rHAO SHI GUANG'),
    text(81, 8, '开盒即涮\rHAO SHI GUANG')];
  assert.equal(checker.inspect(short, {}).ok, true);
});
check('正式品名可重复；相同的长卖点仍然拒绝', () => {
  const product = [group(1, '头版'), group(7, '版7'), group(8, '版8'),
    text(10, 1, '叮咚好食光九层塔巴掌牛肉'), text(71, 7, '叮咚好食光九层塔巴掌牛肉')];
  assert.equal(checker.inspect(product, {}).ok, true);
  product.push(text(72, 7, '甄选黄牛鲜牛腿肉'), text(81, 8, '甄选黄牛鲜牛腿肉'));
  assert.equal(checker.inspect(product, {}).ok, false);
});
check('文字图层隐藏或祖先透明时排除；同一板块不误算成跨板重复', () => {
  const same = fixture.map(x => ({ ...x })); same[3].text = title; same[1].opacity = 0;
  assert.equal(checker.inspect(same, {}).ok, true);
  same.push(text(72, 7, title));
  assert.equal(checker.inspect(same, {}).ok, true);
});
check('无效目标、重复目标或不完整父组结构不能悄悄跳过', () => {
  assert.throws(() => checker.inspect(fixture, { textReplacements: [{ id: 71, oldText: '错误旧文', text: title }] }), /page-copy-selector/);
  assert.throws(() => checker.inspect(fixture, { textReplacements: [{ id: 999, text: title }] }), /page-copy-selector/);
  assert.throws(() => checker.inspect(fixture, { textReplacements: [{ id: 71, text: title }, { id: 71, text: title }] }), /page-copy-selector/);
  assert.throws(() => checker.inspect(fixture.filter(x => x.id !== 80), {}), /page-copy-invalid-index/);
});
check('不把主图跨画板的正常同步当成详情页重复；详情模式缺少板块则报错', () => {
  const main = [group(7, '画板7'), group(8, '画板8'), text(71, 7, title), text(81, 8, title)];
  assert.equal(checker.inspect(main, {}).applicable, false);
  assert.throws(() => checker.inspect(main, { workflow: 'dingdong-detail' }), /page-copy-missing-boards/);
});
check('使用登记模板的完整索引复现版7与原有版8标题冲突', () => {
  const index = JSON.parse(fs.readFileSync(path.join(__dirname,
    '../assets/templates/indexes/dingdong-haoshiguang-detail-1step.index.json'), 'utf8').replace(/^\ufeff/, ''));
  const report = checker.inspect(index.documents[0].layers, { textReplacements: [{ id: 3911, text: title }] });
  assert.equal(report.ok, false);
  assert(report.errors.some(x => [x.first.id, x.second.id].includes(3911) &&
    [x.first.id, x.second.id].includes(2711)));
});
process.stdout.write(`PASS: ${checks} whole-page copy cases completed\n`);
