# 项目重大注意事项（TodoNotch）

## 文档版本记录

| 版本/任务标识 | 北京时间（+08:00） | 变更摘要 | 影响范围 | 原因及需求来源 | 适用代码版本与环境 | 验证状态 |
|---|---|---|---|---|---|---|
| `v0.2-design` (`20261124-1836`) | 2026-11-24 18:36 +08:00 | 建立首份权威项目注意事项基线与 v1 待实施架构约束 | 整体架构、安全边界、运行入口、四份文档索引 | 基于需求 `20261124-1748`（`READY FOR DESIGN`）编写开发设计 | 现行原型 `TodoNotch/main.swift` + `scan_todos.py`（macOS arm64）；v1 尚待实施 | 原型已 `RUN`，v1 待实施 |
| `v1.0-impl` (`20261125-0815`) | 2026-11-25 08:15 +08:00 | v1 原生 SwiftPM 工程实施完成并打包上线 `TodoNotch.app`（1.7 MB），已实机验证自动发现 22 项定时任务 | 全模块（`Sources/TodoNotchCore`、`Sources/TodoNotch`、`scripts/build-app.sh`） | 依据设计 `20261124-1836` 闭环实施 | macOS arm64 Swift 6.4.2，`PID 94661` 运行中 | `swift test` 7/7 通过，`scan_todos.py --self-test` 通过，实机 DB 自动发现 22 任务 |
| `v1.3-ui-i18n` (`20261125-1142`) | 2026-11-25 11:42 +08:00 | 完成方案 A 全页面动态重设计与基于 IP 归属地的默认语种/手动中英文切换（`Localization.swift`） | `TodoNotchCore/Localization`、`OverlayViews`、`AppViewModel`、`main.swift` | 需求 `20261125-1106` 与设计 `design.md`（方案 A） | macOS arm64 | `swift test` 与 Release `TodoNotch.app` 编译签名通过 |
| `20261126-desktop-dispatch` | 2026-11-26 11:01 +08:00 | 记录 Codex 原生会话及 Antigravity 原生桥接的使用和桌面定位要求 | Agent 桌面集成 | 11-26 用户确认的三项修复 | macOS arm64 本地开发版 | 原生会话核对通过 |
| `20261126-desktop-followup` | 2026-11-26 11:48 +08:00 | 记录当前签名的辅助功能提示、桥接回复证据及 Codex 进程组回收 | 桌面与桥接 | 11-26 四项 P2 | macOS arm64 本地开发版 | 定向测试通过 |
| `20261126-retention-filter` | 2026-11-26 12:58 +08:00 | 记录历史待确认关联保留和 Antigravity 列表刷新校验 | 桌面与回执恢复 | 用户要求修复剩余两项 P2 | macOS arm64 本地开发版 | 复审无 P1/P2，14:31 桌面复验通过 |
| `20261126-completion-toast` | 2026-11-26 13:24 +08:00 | 成功横幅使用自身的完成图标，常驻机器人继续展示全局提醒状态 | AC-09 | 用户要求完成时去掉截图中的机器人表情 | macOS arm64 本地开发版 | 成功横幅回放通过，机器人状态定向测试通过 |
| `20261126-search-replace` | 2026-11-26 14:00 +08:00 | 修复 Antigravity 历史跳转时新旧筛选串偶发拼接 | AC-DESKTOP-02 | 用户要求用干净构建修复并连续复验 | `e923f63` 加本次修复，macOS arm64 | 14:31 真实记录连续三次打开指定详情 |
| `20261126-desktop-navigation-feedback` | 2026-11-26 21:35 +08:00 | 记录自动隐藏与用户取消的区别、顶部权限提示和脱敏字段 | 桌面导航、浮窗 | AC-DESKTOP-02 回归整改 | macOS arm64 本地源码 | 编译与定向单测通过，桌面待验 |
| `20261127-reliability-ui-polish` | 2026-11-27 09:10 +08:00 | 待办写回改按 `todoKey` 校验且排除已完成项、收件箱文件延后至 SQLite 落盘后删除，以及深色锁定、主面板首击直达、清单双对勾消歧、Tab 1 计数对齐、设置页吸底保存条与空记录任务直达按钮 | 待办写回、收件箱落盘、浮窗 UI P0 | P1 数据可靠性修复与 UI P0 打磨 | macOS arm64 本地源码 | 12/12 定向单测及 Release `TodoNotch.app`（`6.3M`）编译签名通过；桌面 UI 与 AC-DESKTOP-02 实机复验待执行 |
| `20261127-cert-and-ac-desktop-02` | 2026-11-27 10:17 +08:00 | 创建并信任本地固定代码签名证书 `TodoNotch Local Dev`，改造 `scripts/build-app.sh` 默认使用固定证书签名（避免重编译反复索要辅助功能权限），并修复前缀重叠任务导致 `AC-DESKTOP-02` 误报 `ambiguousMatches` | 打包签名、辅助功能授权持久化、桌面定位 | 解决重编译掉权限及早午班/晚班 ID 前缀重叠误判 | macOS arm64，`/Applications/TodoNotch.app`（`PID 17023`） | `DesktopNavigationTests` 8/8 通过；重打包覆盖后免重授权，实机点击早午班 14:31 打开 `/sidecars/x-ai-vertical-daily?q=x-ai-vertical-daily`（OSLog 与 `audit_logs id=28` 为 `opened`） |
| `20261127-codex-scheduled-tasks` | 2026-11-27 11:12 +08:00 | 补全 Codex 定时任务近 7 天多条运行历史采集、`in_progress`/`cancelled` 等状态映射、`NULLIF` 空摘要回退标题，以及 `Watchers`/`TodoDispatcher` 单引号与行尾注释 TOML 解析，并新增两项 Codex 定时任务定向单测 | `Watchers`、`TodoDispatcher`、`CoreTests` | 核查并完善 Codex 定时任务功能与定向测试，并完成真实 Codex 任务全链路实机验收 | macOS arm64，`/Applications/TodoNotch.app`（`PID 34669`） | 15/15 定向单测通过；实机自动发现 `codex:automation`（`查看最新的热点新闻`）、空记录与历史记录桌面跳转均 `accepted` 唤起 `com.openai.codex`，卡片启停冲突自动派生 `[TodoNotch] 查看最新的热点新闻 11:10`（`01a21afc-16ba-77f1-be2a-fe2d9ef92e4d`）并干净落为 `stopped`，`automation.toml` SHA-256 零变化 |

| `20261127-todo-completion-polling` | 2026-11-27 12:00 +08:00 | 新增「未完成」列表每 5 分钟（及手动刷新）增量后台轮询与多 CLI 自动回退语义核验（`TodoCompletionPoller` + `AppViewModel` + `scan_todos.py` 防噪标记 + 中英轻提示），确认整条完全闭环后按 `todoKey` 安全写回 `每日待办.md` | `TodoCompletionPoller`、`AppViewModel`、`Localization`、`scan_todos.py`、`CoreTests` | 用户反馈部分待办实际已完成但面板仍显示未完成，需每 5 分钟自动核验并消项 | macOS arm64，`/Applications/TodoNotch.app`（`PID 55420`） | 5/5 定向单测与 `scan_todos.py --self-test` 通过；Release `TodoNotch.app`（`5.0M`）构建签名并重启实机验证，首轮拉起只读 `codex exec` 核验 16 条变更待办并落盘指纹（`app_settings.todo_poll_fingerprints`），复合未闭环条目零误标 |

---

## 1. 四份项目权威文档固定路径

| 文档 | 固定路径 | 当前内部版本 |
|---|---|---|
| 接口与事件契约 | [docs/api.md](api.md) | `v1.2-no-smtp` |
| 本地存储与数据模型 | [docs/database.md](database.md) | `v1.3-ui-i18n` |
| 项目重大注意事项 | [docs/project-notes.md](project-notes.md) | `v1.3-ui-i18n` |
| 现有功能与回归清单 | [docs/features-and-regressions.md](features-and-regressions.md) | `v1.3-ui-i18n` |

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

## Agent 桌面集成

- TodoNotch 通过 Codex `app-server` 与 Antigravity 桌面桥创建原生会话。Antigravity 在桥可用且支持停止时接单，桥不可用时界面会报错。本机已安装桥接的脚本入口为 `~/.gemini/config/plugins/todonotch-bridge/sidecars/bridge/server.mjs`。升级现有桥接时，用发布包内 `Contents/Resources/agy_bridge_sidecar.mjs` 更新该入口，然后重启桥接。以 `bridge/agy-bridge-status.json` 的 `ready` 和 `stop_protocol: 2` 核对版本。
- Antigravity 没有对应定时任务的 URL Scheme 路由。TodoNotch 在 macOS 已授予辅助功能访问权限时，通过桌面 Automations 页面定位，并核对详情地址里的任务 ID。

- 从定时任务历史点击 Antigravity 跳转时，若当前 TodoNotch 构建缺少辅助功能权限，macOS 会为该应用弹出授权提示。临时签名的构建换版后可能需要重新授权。Codex 停止保留启动时确认的进程组，父进程退出后仍清理该组。

- Antigravity 一键定位先等待桌面渲染本次查询的空结果，再替换搜索框的整个值并核对目标任务 ID。筛选结果有同名歧义时保持在列表，避免打开错误详情。待确认派发的历史条目是迟到回执的关联记录，收到终态后才按常规历史规则裁剪。

- TodoNotch 失活后同步收起主浮窗，后台定位继续。主动关闭或改点另一任务会取消旧定位，辅助功能操作在按下侧边栏和结果行前检查取消状态。失败和缺权限使用无键盘焦点的屏幕顶部提示，权限提示提供辅助功能设置入口。
- 桌面定位的 OSLog 和 SQLite 审计使用任务键摘要、来源、阶段及终态。详情地址、任务标题与对话内容保持在各自原始数据源。
