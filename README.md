# scheduler-workers

Concurrency-limited multi-task chain scheduler for CLI coding agents. Run many long-running tasks (e.g. model training scripts) in parallel under a parallelism cap, with exclusive/mutex segments, real-time human-in-the-loop, and resumable state — all via a **file-based protocol** and **detached headless workers**.

> 并发上限调度的多任务链框架（主 agent 事件循环 + 分离 headless worker）。协议跨 agent 通用；参考实现在 opencode（Windows PowerShell）验证通过。

---

## What it solves / 解决什么

- **Parallelism cap N** with instant slot refill (`running ≤ N` always) — 并行度 N + 即时补位
- **Task chains** (ordered steps) as the scheduling unit — 任务链（有序步骤）为调度单位
- **Exclusive/mutex segments** — serialize "edit config → launch" to avoid version conflicts — 互斥段串行"改配置→启动"
- **Real-time human-in-the-loop** via file messages — 人在环实时交互
- **Durable & resumable** — state lives in marker files, survives interruptions — 持久化 + 断点续跑
- **Long blocking waits** (hours) without burning model tokens — 数小时长等待、零模型推理

## How it works / 工作原理

```
main agent (event loop)                         workers (detached processes)
   │                                                 │
   ├─ launch N workers (Start-Process) ─────────────▶│  read chain def, run steps
   │                                                 │  write marker (.task-runner/runs/)
   │  ◀── messages (.task-runner/messages/) ─────────│  question / done / failed
   │  wait-event loop → wake on QUESTION/TERMINAL    │
   │  QUESTION → question tool → write answer ───────▶│  resume on answer
   │  TERMINAL → refill next chain (running ≤ N)     │
```

The protocol is **plain files + conventions** (`chain definition`, `marker`, `lock`, `message`), so any CLI agent can follow it.

## Positioning & compatibility / 定位与兼容性

**Cross-agent, cross-OS protocol** — the reference implementation is tested on **opencode (Windows PowerShell)**.

| Layer / 层 | Portability / 通用性 |
|---|---|
| Protocol & file formats / 协议与文件格式 | ✅ any agent, any OS |
| Event-loop & lock scripts (PowerShell) / 事件循环与锁脚本 | ⚠️ Windows only (bash port not included yet) |
| Agent-worker launch command / worker 启动命令 | ⚠️ `opencode run` (one-line change for Claude Code / Codex etc.) |
| Permission config / 权限配置 | ⚠️ opencode (`opencode.jsonc`), example provided |

## Install / 安装（opencode）

1. Copy this repo into `.opencode/skills/scheduler-workers/` in your project, **or** install via skills.sh: `npx skills add <owner>/scheduler-workers`.
2. Merge the permission block from `install/opencode.jsonc.permission.example` into your project `opencode.jsonc`.
3. Restart opencode (config & skills are not hot-reloaded).

## Quick start / 快速开始

1. Write chain definitions to `.task-runner/defs/<chain_id>.json` (see `SKILL.md` and `examples/`).
2. As the main agent, run the event loop with `scripts/wait-event.ps1`.
3. Run the smoke tests in `TEST.md` (TC1 parallel/cap, TC2 real-time HITL + refill, TC3 mutex, TC4 resume).

## Security warning / 安全警告

This skill grants `Start-Process`, `Set-Content`, `System.IO.File` etc., and uses `--auto` for headless workers. **Only use it in a trusted project.** Review the permission example carefully before enabling.

## Docs / 文档

- `SKILL.md` — full protocol (Chinese) / 完整协议（中文）
- `TEST.md` — test cases (Chinese) / 测试用例（中文）

## License / 许可证

MIT
