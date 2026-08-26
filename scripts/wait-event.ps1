$msg = ".task-runner\messages"; $runs = ".task-runner\runs"
while ($true) {
  $qs = @(); $ts = @(); $ds = @()
  Get-ChildItem $msg -Filter *.question.json -ErrorAction SilentlyContinue | ForEach-Object {
    $id = $_.BaseName -replace '\.question$',''
    if (-not (Test-Path (Join-Path $msg ($id + '.answer.json')))) { $qs += $id }
  }
  Get-ChildItem $msg -Filter *.done.json -ErrorAction SilentlyContinue | ForEach-Object {
    $ts += ($_.BaseName -replace '\.done$','') + ":done"
  }
  Get-ChildItem $msg -Filter *.failed.json -ErrorAction SilentlyContinue | ForEach-Object {
    $ts += ($_.BaseName -replace '\.failed$','') + ":failed"
  }
  Get-ChildItem $runs -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object {
    $m = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($m.status -eq 'running' -and $m.pid -and -not (Get-Process -Id $m.pid -ErrorAction SilentlyContinue)) { $ds += $m.chain_id }
  }
  if ($qs.Count -gt 0 -or $ts.Count -gt 0 -or $ds.Count -gt 0) {
    foreach ($q in $qs) { Write-Output ("QUESTION " + $q) }
    foreach ($t in $ts) { Write-Output ("TERMINAL " + $t) }
    foreach ($d in $ds) { Write-Output ("DEAD " + $d) }
    break
  }
  Start-Sleep -Seconds 2
}
