function Get-PsdPageCopyJavaScript {
  # 两个入口读取同一套规则，防止预检与真正写入使用不同的重复判断。
  return ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dingdong-page-copy.js'), [Text.Encoding]::UTF8) + "`n" +
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'psd-page-copy-photoshop.js'), [Text.Encoding]::UTF8))
}

function Test-PsdPageCopy {
  param([Parameter(Mandatory = $true)][string]$DocumentPath, $Job = @{})

  $fullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DocumentPath).Path)
  $wantedJs = ConvertTo-JsString ($fullPath -replace '\\', '/')
  $plan = [ordered]@{
    workflow = if (Test-ObjectProperty $Job 'workflow') { [string]$Job.workflow } else { '' }
    textReplacements = @(Get-OptionalArray $Job 'textReplacements')
    visibilityChanges = @(Get-OptionalArray $Job 'visibilityChanges')
  }
  # 直接嵌入合法 JSON 对象，避免把含 CR 的 JSON 再转义一遍而变成字面的反斜杠 r。
  $planJs = ConvertTo-Json -InputObject $plan -Depth 30 -Compress -EscapeHandling EscapeNonAscii
  $library = Get-PsdPageCopyJavaScript
  $jsx = @"
$library
(function () {
var wanted = $wantedJs, plan = $planJs;
var doc = null, openedHere = false, previous = app.documents.length ? app.activeDocument : null;
try {
  for (var i = 0; i < app.documents.length; i++) {
    var documentPathString = '';
    try { documentPathString = String(app.documents[i].fullName.fsName).replace(/\\/g, '/'); } catch (ignore) {}
    if (documentPathString.toLowerCase() === wanted.toLowerCase()) {
      if (doc) throw new Error('page-copy-document-state: 同一来源打开多次。');
      doc = app.documents[i];
    }
  }
  if (doc && !doc.saved) throw new Error('page-copy-document-state: 来源有未保存修改。');
  if (!doc) { doc = app.open(new File(wanted)); openedHere = true; }
  var report = inspectPsdPageCopy(doc, plan);
} finally {
  // 只读扫描不保存文件；恢复原活动文档，也不关闭用户原本打开的文档。
  if (openedHere && doc) doc.close(SaveOptions.DONOTSAVECHANGES);
  if (previous) { try { app.activeDocument = previous; } catch (ignoreRestore) {} }
}
return pageCopyJson(report);
}());
"@
  return (Invoke-PhotoshopJavaScript -Script $jsx) | ConvertFrom-Json
}

function Assert-PsdPageCopy {
  param([Parameter(Mandatory = $true)][string]$DocumentPath, $Job = @{})
  $report = Test-PsdPageCopy -DocumentPath $DocumentPath -Job $Job
  if (-not $report.ok) {
    $details = @($report.errors | ForEach-Object {
      "$($_.first.board) [ID $($_.first.id)] 与 $($_.second.board) [ID $($_.second.id)]：$($_.text)"
    })
    throw "duplicate-page-copy: 整页可见文字重复，未写入。保留保护目标，处理可改文案并重新确认：$($details -join ' | ')"
  }
  return $report
}
