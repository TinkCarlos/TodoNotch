# 项目重大注意事项（TodoNotch）

## 文档版本记录

| 版本/任务标识 | 北京时间（+08:00） | 变更摘要 | 影响范围 | 原因及需求来源 | 适用代码版本与环境 | 验证状态 |
|---|---|---|---|---|---|---|
| `v0.2-design` (`20261124-1836`) | 2026-11-24 18:36 +08:00 | 建立首份权威项目注意事项基线与 v1 待实施架构约束 | 整体架构、安全边界、运行入口、四份文档索引 | 基于需求 `20261124-1748`（`READY FOR DESIGN`）编写开发设计 | 现行原型 `TodoNotch/main.swift` + `scan_todos.py`（macOS arm64）；v1 尚待实施 | 原型已 `RUN`，v1 待实施 |
| `v1.0-impl` (`20261125-0815`) | 2026-11-25 08:15 +08:00 | v1 原生 SwiftPM 工程实施完成并打包上线 `TodoNotch.app`（1.7 MB），已实机验证自动发现 22 项定时任务 | 全模块（`Sources/TodoNotchCore`、`Sources/TodoNotch`、`scripts/build-app.sh`） | 依据设计 `20261124-1836` 闭环实施 | macOS arm64 Swift 6.4.2，`PID 94661` 运行中 | `swift test` 7/7 通过，`scan_todos.py --self-test` 通过，实机 DB 自动发现 22 任务 |

---

## 1. 四份项目权威文档固定路径

| 文档 | 固定路径 | 当前内部版本 |
|---|---|---|
| 接口与事件契约 | [docs/api.md](api.md) | `v0.2-design` |
| 本地存储与数据模型 | [docs/database.md](database.md) | `v0.2-design` |
| 项目重大注意事项 | [docs/project-notes.md](project-notes.md) | `v0.2-design` |
| 现有功能与回归清单 | [docs/features-and-regressions.md](features-and-regressions.md) | `v0.2-design` |

---

## 2. 架构与模块依赖（Hexagonal / Ports & Adapters）

- **依赖方向**：`UI (SwiftUI / AppKit)` → `Application UseCases` → `Domain (Entities / StateMachine / Ports)` ← `Adapters (Watchers / Storage / Keychain / Push / LmemoryInstaller)`。Domain 层零 AppKit/SQLite/Network 依赖，可纯内存单元测试。
- **核心数据所有者**：
  - 任务元数据与通知历史：`TodoNotch` 私有 SQLite（`~/Library/Application Support/TodoNotch/state.sqlite3`）。
  - 跨项目待办清单：用户 Vault 内的 `05 时间日志/每日待办.md`（由扫描任务写入，应用仅在勾选复选框时做精确单行切换）。
  - 敏感凭据（SMTP 授权码、完整 Webhook URL）：**唯一权威存储为 macOS Keychain**（Service `com.libo.TodoNotch`），严禁写入 SQLite、JSON、plist 或日志。

---

## 3. 不可破坏的历史约束与红线

1. **零侵入只读监听**：严禁修改用户的 `~/.gemini/config/sidecars/*/sidecar.json` 或 `~/.codex/automations/*/automation.toml`（Codex 含 `model_prompt_sha256` 校验，Antigravity 含 `agent_permissions`）。
2. **只读打开外部 SQLite**：读取 `~/.codex/sqlite/codex.db` 必须使用 `SQLITE_OPEN_READONLY` + `busy_timeout=1000`，绝不写入或持长锁，避免阻塞 Codex 主进程。
3. **Lmemory 改前备份与旧 Vault 保护**：一键部署 Lmemory 前必须备份目标配置文件；已有 Vault 必须幂等复用，严禁覆盖或清空；开源版严禁硬编码个人 Vault 路径。
4. **物理刘海几何红线**：MacBook 内建刘海屏胶囊高度必须严格等于 `auxiliaryTopLeftArea.height`，`y = frame.maxY - notchHeight`（0px 下探），单侧耳翼不超过 `32pt`，避免遮挡右侧菜单栏图标；必须尊重 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`。
5. **不越权代跑定时任务**：首版严禁从本应用强制重跑外部 Agent 定时任务，防止重复发帖/投稿等不可逆外部副作用。

---

## 4. 环境、运行入口与恢复

- **构建环境**：macOS 14+，Apple Swift 6+（SwiftPM 编译为原生 `.app`，零 Electron 依赖）。
- **现行原型运行入口**：
  - 应用：`<repo-root>/TodoNotch.app`（或 `/Applications/TodoNotch.app`）
  - 开机自启：`~/Library/LaunchAgents/local.libo.todo-notch.plist`
  - 扫描脚本：`<repo-root>/scan_todos.py`（已内置于 `.app/Contents/Resources/scan_todos.py`）
  - 定时任务：`~/.gemini/config/sidecars/daily-todo-reminder/sidecar.json`
- **故障恢复**：应用日志写入 `~/Library/Logs/todo-notch.log`（脱敏）；若 SQLite 损坏，自动备份损坏库并重建空库（原有 Agent 定时任务与 `每日待办.md` 均不受损，重启后 10 秒内自动重新发现）。
