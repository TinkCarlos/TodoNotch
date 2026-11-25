# 接口与事件契约文档（TodoNotch）

## 文档版本记录

| 版本/任务标识 | 北京时间（+08:00） | 变更摘要 | 影响接口/事件 | 原因及需求来源 | 适用代码版本与环境 | 验证状态 |
|---|---|---|---|---|---|---|
| `v0.2-design` (`20261124-1836`) | 2026-11-24 18:36 +08:00 | 建立首份本地触发契约（含开放第三方本地通知入口）与外部 SMTP/Webhook 推送契约 | `API-LOCAL-01`（`.trigger` JSON 事件）、`API-PUSH-01`（SMTP）、`API-PUSH-02`（Webhook） | 需求 `20261124-1748`（REQ-003, REQ-004, REQ-005） | 现行仅支持纯时间戳 `.trigger`；结构化契约为 v1 待实施 | 待实施与验证 |
| `v1.0-impl` (`20261125-0815`) | 2026-11-25 08:15 +08:00 | 已实现 `inbox/` 原子 JSON 投递（`Watchers.swift` + `scan_todos.py`）、纯 Swift TLS 465 SMTP 与 5 平台 Webhook 客户端（`PushDispatcher.swift`） | `API-LOCAL-01`、`API-PUSH-01`、`API-PUSH-02` | 设计 `20261124-1836` 闭环实施 | macOS arm64 | 单元与隔离目录集成测试通过；真实 SMTP/Webhook 发信待用户在设置页填入授权码/URL 后实测 |
| `v1.2-no-smtp` (`20261125-0933`) | 2026-11-25 09:33 +08:00 | 按用户确认移除 SMTP 邮件发送功能（`API-PUSH-01` 废弃），离席推送仅保留 5 平台 Webhook（`API-PUSH-02`） | `API-PUSH-01`（已移除） | 用户决定去掉邮箱发送功能 | macOS arm64 | `swift test` 8/8 通过，`TodoNotch.app` 重载生效 |

---

## 1. 架构定位说明

TodoNotch 为**纯本地 macOS 原生桌面应用**，不暴露公网 HTTP 监听端口。为满足本机既有脚本（如 `scan_todos.py`）及其他第三方 Agent/自定义脚本的标准化接入，提供文件级/URL Scheme 本地通知入口，并对外部推送（SMTP / Webhook）制定统一契约。

---

## 2. 本地开放接入契约（第三方脚本/新 Agent 零改代码接入）

### `API-LOCAL-01`：本地事件投递目录（Drop-in Event JSON）
- **协议与路径**：文件原子落盘至 `~/Library/Application Support/TodoNotch/inbox/<uuid>.json`（先写 `.tmp` 再 `rename` 原子提交；兼容现行 `.trigger` 触发 `daily-todo-reminder` 刷新）。
- **权限与安全边界**：目录权限 `0700`（仅当前 macOS 登录用户可写），不开放网络监听，天然防跨用户/远程越权；单文件载荷上限 `64 KB`，超限拒绝并记录审计日志。
- **最小请求示例（协议示例）**：
```json
{
  "schema_version": "1",
  "event_id": "antigravity:daily-todo-reminder:2026-11-24T09:00",
  "source": "antigravity",
  "task_id": "daily-todo-reminder",
  "task_name": "每日 9 点跨项目待办提醒",
  "status": "attention",
  "summary": "共 12 项待处理（6 项等你亲自处理），已自动消项 2 项",
  "artifact_path": "<vault>/05 时间日志/每日待办.md",
  "log_path": "",
  "occurred_at": "2026-11-24T09:00:08+08:00"
}
```
- **字段校验**：`status` 仅允许 `running | success | attention | error | missed`；`summary` 超 500 字符截断；`event_id` 幂等去重；非法 JSON 移入 `inbox/rejected/` 并写 `audit_logs`。
- **可观察结果**：处理成功后删除该 inbox 文件，按 `REQ-004` 规则更新 SQLite、机器人表情、触发 5s 轻提示或大浮窗及外部推送。

---

## 3. 外部离席推送契约

### `API-PUSH-01`：通用 SMTP 邮件推送（纯 Swift `NWConnection`）
- **协议**：原生 TLS 465（SMTPS，默认适配 QQ 邮箱 `smtp.qq.com:465` / 163 `smtp.163.com:465`）与 STARTTLS 587（Gmail `smtp.gmail.com:587`）。
- **凭据管理**：发件授权码/密码从 macOS Keychain（`com.libo.TodoNotch` / `smtp_password`）实时读取，内存用完即释放，严禁写入日志或配置文件。
- **超时与重试**：连接+发信总超时 `15s`；后台异步执行绝不阻塞 UI；失败不无限自动重试（防重复发信/限流），在 `run_events.push_status` 标为 `failed` 并供用户手动点「重试推送」。
- **发信触发条件**：默认仅当 `status IN ('error', 'missed')` 或 `task.notify_level == 'priority'` 且当前非勿扰状态时发送。

### `API-PUSH-02`：通用 Webhook 推送（`URLSession` HTTPS POST）
- **协议与安全**：强制仅允许 `https://`（本地调试允许 `http://localhost` / `http://127.0.0.1`），**完整 Webhook URL（含内嵌 token/key）强制存 macOS Keychain**（`com.libo.TodoNotch` / `webhook_url`）。
- **超时与载荷**：单次请求超时 `10s`，单次 JSON 载荷上限 `16 KB`；支持 5 种内置模板（飞书 `msg_type: "text"`、企业微信 `msgtype: "markdown"`、钉钉 `msgtype: "markdown"`、Bark `title/body/group`、通用 JSON）并在设置页提供「发送测试消息」。
- **代表性失败处理**：HTTP 非 2xx、DNS/网络不可达或超时 → 记录脱敏错误（仅保留状态码或错误类型，剥离 URL 路径与查询参数）至 `run_events.push_error` 与 `audit_logs`。

---

## 4. 外部只读数据源契约（零侵入消费方）

| 数据源 | 读取路径 | 权限与读取方式 | 消费字段 |
|---|---|---|---|
| Antigravity 定时配置 | `~/.gemini/config/sidecars/*/sidecar.json` | 只读 JSON | `builtin`, `args[0]`, `display_name`, `description` |
| Antigravity 运行日志 | `~/.gemini/antigravity/sidecar_data/<id>/logs/sidecar.log` | 只读尾部增量 | `conversationId`, `Command completed successfully`, `Next execution scheduled` |
| Codex 定时配置 | `~/.codex/automations/*/automation.toml` | 只读 TOML | `id`, `name`, `status`, `rrule`, `target_thread_id`, `updated_at` |
| Codex 运行库 | `~/.codex/sqlite/codex.db` | `SQLITE_OPEN_READONLY` + `busy_timeout=1000` | `automations.last_run_at/next_run_at`, `automation_runs.*` |
| Claude 定时任务 | `~/.claude/scheduled-tasks/`（`SKILL.md`/`*.json`）、`~/.claude/scheduled_tasks.json`、`~/Library/Application Support/Claude*/local-agent-mode-sessions/**/scheduled_tasks.json` | 只读 JSON / Frontmatter | `id`, `name`, `cronExpression`/`schedule`, `enabled`/`status`, `lastRunAt`, `runs` |
| WorkBuddy 定时任务 | `~/.workbuddy/workbuddy.db`、`~/.workbuddy-ai/workbuddy.db` | `SQLITE_OPEN_READONLY` + `busy_timeout=1000` | `automations.*`（`deleted_at IS NULL`）、`automation_runs.*` |
| ZCode 定时任务 | `~/.zcode/cli/db/db.sqlite`、`~/.zcode/v2/{automations,scheduled-tasks,bot-config.v3}.json`、`~/.zcode/automations/*.json` | `SQLITE_OPEN_READONLY` + 只读 JSON | `workflow_definition`、`workflow_run` 及 JSON 定时任务字段 |
| Lmemory 健康页 | `<Vault>/90 系统文件/自动化/夜间维护.md` | 只读 frontmatter | `nightly`, `nightly_at`, `lane` |
