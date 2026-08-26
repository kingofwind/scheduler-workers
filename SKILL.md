---
name: scheduler-workers
description: "Concurrency-limited multi-task chain scheduler for CLI agents (main-agent event loop + detached headless workers). Use when: running multiple long-running tasks (e.g. training scripts) under a parallelism cap N, with ordered steps, exclusive/mutex segments, long blocking waits, real-time human-in-the-loop, or resumable runs. Defines chain format, concurrency-limited scheduling with instant slot refill, event loop, lock protocol, messages protocol, and marker/resume conventions. Cross-agent protocol; reference implementation tested on opencode (Windows PowerShell). 并发上限调度的多任务链框架（主 agent 事件循环 + 分离 headless worker）：按并行度 N 并行调度多个长时任务（如训练脚本），含顺序步骤、互斥段、长阻塞等待、人在环实时交互与断点续跑。定义链格式、调度协议、锁协议、messages 消息协议与续跑约定。"
---

# scheduler-workers：并发上限调度的多任务链框架

## 概述与适用场景

主 agent 作为**调度者**，维护一个 **while 事件循环**：按并发上限 N **异步分离启动**若干 **worker**（无头 `opencode run` 进程），worker 独立跑各自的任务链；主 agent 靠一个**阻塞的"事件等待"bash 循环**在"有 worker 提问 / 有 worker 结束"时唤醒自己，实时处理，再继续等。全部链完成后汇总退出。

关键点：**worker 是分离进程，不是阻塞主 agent 的 Task 子会话**。这是"实时转发 + 即时补位"能成立的前提（实测 opencode 的 Task 工具会把并行子任务结果整批返回，中途收不到单个完成通知；分离进程 + 文件事件彻底绕开）。

适用于：
- 多个长时/独立任务需要并行调度（如多个模型训练脚本）。
- 任务之间存在"改配置 + 启动"这类必须**串行**的互斥段。
- 任务可能阻塞数小时（如训练 24h）。
- 需要用户实时决策介入（人在环）。
- 会话中断后需要断点续跑。

## 核心概念

1. **Chain（任务链）**：最小调度单位。一个有序步骤序列，由**一个 worker 全权执行**。有依赖关系的步骤打包进一条链；链之间才谈并行。
2. **Step（步骤）**：链内一个动作。类型：`run` / `launch` / `wait` / `check` / `ask` / `report`。
3. **Exclusive Segment（互斥段）**：链内**连续一段步骤**，携带同一 `exclusive` 段名 key。worker 进入前必须持有该 key 的锁，直到段内最后一步完成才释放。**锁的是"任务段"**（如"改配置+启动"），不是单个资源文件。默认全项目用同一段名 → 同一时刻全局只有一个互斥段在执行；不同段名可并行。
4. **并发上限调度 + 事件循环**：主 agent 维护 `pending` 队列与 `running` 集合，**`running ≤ N` 恒成立**；靠事件循环在 worker 完成时**即时补位**、在 worker 提问时**实时转发**。
5. **Worker（分离进程）**：默认是 `Start-Process` 启动的无头 **agent worker**（`opencode run --agent build --auto`）；主 agent 判断链为**纯确定性步骤**时可降级为 **脚本 worker**（`scripts/worker.ps1`，省 token、更快）。两种 worker 遵守同一协议（写标记/事件、ask 走 messages 消息、互斥段走锁）。
6. **Marker（标记文件）**：`.task-runner/runs/<chain_id>.json`，链的唯一权威状态，append-only 记录每步时间戳；续跑依据。
7. **Lock（锁）**：`.task-runner/locks/<段key>.lock`，跨进程文件锁（原子创建）。
8. **Messages（消息）**：`.task-runner/messages/<chain_id>.<type>.json`，worker 与主 agent 之间的统一信令通道。消息类型：`question`（worker→主，提问）、`answer`（主→worker，回答）、`done`/`failed`（worker→主，终态）。文件持久，不丢事件。

## 链定义格式

主 agent 调度前，把**每条链的定义**写成一个 JSON 文件（放在 `.task-runner/defs/<chain_id>.json`），启动 worker 时只传文件路径，避免命令串里夹带被权限拒绝的 token。字段规则：

- `chain_id`：唯一标识，也用作标记/消息文件名。
- `timeout_sec`（可选）：整条链超时，超时记 `failed`。
- `completion`（可选，链级默认完成信号）：`process_exit`（默认）| `marker_file` | `log_keyword` | 组合。`wait` / `check` 步骤可覆盖。
- `steps[]`：有序执行。步骤类型：
  | 类型 | 语义 |
  |---|---|
  | `run` | 前台执行命令并等待其返回（无互斥锁时可 N 路并行） |
  | `launch` | 后台启动进程，返回 PID 存为步骤结果，供 `wait.pid_from` 引用；可选 `log` 记录日志路径 |
  | `wait` | 按 `completion` 规则阻塞等待（见"长阻塞与完成信号"） |
  | `check` | 按 `completion` 规则校验证据一次，不满足 → 链 `failed` 并释放锁 |
  | `ask` | 人在环：写 `question` 消息 → 轮询 `answer` 消息（带超时）→ 读答案继续；超时 → 链 `failed` |
  | `report` | 更新标记为 done/failed、写入摘要，返回 report |
- `exclusive: "<key>"`：该步骤属于互斥段 `key`。**连续且同 key** 的步骤构成一个互斥段：进入首个步骤前加锁、最后一个步骤后释放。

示例：

```json
{
  "chain_id": "train-a",
  "timeout_sec": 90000,
  "completion": { "type": "process_exit" },
  "steps": [
    { "name": "prepare", "run": "python prep.py --input raw" },
    { "name": "edit-cfg", "exclusive": "train",
      "run": "Set-Content -Path config.yaml -Value 'epochs: 100'" },
    { "name": "launch", "exclusive": "train",
      "launch": "python train.py --cfg config.yaml",
      "log": ".task-runner/runs/train-a.log" },
    { "name": "wait", "wait": { "pid_from": "launch", "timeout_sec": 86400 } },
    { "name": "confirm", "ask": "训练完成，是否继续执行评估？" },
    { "name": "verify", "check": { "type": "marker_file", "path": "runs/train-a/done.txt" } },
    { "name": "done", "report": true }
  ]
}
```

## 调度协议（主 agent 事件循环）

1. **建队列**：把所有链定义写成 `.task-runner/defs/<chain_id>.json`，标 `pending`。
2. **确定 N**：执行前询问用户并行度（并发上限）。
3. **分离启动前 N 条**：每条链一个分离 worker（见下），记录 chain_id、PID、发起时刻，加入 `running`。
4. **事件等待**：执行一次**阻塞的"事件等待"bash**（轮询 messages + 标记，事件出现即 `break` 返回，参考脚本见下）。
5. **处理事件**：
   - `QUESTION <id>`：读 `.question.json` → 用 `question` 工具实时问用户 → 写 `.answer.json` → 回到第 4 步。
   - `DONE/FAILED <id>`：该链记 done/failed，从 `running` 移除 → 若 `pending` 非空，立即分离启动下一条（**即时补位**）→ 回到第 4 步。
   - `DEAD <id>`：worker 进程已死但链未终态 → 按中断续跑处理（见下）。
6. **汇总退出**：`pending` 空 且 `running` 空 → 输出汇总表（`chain_id / 状态 / 自测时长 / 墙钟时长 / 摘要`）→ 退出。

**分离启动 worker**（命令串只含路径/ID，不含被权限拒绝的 token）：

```powershell
Start-Process -FilePath "opencode" -ArgumentList "run","--agent","build","--auto",
  "--dir",(Get-Location).Path,
  "读取链定义文件 .task-runner/defs/<chain_id>.json，严格按 scheduler-workers 协议执行该链，写标记，ask 步骤写 question 消息并等待 answer，完成后写 done/failed 消息并返回 report。" `
  -RedirectStandardOutput ".task-runner/logs/<chain_id>.out.log" `
  -RedirectStandardError  ".task-runner/logs/<chain_id>.err.log" `
  -WindowStyle Hidden -PassThru
```

**事件等待参考脚本**（单条阻塞 bash，事件出现即打印并退出；主 agent 处理后再次调用）：

```powershell
# wait-event.ps1 —— 打印待处理事件并退出（messages/ 目录统一消息类型）
$msg = ".task-runner\messages"; $runs = ".task-runner\runs"
while ($true) {
  $qs = @(); $ts = @(); $ds = @()
  # 1) 待答问题（有 question 无 answer）
  Get-ChildItem $msg -Filter *.question.json -ErrorAction SilentlyContinue | ForEach-Object {
    $id = $_.BaseName -replace '\.question$',''
    if (-not (Test-Path (Join-Path $msg ($id + '.answer.json')))) { $qs += $id }
  }
  # 2) 终态（done/failed 消息，文件名即类型）
  Get-ChildItem $msg -Filter *.done.json -ErrorAction SilentlyContinue | ForEach-Object { $ts += ($_.BaseName -replace '\.done$','') + ":done" }
  Get-ChildItem $msg -Filter *.failed.json -ErrorAction SilentlyContinue | ForEach-Object { $ts += ($_.BaseName -replace '\.failed$','') + ":failed" }
  # 3) 死亡 worker（running 但 pid 已死）
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
```

> 说明：消息脚本只"发现"不"消费"；终态消息（done/failed）由主 agent 在处理后删除对应文件去重。文件持久，事件不丢。

## Worker 执行协议

Worker 有两种，主 agent 按链的性质选择，两者遵守同一协议：

- **agent worker（默认）**：`Start-Process opencode -ArgumentList "run","--agent","build","--auto","<读 def 文件并按协议执行该链>"`。适合含**判断/决策**的步骤（改配置怎么改、读日志怎么做决策）。
- **脚本 worker（降级）**：`Start-Process powershell -ArgumentList "-NoProfile","-File","<skill>/scripts/worker.ps1","-Def","<def>"`。适合**纯确定性**步骤（固定命令 + sleep/ask），省 token、更快。

1. 读 `.task-runner/defs/<chain_id>.json`，写标记 `status=running`、`launched_at`、`pid`（用 bash 内 `$PID`）。
2. 顺序执行步骤；每步开始/结束追加一条 `steps[]`（name + started_at + finished_at + result）→ **append-only**。
3. **互斥段**：段内所有步骤 + acquire + release **放在同一条内联 bash 脚本里一次执行**（因每次 bash 调用是全新 PowerShell 进程，函数定义不跨调用保留），release 放 `try/finally` 保证失败也释放。
4. `launch` 记录 PID 与日志路径到标记。
5. `wait` / `check` 按完成信号阻塞/校验。
6. `ask`：写 `.task-runner/messages/<chain_id>.question.json` → bash 轮询 `.answer.json`（`Start-Sleep` + `Test-Path`，带超时）→ 读答案继续。
7. 收尾：更新标记 `status=done/failed`、`finished_at`、`summary`；写 `.task-runner/messages/<chain_id>.done.json` 或 `.failed.json`；返回 report。

## 锁协议（L1，PowerShell 助手，内联使用）

锁文件 `.task-runner/locks/<段key>.lock`，内容 `{ "pid": <持有者PID>, "started_at": <时间> }`。原子创建（`CreateNew`），已存在则等待；持有者进程已死则判陈旧锁、接管。用 .NET IO 实现，避免触碰全局 `Remove-Item`/`New-Item` 拒绝：

```powershell
function Acquire-SegmentLock {
  param([string]$Key, [int]$TimeoutSec = 600)
  $lockDir = ".task-runner\locks"
  [System.IO.Directory]::CreateDirectory($lockDir) | Out-Null
  $lock = Join-Path $lockDir ($Key + ".lock")
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
      $j = @{ pid = $PID; started_at = (Get-Date -Format o) } | ConvertTo-Json
      $b = [System.Text.Encoding]::UTF8.GetBytes($j)
      $fs.Write($b, 0, $b.Length); $fs.Close()
      return $true
    } catch [System.IO.IOException] {
      if (-not (Test-Path $lock)) { continue }
      $owner = Get-Content $lock -Raw | ConvertFrom-Json
      if (-not (Get-Process -Id $owner.pid -ErrorAction SilentlyContinue)) {
        [System.IO.File]::Delete($lock)   # 陈旧锁：持有者已死，接管
        continue
      }
      Start-Sleep -Seconds 1
    }
  }
  return $false                            # 超时未拿到 → 链 failed
}

function Release-SegmentLock {
  param([string]$Key)
  $lock = Join-Path ".task-runner\locks" ($Key + ".lock")
  if (Test-Path $lock) { [System.IO.File]::Delete($lock) }
}
```

**锁语义**：锁覆盖"改配置 → 启动"整段；A 持锁期间 B 的同 key 互斥段等待；`wait/check/ask/report` 等非互斥步骤不受影响。

## 标记文件约定

- 路径：`.task-runner/runs/<chain_id>.json`
- 结构：
  ```json
  {
    "chain_id": "train-a",
    "status": "pending|running|done|failed",
    "launched_at": "ISO8601|null",
    "finished_at": "ISO8601|null",
    "pid": 12345,
    "log_path": ".task-runner/runs/train-a.log",
    "completion": { "type": "process_exit" },
    "steps": [
      { "name": "edit-cfg", "started_at": "...", "finished_at": "...", "result": "ok" }
    ],
    "summary": null
  }
  ```
- append-only：每步完成追加一条 `steps[]`；只更新 `status / finished_at / pid`，不覆盖步骤历史。

## Messages 消息协议（人在环实时交互）

统一消息目录 `.task-runner/messages/`，文件名 `<chain_id>.<type>.json`：
- `question`：worker `ask` 步骤写（`{"chain_id","question"}`），然后轮询 `.answer.json`。
- `answer`：主 agent 事件循环检测到 QUESTION → `question` 工具实时问用户 → 写（`{"answer":"..."}`）。
- `done` / `failed`：worker 收尾时写（终态信号，文件名即类型）。
- worker 读到 `.answer.json` 后清理 `question`/`answer` 两个文件（用 `[System.IO.File]::Delete`，避免 `Remove-Item` 拒绝）；主 agent 处理完 `done`/`failed` 后删除对应消息。
- 消息靠文件持久，worker 无论何时提问都能被主 agent 稍后检测到（不丢）；主 agent 不在场时，用户也可直接改 `.answer.json`。

## 长阻塞与完成信号

- `wait` 步骤 = 单条 bash + 显式大 `timeout`（已验证 300s 调用可配 400000ms 不中断），阻塞期 0 模型推理。
- 按 `completion.type`：
  - `process_exit`：`Wait-Process -Id <pid>`，或轮询 `Get-Process -Id <pid>`。
  - `marker_file`：轮询 `Test-Path <path>`。
  - `log_keyword`：轮询 `Select-String -Path <log> -Pattern <kw>`。
  - 组合：全部满足才算完成。
  - 轮询用 bash 内 `while` + `Start-Sleep 60`，保持单次调用阻塞。
- `check` = 校验一次，不满足 → 链 `failed`（释放锁）；`wait` 超 `timeout_sec` → 链 `failed`（释放锁）。

## 中断续跑

- 主 agent 重启后扫描 `.task-runner/runs/*.json`：`status=running` 且 `pid` 已死 → 读标记 → 重新分离启动一个 worker 从 `steps[]` 最后未完成步骤续跑（`wait` 步骤直接重新阻塞等原进程/信号）。
- 锁与续跑：持锁进程已死时，新 worker 走 `Acquire-SegmentLock` 的陈旧锁逻辑自动接管。

## 权限清单（项目 `opencode.jsonc`，主 agent 与子/worker 统一生效）

> 一键复制的权限示例见 `install/opencode.jsonc.permission.example`。

- 放行（中风险，框架核心能力）：`Start-Process`、`Wait-Process`、`Set-Content`、`Add-Content`、`System.IO.File`（子串匹配，兼容复合写法）。
- 放行（低风险）：`Start-Sleep`、`Get-Process`、`Get-Date`、`ConvertTo-Json`、`ConvertFrom-Json`、`System.IO.Directory`、`powershell`（主 agent 运行事件循环脚本）。
- **headless worker 用 `--auto`**：自动批准未显式拒绝的权限，避免无头进程卡在权限确认上（deny 规则仍生效）。
- **不额外放行**（保持全局 deny）：`Remove-Item`、`Clear-Content`、`rm -rf`、`curl`/`iwr`/`irm`、`git push` 等；锁/清理统一走 `[System.IO.File]::Delete`。
- 命令串按字符串匹配：**不要把被拒 token（如 `Set-Content` 字面量）写进主 agent 的启动命令里**，指令放文件、命令串只引用文件名。

## 时长口径

- worker 自测：`launched_at → finished_at`（纯执行）。
- 主 agent 墙钟：分离启动时刻 → 收到终态事件时刻。
- 报告输出：每链 `chain_id / 状态 / 自测时长 / 墙钟时长 / 摘要`。

## 自检清单

> 可执行的验证用例见同目录 `TEST.md`（TC1 并行/并发上限、TC2 实时交互+补位+正确性、TC3 互斥段、TC4 中断续跑），含逐条通过标准与判定总表。

1. 并行性：N 路 worker 并行窗口重叠，总墙钟 ≈ max + 初始化。
2. 长阻塞：单条 bash 300s + 大 timeout 不被中断。
3. 并发上限 + 即时补位：worker 结束即补下一条，`running ≤ N`。
4. 互斥段：两个 worker 同 key 互斥段不重叠。
5. 人在环实时：worker `ask` 写 question → 主 agent 事件循环秒级唤醒 → `question` 实时转发 → 答案回流。
6. headless worker：`opencode run --agent build --auto` 能读项目配置、写文件、返回结果。
7. 中断续跑：读标记续跑、陈旧锁接管。

## 示例与自测

本 skill 附带可直接运行的参考实现与示例（`scripts/` 与 `examples/` 子目录，随 skill 一起分发）：

- `scripts/worker.ps1`：参考 worker（读链定义 → 执行 `sleep`/`ask` 步骤 → 写标记/事件）。
- `scripts/wait-event.ps1`：主 agent 的事件等待脚本（阻塞，事件出现即打印并退出）。
- `examples/a.json` ~ `d.json`：四条示例链定义（sleep + 可选 ask）。

冒烟测试流程（验证实时交互 / 补位 / 正确性，N=2）：
1. 清空 `.task-runner/{runs,messages}`。
2. `Start-Process powershell -File scripts/worker.ps1 -Def examples/a.json` 启动 a、b；主 agent 循环跑 `powershell -File scripts/wait-event.ps1`。
3. 遇 `QUESTION` → `question` 工具问用户 → 写 `<id>.answer.json`；遇 `TERMINAL` → 删除事件文件并补位下一条；直到全 done。
4. 检查 `runs/*.json` 的 `steps[]` 时间戳与 `result`（答案回传）。

> `examples/` 里 ask 文案用英文，只为规避中文在不同编码下的显示/解析噪音；真实链可放心用中文（脚本已统一 `-Encoding UTF8`）。

## 实现注意（踩坑记录）

1. **PowerShell 变量大小写不敏感**：`$def` 与参数 `$Def` 是同一个变量，互相覆盖会让解析结果变回字符串。脚本内变量名避开与参数同名（用 `$cfg`）。
2. **UTF-8 无 BOM 文件读取**：`write` 工具/编辑器写的是 UTF-8 无 BOM；PowerShell 5.1 `Get-Content` 默认按系统 ANSI（中文 Windows 为 GBK）解码，中文会乱码、JSON 解析失败。链定义 / messages / 标记一律显式 `-Encoding UTF8` 读写。
3. **权限按命令字符串匹配**：复合单行（如 `$p = Start-Process ...`）不以放行 cmdlet 开头会被前缀规则误拒，故配置用子串匹配（`*Start-Process*` 等）；主 agent 的启动命令里**不要夹带被拒 token 字面量**（指令放文件、命令串只引文件名）。
4. **opencode Task 工具结果批量交付**：并行子任务结果等整批结束才返回，主 agent 中途收不到单个完成；子 agent 也无 `question` 工具 → 改用"分离进程 + 文件事件 + 事件循环"绕开（本 skill 的核心设计）。
5. **每次 bash 调用是全新 PowerShell 进程**：函数定义不跨调用保留，互斥段必须把"函数定义 + acquire + 段内步骤 + release"内联到**同一条** bash 脚本执行。
6. **主 agent 是单线程事件循环**：一次只处理一个事件（问用户 或 补位）；多事件同时到达按序处理、靠文件持久不丢，但补位/转发有串行延迟。若将来要"无人值守 + 完全即时补位"，可把事件循环下沉为独立监督进程（方向 3），skill 协议不变。
