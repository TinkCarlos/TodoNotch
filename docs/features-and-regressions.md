# 现有功能与回归清单（TodoNotch）

## 文档版本记录

| 版本/任务标识 | 北京时间（+08:00） | 变更摘要 | 影响功能 | 原因及需求来源 | 适用代码版本与环境 | 验证状态 |
|---|---|---|---|---|---|---|
| `v0.2-design` (`20261124-1836`) | 2026-11-24 18:36 +08:00 | 建立现行原型基线（`F-BASE-01 ~ 02`）与 v1 规划回归清单（`AC-01 ~ AC-15`） | 全部功能 | 需求 `20261124-1748` + 设计 `20261124-1836` | 原型运行于 macOS arm64（2026-11-24） | 基线已验证，v1 待实施 |
| `v1.0-impl` (`20261125-0815`) | 2026-11-25 08:15 +08:00 | v1 全部 4 个增量实现完成并实机运行 `TodoNotch.app`（`PID 94661`），更新各项 AC 验证状态 | `AC-01 ~ AC-15` | 设计 `20261124-1836` 闭环实施 | macOS arm64 Swift 6.4.2 | `swift test` 7/7 通过，`scan_todos.py --self-test` 通过，实机自动发现 22 任务；SMTP/Webhook 真实发信与双屏肉眼观感待用户现场体验确认 |
| `v1.1-parsers` (`20261125-0856`) | 2026-11-25 08:56 +08:00 | 新增 Claude、WorkBuddy（真实 `workbuddy.db` 只读）、ZCode（`db.sqlite` + `v2` JSON 只读）定时任务及近 7 天执行记录解析；工具分类筛选与 18 种动态表情已上线 | `AC-06`, `AC-07`, `AC-14` | 用户追加 Claude/WorkBuddy/ZCode 解析与 Lmemory 绿点验证 | macOS arm64 Swift 6.4.2 | `swift test` 8/8 通过（含三工具真实表结构只读用例），实机 `TodoNotch.app` 已重载 |
| `v1.3-ui-i18n` (`20261125-1142`) | 2026-11-25 11:42 +08:00 | 落地方案 A（精密暗炭顶光舱）全页面重设计与动态交互组件（滑动 Tab/筛选滑块、7 天节律点阵、时间线展开、5s 进度条、三态保存按钮、`Reduce Motion` 降级）；新增 IP 归属地默认语种初始化与手动中英文切换 | `AC-20 ~ AC-23` | 需求 `20261125-1106`（`REQ-007`、`REQ-008`）与选型 `design.md`（方案 A） | macOS arm64 | `swift test` 全部通过，Release 打包与实机重启验证；真实弹窗动态观感待用户现场操作确认 |
| `20261126-desktop-dispatch` | 2026-11-26 11:01 +08:00 | 未完成页逐行启停，保留原生会话，定时任务历史跳转桌面详情 | AC-DESKTOP-01 至 03 | 11-26 用户确认的三项修复 | macOS arm64 本地开发版 | 6 项定向测试通过，Antigravity 一键定位未通过 |
| `20261126-desktop-followup` | 2026-11-26 11:48 +08:00 | 补记父进程退出、迟到回执、本轮回复隔离和早午班详情 | AC-DESKTOP-01 至 03 | 11-26 早午班 14:31 和四项 P2 复验 | macOS arm64 本地开发版 | 10 项定向测试通过，14:31 桌面详情实测通过 |
| `20261126-retention-filter` | 2026-11-26 12:58 +08:00 | 补记待确认裁剪验证边界与 14:31 刷新验收 | AC-DESKTOP-02、03 | 用户要求修复剩余两项 P2 | macOS arm64 本地开发版 | 14:31 最终构建复验通过 |
| `20261126-completion-toast` | 2026-11-26 13:24 +08:00 | 执行成功横幅使用绿色对勾 | AC-09 | 用户要求完成时去掉截图中的机器人表情 | macOS arm64 本地开发版 | 同一真实成功记录回放通过，机器人状态定向测试通过 |
| `20261126-search-replace` | 2026-11-26 14:00 +08:00 | 修复筛选串拼接，复验早午班 14:31 一键定位 | AC-DESKTOP-02 | 用户要求使用真实数据连续复验三次 | `a8ac84f`、`e923f63` 加本次修复，macOS arm64 Release | 连续三次通过 |
| `20261126-desktop-navigation-feedback` | 2026-11-26 21:35 +08:00 | 补记桌面定位终态、失活状态和快速切换的验收 | AC-DESKTOP-02 | AC-DESKTOP-02 回归整改 | macOS arm64 本地源码 | 7 项定向单测通过，桌面待验 |
| `20261127-reliability-ui-polish` | 2026-11-27 09:10 +08:00 | 修复待办写回按 `todoKey` 校验（忽略已勾选 `- [x]`）与收件箱延后至 SQLite 落盘成功后再删文件，并完成深色锁定、首击直达、双对勾消歧、Tab 1 角标对齐、设置吸底保存条与无运行记录任务桌面定位按钮 | `F-BASE-02`, `AC-13`, `AC-20 ~ AC-23`, `AC-DESKTOP-02` | P1 数据可靠性修复与 UI P0 打磨 | macOS arm64 本地源码 | 12/12 定向单测及 Release `TodoNotch.app`（`6.3M`）编译签名通过；桌面 UI 与 AC-DESKTOP-02 实机复验待执行 |
| `20261127-cert-and-ac-desktop-02` | 2026-11-27 10:17 +08:00 | `build-app.sh` 默认改用本地固定证书 `TodoNotch Local Dev` 签名，同步更新 `/Applications/TodoNotch.app` 后验证重编译免重授权；`DesktopNavigationRules.decideRows` 修复 ID 前缀重叠（早午班/晚班）误判多候选问题 | `AC-DESKTOP-02` | 用户确认固定签名并实机复验 `AC-DESKTOP-02` | macOS arm64，`/Applications/TodoNotch.app`（`PID 17023`） | `DesktopNavigationTests` 8/8 通过；Antigravity 普通会话页点击早午班 14:31 实测打开 `/sidecars/x-ai-vertical-daily?q=x-ai-vertical-daily`（OSLog 与 `audit_logs id=28` 均为 `opened`） |
| `20261127-codex-scheduled-tasks` | 2026-11-27 11:12 +08:00 | 补全 Codex 近 7 天多条运行历史、`in_progress`/`cancelled` 状态映射、`NULLIF` 空摘要回退与 TOML 单引号/行尾注释解析，新增 `testCodexScheduledTaskDiscoveryAndDBRuns`、`testCodexScheduledTaskSpecExtractionAndFallbacks` | `AC-06`, `AC-07`, `AC-DESKTOP-01`, `AC-DESKTOP-02` | 完善 Codex 定时任务功能与测试，并完成真机全链路验收 | macOS arm64，`/Applications/TodoNotch.app`（`PID 34669`） | 15/15 定向单测与 Release 打包签名通过；实机自动发现 `codex:automation`、空态及历史桌面深链均 `accepted` 唤起 `com.openai.codex`，运行中停止干净落为 `stopped` 并保留会话 `01a21afc-16ba-77f1-be2a-fe2d9ef92e4d`（原线程忙时自动 fork），`automation.toml` 零修改 |
| `20261127-todo-completion-polling` | 2026-11-27 12:00 +08:00 | 新增每 5 分钟后台轮询与多 CLI 回退链（`codex → claude → pi → opencode → cursor → grok → qoder → antigravity`）只读核验未完成待办，基于证据指纹去重并仅在高置信整条闭环时安全写回 `每日待办.md` | `F-BASE-02`, `AC-09` | 用户要求每 5 分钟轮询检查「未完成」列表中是否已有实际完成的条目并更新状态 | macOS arm64，`/Applications/TodoNotch.app`（`PID 55420`） | 5/5 定向单测（`testTodoCompletion*` 等）与 `scan_todos.py --self-test` 通过；实机 `/Applications/TodoNotch.app` 触发 `codex exec --ephemeral -s read-only` 核验 16 条有更新的待办并持久化指纹，无变更零调用，未误标复合待办 |

---

## 1. 现行已实现功能（必须保留且不得回归）

| 功能 ID | 模块与入口 | 当前行为与边界 | 历史缺陷与防回归要点 | 回归命令与最近验证 |
|---|---|---|---|---|
| `F-BASE-01` | [scan_todos.py](../scan_todos.py) | 优先读 Lmemory 会话摘录 + 截断/未同步会话原始日志末段补读（`ASK_CLIP=2000`, `ANSWER_CLIP=2500`）；首次 7 天建池、此后按 `state.json` 增量扫描；支持 `--sync-lmemory`、`--out`、`--commit`、`--notify` | ① 曾因 `ASK_CLIP=400` 与只看末轮空回复漏掉 GEO 报告挂起待办（`82252200`）；② 曾因 `TAIL_BYTES=320KB` 漏抓长工具链会话；③ 曾因 `glob` 顺序覆盖跨天摘录 | `python3 scan_todos.py --self-test`（2026-11-24 `SELF_TEST_OK`） |
| `F-BASE-02` | `TodoNotch.app`（[Sources/TodoNotch/main.swift](../Sources/TodoNotch/main.swift)） | 原生 Swift 应用，监听 `每日待办.md` 与 `.trigger`，勾选复选框直接写回原文件；开机自启 `local.libo.todo-notch.plist` | ① 曾因 `y` 偏移下探遮挡应用标题栏；② 曾因 `earWidth=96` 遮挡右侧菜单栏图标；现已修正为 `y=frame.maxY-notchHeight`、`earWidth=28` | `swiftc -O ...` 编译通过 + `launchctl` 加载运行（2026-11-24） |

---

## 2. v1 待实施回归与验收清单（均标待执行）

| AC ID | 对应 REQ | 验证方式 | 核心断言与禁止副作用 | 当前状态 |
|---|---|---|---|---|
| `AC-01` | REQ-001 | LIVE-PATH（内建刘海屏） | 胶囊底边与 `32pt` 菜单栏齐平（0px 下探），单侧耳翼 `<= 32pt`，不覆盖右侧图标 | 待实施 |
| `AC-02` | REQ-001 | UNIT + LIVE-PATH | `Error` 优先级高于 `Success`；开启 `Reduce Motion` 后停止自主位移动画 | 待实施 |
| `AC-03` | REQ-001 | LIVE-PATH（双屏） | 两屏常驻胶囊零跳屏；焦点在外接 2K 屏时弹窗仅落外接屏；合盖切换无崩溃 | 待实施 |
| `AC-04` | REQ-002 | REAL-DATA-DRY-RUN / 隔离目录 | 已有 Vault 幂等复用不被覆盖，改前生成备份文件 | 待实施 |
| `AC-05` | REQ-002 | SYNTHETIC（只读文件） | 单 Agent 受限/含注释不阻断其余 Agent，原文件无损且界面给修复指引 | 待实施 |
| `AC-06` | REQ-003 | REAL-DATA-DRY-RUN | 准确发现本机 Antigravity 4 个 + Codex 18 个（1 ACTIVE/16 PAUSED） | 待实施 |
| `AC-07` | REQ-003 | SYNTHETIC（临时任务） | 新增定时任务 10 秒内自动出现，原配置 SHA-256 零修改 | 待实施 |
| `AC-08` | REQ-003 | UNIT（模拟休眠时钟） | 剔除休眠时长 + 唤醒 5 分钟宽限期；运行中不误报漏跑 | 待实施 |
| `AC-09` | REQ-004 | LIVE-PATH | 5 秒轻提示不抢编辑器焦点。5 秒内并发 3 条合并展示，无重叠闪烁。同时存在逾期事项时，执行成功横幅左侧显示绿色对勾。 | 图标已通过本地 inbox 回放验证。2026-11-26 13:20 的「X 工作日双轨智能回复」真实成功记录在旧版显示哭脸，在新版显示绿色对勾。焦点和合并仍待验收。 |
| `AC-10` | REQ-004 | LIVE-PATH + STATIC | SMTP 授权码与完整 Webhook URL 仅存 Keychain，磁盘/日志零明文泄露 | 待实施 |
| `AC-11` | REQ-004 | SYNTHETIC（断网） | 断网时本地浮窗正常弹出，外部推送标失败可重试，不阻塞 UI | 待实施 |
| `AC-12` | REQ-005 | UNIT（时钟注入） | 勿扰 `22:00-08:30` 在 `23:30` / `07:15` 屏蔽弹窗与外推，保留机器人色+静音标 | 待实施 |
| `AC-13` | REQ-005 | SYNTHETIC（缺失文件） | 点击已删产出文件给出内联提示，应用不闪退 | 待实施 |
| `AC-14` | REQ-005 | SYNTHETIC（状态变更） | `夜间维护.md` 为 `nightly: failed` 时健康栏 10 秒内变红并可一键打开 | 待实施 |
| `AC-15` | REQ-004 | REAL-DATA-DRY-RUN | GEO 样本 `82252200` 的长提问与挂起待办完整保留不截断 | 已在原型 `scan_todos.py` 验证，v1 集成后复验 |

## 2026-11-26 桌面执行回归

| 验收 | 操作与通过条件 |
|---|---|
| `AC-DESKTOP-01` | 从 TodoNotch 启动任务，等进度回复后停止。在 Codex 或 Antigravity 桌面原会话中读到用户消息、进度回复和中断状态。 |
| `AC-DESKTOP-02` | 展开现有定时任务，从其历史点击「在桌面应用打开定时任务」，核对 Agent 桌面打开的是同一任务详情。 |
| `AC-DESKTOP-03` | 「待处理」及「进行中」各选一条未完成待办，逐行启动后停止，刷新后仍显示真实终态。已有批量执行沿用同一入口。桥接失联时保存待确认且不推送，收到真实终态后纠正原执行历史。 |

定向回归使用 `swift test --filter 'CoreTests/(testCodexAppServerCancelSendsInterruptAndKillsTree|testCodexAppServerProtocolParsers|testAntigravityBridgeRoutingAndFallbackProcessTreeKill|testAntigravityBridgeHealthAndResultParsing|testStoppedStatusCompletionCuesAndProcessCancellation|testTodoDispatchSQLitePersistence)'`。

本机验证记录（2026-11-26）：两条临时真实待办均从未完成页启动并停止，状态读回为已停止。Codex 桌面会话与 automation 详情由用户确认，Antigravity 会话由桌面和原生回执核对。已授权后的 Antigravity 历史按钮尚未稳定定位到早午班详情。临时待办已移除，测试会话保留。

### 14:31 详情及四项 P2 复验

- 从 Antigravity 普通会话页出发，点击 TodoNotch 的 11 月 25 日早午班 14:31 历史跳转按钮，检查实际详情地址为 `/sidecars/x-ai-vertical-daily`。
- SQLite 回归覆盖同 ID 待确认记录改为停止、普通待办无历史时补写成功记录，以及重复恢复不产生第二条历史。Codex 回归覆盖 app-server 父进程退出时，继承管道的子进程仍被清理。Antigravity 回归覆盖旧回执缺少证据、以及读取本轮回复时屏蔽同一会话的前后轮次。

- 本轮补测包含父进程退出后持续写 stdout 的真实子进程和同任务 A/B 两轮迟到回执，10 项 Swift 定向测试通过。用 14:31 的真实日志行验证了 CRLF、无尾换行的字节位置和旧轮次拒绝。移除旧的 `/Applications/TodoNotch.app` 授权项并开启项目目录版权限后，从 Antigravity 普通会话页点击 TodoNotch 的 11 月 25 日早午班 14:31 历史按钮，实测打开「X 每日 AI 垂直直发（早午班 09:30/11:30）」详情，实际地址为 `/sidecars/x-ai-vertical-daily?q=x-ai-vertical-daily`。

### 待确认记录与列表刷新

- 待确认关联记录应跨越普通历史的 500 条上限及 30 天期限，迟到回执处理后恢复普通保留规则。按用户要求只使用现有真实数据。本机有 57 条历史和 0 条待确认关联记录，验收采用只读 SQL 执行计划及独立复审，未复现 500 条负载。
- Antigravity 先出现本次清空查询的无匹配标记，再按目标任务 ID 筛选。北京时间 13:16，从 Antigravity 普通会话页点击 11 月 25 日早午班 14:31 历史按钮。最终构建实际打开 `/sidecars/x-ai-vertical-daily?q=x-ai-vertical-daily`，详情 ID 为 `x-ai-vertical-daily`。复验前观察到 Antigravity 会将空列表提示分段暴露，兼容后已复审并核对最终构建。

### 搜索框查询值替换

- 仅含 `a8ac84f` 和 `e923f63` 的干净构建曾将临时查询和目标 ID 拼在一起，导致结果为空。修复后通过辅助功能接口替换搜索框的整个值，并继续核对实际筛选结果和详情地址。
- 仅用两次提交加本次修复构建 Release 应用。从 Antigravity 普通会话页点击 2026-11-25 14:31:47 的同一条真实历史记录，三次分别于北京时间 13:59:18、13:59:41、14:00:03 打开 `/sidecars/x-ai-vertical-daily?q=x-ai-vertical-daily`，详情 ID 均为 `x-ai-vertical-daily`。三次均只打开详情。

### 桌面定位失败反馈与取消

- 从已有定时任务的执行记录点击桌面跳转。核对 Antigravity 详情 ID、改名后的同 ID 定位，以及同名多候选时保留精确筛选和前台轻提示。用英文、中文界面各核对空结果。
- 核对自动失活后定位继续，成功或失败后的胶囊首次点击展开主浮窗，Esc、收起、胶囊关闭或改点另一个任务可停止旧导航。权限提示可关闭并直达辅助功能设置。后续正常执行轻提示能显示。
- `swift build` 与 `swift test --filter DesktopNavigationTests` 已通过。浮窗焦点、真实 AX 树、Codex 详情及审计读回待桌面验收。
