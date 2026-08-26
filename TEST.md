# scheduler-workers 关键测试用例

> 供验证框架用（尤其弱模型 self-test）。跑之前：重启 opencode（加载 skill + 权限），清空 `.task-runner/{runs,messages}`。参考脚本：`scripts/worker.ps1`（脚本 worker）、`scripts/wait-event.ps1`（事件循环）。

## TC1 · 并行 + 并发上限（无交互）

- 链：3 条，各 `sleep` 8 / 12 / 8 秒，无 `ask`。并行度 N=2。
- 步骤：写 3 份 def → `Start-Process` 启动前 2 条 → 事件循环等 done → 补第 3 条。
- **通过标准**：
  1. 任意时刻 `running ≤ 2`；
  2. 总墙钟 ≈ 12s + 初始化（明显小于三者之和 28s）；
  3. 3 链全 `done`。

## TC2 · 实时交互 + 单个补位 + 正确性（有交互）

- 链：A = `sleep8 → ask → sleep3`；B = `sleep20`；C = `sleep12 → ask → sleep2`；D = `sleep6`。N=2。
- 步骤：启动 A+B → 事件循环。遇 `QUESTION` 用 `question` 工具问用户并写 `<id>.answer.json`；遇 `TERMINAL` 删消息文件并补位下一条；直到全 done。
- **通过标准**：
  1. A 的 `QUESTION` 在 A sleep 结束后 ~2s 内被事件循环检测（轮询间隔），且此时 B 仍在跑（**不是批末才送达**）；
  2. B 结束 → 启动 C；A 结束 → 启动 D；全程 `running ≤ 2`；
  3. 4 链全 `done`；A/C 的 `runs/<id>.json` 里 `steps[]` 的 ask 步骤 `result` 含 `answer=...`。

## TC3 · 互斥段

- 链：X、Y 各含**同 key** 互斥段（段内 `sleep 5` 并记录起止时间到文件），并行启动。
- **通过标准**：X/Y 互斥段窗口不重叠（一段 `END` < 另一段 `START`）。

## TC4 · 中断续跑（可选）

- 链：启动一条 `sleep 20` 的链，中途 kill 其 worker 进程。
- **通过标准**：`wait-event` 报 `DEAD`；读 `runs/<id>.json` 标记后重新启动续跑。

## 判定总表

| 用例 | 验证点 | 关键判据 |
|---|---|---|
| TC1 | 并行 + 并发上限 | running≤2；墙钟≈max 非 sum |
| TC2 | 实时交互/补位/正确性 | 询问秒级送达；补位不超 N；答案回传正确 |
| TC3 | 互斥段 | 两段窗口不重叠 |
| TC4 | 中断续跑 | DEAD 检测 + 读标记续跑 |
