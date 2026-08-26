param([string]$Def)
$cfg = Get-Content $Def -Raw -Encoding UTF8 | ConvertFrom-Json
$id = $cfg.chain_id
$runs = ".task-runner\runs"
$msg = ".task-runner\messages"
$failed = $false
$steps = @()
$marker = [ordered]@{ chain_id = $id; status = "running"; launched_at = (Get-Date -Format o); pid = $PID; steps = @() }
Set-Content -Path "$runs\$id.json" -Value ($marker | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
foreach ($s in $cfg.steps) {
  $st = Get-Date
  $res = "ok"
  if ($s.sleep) { Start-Sleep -Seconds ([int]$s.sleep) }
  if ($s.ask) {
    $q = @{ chain_id = $id; question = $s.ask }
    Set-Content -Path "$msg\$id.question.json" -Value ($q | ConvertTo-Json -Compress) -Encoding UTF8
    $ans = "$msg\$id.answer.json"
    $dl = (Get-Date).AddSeconds(300)
    $got = $false
    while ((Get-Date) -lt $dl) {
      if (Test-Path $ans) { $got = $true; break }
      Start-Sleep -Seconds 1
    }
    if ($got) {
      $a = (Get-Content $ans -Raw -Encoding UTF8).Trim()
      $res = "answer=" + $a
      [System.IO.File]::Delete($ans)
      [System.IO.File]::Delete("$msg\$id.question.json")
    } else {
      $failed = $true; $res = "ask-timeout"
    }
  }
  $steps += [ordered]@{ name = $s.name; started_at = $st.ToString("o"); finished_at = (Get-Date).ToString("o"); result = $res }
}
$marker.status = if ($failed) { "failed" } else { "done" }
$marker.finished_at = (Get-Date -Format o)
$marker.steps = $steps
Set-Content -Path "$runs\$id.json" -Value ($marker | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
$type = if ($failed) { "failed" } else { "done" }
Set-Content -Path "$msg\$id.$type.json" -Value (@{ chain_id = $id; status = $type } | ConvertTo-Json -Compress) -Encoding UTF8
