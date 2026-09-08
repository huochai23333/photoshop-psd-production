# 轻量 PSD 任务

## 任务格式

```json
{
  "jobVersion": 1,
  "workflow": "generic",
  "sourcePsdPath": "D:/work/source.psd",
  "targetPsdPath": "D:/work/product.psd",
  "textReplacements": [
    {
      "id": 101,
      "path": "画板1/标题",
      "oldText": "旧标题",
      "text": "新标题",
      "mode": "verbatim",
      "allowedBounds": [0, 0, 800, 200]
    }
  ],
  "imageTransfers": [
    {
      "imagePath": "D:/work/image.jpg",
      "target": { "id": 202, "path": "画板1/图片剪贴蒙版位置" },
      "name": "商品图",
      "fit": "cover",
      "clip": true
    }
  ],
  "visibilityChanges": [
    {
      "id": 303,
      "visible": false,
      "reason": "当前商品没有这个配料槽位，隐藏整组标签"
    }
  ],
  "outputs": {
    "preview": { "enabled": true, "maxWidth": 1600, "quality": 9 },
    "final": null
  },
  "organizeUsedAssets": false
}
```

`sourcePsdPath` 与 `source.templateId` 二选一。选择器可使用 `id`、`path`、`name`、`oldText`，所有已提供字段同时匹配且必须唯一。

图片也可从另一个已保存 PSD 复制：

```json
{
  "sourcePsdPath": "D:/work/detail.psd",
  "source": { "id": 301, "path": "板块1/商品图" },
  "target": { "id": 401, "path": "画板1/图片剪贴蒙版位置" },
  "fit": "cover",
  "clip": true
}
```

`visibilityChanges` 用唯一的 `id`、完整 `path` 或唯一 `name` 选择图层或组，并显式设置 `visible: true/false`。配料槽位不适用时应隐藏包含文字、底框、圆点和引导线的完整父组；不要向文字层写空字符串。准备和提交后的重开验证都会检查显隐状态。

用户明确允许当前任务临时兼容时，可在普通 `sourcePsdPath` 任务中记录授权与边界：

```json
{
  "temporaryCompatibility": {
    "userInstruction": "全部允许，遇到问题临时调整，完成后保持原规则",
    "reason": "当前正式详情与主图母版槽位不同，需要只在工作副本中适配",
    "scope": "working-copy-only"
  }
}
```

`temporaryCompatibility` 只允许用于一次性工作副本，不能与登记母版的 `templateId` 同时使用，也不能修改母版、定义或 skill 文件。

场景卡使用 `sceneCards`；每项可包含 `textTarget`/`text`、`baseTarget`/`imagePath` 和 `oldImageTarget`。新图验证通过后才删除旧图。

## 运行记录

`prepare-psd-job.ps1` 创建工作副本、执行目标修改、保存、导出预览并写入 `run.json`。`complete-psd-job.ps1` 验证源和工作副本未变化、原子提交、重开复验，并执行任务中要求的输出。默认不创建目标 PSD 备份；只有用户在当前任务中明确要求时，任务才可设置 `backupExistingTarget: true`。

旧 `schemaVersion` 任务、审批清单和运行记录不兼容；重新建立 `jobVersion: 1` 任务。
