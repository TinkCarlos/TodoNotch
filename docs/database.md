# 本地存储与数据模型文档（TodoNotch）

## 文档版本记录

| 版本/任务标识 | 北京时间（+08:00） | 变更摘要 | 影响的表/文件 | 原因及需求来源 | 适用代码版本与环境 | 验证状态 |
|---|---|---|---|---|---|---|
| `v0.2-design` (`20261124-1836`) | 2026-11-24 18:36 +08:00 | 建立首份本地存储规格：区分现行文件原型与 v1 待实施 SQLite 模型及 Keychain 凭据契约 | `monitored_tasks`、`run_events`、`notification_history`、`app_settings`、`audit_logs` | 需求 `20261124-1748`（REQ-002 ~ REQ-005） | 现行原型仅用 `state.json` + `每日待办.md`；SQLite 为 v1 待实施 | 待实施与验证 |
| `v1.0-impl` (`20261125-0815`) | 2026-11-25 08:15 +08:00 | 已落地 `SQLiteStore.swift`（WAL、无外键、`user_version=1`）与 `KeychainSecretStore.swift`，并在本机自动建库落盘 | `~/Library/Application Support/TodoNotch/state.sqlite3`（4 表 + 6 索引） | 设计 `20261124-1836` 闭环实施 | macOS arm64 实机运行 | `swift test` 幂等与保留单测通过；实机建库并写入 22 条任务与 2 条事件 |
| `v1.3-ui-i18n` (`20261125-1142`) | 2026-11-25 11:42 +08:00 | `app_settings` 新增 `language_mode`、`detected_ip_country` 键值（无表结构迁移）；`SQLiteStore` 新增 `listAllRecentWeekEvents` 批量 7 天查询 | `app_settings`、`run_events`（只读查询） | 需求 `20261125-1106`（`REQ-007`、`REQ-008`） | macOS arm64 | `swift test` 验证配置持久化与 7 天查询通过 |
| `20261126-desktop-dispatch` | 2026-11-26 11:01 +08:00 | 沿用 todo_dispatches，保留同一次执行的 dispatch_id 及原生会话标识，无 DDL 变化 | todo_dispatches | 11-26 用户确认的启停联动 | macOS arm64 本地开发版 | 定向持久化测试与本机执行回执通过 |
| `20261126-desktop-followup` | 2026-11-26 11:48 +08:00 | 迟到回执以 dispatch_id 原子更新执行状态和运行历史，兼容旧待确认事件 | todo_dispatches、run_events | 11-26 迟到终态复审 | macOS arm64 本地开发版 | 定向 SQLite 测试通过，无迁移 |
| `20261126-retention-filter` | 2026-11-26 12:58 +08:00 | 未收回执的 Antigravity 待确认历史免于期限和数量裁剪 | run_events | 用户要求保留迟到回执关联依据 | macOS arm64 本地开发版 | 真实库只读检查，无迁移 |
| `20261126-completion-toast` | 2026-11-26 13:24 +08:00 | 核对成功横幅使用现有运行结果 | run_events | 用户要求完成时去掉截图中的机器人表情 | macOS arm64 本地开发版 | 已核对事件读写路径，无迁移 |
| `20261126-desktop-navigation-feedback` | 2026-11-26 21:35 +08:00 | 桌面导航沿用审计表记录脱敏终态 | audit_logs | AC-DESKTOP-02 回归整改 | macOS arm64 本地源码 | 编译通过，真实导航审计待验 |

---

## 1. 现行存储现状（READ + RUN）

1. `<repo-root>/state.json`：仅记录 `scan_todos.py` 增量扫描水位线（`initialized`, `last_scan_ts`, `last_scan_iso`）。
2. `<repo-root>/.trigger`：单行时间戳文件，用于唤醒现行原型弹窗。
3. `<Vault>/05 时间日志/每日待办.md`：Markdown 清单，现行原型按行号解析与切换 `- [ ]` / `- [x]`。

---

## 2. v1 目标本地存储架构（待实施）

- **引擎**：macOS 内置 `libsqlite3`（SQLite 3.x，零第三方依赖），路径 `~/Library/Application Support/TodoNotch/state.sqlite3`，开启 `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=2000;`。
- **核心约束**：
  - **严格禁止使用外键约束（NO FOREIGN KEY）**，表间关系通过普通关联字段维护，应用层在事务内保障一致性。
  - **零敏感明文落库**：SMTP 授权码与完整 Webhook URL 严禁写入 SQLite，统一存于 macOS Keychain（Service=`com.libo.TodoNotch`），表内仅存脱敏展示标签（如 `smtp.qq.com:465`、`https://open.feishu.cn/...a1b2`）。
  - **无同步长事务**：写入均在后台串行 `DispatchQueue` 执行，单次写入耗时 < 5ms，绝不阻塞主线程 UI 或网络推送。

---

## 3. v1 目标表结构与字段字典（待实施 DDL）

### 3.1 `monitored_tasks`（纳管定时任务表）
业务含义：记录从 Antigravity、Codex、LaunchAgents 自动发现的定时任务及其用户自定义通知级别。

```sql
CREATE TABLE IF NOT EXISTS monitored_tasks (
  task_key        TEXT PRIMARY KEY,          -- 稳定唯一键：<source>:<native_id>，如 antigravity:daily-todo-reminder
  source          TEXT NOT NULL,             -- 来源类型：antigravity / codex / launchd
  native_id       TEXT NOT NULL,             -- 原工具任务标识
  display_name    TEXT NOT NULL,             -- 任务展示名称
  schedule_expr   TEXT NOT NULL DEFAULT '',  -- 原始调度表达式（cron 或 rrule）
  source_status   TEXT NOT NULL DEFAULT 'active', -- 原工具状态：active / paused / removed
  notify_level    TEXT NOT NULL DEFAULT 'normal', -- 用户设置级别：priority / normal / muted
  config_path     TEXT NOT NULL,             -- 原始配置文件绝对路径（只读引用）
  last_run_at     INTEGER,                   -- 最近一次观测到的运行完成时间戳（Unix 秒）
  last_run_status TEXT NOT NULL DEFAULT 'unknown', -- unknown / running / success / attention / error / missed
  next_due_at     INTEGER,                   -- 计算出的下一次计划触发时间戳（Unix 秒）
  updated_at      INTEGER NOT NULL           -- 记录更新时间（Unix 秒）
);
CREATE INDEX IF NOT EXISTS idx_tasks_source_status ON monitored_tasks (source, source_status);
CREATE INDEX IF NOT EXISTS idx_tasks_due ON monitored_tasks (source_status, next_due_at);
```

### 3.2 `run_events`（任务运行事件与通知历史表）
业务含义：记录每次定时任务完成、报错、漏跑或疑似待人工介入的事件，驱动刘海未读数、通知流展示及离席推送状态。保留策略：写入时自动滚动清理超过 30 天或超过 500 条的普通历史（`F-05`）。Antigravity 待确认派发历史保留到收到终态回执，不占普通历史的 500 条额度。

```sql
CREATE TABLE IF NOT EXISTS run_events (
  event_id        TEXT PRIMARY KEY,          -- 幂等事件键：<task_key>:<run_marker>（防重复弹窗与重复外推）
  task_key        TEXT NOT NULL,             -- 关联 monitored_tasks.task_key（普通字段，无外键）
  task_name       TEXT NOT NULL,             -- 冗余任务名快照（原任务删除后历史仍可读）
  source          TEXT NOT NULL,             -- 来源工具：antigravity / codex / launchd
  status          TEXT NOT NULL,             -- success / attention / error / missed
  summary         TEXT NOT NULL,             -- 精炼单行/多行摘要（最多 500 字符）
  artifact_path   TEXT NOT NULL DEFAULT '',  -- 一键直达产出文件路径（可空）
  log_path        TEXT NOT NULL DEFAULT '',  -- 一键直达运行日志路径（可空）
  is_read         INTEGER NOT NULL DEFAULT 0,-- 0=未读，1=已读/已阅
  push_status     TEXT NOT NULL DEFAULT 'skipped', -- skipped / pending / sent / failed
  push_error      TEXT NOT NULL DEFAULT '',  -- 外部推送失败时的脱敏简短原因
  occurred_at     INTEGER NOT NULL,          -- 事件发生时间戳（Unix 秒）
  created_at      INTEGER NOT NULL           -- 入库时间戳（Unix 秒）
);
CREATE INDEX IF NOT EXISTS idx_events_occurred ON run_events (occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_unread ON run_events (is_read, status, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_task ON run_events (task_key, occurred_at DESC);
```

### 3.3 `app_settings`（应用非敏感配置键值表）
业务含义：存储 Vault 路径、勿扰起止时间、专注开关、多屏锁定模式、SMTP 非敏感参数（Host/Port/From/To）、Webhook 类型与启用开关。

```sql
CREATE TABLE IF NOT EXISTS app_settings (
  key        TEXT PRIMARY KEY, -- 如 vault_path / dnd_enabled / dnd_start / dnd_end / screen_mode / smtp_host / smtp_port / smtp_to / webhook_kind
  value      TEXT NOT NULL,    -- JSON 或纯文本值（严禁存密钥）
  updated_at INTEGER NOT NULL
);
```

### 3.4 `audit_logs`（本地操作审计表）
业务含义：记录 Lmemory 部署/备份、任务级别变更、测试推送与推送失败等关键操作，便于故障定位，保留最近 30 天。

桌面导航调用复用 `audit_logs`。操作为 `desktop_navigation`，`target` 为任务键的 SHA-256 摘要，`result` 为分类终态，`detail` 记录来源与阶段。保留沿用现行 30 天策略。

```sql
CREATE TABLE IF NOT EXISTS audit_logs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  action     TEXT NOT NULL,    -- lmemory_deploy / task_level_change / push_smtp / push_webhook / config_backup
  target     TEXT NOT NULL,    -- 目标对象（如 codex / antigravity:daily-todo-reminder / smtp）
  result     TEXT NOT NULL,    -- ok / partial / failed
  detail     TEXT NOT NULL,    -- 脱敏摘要（严禁含密码/URL密钥）
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs (created_at DESC);
```

---

## 4. 关键查询路径、并发与生命周期

- **高频查询均命中索引**：
  - 胶囊/机器人聚合状态：`SELECT status, count(*) FROM run_events WHERE is_read = 0 GROUP BY status` → 命中 `idx_events_unread`（数据量上限 500 行，耗时 < 0.2ms）。
  - 通知历史列表：`SELECT * FROM run_events ORDER BY occurred_at DESC LIMIT 50` → 命中 `idx_events_occurred`，无无界全扫、无深分页。
  - 漏跑检查：`SELECT * FROM monitored_tasks WHERE source_status = 'active' AND next_due_at <= ?` → 命中 `idx_tasks_due`。
- **幂等防重**：`run_events` 使用 `INSERT OR IGNORE INTO run_events (event_id, ...)`，`event_id` 由 `<task_key>:<conversationId 或 run_ts>` 确定性生成，保证重复轮询或重启绝不重复弹大窗、不重复发邮件/Webhook。
- **迁移与恢复**：使用 `PRAGMA user_version` 管理顺序轻量迁移（`v0 → v1`）；如遇损坏，备份原库后重建，不影响外部 Agent 与 Vault 数据。

## 手动执行状态

`todo_dispatches` 仍按待办或定时任务键保存最新一轮执行。写入开始、运行和结束状态时沿用同一 `dispatch_id`，回调只更新匹配的当前执行，重启读回可使用保存的 Agent、原生会话 ID 和记录路径。桥接停止协议的回执归本地桥接目录管理，本次无需 SQLite 迁移。

- 本机恢复 Antigravity 终态时，在一个 SQLite 事务中核对当前 `dispatch_id` 并回写 `todo_dispatches` 和 `run_events`。同 ID 的旧待确认事件更新结果并保留已读和推送记录。没有历史行时补写。待确认先持久化为已读历史，不触发推送。新一轮覆盖执行记录时，上一轮仍可按原 dispatch ID 纠正历史。手动停止记为 `stopped`，无新推送，未增加表或字段。
