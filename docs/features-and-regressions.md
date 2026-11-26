# 现有功能与回归清单（TodoNotch）

## 文档版本记录

| 版本/任务标识 | 北京时间（+08:00） | 变更摘要 | 影响功能 | 原因及需求来源 | 适用代码版本与环境 | 验证状态 |
|---|---|---|---|---|---|---|
| `v0.2-design` (`20261124-1836`) | 2026-11-24 18:36 +08:00 | 建立现行原型基线（`F-BASE-01 ~ 02`）与 v1 规划回归清单（`AC-01 ~ AC-15`） | 全部功能 | 需求 `20261124-1748` + 设计 `20261124-1836` | 原型运行于 macOS arm64（2026-11-24） | 基线已验证，v1 待实施 |
| `v1.0-impl` (`20261125-0815`) | 2026-11-25 08:15 +08:00 | v1 全部 4 个增量实现完成并实机运行 `TodoNotch.app`（`PID 94661`），更新各项 AC 验证状态 | `AC-01 ~ AC-15` | 设计 `20261124-1836` 闭环实施 | macOS arm64 Swift 6.4.2 | `swift test` 7/7 通过，`scan_todos.py --self-test` 通过，实机自动发现 22 任务；SMTP/Webhook 真实发信与双屏肉眼观感待用户现场体验确认 |
| `v1.1-parsers` (`20261125-0856`) | 2026-11-25 08:56 +08:00 | 新增 Claude、WorkBuddy（真实 `workbuddy.db` 只读）、ZCode（`db.sqlite` + `v2` JSON 只读）定时任务及近 7 天执行记录解析；工具分类筛选与 18 种动态表情已上线 | `AC-06`, `AC-07`, `AC-14` | 用户追加 Claude/WorkBuddy/ZCode 解析与 Lmemory 绿点验证 | macOS arm64 Swift 6.4.2 | `swift test` 8/8 通过（含三工具真实表结构只读用例），实机 `TodoNotch.app` 已重载 |
| `20261126-retention-filter` | 2026-11-26 12:58 +08:00 | 补记待确认裁剪验证边界与 14:31 刷新验收 | AC-DESKTOP-02、03 | 用户要求修复剩余两项 P2 | macOS arm64 本地开发版 | 14:31 最终构建复验通过 |

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
| `AC-09` | REQ-004 | LIVE-PATH | 5s 轻提示不抢编辑器焦点；5s 内并发 3 条合并展示无重叠闪烁 | 待实施 |
| `AC-10` | REQ-004 | LIVE-PATH + STATIC | SMTP 授权码与完整 Webhook URL 仅存 Keychain，磁盘/日志零明文泄露 | 待实施 |
| `AC-11` | REQ-004 | SYNTHETIC（断网） | 断网时本地浮窗正常弹出，外部推送标失败可重试，不阻塞 UI | 待实施 |
| `AC-12` | REQ-005 | UNIT（时钟注入） | 勿扰 `22:00-08:30` 在 `23:30` / `07:15` 屏蔽弹窗与外推，保留机器人色+静音标 | 待实施 |
| `AC-13` | REQ-005 | SYNTHETIC（缺失文件） | 点击已删产出文件给出内联提示，应用不闪退 | 待实施 |
| `AC-14` | REQ-005 | SYNTHETIC（状态变更） | `夜间维护.md` 为 `nightly: failed` 时健康栏 10 秒内变红并可一键打开 | 待实施 |
| `AC-15` | REQ-004 | REAL-DATA-DRY-RUN | GEO 样本 `82252200` 的长提问与挂起待办完整保留不截断 | 已在原型 `scan_todos.py` 验证，v1 集成后复验 |

### 待确认记录与列表刷新

- 待确认关联记录应跨越普通历史的 500 条上限及 30 天期限，迟到回执处理后恢复普通保留规则。按用户要求只使用现有真实数据。本机有 57 条历史和 0 条待确认关联记录，验收采用只读 SQL 执行计划及独立复审，未复现 500 条负载。
- Antigravity 先出现本次清空查询的无匹配标记，再按目标任务 ID 筛选。北京时间 13:16，从 Antigravity 普通会话页点击 11 月 25 日早午班 14:31 历史按钮。最终构建实际打开 `/sidecars/x-ai-vertical-daily?q=x-ai-vertical-daily`，详情 ID 为 `x-ai-vertical-daily`。复验前观察到 Antigravity 会将空列表提示分段暴露，兼容后已复审并核对最终构建。

拆分说明：13:16 真机记录来自完整工作区的最终构建。两层独立补丁分别完成编译核对。
