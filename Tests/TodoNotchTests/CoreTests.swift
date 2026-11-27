import XCTest
import SQLite3
@testable import TodoNotchCore

final class CoreTests: XCTestCase {
    // AC-02: Robot mood priority & Reduce Motion & DND overlay
    func testRobotStateMachinePriorityAndDND() {
        let now = Date()
        let errOverSuccess = RobotStateMachine.compute(
            unreadErrors: 1, unreadMissed: 0, unreadAttention: 2,
            openPersonalTodos: 3, runningTasks: 1,
            recentSuccessUntil: now.addingTimeInterval(5),
            isDND: false, reduceMotion: false, now: now
        )
        XCTAssertEqual(errOverSuccess.mood, .error)
        XCTAssertFalse(errOverSuccess.showMutedBadge)
        XCTAssertTrue(errOverSuccess.animateIdle)

        // Overdue/missed task beats error & triggers crying mood
        let overdueCry = RobotStateMachine.compute(
            unreadErrors: 1, unreadMissed: 0, unreadAttention: 0,
            openPersonalTodos: 1, overdueTodos: 1, runningTasks: 0,
            recentSuccessUntil: nil, isDND: false, reduceMotion: false, now: now
        )
        XCTAssertEqual(overdueCry.mood, .overdue)

        // DND keeps error color + shows muted badge + stops animation
        let dndErr = RobotStateMachine.compute(
            unreadErrors: 1, unreadMissed: 0, unreadAttention: 0,
            openPersonalTodos: 0, runningTasks: 0, recentSuccessUntil: nil,
            isDND: true, reduceMotion: false, now: now
        )
        XCTAssertEqual(dndErr.mood, .error)
        XCTAssertTrue(dndErr.showMutedBadge)
        XCTAssertFalse(dndErr.animateIdle)

        // Reduce motion stops animation even when idle
        let idleReduced = RobotStateMachine.compute(
            unreadErrors: 0, unreadMissed: 0, unreadAttention: 0,
            openPersonalTodos: 0, runningTasks: 0, recentSuccessUntil: nil,
            isDND: false, reduceMotion: true, now: now
        )
        XCTAssertEqual(idleReduced.mood, .idle)
        XCTAssertFalse(idleReduced.animateIdle)
    }

    // AC-12: Cross-midnight DND
    func testCrossMidnightDND() {
        XCTAssertNotNil(DNDPolicy.validateRange(start: "09:00", end: "09:00"))
        XCTAssertNil(DNDPolicy.validateRange(start: "22:00", end: "08:30"))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let d2330 = cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 23, minute: 30))!
        let d0715 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 7, minute: 15))!
        let d0900 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9, minute: 0))!

        XCTAssertTrue(DNDPolicy.isActive(dndEnabled: true, focusMode: false, start: "22:00", end: "08:30", now: d2330, calendar: cal))
        XCTAssertTrue(DNDPolicy.isActive(dndEnabled: true, focusMode: false, start: "22:00", end: "08:30", now: d0715, calendar: cal))
        XCTAssertFalse(DNDPolicy.isActive(dndEnabled: true, focusMode: false, start: "22:00", end: "08:30", now: d0900, calendar: cal))
        XCTAssertTrue(DNDPolicy.isActive(dndEnabled: false, focusMode: true, start: "22:00", end: "08:30", now: d0900, calendar: cal))
    }

    // AC-08: Sleep exclusion, wake grace, running protection
    func testMissedRunCalculatorSleepAndRunningProtection() {
        let due: Int64 = 1_700_000_000
        let overdueTask = MonitoredTask(
            taskKey: "antigravity:daily", source: .antigravity, nativeId: "daily",
            displayName: "Daily", sourceStatus: "active", lastRunAt: due - 86400,
            lastRunStatus: .success, nextDueAt: due
        )
        let runningTask = MonitoredTask(
            taskKey: "codex:run", source: .codex, nativeId: "run",
            displayName: "Running", sourceStatus: "active", lastRunAt: due - 86400,
            lastRunStatus: .running, nextDueAt: due
        )

        // Within 5-min wake grace => 0 missed
        let inGrace = MissedRunCalculator.findMissedTasks(
            tasks: [overdueTask, runningTask],
            now: due + 3600,
            wakeGraceUntil: due + 3700,
            overlappedSleepSeconds: { _, _ in 0 }
        )
        XCTAssertTrue(inGrace.isEmpty)

        // Slept for 3000s out of 3600s => effectiveDelay = 600s <= 900s => 0 missed
        let sleptMost = MissedRunCalculator.findMissedTasks(
            tasks: [overdueTask, runningTask],
            now: due + 3600,
            wakeGraceUntil: 0,
            overlappedSleepSeconds: { _, _ in 3000 }
        )
        XCTAssertTrue(sleptMost.isEmpty)

        // Awake 1200s past due => overdueTask missed, runningTask NOT missed
        let realMissed = MissedRunCalculator.findMissedTasks(
            tasks: [overdueTask, runningTask],
            now: due + 1200,
            wakeGraceUntil: 0,
            overlappedSleepSeconds: { _, _ in 0 }
        )
        XCTAssertEqual(realMissed.map(\.taskKey), ["antigravity:daily"])
    }

    // SQLite idempotency + preserve notify_level + rolling retention + secret URL validation
    func testSQLiteIdempotencyAndValidation() throws {
        let store = try SQLiteStore(path: ":memory:")
        let task = MonitoredTask(taskKey: "codex:t1", source: .codex, nativeId: "t1", displayName: "T1", notifyLevel: .normal)
        store.upsertTask(task)
        store.updateTaskNotifyLevel(taskKey: "codex:t1", level: .priority)
        // Re-syncing from watcher must preserve user's priority level
        store.upsertTask(MonitoredTask(taskKey: "codex:t1", source: .codex, nativeId: "t1", displayName: "T1 Renamed", notifyLevel: .normal))
        let loaded = store.listTasks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].displayName, "T1 Renamed")
        XCTAssertEqual(loaded[0].notifyLevel, .priority)

        let ev = RunEvent(eventId: "ev-1", taskKey: "codex:t1", taskName: "T1", source: .codex, status: .error, summary: "boom")
        XCTAssertTrue(store.insertEventIfNew(ev))
        XCTAssertFalse(store.insertEventIfNew(ev)) // Idempotent duplicate ignored
        XCTAssertEqual(store.unreadCounts()[.error], 1)

        // Webhook URL validation & masking
        XCTAssertTrue(ValidationHelpers.isValidWebhookURL("https://open.feishu.cn/open-apis/bot/v2/hook/secret1234"))
        XCTAssertTrue(ValidationHelpers.isValidWebhookURL("http://localhost:8080/hook"))
        XCTAssertFalse(ValidationHelpers.isValidWebhookURL("http://example.com/hook"))
        let masked = ValidationHelpers.maskSecretURL("https://open.feishu.cn/open-apis/bot/v2/hook/secret1234")
        XCTAssertFalse(masked.contains("secret"))
        XCTAssertTrue(masked.hasSuffix("1234"))
    }

    func testTodoMarkdownParseAndToggle() {
        let md = """
        ---
        updated_at: 2026-11-24T17:13:00+08:00
        ---
        ## 待你亲自处理
        - [ ] **[html-report-generator-master]** 推进 GEO 报告缺失数据对接
        ## 进行中 / 未收尾项目任务
        - [ ] **[planops]** 补丁待部署
        """
        let (items, label) = TodoMarkdownParser.parse(md)
        XCTAssertEqual(label, "2026-11-24 17:13")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].project, "html-report-generator-master")
        let toggled = TodoMarkdownParser.toggleLine(in: md, lineIndex: items[0].id)!
        let (items2, _) = TodoMarkdownParser.parse(toggled)
        XCTAssertTrue(items2[0].done)
        XCTAssertFalse(items2[1].done)
    }

    // AC-06, AC-07, AC-14: Read-only discovery, inbox drop-in, zero config mutation, Lmemory health
    func testTaskDiscoveryInboxAndLmemoryHealth() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. Antigravity sidecar.json + sidecar.log
        let agyCfgDir = tmp.appendingPathComponent(".gemini/config/sidecars/demo-job")
        let agyLogDir = tmp.appendingPathComponent(".gemini/antigravity/sidecar_data/demo-job/logs")
        try fm.createDirectory(at: agyCfgDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agyLogDir, withIntermediateDirectories: true)
        let sidecarJSON = """
        {"builtin":"schedule","display_name":"演示巡检","args":["CRON_TZ=Asia/Shanghai 0 9 * * *","agentapi","new-conversation","--","hi"]}
        """
        let sidecarURL = agyCfgDir.appendingPathComponent("sidecar.json")
        try sidecarJSON.write(to: sidecarURL, atomically: true, encoding: .utf8)
        let beforeData = try Data(contentsOf: sidecarURL)
        try """
        {"conversationId": "conv-1234"}
        2026-11-24 01:00:05 [schedule] Command completed successfully
        2026-11-24 01:00:06 [schedule] Next execution scheduled in 23h (at 2026-11-25 01:00:00 UTC)
        """.write(to: agyLogDir.appendingPathComponent("sidecar.log"), atomically: true, encoding: .utf8)

        // 2. Codex automation.toml
        let codexDir = tmp.appendingPathComponent(".codex/automations/job-1")
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try """
        id = "job-1"
        name = "每日表情包"
        status = "ACTIVE"
        rrule = "FREQ=DAILY;BYHOUR=12;BYMINUTE=30"
        """.write(to: codexDir.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)

        // 3. Inbox valid + invalid JSON
        let inbox = tmp.appendingPathComponent("inbox")
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        try """
        {"schema_version":"1","event_id":"evt-ok","source":"custom","task_id":"t1","task_name":"测试任务","status":"attention","summary":"需确认"}
        """.write(to: inbox.appendingPathComponent("ok.json"), atomically: true, encoding: .utf8)
        try "{bad json".write(to: inbox.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)

        // 4. Lmemory health failed
        let vault = tmp.appendingPathComponent("vault")
        let autoDir = vault.appendingPathComponent("90 系统文件/自动化")
        try fm.createDirectory(at: autoDir, withIntermediateDirectories: true)
        try "---\nnightly: failed\nnightly_at: 2026-11-24T10:26:28\nlane: cli codex\n---\n".write(
            to: autoDir.appendingPathComponent("夜间维护.md"), atomically: true, encoding: .utf8
        )

        let disc = TaskDiscoveryService(homeDir: tmp, inboxDir: inbox)
        let snap = disc.scanAll()
        XCTAssertEqual(snap.tasks.count, 2)
        XCTAssertTrue(snap.tasks.contains(where: { $0.taskKey == "antigravity:demo-job" && $0.lastRunStatus == .success }))
        XCTAssertTrue(snap.tasks.contains(where: { $0.taskKey == "codex:job-1" && $0.sourceStatus == "active" }))
        XCTAssertTrue(snap.newEvents.contains(where: { $0.eventId == "evt-ok" && $0.status == .attention }))
        XCTAssertTrue(fm.fileExists(atPath: inbox.appendingPathComponent("rejected/bad.json").path))
        // Zero mutation on user config
        XCTAssertEqual(try Data(contentsOf: sidecarURL), beforeData)

        let health = disc.readLmemoryHealth(configuredVault: vault.path)
        XCTAssertEqual(health.state, .failed)
        let missingHealth = disc.readLmemoryHealth(configuredVault: "")
        XCTAssertEqual(missingHealth.state, .missing)
    }

    // AC-04, AC-05: Lmemory installer idempotent backup & payload templates
    func testLmemoryInstallerIdempotencyAndWebhookPayloads() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-inst-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try "[mcp_servers.lmemory]\ncommand = \"lmemory\"\n".write(
            to: tmp.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8
        )
        let store = try SQLiteStore(path: ":memory:")
        let inst = LmemoryInstallerService(homeDir: tmp, store: store)
        let env = inst.detectEnvironment()
        let codex = env.agents.first(where: { $0.name == "codex" })!
        XCTAssertTrue(codex.installed)
        XCTAssertTrue(codex.lmemoryConnected)
        let res = inst.deploy(env: env, vaultPath: tmp.appendingPathComponent("v").path)
        XCTAssertEqual(res.first?.status, "ok")
        XCTAssertGreaterThanOrEqual(store.listAuditCount(), 2)

        let wh = WebhookHTTPClient()
        let feishu = wh.buildPayload(kind: .feishu, title: "T", body: "B")
        XCTAssertEqual(feishu["msg_type"] as? String, "text")
        let bark = wh.buildPayload(kind: .bark, title: "T", body: "B")
        XCTAssertEqual(bark["group"] as? String, "TodoNotch")
    }

    // Read-only discovery for Claude, WorkBuddy (SQLite), and ZCode (SQLite + JSON)
    func testClaudeWorkBuddyAndZCodeDiscovery() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-3tools-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let nowSec = Int64(Date().timeIntervalSince1970)
        let nowMs = nowSec * 1000

        // 1. Claude: ~/.claude/scheduled-tasks/daily-brief/SKILL.md + Desktop scheduled_tasks.json
        let claudeSkillDir = tmp.appendingPathComponent(".claude/scheduled-tasks/daily-brief")
        try fm.createDirectory(at: claudeSkillDir, withIntermediateDirectories: true)
        try """
        ---
        name: Claude 每日简报
        schedule: "0 9 * * *"
        enabled: true
        ---
        Run daily brief.
        """.write(to: claudeSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let claudeDesktopDir = tmp.appendingPathComponent("Library/Application Support/Claude-3p/local-agent-mode-sessions/org1/usr1")
        try fm.createDirectory(at: claudeDesktopDir, withIntermediateDirectories: true)
        try """
        {"tasks":[{"id":"cd-1","name":"Claude 周报","cronExpression":"0 18 * * 5","enabled":true,"lastRunAt":\(nowSec - 300),"lastRunStatus":"success"}]}
        """.write(to: claudeDesktopDir.appendingPathComponent("scheduled_tasks.json"), atomically: true, encoding: .utf8)

        // 2. WorkBuddy: ~/.workbuddy/workbuddy.db (real automations + automation_runs schema)
        let wbDir = tmp.appendingPathComponent(".workbuddy")
        try fm.createDirectory(at: wbDir, withIntermediateDirectories: true)
        let wbDBPath = wbDir.appendingPathComponent("workbuddy.db").path
        var wbDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(wbDBPath, &wbDB), SQLITE_OK)
        let wbSQL = """
        CREATE TABLE automations (id TEXT PRIMARY KEY, name TEXT NOT NULL, prompt TEXT NOT NULL, status TEXT NOT NULL, schedule_type TEXT NOT NULL DEFAULT 'recurring', next_run_at INTEGER, last_run_at INTEGER, rrule TEXT NOT NULL DEFAULT '', scheduled_at TEXT, deleted_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE automation_runs (thread_id TEXT PRIMARY KEY, automation_id TEXT NOT NULL, status TEXT NOT NULL, thread_title TEXT, result_success INTEGER, failure_code TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        INSERT INTO automations VALUES ('wb-1','企微日报','prompt','active','recurring',\(nowMs + 3600000),\(nowMs - 600000),'FREQ=DAILY;BYHOUR=18',NULL,NULL,\(nowMs),\(nowMs));
        INSERT INTO automation_runs VALUES ('th-1','wb-1','completed','日报已发送',1,'',\(nowMs - 600000),\(nowMs - 600000));
        """
        XCTAssertEqual(sqlite3_exec(wbDB, wbSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(wbDB)

        // 3. ZCode: ~/.zcode/cli/db/db.sqlite + ~/.zcode/v2/automations.json
        let zcDBDir = tmp.appendingPathComponent(".zcode/cli/db")
        try fm.createDirectory(at: zcDBDir, withIntermediateDirectories: true)
        let zcDBPath = zcDBDir.appendingPathComponent("db.sqlite").path
        var zcDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(zcDBPath, &zcDB), SQLITE_OK)
        let zcSQL = """
        CREATE TABLE workflow_definition (id TEXT PRIMARY KEY, name TEXT, enabled INTEGER, script_path TEXT, meta_json TEXT, time_updated INTEGER);
        CREATE TABLE workflow_run (id TEXT PRIMARY KEY, definition_id TEXT, name TEXT, status TEXT, failure_json TEXT, time_created INTEGER, time_updated INTEGER, time_completed INTEGER);
        INSERT INTO workflow_definition VALUES ('wf-1','ZCode 夜间巡检',1,'/tmp/wf.py','{"cron":"0 2 * * *"}',\(nowMs));
        INSERT INTO workflow_run VALUES ('run-1','wf-1','ZCode 夜间巡检','failed','{"msg":"timeout"}',\(nowMs - 120000),\(nowMs - 100000),\(nowMs - 100000));
        """
        XCTAssertEqual(sqlite3_exec(zcDB, zcSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(zcDB)

        let zcV2Dir = tmp.appendingPathComponent(".zcode/v2")
        try fm.createDirectory(at: zcV2Dir, withIntermediateDirectories: true)
        try """
        {"automations":[{"id":"zc-auto-1","name":"ZCode 代码评审","schedule":"0 10 * * 1-5","status":"paused"}]}
        """.write(to: zcV2Dir.appendingPathComponent("automations.json"), atomically: true, encoding: .utf8)

        let disc = TaskDiscoveryService(homeDir: tmp, inboxDir: tmp.appendingPathComponent("inbox"))
        let snap = disc.scanAll()

        XCTAssertTrue(snap.tasks.contains(where: { $0.taskKey == "claude:daily-brief" && $0.source == .claude && $0.scheduleExpr == "0 9 * * *" }))
        XCTAssertTrue(snap.tasks.contains(where: { $0.taskKey == "claude:cd-1" && $0.source == .claude && $0.lastRunStatus == .success }))
        XCTAssertTrue(snap.tasks.contains(where: { $0.taskKey == "workbuddy:wb-1" && $0.source == .workbuddy && $0.lastRunStatus == .success }))
        XCTAssertTrue(snap.tasks.contains(where: { $0.taskKey == "zcode:wf-1" && $0.source == .zcode && $0.lastRunStatus == .error }))
        XCTAssertTrue(snap.tasks.contains(where: { $0.taskKey == "zcode:zc-auto-1" && $0.source == .zcode && $0.sourceStatus == "paused" }))

        XCTAssertTrue(snap.newEvents.contains(where: { $0.taskKey == "claude:cd-1" && $0.status == .success }))
        XCTAssertTrue(snap.newEvents.contains(where: { $0.taskKey == "workbuddy:wb-1" && $0.summary == "日报已发送" }))
        XCTAssertTrue(snap.newEvents.contains(where: { $0.taskKey == "zcode:wf-1" && $0.status == .error }))
    }

    // AC-20, AC-21: IP-based default language, offline fallback, manual lock precedence, SQLite persistence
    func testIPLanguageResolutionAndPersistence() throws {
        // 1. Country code parsing (JSON & plain text & invalid)
        XCTAssertEqual(IPLanguageResolver.parseCountryCode(from: Data("{\"country\":\"cn\"}".utf8)), "CN")
        XCTAssertEqual(IPLanguageResolver.parseCountryCode(from: Data("US\n".utf8)), "US")
        XCTAssertNil(IPLanguageResolver.parseCountryCode(from: Data("invalid-country".utf8)))
        XCTAssertNil(IPLanguageResolver.parseCountryCode(from: Data()))

        // 2. CN -> Chinese, non-CN -> English, nil -> system fallback
        XCTAssertEqual(IPLanguageResolver.resolveFromCountry("CN"), .zhHans)
        XCTAssertEqual(IPLanguageResolver.resolveFromCountry("US"), .en)
        XCTAssertEqual(IPLanguageResolver.resolveFromCountry("SG"), .en)
        XCTAssertNil(IPLanguageResolver.resolveFromCountry(""))

        XCTAssertEqual(
            IPLanguageResolver.resolveEffective(mode: .auto, detectedCountry: nil, preferredLanguages: ["zh-Hans-CN", "en-US"]),
            .zhHans
        )
        XCTAssertEqual(
            IPLanguageResolver.resolveEffective(mode: .auto, detectedCountry: nil, preferredLanguages: ["en-US"]),
            .en
        )

        // 3. Manual lock strictly overrides IP changes
        XCTAssertEqual(
            IPLanguageResolver.resolveEffective(mode: .zhHans, detectedCountry: "US", preferredLanguages: ["en-US"]),
            .zhHans
        )
        XCTAssertEqual(
            IPLanguageResolver.resolveEffective(mode: .en, detectedCountry: "CN", preferredLanguages: ["zh-Hans-CN"]),
            .en
        )

        // 4. SQLite persistence + listAllRecentWeekEvents
        let store = try SQLiteStore(path: ":memory:")
        var cfg = store.loadConfig()
        XCTAssertEqual(cfg.languageMode, .auto)
        cfg.languageMode = .en
        cfg.detectedIPCountry = "CN"
        store.saveConfig(cfg)

        let reloaded = store.loadConfig()
        XCTAssertEqual(reloaded.languageMode, .en)
        XCTAssertEqual(reloaded.detectedIPCountry, "CN")

        let now = Int64(Date().timeIntervalSince1970)
        store.insertEventIfNew(RunEvent(eventId: "e-recent", taskKey: "t1", taskName: "T1", source: .codex, status: .success, summary: "ok", occurredAt: now - 3600, createdAt: now))
        store.insertEventIfNew(RunEvent(eventId: "e-old", taskKey: "t1", taskName: "T1", source: .codex, status: .error, summary: "old", occurredAt: now - 10 * 86400, createdAt: now))
        let week = store.listAllRecentWeekEvents(now: now)
        XCTAssertEqual(week.map(\.eventId), ["e-recent"])

        // 5. English & Chinese localization coverage for Core messages, health, deploy & fallback summaries
        XCTAssertEqual(L10n.webhookInvalidURL(.en), "Invalid Webhook URL (https:// or localhost only)")
        XCTAssertEqual(L10n.webhookTestSent(.feishu, .en), "Test message sent to Feishu / Lark")
        XCTAssertEqual(L10n.displayEventSummary("执行完成", status: .success, lang: .en), "Run completed")
        XCTAssertEqual(L10n.displayTaskName("Lmemory 每日维护", source: .launchd, lang: .en), "Lmemory Daily Maintenance")
        XCTAssertEqual(L10n.healthTooltip(LmemoryHealth(state: .healthy, detail: "正常"), .en), "Lmemory synced normally (nightly maintenance succeeded)")
        XCTAssertEqual(ValidationHelpers.maskSecretURL("invalid-url", lang: .en), "Configured (masked)")
    }

    func testTodoSourceParsingAndStableKey() {
        let md = """
        ---
        updated_at: 2026-11-25T09:00:29+08:00
        ---
        ## 待你亲自处理
        - [ ] **[forge]** 确认升级策略 — 来源：`2026-11-25 antigravity (6bc9ba43)`
        - [ ] **[微信表情包]** 处理驳回并复查审核 — 来源：`2026-11-24 codex (01a20b72 / 01a1ed13)、2026-11-25 codex (01a21026)`
        - [ ] **[微信小游戏]** 截取备案原图 — 来源：`2026-11-24 codex (01a206c3)、2026-11-25 antigravity (1fc2a900)`
        """
        let (items, _) = TodoMarkdownParser.parse(md)
        XCTAssertEqual(items.count, 3)

        XCTAssertEqual(items[0].sources, [TodoSourceRef(agent: "antigravity", sessionPrefix: "6bc9ba43")])
        XCTAssertEqual(TodoMarkdownParser.stripSourceSuffix(items[0].text), "确认升级策略")

        XCTAssertEqual(items[1].sources, [
            TodoSourceRef(agent: "codex", sessionPrefix: "01a20b72"),
            TodoSourceRef(agent: "codex", sessionPrefix: "01a1ed13"),
            TodoSourceRef(agent: "codex", sessionPrefix: "01a21026")
        ])
        XCTAssertEqual(items[1].sources.last?.sessionPrefix, "01a21026")

        XCTAssertEqual(items[2].sources, [
            TodoSourceRef(agent: "codex", sessionPrefix: "01a206c3"),
            TodoSourceRef(agent: "antigravity", sessionPrefix: "1fc2a900")
        ])

        // Shifting line index must preserve todoKey
        let shiftedMd = "\n\n" + md
        let (shiftedItems, _) = TodoMarkdownParser.parse(shiftedMd)
        XCTAssertNotEqual(shiftedItems[0].id, items[0].id)
        XCTAssertEqual(shiftedItems[0].todoKey, items[0].todoKey)
    }

    func testTodoDispatchSQLitePersistence() throws {
        let store = try SQLiteStore(path: ":memory:")
        let now: Int64 = 1_795_570_000
        let rec = TodoDispatchRecord(
            todoKey: "k-1",
            dispatchId: "d-1",
            project: "forge",
            todoText: "确认升级策略",
            agent: "codex",
            sessionId: "01a21026-b0a9-7711-af26-768918852de1",
            cwd: "/tmp/forge",
            transcriptPath: "/tmp/rollout.jsonl",
            logPath: "/tmp/d-1.log",
            status: .running,
            summary: "",
            dispatchedAt: now,
            updatedAt: now,
            lastTranscriptMtime: 100,
            pid: 4321
        )
        store.upsertTodoDispatch(rec)
        let fetched = store.getTodoDispatch(todoKey: "k-1")
        XCTAssertEqual(fetched?.status, .running)
        XCTAssertEqual(fetched?.pid, 4321)

        var updated = rec
        updated.status = .completed
        updated.summary = "已完成升级"
        updated.pid = 0
        updated.updatedAt = now + 20
        store.upsertTodoDispatch(updated)

        let list = store.listTodoDispatches()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].status, .completed)
        XCTAssertEqual(list[0].summary, "已完成升级")

        store.deleteTodoDispatch(todoKey: "k-1")
        XCTAssertNil(store.getTodoDispatch(todoKey: "k-1"))
    }

    func testRecoveredAntigravityDispatchHistory() throws {
        let store = try SQLiteStore(path: ":memory:")
        let now = Int64(Date().timeIntervalSince1970)
        for (key, scheduled) in [("antigravity:opta-job", true), ("ordinary-todo", false)] {
            let id = UUID().uuidString
            var record = TodoDispatchRecord(
                todoKey: key, dispatchId: id, project: "OptA", todoText: "run opta",
                agent: "antigravity", sessionId: "conv-opta-1", cwd: "/tmp",
                status: .needsAttention, summary: TodoDispatchRunner.unconfirmedAntigravitySummary,
                dispatchedAt: now, updatedAt: now
            )
            store.upsertTodoDispatch(record)
            let taskKey = scheduled ? key : "dispatch:\(key)"
            if scheduled {
                XCTAssertTrue(store.insertEventIfNew(RunEvent(
                    eventId: "dispatch:\(id)", taskKey: taskKey, taskName: "OptA", source: .antigravity,
                    status: .attention, summary: record.summary, isRead: true, pushStatus: "sent"
                )))
            }
            record.status = scheduled ? .stopped : .completed
            record.summary = scheduled ? "已停止" : "已完成"
            let event = RunEvent(
                eventId: "dispatch:\(id)", taskKey: taskKey, taskName: "OptA", source: .antigravity,
                status: scheduled ? .stopped : .success, summary: record.summary
            )
            XCTAssertTrue(store.saveAntigravityDispatchAndHistory(record, event: event))
            XCTAssertTrue(store.saveAntigravityDispatchAndHistory(record, event: event))
            XCTAssertEqual(store.getTodoDispatch(todoKey: key)?.status, record.status)
            let rows = store.listEvents().filter { $0.eventId == event.eventId }
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.status, event.status)
            if scheduled {
                XCTAssertEqual(rows.first?.isRead, true)
                XCTAssertEqual(rows.first?.pushStatus, "sent")
            }
        }
    }

    func testLateAntigravityHistorySurvivesRetryingSameTask() throws {
        let store = try SQLiteStore(path: ":memory:")
        let now = Int64(Date().timeIntervalSince1970)
        let record = TodoDispatchRecord(
            todoKey: "same-todo", dispatchId: "first", project: "OptA", todoText: "run opta",
            agent: "antigravity", sessionId: "first-session", cwd: "/tmp",
            status: .needsAttention, summary: TodoDispatchRunner.unconfirmedAntigravitySummary,
            dispatchedAt: now, updatedAt: now
        )
        store.upsertTodoDispatch(record)
        let pending = RunEvent(
            eventId: "dispatch:first", taskKey: "dispatch:same-todo", taskName: "OptA",
            source: .antigravity, status: .attention, summary: record.summary, isRead: true
        )
        XCTAssertTrue(store.saveAntigravityDispatchAndHistory(record, event: pending))
        let retry = TodoDispatchRecord(
            todoKey: record.todoKey, dispatchId: "second", project: record.project, todoText: record.todoText,
            agent: record.agent, sessionId: "second-session", cwd: record.cwd,
            status: .running, summary: "", dispatchedAt: now, updatedAt: now
        )
        store.upsertTodoDispatch(retry)
        XCTAssertEqual(store.listUnconfirmedAntigravityHistory().map(\.eventId), [pending.eventId])
        let stopped = RunEvent(
            eventId: pending.eventId, taskKey: pending.taskKey, taskName: pending.taskName,
            source: .antigravity, status: .stopped, summary: "已停止"
        )
        XCTAssertTrue(store.repairUnconfirmedAntigravityHistory(stopped))
        XCTAssertFalse(store.repairUnconfirmedAntigravityHistory(stopped))
        XCTAssertEqual(store.listEvents().first?.status, .stopped)
        XCTAssertEqual(store.getTodoDispatch(todoKey: record.todoKey)?.dispatchId, "second")
        XCTAssertEqual(store.getTodoDispatch(todoKey: record.todoKey)?.status, .running)
    }

    func testTodoTargetResolverAndConversationTracker() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-dispatch-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let projDir = tmp.appendingPathComponent("projects/forge")
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)

        // Lmemory excerpt fixture
        let vault = tmp.appendingPathComponent("vault")
        let excerptsDir = vault.appendingPathComponent("05 时间日志/会话摘录")
        try fm.createDirectory(at: excerptsDir, withIntermediateDirectories: true)
        try """
        ---
        agent: antigravity
        session: 6bc9ba43-fe1a-4e34-aa04-06ffc31234a3
        project: forge
        project_root: \(projDir.path)
        ---
        - **问**：帮我检查升级策略
          **答**：建议优先 P2-A。
        """.write(to: excerptsDir.appendingPathComponent("2026-11-25｜继续（6bc9ba43）.md"), atomically: true, encoding: .utf8)

        // Antigravity transcript fixture
        let agyLogDir = tmp.appendingPathComponent(".gemini/antigravity/brain/6bc9ba43-fe1a-4e34-aa04-06ffc31234a3/.system_generated/logs")
        try fm.createDirectory(at: agyLogDir, withIntermediateDirectories: true)
        let agyTranscript = agyLogDir.appendingPathComponent("transcript.jsonl")
        try """
        {"step_index":1,"type":"USER_INPUT","content":"<USER_REQUEST>继续执行升级</USER_REQUEST>"}
        {"step_index":2,"type":"PLANNER_RESPONSE","content":"已完成升级并验证通过。"}
        """.write(to: agyTranscript, atomically: true, encoding: .utf8)

        let agyItem = TodoItem(
            id: 1,
            section: "personal",
            project: "forge",
            text: "确认升级 — 来源：`2026-11-25 antigravity (6bc9ba43)`",
            done: false,
            sources: [TodoSourceRef(agent: "antigravity", sessionPrefix: "6bc9ba43")]
        )
        let resolvedAgy = TodoTargetResolver.resolve(item: agyItem, vaultPath: vault.path, homeDir: tmp)
        XCTAssertEqual(resolvedAgy.agent, "antigravity")
        XCTAssertEqual(resolvedAgy.sessionId, "6bc9ba43-fe1a-4e34-aa04-06ffc31234a3")
        XCTAssertTrue(resolvedAgy.sessionExists)
        XCTAssertEqual(resolvedAgy.cwd, projDir.path)
        XCTAssertEqual(
            URL(fileURLWithPath: resolvedAgy.transcriptPath).resolvingSymlinksInPath().path,
            agyTranscript.resolvingSymlinksInPath().path
        )

        let agyTurns = ConversationTracker.readConversationTurns(
            agent: "antigravity",
            transcriptPath: resolvedAgy.transcriptPath,
            excerptPath: resolvedAgy.excerptPath,
            logPath: ""
        )
        XCTAssertEqual(agyTurns.count, 2)
        XCTAssertEqual(agyTurns[0].role, "user")
        XCTAssertEqual(agyTurns[0].text, "继续执行升级")
        XCTAssertEqual(agyTurns[1].role, "assistant")
        XCTAssertEqual(agyTurns[1].text, "已完成升级并验证通过。")

        // Codex rollout fixture
        let codexDayDir = tmp.appendingPathComponent(".codex/sessions/2026/11/25")
        try fm.createDirectory(at: codexDayDir, withIntermediateDirectories: true)
        let codexRollout = codexDayDir.appendingPathComponent("rollout-2026-11-25T08-41-40-01a21026-b0a9-7711-af26-768918852de1.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"01a21026-b0a9-7711-af26-768918852de1","cwd":"\(projDir.path)"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请复查审核状态"}]}}
        {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"已重新提交，请登录后台确认审核结果？"}}
        """.write(to: codexRollout, atomically: true, encoding: .utf8)

        let codexItem = TodoItem(
            id: 2,
            section: "personal",
            project: "微信表情包",
            text: "复查审核 — 来源：`2026-11-25 codex (01a21026)`",
            done: false,
            sources: [TodoSourceRef(agent: "codex", sessionPrefix: "01a21026")]
        )
        let resolvedCodex = TodoTargetResolver.resolve(item: codexItem, vaultPath: vault.path, homeDir: tmp)
        XCTAssertEqual(resolvedCodex.agent, "codex")
        XCTAssertEqual(resolvedCodex.sessionId, "01a21026-b0a9-7711-af26-768918852de1")
        XCTAssertTrue(resolvedCodex.sessionExists)
        XCTAssertEqual(resolvedCodex.cwd, projDir.path)

        let codexTurns = ConversationTracker.readConversationTurns(
            agent: "codex",
            transcriptPath: resolvedCodex.transcriptPath,
            excerptPath: "",
            logPath: ""
        )
        XCTAssertEqual(codexTurns.count, 2)
        XCTAssertEqual(codexTurns[1].text, "已重新提交，请登录后台确认审核结果？")

        // Completion classifier checks
        XCTAssertEqual(ConversationTracker.evaluateCompletion(exitCode: 0, latestAssistantReply: "已完成升级并验证通过。", hasPendingUserTurn: false), .completed)
        XCTAssertEqual(ConversationTracker.evaluateCompletion(exitCode: 0, latestAssistantReply: "已重新提交，请登录后台确认审核结果？", hasPendingUserTurn: false), .needsAttention)
        XCTAssertEqual(ConversationTracker.evaluateCompletion(exitCode: 1, latestAssistantReply: "error", hasPendingUserTurn: false), .failed)
    }

    func testTodoDispatchCommandBuilderAndPath() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-env-test-\(UUID().uuidString)")
        let fnmBin = tmp.appendingPathComponent(".local/share/fnm/aliases/default/bin")
        try fm.createDirectory(at: fnmBin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let env = TodoDispatchRunner.buildEnvironment(homeDir: tmp)
        XCTAssertTrue((env["PATH"] ?? "").contains(fnmBin.path))

        let resumeTarget = ResolvedTodoTarget(
            agent: "codex",
            sessionId: "01a21026-b0a9-7711-af26-768918852de1",
            sessionExists: true,
            cwd: "/tmp/proj",
            transcriptPath: "",
            excerptPath: ""
        )
        let codexResume = TodoDispatchRunner.buildCommand(
            agent: "codex",
            executable: "/usr/local/bin/codex",
            target: resumeTarget,
            prompt: "go",
            outputFile: "/tmp/out.txt"
        )
        XCTAssertEqual(codexResume.arguments, ["exec", "resume", "--json", "--skip-git-repo-check", "-o", "/tmp/out.txt", "01a21026-b0a9-7711-af26-768918852de1", "go"])

        let newTarget = ResolvedTodoTarget(
            agent: "antigravity",
            sessionId: "",
            sessionExists: false,
            cwd: "/tmp/proj",
            transcriptPath: "",
            excerptPath: "/tmp/excerpt.md"
        )
        let agyNew = TodoDispatchRunner.buildCommand(
            agent: "antigravity",
            executable: "/Users/test/.local/bin/agy",
            target: newTarget,
            prompt: "go",
            outputFile: "/tmp/out.txt"
        )
        XCTAssertEqual(agyNew.arguments.suffix(3), ["--output-format", "json", "--print", "go"].suffix(3))
        XCTAssertTrue(agyNew.arguments.contains("--settings"))
        XCTAssertTrue(agyNew.arguments.contains(where: { $0.contains("mcp(agy-dart_fast/*)") && $0.contains("mcp(agy-dart_context/*)") && $0.contains("mcp(lmemory/*)") }))
        XCTAssertEqual(agyNew.arguments.last, "go")

        let agyResume = TodoDispatchRunner.buildCommand(
            agent: "antigravity",
            executable: "/Users/test/.local/bin/agy",
            target: ResolvedTodoTarget(agent: "antigravity", sessionId: "conv-abc", sessionExists: true, cwd: "/tmp/proj", transcriptPath: "", excerptPath: ""),
            prompt: "go",
            outputFile: "/tmp/out.txt",
            accessGrants: ["command(node)", "mcp(lmemory/lmemory_ask)"]
        )
        XCTAssertEqual(agyResume.arguments.prefix(2), ["--conversation", "conv-abc"])
        XCTAssertEqual(agyResume.arguments.suffix(3), ["json", "--print", "go"])
        XCTAssertTrue(agyResume.arguments.contains(where: { $0.contains("command(node)") && $0.contains("lmemory_ask") && $0.contains("mcp(agy-dart_fast/*)") }))
    }

    func testScheduledTaskSpecExtractionAndAntigravityLogUTF8Tail() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-sched-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let projDir = tmp.appendingPathComponent("projects/x-ai-blogger")
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)

        // 1. Antigravity sidecar.json + >262KB sidecar.log with Chinese UTF-8 across the tail boundary
        let sidecarDir = tmp.appendingPathComponent(".gemini/config/sidecars/x-test")
        let logDir = tmp.appendingPathComponent(".gemini/antigravity/sidecar_data/x-test/logs")
        try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        let sidecarURL = sidecarDir.appendingPathComponent("sidecar.json")
        let sidecarJSON = """
        {"builtin":"schedule","display_name":"X 测试任务","args":["CRON_TZ=Asia/Shanghai 0 9 * * *","agentapi","new-conversation","--","执行 X 测试任务"],"agent_permissions":{"workspace_uris":["file://\(projDir.path)"],"access_grants":["command(node)","mcp(lmemory/lmemory_ask)"]}}
        """
        try sidecarJSON.write(to: sidecarURL, atomically: true, encoding: .utf8)

        let paddingLine = "2026-11-25 01:00:00 [schedule] 中文日志填充内容用于跨过字节截断边界避免严格解码失败\n"
        var logContent = String(repeating: paddingLine, count: 3000) // > 270 KB
        logContent += """
        {"conversationId":"conv-utf8-ok"}
        2026-11-25 04:20:34 [schedule] Command completed successfully
        2026-11-25 04:20:35 [schedule] Next execution scheduled in 30m (at 2026-11-25 04:50:00 UTC)
        """
        try logContent.write(to: logDir.appendingPathComponent("sidecar.log"), atomically: true, encoding: .utf8)

        let disc = TaskDiscoveryService(homeDir: tmp, inboxDir: tmp.appendingPathComponent("inbox"))
        let snap = disc.scanAll()
        let agyTask = snap.tasks.first(where: { $0.taskKey == "antigravity:x-test" })
        XCTAssertNotNil(agyTask)
        XCTAssertEqual(agyTask?.lastRunStatus, .success)
        XCTAssertNotNil(agyTask?.nextDueAt)

        let agySpec = TodoDispatchRunner.extractScheduledTaskSpec(task: agyTask!, homeDir: tmp)
        XCTAssertEqual(agySpec?.agent, "antigravity")
        XCTAssertEqual(agySpec?.prompt, "执行 X 测试任务")
        XCTAssertEqual(agySpec?.accessGrants, ["command(node)", "mcp(lmemory/lmemory_ask)"])
        XCTAssertEqual(
            agySpec.map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path },
            projDir.resolvingSymlinksInPath().path
        )

        // 2. Denied MCP action log (stderr warning + trailing JSON) must classify as needsAttention
        let deniedLog = tmp.appendingPathComponent("denied.log")
        try """
        jetski: no output produced — a tool required the "mcp" permission that headless mode cannot prompt for, so it was auto-denied.
        {"conversation_id":"0420b3eb","status":"SUCCESS","response":"","denied_actions":[{"action":"mcp","display_name":"McpTool"}]}
        """.write(to: deniedLog, atomically: true, encoding: .utf8)
        let deniedTurns = ConversationTracker.readConversationTurns(
            agent: "antigravity",
            transcriptPath: "",
            excerptPath: "",
            logPath: deniedLog.path,
            maxTurns: 4,
            fallbackPrompt: "运行 X 任务"
        )
        XCTAssertEqual(deniedTurns.count, 2)
        XCTAssertTrue(deniedTurns[1].text.contains("McpTool"))
        XCTAssertEqual(
            ConversationTracker.evaluateCompletion(
                exitCode: 0,
                latestAssistantReply: deniedTurns[1].text,
                hasPendingUserTurn: false,
                deniedActions: ["McpTool"]
            ),
            .needsAttention
        )

        // 2. Codex automation.toml with escaped prompt + target_thread_id
        let codexAutoDir = tmp.appendingPathComponent(".codex/automations/auto-x")
        try fm.createDirectory(at: codexAutoDir, withIntermediateDirectories: true)
        let tomlURL = codexAutoDir.appendingPathComponent("automation.toml")
        try """
        id = "auto-x"
        name = "Codex 测试"
        status = "ACTIVE"
        prompt = "第一行\\n第二行\\"引用\\""
        target_thread_id = "01a21026-b0a9-7711-af26-768918852de1"
        cwds = ["\(projDir.path)"]
        """.write(to: tomlURL, atomically: true, encoding: .utf8)

        let codexTask = MonitoredTask(
            taskKey: "codex:auto-x",
            source: .codex,
            nativeId: "auto-x",
            displayName: "Codex 测试",
            configPath: tomlURL.path
        )
        let codexSpec = TodoDispatchRunner.extractScheduledTaskSpec(task: codexTask, homeDir: tmp)
        XCTAssertEqual(codexSpec?.agent, "codex")
        XCTAssertEqual(codexSpec?.sessionId, "01a21026-b0a9-7711-af26-768918852de1")
        XCTAssertEqual(codexSpec?.sessionExists, true)
        XCTAssertEqual(codexSpec?.prompt, "第一行\n第二行\"引用\"")
    }

    func testAntigravityBridgeHealthAndResultParsing() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-bridge-test-\(UUID().uuidString)")
        let resultsDir = tmp.appendingPathComponent("results")
        try fm.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let now = Int64(Date().timeIntervalSince1970)
        let myPid = ProcessInfo.processInfo.processIdentifier

        // Healthy bridge status (current process PID, fresh timestamp, ready=true)
        let statusURL = tmp.appendingPathComponent("agy-bridge-status.json")
        try """
        {"pid":\(myPid),"ready":true,"updated_at":\(now)}
        """.write(to: statusURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(TodoDispatchRunner.isAntigravityBridgeHealthy(bridgeDir: tmp, now: now))

        // Stale heartbeat (> 30s) -> unhealthy
        XCTAssertFalse(TodoDispatchRunner.isAntigravityBridgeHealthy(bridgeDir: tmp, now: now + 45))

        // Dead PID -> unhealthy
        try """
        {"pid":999999,"ready":true,"updated_at":\(now)}
        """.write(to: statusURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(TodoDispatchRunner.isAntigravityBridgeHealthy(bridgeDir: tmp, now: now))

        // Result file parsing
        try """
        {"dispatch_id":"d-123","status":"running","conversation_id":"conv-999","error":""}
        """.write(to: resultsDir.appendingPathComponent("d-123.json"), atomically: true, encoding: .utf8)
        let res = TodoDispatchRunner.readBridgeResult(bridgeDir: tmp, dispatchId: "d-123")
        XCTAssertEqual(res?.status, "running")
        XCTAssertEqual(res?.conversationId, "conv-999")

        let dispatchId = UUID().uuidString.lowercased()
        let current = UUID().uuidString.lowercased()
        let previous = UUID().uuidString.lowercased()
        let resultURL = resultsDir.appendingPathComponent("\(dispatchId).json")
        try """
        {"pid":\(myPid),"ready":true,"updated_at":\(now),"stop_protocol":2,"bridge_instance":"\(current)"}
        """.write(to: statusURL, atomically: true, encoding: .utf8)
        try """
        {"status":"running","conversation_id":"conv-999","bridge_instance":"\(previous)"}
        """.write(to: resultURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(TodoDispatchRunner.canStopAntigravityBridgeDispatch(dispatchId: dispatchId, bridgeDir: tmp))
        XCTAssertNil(TodoDispatchRunner.requestAntigravityBridgeStop(dispatchId: dispatchId, bridgeDir: tmp))
        try """
        {"status":"running","conversation_id":"conv-999","bridge_instance":"\(current)"}
        """.write(to: resultURL, atomically: true, encoding: .utf8)
        let stop = try XCTUnwrap(TodoDispatchRunner.requestAntigravityBridgeStop(dispatchId: dispatchId, bridgeDir: tmp))
        XCTAssertEqual(TodoDispatchRunner.requestAntigravityBridgeStop(dispatchId: dispatchId, bridgeDir: tmp), stop)

        // Codex JSONL thread_id extraction
        let codexStdout = """
        {"type":"thread.started","thread_id":"01a21103-881e-7a11-9891-6f2bc7c04902"}
        {"type":"turn.started"}
        """
        XCTAssertEqual(TodoDispatchRunner.extractCodexThreadId(fromJSONL: codexStdout), "01a21103-881e-7a11-9891-6f2bc7c04902")
    }

    func testExtendedAgentsPiOpenCodeGrokQoder() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-ext-agents-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. Source parsing for pi / opencode / grok / qoder
        let sources = TodoMarkdownParser.parseSources(
            from: "跟进处理 — 来源：`2026-11-25 pi (019fc7c1)、opencode (ses_abc123)、grok (g12345)、qoder (q98765)`"
        )
        XCTAssertEqual(sources, [
            TodoSourceRef(agent: "pi", sessionPrefix: "019fc7c1"),
            TodoSourceRef(agent: "opencode", sessionPrefix: "ses_abc123"),
            TodoSourceRef(agent: "grok", sessionPrefix: "g12345"),
            TodoSourceRef(agent: "qoder", sessionPrefix: "q98765")
        ])

        // 2. Pi session resolution + Pi JSONL ("type":"message") turn reading
        let projDir = tmp.appendingPathComponent("projects/demo")
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        let piRunDir = tmp.appendingPathComponent(".pi/agent/sessions/--Users-libo-projects-demo--/run-0")
        try fm.createDirectory(at: piRunDir, withIntermediateDirectories: true)
        let piSession = piRunDir.appendingPathComponent("session.jsonl")
        try """
        {"type":"session","version":3,"id":"019fc7c1-e7f4-7275-9def-dc7ee20c1b4c","cwd":"\(projDir.path)"}
        {"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"修复 Pi 调度"}]}}
        {"type":"message","id":"m2","message":{"role":"assistant","content":[{"type":"text","text":"已完成 Pi 调度修复。"}]}}
        """.write(to: piSession, atomically: true, encoding: .utf8)

        let piItem = TodoItem(
            id: 0, section: "personal", project: "demo",
            text: "修复 Pi 调度 — 来源：pi (019fc7c1)", done: false,
            sources: [TodoSourceRef(agent: "pi", sessionPrefix: "019fc7c1")]
        )
        let piTarget = TodoTargetResolver.resolve(item: piItem, vaultPath: "", homeDir: tmp)
        XCTAssertEqual(piTarget.agent, "pi")
        XCTAssertTrue(piTarget.sessionExists)
        XCTAssertEqual(piTarget.sessionId, "019fc7c1-e7f4-7275-9def-dc7ee20c1b4c")
        let piTurns = ConversationTracker.readConversationTurns(
            agent: "pi", transcriptPath: piTarget.transcriptPath, excerptPath: "", logPath: ""
        )
        XCTAssertEqual(piTurns.count, 2)
        XCTAssertEqual(piTurns[0].role, "user")
        XCTAssertEqual(piTurns[1].text, "已完成 Pi 调度修复。")

        // 3. OpenCode SQLite session_v2 lookup
        let ocDir = tmp.appendingPathComponent(".local/share/opencode")
        try fm.createDirectory(at: ocDir, withIntermediateDirectories: true)
        var ocDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(ocDir.appendingPathComponent("opencode.db").path, &ocDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(ocDB, """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT);
        INSERT INTO session_v2 VALUES ('ses_abc123full', 'p1', '\(projDir.path)');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(ocDB)

        let ocItem = TodoItem(
            id: 1, section: "personal", project: "demo",
            text: "OpenCode 任务 — 来源：opencode (ses_abc123)", done: false,
            sources: [TodoSourceRef(agent: "opencode", sessionPrefix: "ses_abc123")]
        )
        let ocTarget = TodoTargetResolver.resolve(item: ocItem, vaultPath: "", homeDir: tmp)
        XCTAssertEqual(ocTarget.agent, "opencode")
        XCTAssertTrue(ocTarget.sessionExists)
        XCTAssertEqual(ocTarget.sessionId, "ses_abc123full")

        // 4. PATH + command builder for pi, opencode, grok, qoder
        let grokBin = tmp.appendingPathComponent(".grok/bin")
        try fm.createDirectory(at: grokBin, withIntermediateDirectories: true)
        let env = TodoDispatchRunner.buildEnvironment(homeDir: tmp)
        XCTAssertTrue((env["PATH"] ?? "").contains(grokBin.path))

        XCTAssertEqual(
            TodoDispatchRunner.buildCommand(agent: "pi", executable: "/usr/bin/pi", target: piTarget, prompt: "go", outputFile: "/tmp/o").arguments,
            ["--mode", "json", "--session", "019fc7c1-e7f4-7275-9def-dc7ee20c1b4c", "-p", "go"]
        )
        XCTAssertEqual(
            TodoDispatchRunner.buildCommand(agent: "opencode", executable: "/usr/bin/opencode", target: ocTarget, prompt: "go", outputFile: "/tmp/o").arguments,
            ["run", "--format", "json", "-s", "ses_abc123full", "go"]
        )
        let grokNew = ResolvedTodoTarget(agent: "grok", sessionId: "", sessionExists: false, cwd: "/tmp/p", transcriptPath: "", excerptPath: "")
        XCTAssertEqual(
            TodoDispatchRunner.buildCommand(agent: "grok", executable: "/usr/bin/grok", target: grokNew, prompt: "go", outputFile: "/tmp/o").arguments,
            ["--output-format", "json", "--cwd", "/tmp/p", "-p", "go"]
        )
        let qoderNew = ResolvedTodoTarget(agent: "qoder", sessionId: "", sessionExists: false, cwd: "/tmp/p", transcriptPath: "", excerptPath: "")
        XCTAssertEqual(
            TodoDispatchRunner.buildCommand(agent: "qoder", executable: "/usr/bin/qoderclicn", target: qoderNew, prompt: "go", outputFile: "/tmp/o").arguments,
            ["-w", "/tmp/p", "-p", "go"]
        )
    }

    func testCodexLockFallbackHelpersAndState5CwdResolution() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-codex-state5-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. Fork command builder + conflict detection + process error summary
        let forkCmd = TodoDispatchRunner.buildCodexForkCommand(
            executable: "/usr/bin/codex",
            sessionId: "01a1ed13-a0bd-72b1-868a-f80dbe703423",
            prompt: "go",
            outputFile: "/tmp/out.txt"
        )
        XCTAssertEqual(
            forkCmd.arguments,
            ["exec", "fork", "--json", "--skip-git-repo-check", "-o", "/tmp/out.txt", "01a1ed13-a0bd-72b1-868a-f80dbe703423", "go"]
        )

        let conflictLog = """
        2026-11-25T06:27:31.618095Z ERROR codex_core::session::session: failed to initialize thread persistence: thread-store conflict: thread 01a1ed13-a0bd-72b1-868a-f80dbe703423 already has an active writer
        Error: thread/resume: thread/resume failed: thread 01a1ed13-a0bd-72b1-868a-f80dbe703423 already has an active writer (code -32600)
        """
        XCTAssertTrue(TodoDispatchRunner.isCodexResumeConflictError(conflictLog))
        XCTAssertFalse(TodoDispatchRunner.isCodexResumeConflictError("{\"type\":\"turn.completed\"}"))
        XCTAssertTrue(
            TodoDispatchRunner.extractProcessErrorSummary(from: Data(conflictLog.utf8))
                .hasPrefix("Error: thread/resume:")
        )

        // 2. Fallback to ~/.codex/state_5.sqlite for cwd and rollout_path when automation.toml omits cwds
        let codexDir = tmp.appendingPathComponent(".codex")
        let projDir = tmp.appendingPathComponent("projects/sticker-pack")
        let autoDir = codexDir.appendingPathComponent("automations/automation-test")
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: autoDir, withIntermediateDirectories: true)

        let fakeRollout = tmp.appendingPathComponent("rollout-test.jsonl")
        try "{}\n".write(to: fakeRollout, atomically: true, encoding: .utf8)

        var stateDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(codexDir.appendingPathComponent("state_5.sqlite").path, &stateDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(stateDB, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, cwd TEXT NOT NULL);
        INSERT INTO threads VALUES ('01a1ed13-a0bd-72b1-868a-f80dbe703423', '\(fakeRollout.path)', '\(projDir.path)');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(stateDB)

        let tomlURL = autoDir.appendingPathComponent("automation.toml")
        try """
        id = "automation-test"
        name = "表情包测试"
        status = "ACTIVE"
        prompt = "执行测试任务"
        target_thread_id = "01a1ed13-a0bd-72b1-868a-f80dbe703423"
        """.write(to: tomlURL, atomically: true, encoding: .utf8)

        let item = TodoItem(
            id: 0,
            section: "personal",
            project: "表情包",
            text: "跟进投稿 — 来源：codex (01a1ed13)",
            done: false,
            sources: [TodoSourceRef(agent: "codex", sessionPrefix: "01a1ed13")]
        )
        let resolved = TodoTargetResolver.resolve(item: item, vaultPath: "", homeDir: tmp)
        XCTAssertTrue(resolved.sessionExists)
        XCTAssertEqual(URL(fileURLWithPath: resolved.cwd).resolvingSymlinksInPath().path, projDir.resolvingSymlinksInPath().path)
        XCTAssertEqual(URL(fileURLWithPath: resolved.transcriptPath).resolvingSymlinksInPath().path, fakeRollout.resolvingSymlinksInPath().path)

        let task = MonitoredTask(
            taskKey: "codex:automation-test",
            source: .codex,
            nativeId: "automation-test",
            displayName: "表情包测试",
            configPath: tomlURL.path
        )
        let spec = TodoDispatchRunner.extractScheduledTaskSpec(task: task, homeDir: tmp)
        XCTAssertEqual(URL(fileURLWithPath: spec?.cwd ?? "").resolvingSymlinksInPath().path, projDir.resolvingSymlinksInPath().path)
    }

    func testCodexAppServerProtocolParsers() throws {
        let threadJSON: [String: Any] = [
            "id": 3,
            "result": [
                "thread": [
                    "id": "01a2116c-d98d-7061-9db5-7863d8a3554f",
                    "path": "/tmp/rollout.jsonl",
                    "source": "vscode"
                ]
            ]
        ]
        let parsedThread = TodoDispatchRunner.parseCodexAppServerThreadResponse(threadJSON)
        XCTAssertEqual(parsedThread?.threadId, "01a2116c-d98d-7061-9db5-7863d8a3554f")
        XCTAssertEqual(parsedThread?.path, "/tmp/rollout.jsonl")
        XCTAssertEqual(parsedThread?.source, "vscode")

        let completedTurnJSON: [String: Any] = [
            "method": "turn/completed",
            "params": [
                "threadId": "01a2116c-d98d-7061-9db5-7863d8a3554f",
                "turn": [
                    "id": "turn-1",
                    "status": "completed",
                    "items": [
                        ["type": "userMessage", "id": "i1"],
                        ["type": "agentMessage", "id": "i2", "text": "已完成微信表情包投稿检查。"]
                    ]
                ]
            ]
        ]
        let parsedCompleted = TodoDispatchRunner.parseCodexAppServerTurnCompleted(completedTurnJSON)
        XCTAssertEqual(parsedCompleted?.turnId, "turn-1")
        XCTAssertEqual(parsedCompleted?.status, "completed")
        XCTAssertEqual(parsedCompleted?.assistantText, "已完成微信表情包投稿检查。")
        XCTAssertEqual(parsedCompleted?.errorMessage, "")

        let failedTurnJSON: [String: Any] = [
            "method": "turn/completed",
            "params": [
                "threadId": "01a2116c-d98d-7061-9db5-7863d8a3554f",
                "turn": [
                    "id": "turn-2",
                    "status": "failed",
                    "items": [],
                    "error": ["message": "Rate limit exceeded"]
                ]
            ]
        ]
        let parsedFailed = TodoDispatchRunner.parseCodexAppServerTurnCompleted(failedTurnJSON)
        XCTAssertEqual(parsedFailed?.status, "failed")
        XCTAssertEqual(parsedFailed?.errorMessage, "Rate limit exceeded")

        let resumeParams = TodoDispatchRunner.buildCodexAppServerThreadParams(method: "thread/resume", threadId: "tid-1", cwd: "/tmp/p")
        XCTAssertEqual(resumeParams["excludeTurns"] as? Bool, true)
        XCTAssertEqual(resumeParams["threadId"] as? String, "tid-1")
        XCTAssertEqual(resumeParams["approvalPolicy"] as? String, "never")
        XCTAssertNil(resumeParams["threadSource"])

        let forkParams = TodoDispatchRunner.buildCodexAppServerThreadParams(method: "thread/fork", threadId: "tid-1", cwd: "/tmp/p")
        XCTAssertEqual(forkParams["excludeTurns"] as? Bool, true)
        XCTAssertEqual(forkParams["ephemeral"] as? Bool, false)
        XCTAssertEqual(forkParams["threadSource"] as? String, "user")
        XCTAssertEqual(forkParams["approvalPolicy"] as? String, "never")

        let startParams = TodoDispatchRunner.buildCodexAppServerThreadParams(method: "thread/start", threadId: nil, cwd: "/tmp/p")
        XCTAssertNil(startParams["excludeTurns"])
        XCTAssertEqual(startParams["ephemeral"] as? Bool, false)
        XCTAssertEqual(startParams["threadSource"] as? String, "user")
        XCTAssertEqual(startParams["approvalPolicy"] as? String, "never")

        let title = TodoDispatchRunner.formatCodexThreadTitle(project: "每日原创微信表情包制作与投稿", startedAt: 1_795_590_470)
        XCTAssertTrue(title.hasPrefix("[TodoNotch] 每日原创微信表情包制作与投稿 "))
        XCTAssertTrue(title.count <= 80)
    }

    func testStoppedStatusCompletionCuesAndProcessCancellation() throws {
        // 1. Stopped status persistence & L10n labels
        let store = try SQLiteStore(path: ":memory:")
        let now: Int64 = 1_795_591_000
        let stoppedRec = TodoDispatchRecord(
            todoKey: "codex:stop-test",
            dispatchId: "disp-stop-1",
            project: "表情包",
            todoText: "测试停止",
            agent: "codex",
            sessionId: "",
            cwd: "/tmp",
            status: .stopped,
            summary: L10n.taskStoppedSummary(.zhHans),
            dispatchedAt: now,
            updatedAt: now,
            pid: 0
        )
        store.upsertTodoDispatch(stoppedRec)
        let loaded = store.getTodoDispatch(todoKey: "codex:stop-test")
        XCTAssertEqual(loaded?.status, .stopped)
        XCTAssertEqual(L10n.dispatchStatusLabel(.stopped, .zhHans), "已停止")
        XCTAssertEqual(L10n.dispatchStatusLabel(.stopped, .en), "Stopped")

        // 2. Incomplete / blocked Codex reply must classify as needsAttention, not completed
        let blockedReply = """
        已复核：今天5套仍待审核。
        **定时任务配置尚未保存修改**：当前缺少任务管理工具，桌面工具也因安全限制拒绝访问 Codex。原任务仍启用在北京时间12:30；需要在原任务编辑器替换上述提示词。
        """
        XCTAssertEqual(
            ConversationTracker.evaluateCompletion(
                exitCode: 0,
                latestAssistantReply: blockedReply,
                hasPendingUserTurn: false
            ),
            .needsAttention
        )

        // 3. Real subprocess cancellation via TodoDispatchRunner.cancel
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-cancel-test-\(UUID().uuidString)")
        let binDir = tmp.appendingPathComponent(".local/bin")
        let skillDir = tmp.appendingPathComponent(".claude/scheduled-tasks/slow-task")
        let logDir = tmp.appendingPathComponent("logs")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let fakeClaude = binDir.appendingPathComponent("claude")
        try "#!/bin/sh\nsleep 30\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let skillMD = skillDir.appendingPathComponent("SKILL.md")
        try """
        ---
        name: Slow Task
        schedule: "0 9 * * *"
        ---
        Run slow check
        """.write(to: skillMD, atomically: true, encoding: .utf8)

        let task = MonitoredTask(
            taskKey: "claude:slow-task",
            source: .claude,
            nativeId: "slow-task",
            displayName: "Slow Task",
            configPath: skillMD.path
        )
        final class CaptureBox: @unchecked Sendable {
            private let lock = NSLock()
            var pid: Int32 = 0
            var rec: TodoDispatchRecord?
            func recordStart(_ p: Int32) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard p > 0 && pid == 0 else { return false }
                pid = p
                return true
            }
            func setCompleted(_ r: TodoDispatchRecord) {
                lock.lock()
                rec = r
                lock.unlock()
            }
            func snapshot() -> (Int32, TodoDispatchRecord?) {
                lock.lock()
                defer { lock.unlock() }
                return (pid, rec)
            }
        }

        let runner = TodoDispatchRunner()
        let startedExp = expectation(description: "dispatch started")
        let completedExp = expectation(description: "dispatch stopped")
        let box = CaptureBox()

        runner.dispatchScheduledTask(
            task: task,
            logDir: logDir,
            homeDir: tmp,
            onStarted: { rec in
                if box.recordStart(rec.pid) {
                    startedExp.fulfill()
                    _ = runner.cancel(recordKey: task.taskKey)
                }
            },
            onCompleted: { rec in
                box.setCompleted(rec)
                completedExp.fulfill()
            }
        )

        wait(for: [startedExp, completedExp], timeout: 5.0)
        let (launchedPid, finalRec) = box.snapshot()
        XCTAssertGreaterThan(launchedPid, 0)
        XCTAssertEqual(finalRec?.status, .stopped)
        XCTAssertEqual(finalRec?.pid, 0)
        XCTAssertFalse(runner.isActive(recordKey: task.taskKey))
        XCTAssertFalse(ConversationTracker.isProcessAlive(launchedPid))
    }

    func testAntigravityBridgeRoutingAndFallbackProcessTreeKill() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-opta-bridge-\(UUID().uuidString)")
        let binDir = tmp.appendingPathComponent(".local/bin")
        let sidecarDir = tmp.appendingPathComponent(".gemini/config/sidecars/opta-job")
        let bridgeDir = tmp.appendingPathComponent("Library/Application Support/TodoNotch/bridge")
        let resultsDir = bridgeDir.appendingPathComponent("results")
        let requestsDir = bridgeDir.appendingPathComponent("requests")
        let logDir = tmp.appendingPathComponent("logs")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: requestsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let statusFile = bridgeDir.appendingPathComponent("agy-bridge-status.json")
        let now = Int64(Date().timeIntervalSince1970)
        try """
        {"pid":\(ProcessInfo.processInfo.processIdentifier),"ready":true,"updated_at":\(now)}
        """.write(to: statusFile, atomically: true, encoding: .utf8)

        let childPidFile = tmp.appendingPathComponent("child.pid")
        let cliInvokedFile = tmp.appendingPathComponent("cli.invoked")
        let fakeAgy = binDir.appendingPathComponent("agy")
        try """
        #!/bin/sh
        echo "invoked" > "\(cliInvokedFile.path)"
        sleep 30 >/dev/null 2>&1 &
        CHILD=$!
        echo "$CHILD" > "\(childPidFile.path)"
        wait "$CHILD"
        """.write(to: fakeAgy, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgy.path)

        let sidecarJSON = sidecarDir.appendingPathComponent("sidecar.json")
        try """
        {"builtin":"schedule","display_name":"OptA Bridge Test","args":["CRON_TZ=Asia/Shanghai 0 9 * * *","agentapi","new-conversation","--","run opta"]}
        """.write(to: sidecarJSON, atomically: true, encoding: .utf8)

        let task = MonitoredTask(
            taskKey: "antigravity:opta-job",
            source: .antigravity,
            nativeId: "opta-job",
            displayName: "OptA Bridge Test",
            configPath: sidecarJSON.path
        )

        final class BridgeBox: @unchecked Sendable {
            private let lock = NSLock()
            var pid: Int32 = 0
            var rec: TodoDispatchRecord?
            func recordStart(_ p: Int32) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                pid = p
                return true
            }
            func setCompleted(_ r: TodoDispatchRecord) {
                lock.lock()
                rec = r
                lock.unlock()
            }
            func snapshot() -> (Int32, TodoDispatchRecord?) {
                lock.lock()
                defer { lock.unlock() }
                return (pid, rec)
            }
        }

        // 1. Healthy bridge (Option A): routes via bridge/requests/, never invokes local CLI `agy`.
        let runner = TodoDispatchRunner()
        let startedExp = expectation(description: "bridge started")
        let completedExp = expectation(description: "bridge completed")
        let box = BridgeBox()

        runner.dispatchScheduledTask(
            task: task,
            logDir: logDir,
            homeDir: tmp,
            onStarted: { rec in
                if box.recordStart(rec.pid) {
                    startedExp.fulfill()
                }
            },
            onCompleted: { rec in
                box.setCompleted(rec)
                completedExp.fulfill()
            }
        )

        let reqDeadline = Date().addingTimeInterval(3.0)
        var capturedDispatchId = ""
        var capturedPrompt = ""
        while Date() < reqDeadline {
            let names = ((try? fm.contentsOfDirectory(atPath: requestsDir.path)) ?? [])
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            if let first = names.first,
               let data = try? Data(contentsOf: requestsDir.appendingPathComponent(first)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let did = obj["dispatch_id"] as? String {
                capturedDispatchId = did
                capturedPrompt = (obj["prompt"] as? String) ?? ""
                XCTAssertEqual(obj["mode"] as? String, "new")
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(capturedDispatchId.isEmpty)
        XCTAssertTrue(capturedPrompt.contains("run opta"))

        // A late receipt must identify the current reply, even if a later turn has since been appended.
        let transcriptDir = tmp.appendingPathComponent(".gemini/antigravity/brain/conv-opta-1/.system_generated/logs")
        try fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcript = transcriptDir.appendingPathComponent("transcript.jsonl")
        let prefix = """
        {"type":"PLANNER_RESPONSE","status":"DONE","step_index":0,"content":"旧任务已完成。"}
        {"type":"USER_INPUT","content":"run opta"}
        """ + "\n"
        let reply = """
        {"type":"PLANNER_RESPONSE","status":"DONE","step_index":2,"tool_calls":[],"content":"已完成 OptA 调度检查。"}
        """
        let later = """
        {"type":"PLANNER_RESPONSE","status":"DONE","step_index":4,"content":"另一轮需要你确认。"}
        """
        try (prefix + reply + "\n" + later).write(to: transcript, atomically: true, encoding: .utf8)

        try """
        {"dispatch_id":"\(capturedDispatchId)","status":"completed","conversation_id":"conv-opta-1","error":"",
        "reply_evidence":{"offset":\(prefix.utf8.count),"length":\(reply.utf8.count),"step_index":2}}
        """.write(to: resultsDir.appendingPathComponent("\(capturedDispatchId).json"), atomically: true, encoding: .utf8)

        let legacy = TodoDispatchRunner.BridgeResult(status: "completed", conversationId: "conv-opta-1", error: "")
        let unverified = TodoDispatchRunner.antigravityCompletion(legacy, transcriptPath: transcript.path)
        XCTAssertEqual(unverified.status, .needsAttention)
        XCTAssertTrue(unverified.reply.isEmpty)

        wait(for: [startedExp, completedExp], timeout: 6.0)
        let (bridgePid, bridgeRec) = box.snapshot()
        XCTAssertEqual(bridgePid, 0)
        XCTAssertEqual(bridgeRec?.status, .completed)
        XCTAssertEqual(bridgeRec?.summary, "已完成 OptA 调度检查。")
        XCTAssertEqual(bridgeRec?.sessionId, "conv-opta-1")
        XCTAssertEqual(bridgeRec?.pid, 0)
        XCTAssertFalse(fm.fileExists(atPath: cliInvokedFile.path))

        // 2. Unhealthy bridge fallback: runs local `agy` CLI and kills entire process tree on cancel.
        try? fm.removeItem(at: statusFile)
        let fallbackStartedExp = expectation(description: "cli fallback started")
        let fallbackCompletedExp = expectation(description: "cli fallback stopped")
        let fallbackBox = BridgeBox()

        runner.dispatchScheduledTask(
            task: task,
            logDir: logDir,
            homeDir: tmp,
            onStarted: { rec in
                if rec.pid > 0 {
                    _ = fallbackBox.recordStart(rec.pid)
                    fallbackStartedExp.fulfill()
                }
            },
            onCompleted: { rec in
                fallbackBox.setCompleted(rec)
                fallbackCompletedExp.fulfill()
            }
        )

        wait(for: [fallbackStartedExp], timeout: 5.0)
        let pidWaitDeadline = Date().addingTimeInterval(2.0)
        var childPid: Int32 = 0
        while Date() < pidWaitDeadline {
            if let txt = try? String(contentsOf: childPidFile, encoding: .utf8),
               let parsed = Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                childPid = parsed
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(childPid, 0)
        XCTAssertTrue(ConversationTracker.isProcessAlive(childPid))

        XCTAssertTrue(runner.cancel(recordKey: task.taskKey))
        wait(for: [fallbackCompletedExp], timeout: 5.0)

        let (launchedPid, finalRec) = fallbackBox.snapshot()
        XCTAssertGreaterThan(launchedPid, 0)
        XCTAssertEqual(finalRec?.status, .stopped)
        XCTAssertEqual(finalRec?.pid, 0)
        XCTAssertFalse(ConversationTracker.isProcessAlive(launchedPid))
        XCTAssertFalse(ConversationTracker.isProcessAlive(childPid))
    }

    func testCodexAppServerCancelSendsInterruptAndKillsTree() throws {
        try checkCodexAppServerCancellation(exitsBeforeTerminalReceipt: false)
    }

    func testCodexAppServerStopAfterParentExitWithWritingChild() throws {
        try checkCodexAppServerCancellation(exitsBeforeTerminalReceipt: true)
    }

    private func checkCodexAppServerCancellation(exitsBeforeTerminalReceipt: Bool) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-codex-cancel-\(UUID().uuidString)")
        let binDir = tmp.appendingPathComponent(".local/bin")
        let autoDir = tmp.appendingPathComponent(".codex/automations/cancel-job")
        let projDir = tmp.appendingPathComponent("projects/demo")
        let logDir = tmp.appendingPathComponent("logs")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: autoDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let rpcLog = tmp.appendingPathComponent("rpc.log")
        let childPidFile = tmp.appendingPathComponent("codex-child.pid")
        let persisted = tmp.appendingPathComponent("interrupted-turn.json")
        let fakeCodex = binDir.appendingPathComponent("codex")
        try """
        #!/usr/bin/python3 -u
        import json, subprocess, sys, time

        rpc_log = "\(rpcLog.path)"
        child_pid_file = "\(childPidFile.path)"
        persisted = "\(persisted.path)"
        child = None

        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            with open(rpc_log, "a", encoding="utf-8") as f:
                f.write(line + "\\n")
                f.flush()
            try:
                msg = json.loads(line)
            except Exception:
                continue
            mid = msg.get("id")
            method = msg.get("method", "")
            if method == "initialize":
                print(json.dumps({"id": mid, "result": {"userAgent": "codex-test"}}), flush=True)
            elif method == "thread/start":
                print(json.dumps({"id": mid, "result": {"thread": {"id": "thr-cancel-1", "path": "", "source": "vscode"}}}), flush=True)
            elif method == "thread/name/set":
                print(json.dumps({"id": mid, "result": {}}), flush=True)
            elif method == "turn/start":
                child = subprocess.Popen(["/usr/bin/yes", " "] if \(exitsBeforeTerminalReceipt ? "True" : "False") else ["/bin/sleep", "30"])
                with open(child_pid_file, "w", encoding="utf-8") as pf:
                    pf.write(str(child.pid))
                    pf.flush()
                time.sleep(0.45)
                print(json.dumps({"id": mid, "result": {"turn": {"id": "turn-live-1", "status": "inProgress"}}}), flush=True)
                print(json.dumps({"method": "turn/started", "params": {"threadId": "thr-cancel-1", "turn": {"id": "turn-live-1", "status": "inProgress"}}}), flush=True)

            elif method == "turn/interrupt":
                print(json.dumps({"id": mid, "result": {}}), flush=True)
                if \(exitsBeforeTerminalReceipt ? "True" : "False"):
                    break
                time.sleep(0.6)
                with open(persisted, "w", encoding="utf-8") as f:
                    json.dump({"role": "assistant", "text": "Progress before stop"}, f)
                print(json.dumps({"method": "turn/completed", "params": {"threadId": "thr-cancel-1", "turn": {"id": "turn-live-1", "status": "interrupted"}}}), flush=True)
            elif method == "thread/unsubscribe":
                break
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let tomlURL = autoDir.appendingPathComponent("automation.toml")
        try """
        id = "cancel-job"
        name = "Codex Stop Test"
        status = "ACTIVE"
        prompt = "run long codex turn"
        cwds = ["\(projDir.path)"]
        """.write(to: tomlURL, atomically: true, encoding: .utf8)

        let task = MonitoredTask(
            taskKey: "codex:cancel-job",
            source: .codex,
            nativeId: "cancel-job",
            displayName: "Codex Stop Test",
            configPath: tomlURL.path
        )

        final class CodexBox: @unchecked Sendable {
            private let lock = NSLock()
            var pid: Int32 = 0
            var rec: TodoDispatchRecord?
            func recordStart(_ p: Int32) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard p > 0 && pid == 0 else { return false }
                pid = p
                return true
            }
            func setCompleted(_ r: TodoDispatchRecord) {
                lock.lock()
                rec = r
                lock.unlock()
            }
            func snapshot() -> (Int32, TodoDispatchRecord?) {
                lock.lock()
                defer { lock.unlock() }
                return (pid, rec)
            }
        }

        let runner = TodoDispatchRunner()
        let startedExp = expectation(description: "codex started")
        let completedExp = expectation(description: "codex stopped")
        let box = CodexBox()

        runner.dispatchScheduledTask(
            task: task,
            logDir: logDir,
            homeDir: tmp,
            onStarted: { rec in
                if box.recordStart(rec.pid) {
                    startedExp.fulfill()
                }
            },
            onCompleted: { rec in
                box.setCompleted(rec)
                completedExp.fulfill()
            }
        )

        wait(for: [startedExp], timeout: 5.0)
        let deadline = Date().addingTimeInterval(3.0)
        var childPid: Int32 = 0
        while Date() < deadline {
            if let txt = try? String(contentsOf: childPidFile, encoding: .utf8),
               let parsed = Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                childPid = parsed
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(childPid, 0)
        XCTAssertTrue(ConversationTracker.isProcessAlive(childPid))

        // The stop arrives before turn/start sends the native turn ID.
        XCTAssertTrue(runner.cancel(recordKey: task.taskKey))
        wait(for: [completedExp], timeout: 5.0)

        let (launchedPid, finalRec) = box.snapshot()
        XCTAssertGreaterThan(launchedPid, 0)
        XCTAssertEqual(finalRec?.status, exitsBeforeTerminalReceipt ? .failed : .stopped)
        XCTAssertEqual(finalRec?.pid, 0)
        XCTAssertEqual(fm.fileExists(atPath: persisted.path), !exitsBeforeTerminalReceipt)
        XCTAssertEqual(finalRec?.sessionId, "thr-cancel-1")
        XCTAssertFalse(ConversationTracker.isProcessAlive(launchedPid))
        XCTAssertFalse(ConversationTracker.isProcessAlive(childPid))

        let rpcText = (try? String(contentsOf: rpcLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(rpcText.contains("\"turn/interrupt\""))
        XCTAssertTrue(rpcText.contains("\"turn-live-1\""))
        XCTAssertEqual(rpcText.contains("\"thread/unsubscribe\""), !exitsBeforeTerminalReceipt)
    }

    func testTodoToggleByKeySurvivesLineReorderAndRejectsStaleMissing() {
        let initial = """
        ## 待你亲自处理
        - [ ] **[proj-a]** 第一项任务
        - [ ] **[proj-b]** 目标任务
        """
        let (items, _) = TodoMarkdownParser.parse(initial)
        XCTAssertEqual(items.count, 2)
        let target = items[1]

        // 1. Line reorder above target still toggles the right item by todoKey
        let reordered = """
        ## 待你亲自处理
        - [ ] **[proj-x]** 顶部插入的新任务
        - [ ] **[proj-a]** 第一项任务
        - [ ] **[proj-b]** 目标任务
        """
        let toggled = TodoMarkdownParser.toggleTodo(in: reordered, todoKey: target.todoKey, preferredLineIndex: target.id)
        XCTAssertNotNil(toggled)
        let (afterItems, _) = TodoMarkdownParser.parse(toggled!)
        XCTAssertFalse(afterItems[0].done)
        XCTAssertFalse(afterItems[1].done)
        XCTAssertTrue(afterItems[2].done)

        // 2. Missing target at the old line index must return nil instead of toggling another line
        let missing = """
        ## 待你亲自处理
        - [ ] **[proj-a]** 第一项任务
        - [ ] **[proj-c]** 占用了原行号的其他任务
        """
        XCTAssertNil(TodoMarkdownParser.toggleTodo(in: missing, todoKey: target.todoKey, preferredLineIndex: target.id))

        // 3. Duplicate open todoKey with stale preferredLineIndex must return nil
        let duplicated = """
        ## 待你亲自处理
        - [ ] **[proj-x]** 顶部插入的新任务
        - [ ] **[proj-a]** 第一项任务
        - [ ] **[proj-b]** 目标任务
        - [ ] **[proj-b]** 目标任务
        """
        XCTAssertNil(TodoMarkdownParser.toggleTodo(in: duplicated, todoKey: target.todoKey, preferredLineIndex: target.id))

        // 4. Already checked-off `- [x]` item at preferredLineIndex must NOT be flipped back to `- [ ]`
        let alreadyChecked = """
        ## 待你亲自处理
        - [ ] **[proj-a]** 第一项任务
        - [x] **[proj-b]** 目标任务
        """
        XCTAssertNil(TodoMarkdownParser.toggleTodo(in: alreadyChecked, todoKey: target.todoKey, preferredLineIndex: target.id))

        // 5. Prior `- [x]` item with the same todoKey must not cause ambiguity when one open `- [ ]` item exists
        let checkedAndNewOpen = """
        ## 待你亲自处理
        - [x] **[proj-b]** 目标任务
        - [ ] **[proj-a]** 第一项任务
        - [ ] **[proj-b]** 目标任务
        """
        let toggledOpen = TodoMarkdownParser.toggleTodo(in: checkedAndNewOpen, todoKey: target.todoKey, preferredLineIndex: target.id)
        XCTAssertNotNil(toggledOpen)
        let (checkedItems, _) = TodoMarkdownParser.parse(toggledOpen!)
        XCTAssertTrue(checkedItems[0].done)
        XCTAssertFalse(checkedItems[1].done)
        XCTAssertTrue(checkedItems[2].done)
    }

    func testPendingInboxDeletesOnlyAfterSQLitePersistence() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-inbox-persist-\(UUID().uuidString)")
        let inbox = tmp.appendingPathComponent("inbox")
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let okURL = inbox.appendingPathComponent("ok.json")
        try """
        {"schema_version":"1","event_id":"evt-pending-1","source":"custom","task_id":"t1","task_name":"测试任务","status":"attention","summary":"待确认"}
        """.write(to: okURL, atomically: true, encoding: .utf8)
        try "{bad json".write(to: inbox.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)

        let disc = TaskDiscoveryService(homeDir: tmp, inboxDir: inbox)
        let pending = disc.readPendingInbox()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].event.eventId, "evt-pending-1")
        XCTAssertTrue(fm.fileExists(atPath: okURL.path))
        XCTAssertTrue(fm.fileExists(atPath: inbox.appendingPathComponent("rejected/bad.json").path))

        let store = try SQLiteStore(path: ":memory:")
        XCTAssertEqual(store.persistEvent(pending[0].event), .inserted)
        XCTAssertEqual(store.persistEvent(pending[0].event), .duplicate)
        disc.acknowledgeInboxFile(pending[0].fileURL)
        XCTAssertFalse(fm.fileExists(atPath: okURL.path))

        // Failed SQLite persistence must retain the file in inbox/
        let retryURL = inbox.appendingPathComponent("retry.json")
        try """
        {"schema_version":"1","event_id":"evt-retry-1","source":"custom","task_id":"t2","task_name":"重试任务","status":"error","summary":"db failed"}
        """.write(to: retryURL, atomically: true, encoding: .utf8)

        let pendingRetry = disc.readPendingInbox()
        XCTAssertEqual(pendingRetry.count, 1)

        let brokenPath = tmp.appendingPathComponent("broken.sqlite").path
        let brokenStore = try SQLiteStore(path: brokenPath)
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(brokenPath, &rawDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(rawDB, "DROP TABLE run_events;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(rawDB)

        let failResult = brokenStore.persistEvent(pendingRetry[0].event)
        XCTAssertEqual(failResult, .failed)
        if failResult == .inserted || failResult == .duplicate {
            disc.acknowledgeInboxFile(pendingRetry[0].fileURL)
        }
        XCTAssertTrue(fm.fileExists(atPath: retryURL.path))
    }

    func testCodexScheduledTaskDiscoveryAndDBRuns() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-codex-disc-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let job1Dir = tmp.appendingPathComponent(".codex/automations/job-active")
        let job2Dir = tmp.appendingPathComponent(".codex/automations/job-paused")
        let sqliteDir = tmp.appendingPathComponent(".codex/sqlite")
        try fm.createDirectory(at: job1Dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: job2Dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sqliteDir, withIntermediateDirectories: true)

        try #"""
        id = "job-active" # inline comment
        name = "每日 \"Codex\" 巡检" # escaped quotes
        status = "ACTIVE"
        rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
        """#.write(to: job1Dir.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)

        // Omit id (falls back to directory name) and use single-quoted literal values
        try """
        name = '暂停任务 #保留井号' # trailing comment
        status = 'PAUSED'
        rrule = 'FREQ=WEEKLY;BYDAY=MO'
        """.write(to: job2Dir.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)

        let nowSec = Int64(Date().timeIntervalSince1970)
        let dbURL = sqliteDir.appendingPathComponent("codex.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let lastRunMs = (nowSec - 1800) * 1000
        let nextRunMs = (nowSec + 3600) * 1000
        let tRunMs = (nowSec - 300) * 1000
        let tCancelMs = (nowSec - 3600) * 1000
        let tFailMs = (nowSec - 2 * 86400) * 1000
        let tDoneMs = (nowSec - 5 * 86400) * 1000
        let tOldMs = (nowSec - 10 * 86400) * 1000
        let sql = """
        CREATE TABLE automations (id TEXT PRIMARY KEY, name TEXT, status TEXT, last_run_at INTEGER, next_run_at INTEGER);
        CREATE TABLE automation_runs (thread_id TEXT, automation_id TEXT, status TEXT, inbox_summary TEXT, inbox_title TEXT, updated_at INTEGER);
        INSERT INTO automations VALUES ('job-active', '每日巡检', 'ACTIVE', \(lastRunMs), \(nextRunMs));
        INSERT INTO automation_runs VALUES
          ('th-running', 'job-active', 'IN_PROGRESS', '正在执行', NULL, \(tRunMs)),
          ('th-cancel', 'job-active', 'CANCELLED', '手动停止', NULL, \(tCancelMs)),
          ('th-fail', 'job-active', 'FAILED', '运行报错', NULL, \(tFailMs)),
          ('th-done', 'job-active', 'COMPLETED', '', '已完成摘要', \(tDoneMs)),
          ('th-old', 'job-active', 'COMPLETED', '十天前记录', NULL, \(tOldMs));
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let disc = TaskDiscoveryService(homeDir: tmp, inboxDir: tmp.appendingPathComponent("inbox"))
        let (tasks, events) = disc.scanCodex()
        XCTAssertEqual(tasks.count, 2)

        let active = try XCTUnwrap(tasks.first(where: { $0.taskKey == "codex:job-active" }))
        XCTAssertEqual(active.displayName, "每日 \"Codex\" 巡检")
        XCTAssertEqual(active.sourceStatus, "active")
        XCTAssertEqual(active.lastRunAt, nowSec - 1800)
        XCTAssertEqual(active.nextDueAt, nowSec + 3600)
        XCTAssertEqual(active.lastRunStatus, .running)

        let paused = try XCTUnwrap(tasks.first(where: { $0.taskKey == "codex:job-paused" }))
        XCTAssertEqual(paused.nativeId, "job-paused")
        XCTAssertEqual(paused.displayName, "暂停任务 #保留井号")
        XCTAssertEqual(paused.sourceStatus, "paused")
        XCTAssertEqual(paused.lastRunStatus, .unknown)

        // All 4 runs within 7 days are returned; 10-day-old run is excluded
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.first(where: { $0.eventId.contains("th-running") })?.status, .running)
        XCTAssertEqual(events.first(where: { $0.eventId.contains("th-cancel") })?.status, .stopped)
        XCTAssertEqual(events.first(where: { $0.eventId.contains("th-fail") })?.status, .error)
        let doneEv = try XCTUnwrap(events.first(where: { $0.eventId.contains("th-done") }))
        XCTAssertEqual(doneEv.status, .success)
        XCTAssertEqual(doneEv.summary, "已完成摘要")
        XCTAssertFalse(events.contains(where: { $0.eventId.contains("th-old") }))
    }

    func testCodexScheduledTaskSpecExtractionAndFallbacks() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("todonotch-codex-spec-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let projA = tmp.appendingPathComponent("projA")
        let projB = tmp.appendingPathComponent("projB")
        let autoDir = tmp.appendingPathComponent(".codex/automations")
        try fm.createDirectory(at: projA, withIntermediateDirectories: true)
        try fm.createDirectory(at: projB, withIntermediateDirectories: true)
        try fm.createDirectory(at: autoDir, withIntermediateDirectories: true)

        // 1. Multi-line triple-quoted prompt + single-quoted cwds + trailing comment on target_thread_id
        let tomlMulti = autoDir.appendingPathComponent("multi.toml")
        try """
        id = "multi"
        name = "多行任务"
        status = "ACTIVE"
        target_thread_id = "01a1ed13-a0bd-72b1-868a-f80dbe703423" # comment
        cwds = ['\(projA.path)']
        prompt = \"\"\"
        第一行检查
        第二行输出 \"OK\"
        \"\"\" # comment
        """.write(to: tomlMulti, atomically: true, encoding: .utf8)

        let multiTask = MonitoredTask(
            taskKey: "codex:multi", source: .codex, nativeId: "multi",
            displayName: "多行任务", configPath: tomlMulti.path
        )
        let multiSpec = try XCTUnwrap(TodoDispatchRunner.extractScheduledTaskSpec(task: multiTask, homeDir: tmp))
        XCTAssertEqual(multiSpec.agent, "codex")
        XCTAssertEqual(multiSpec.sessionId, "01a1ed13-a0bd-72b1-868a-f80dbe703423")
        XCTAssertTrue(multiSpec.sessionExists)
        XCTAssertEqual(multiSpec.prompt, "第一行检查\n第二行输出 \"OK\"")
        XCTAssertEqual(URL(fileURLWithPath: multiSpec.cwd).resolvingSymlinksInPath().path, projA.resolvingSymlinksInPath().path)

        // 2. Single-quoted multi-line literal prompt + fallback to state_5.sqlite cwd
        var stateDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tmp.appendingPathComponent(".codex/state_5.sqlite").path, &stateDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(stateDB, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, cwd TEXT NOT NULL);
        INSERT INTO threads VALUES ('01a1ed13-a0bd-72b1-868a-f80dbe703424', '', '\(projB.path)');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(stateDB)

        let tomlLit = autoDir.appendingPathComponent("lit.toml")
        try """
        id = 'lit'
        target_thread_id = '01a1ed13-a0bd-72b1-868a-f80dbe703424' # comment
        prompt = '''
        保留字面 \\n 与 '引号'
        '''
        """.write(to: tomlLit, atomically: true, encoding: .utf8)

        let litTask = MonitoredTask(
            taskKey: "codex:lit", source: .codex, nativeId: "lit",
            displayName: "字面任务", configPath: tomlLit.path
        )
        let litSpec = try XCTUnwrap(TodoDispatchRunner.extractScheduledTaskSpec(task: litTask, homeDir: tmp))
        XCTAssertEqual(litSpec.prompt, "保留字面 \\n 与 '引号'")
        XCTAssertEqual(URL(fileURLWithPath: litSpec.cwd).resolvingSymlinksInPath().path, projB.resolvingSymlinksInPath().path)

        // 3. Empty prompt returns nil and dispatchScheduledTask fails gracefully via onCompleted
        let emptyToml = autoDir.appendingPathComponent("empty.toml")
        try "id = \"empty\"\nstatus = \"ACTIVE\"\n".write(to: emptyToml, atomically: true, encoding: .utf8)
        let emptyTask = MonitoredTask(
            taskKey: "codex:empty", source: .codex, nativeId: "empty",
            displayName: "空提示词", configPath: emptyToml.path
        )
        XCTAssertNil(TodoDispatchRunner.extractScheduledTaskSpec(task: emptyTask, homeDir: tmp))

        let runner = TodoDispatchRunner()
        let exp = expectation(description: "empty scheduled task completes with failed")
        final class ResultBox: @unchecked Sendable { var value: TodoDispatchRecord? }
        let box = ResultBox()
        runner.dispatchScheduledTask(
            task: emptyTask,
            logDir: tmp.appendingPathComponent("logs"),
            homeDir: tmp,
            onStarted: { _ in XCTFail("should not report started for invalid config") },
            onCompleted: { rec in
                box.value = rec
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 3.0)
        XCTAssertEqual(box.value?.status, .failed)
        XCTAssertEqual(box.value?.summary, "Unsupported or empty scheduled task config")
    }

    func testTodoCompletionEvidenceCollectionAndFingerprintDedup() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("todonotch-poll-ev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vault = tmp.appendingPathComponent("vault")
        let excerptsDir = vault.appendingPathComponent("05 时间日志/会话摘录")
        try FileManager.default.createDirectory(at: excerptsDir, withIntermediateDirectories: true)

        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let codexDayDir = tmp.appendingPathComponent(
            String(format: ".codex/sessions/%04d/%02d/%02d", comps.year!, comps.month!, comps.day!)
        )
        try FileManager.default.createDirectory(at: codexDayDir, withIntermediateDirectories: true)

        let agyLogsA = tmp.appendingPathComponent(".gemini/antigravity/brain/agy11111-0000-0000-0000-000000000001/.system_generated/logs")
        let agyLogsNoise = tmp.appendingPathComponent(".gemini/antigravity/brain/agy99999-0000-0000-0000-000000000009/.system_generated/logs")
        try FileManager.default.createDirectory(at: agyLogsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agyLogsNoise, withIntermediateDirectories: true)

        // Old source session (before baseline) + newer first source session (after baseline)
        let codexFirst = codexDayDir.appendingPathComponent("rollout-2026-11-27T10-00-00-01a20001-1111-2222-3333-444455556666.jsonl")
        let codexFirstLines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"01a20001-1111-2222-3333-444455556666\",\"cwd\":\"/Users/demo/projects/AlphaProj\",\"originator\":\"Codex Desktop\"}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"发布 Alpha\"}]}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"已完成提交并上线发布 Alpha。\"}]}}"
        ].joined(separator: "\n") + "\n"
        try codexFirstLines.write(to: codexFirst, atomically: true, encoding: .utf8)

        let agyTranscript = agyLogsA.appendingPathComponent("transcript.jsonl")
        try ("{\"type\":\"USER_INPUT\",\"content\":\"旧进展 /Users/demo/projects/AlphaProj\"}\n"
            + "{\"type\":\"PLANNER_RESPONSE\",\"content\":\"等待后续确认\"}\n")
            .write(to: agyTranscript, atomically: true, encoding: .utf8)

        // Newer same-project session for BetaProj (no source update, matched by project)
        let codexBeta = codexDayDir.appendingPathComponent("rollout-2026-11-27T10-20-00-01a20002-1111-2222-3333-444455556666.jsonl")
        let codexBetaLines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"01a20002-1111-2222-3333-444455556666\",\"cwd\":\"/Users/demo/projects/BetaProj\",\"originator\":\"Codex Desktop\"}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"收尾 Beta\"}]}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Beta 全部验收通过并已关闭。\"}]}}"
        ].joined(separator: "\n") + "\n"
        try codexBetaLines.write(to: codexBeta, atomically: true, encoding: .utf8)

        // Noise session containing promptMarker must be excluded
        let agyNoise = agyLogsNoise.appendingPathComponent("transcript.jsonl")
        try ("{\"type\":\"USER_INPUT\",\"content\":\"\(TodoCompletionPoller.promptMarker) /Users/demo/projects/BetaProj\"}\n"
            + "{\"type\":\"PLANNER_RESPONSE\",\"content\":\"{\\\"results\\\":[]}\"}\n")
            .write(to: agyNoise, atomically: true, encoding: .utf8)

        let baselineTs = Int64(now.timeIntervalSince1970) - 300
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(baselineTs + 120))], ofItemAtPath: codexFirst.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(baselineTs - 1200))], ofItemAtPath: agyTranscript.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(baselineTs + 180))], ofItemAtPath: codexBeta.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(baselineTs + 200))], ofItemAtPath: agyNoise.path)

        let md = """
        ---
        updated_at: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(baselineTs + 600))))
        ---
        ## 待你亲自处理
        - [ ] **[AlphaProj]** 发布 Alpha — 来源：2026-11-27 codex (01a20001)、antigravity (agy11111)
        - [ ] **[BetaProj]** 收尾 Beta — 来源：2026-11-25 codex (01a29999)
        - [ ] **[GammaProj]** 运行中的任务 — 来源：2026-11-27 codex (01a20002)
        - [ ] **[DeltaProj]** 无更新的任务 — 来源：2026-11-25 codex (01a28888)
        """
        let parsed = TodoMarkdownParser.parse(md)
        XCTAssertEqual(parsed.items.count, 4)
        let parsedBaseline = TodoCompletionPoller.parseTodoBaselineTimestamp(markdown: md, fileMtime: baselineTs)
        XCTAssertEqual(parsedBaseline, baselineTs)

        let runningKey = parsed.items[2].todoKey
        let firstPass = TodoCompletionPoller.collectChangedCandidates(
            openTodos: parsed.items,
            runningTodoKeys: [runningKey],
            baselineTs: baselineTs,
            previousFingerprints: [:],
            vaultPath: vault.path,
            homeDir: tmp,
            includeGitCommits: false
        )
        XCTAssertEqual(Set(firstPass.map(\.item.project)), ["AlphaProj", "BetaProj"])

        let alphaPacket = try XCTUnwrap(firstPass.first(where: { $0.item.project == "AlphaProj" }))
        // Verifies multi-source resolution picked up the first source (01a20001), not only .last (agy11111)
        XCTAssertTrue(alphaPacket.sessions.contains(where: { $0.agent == "codex" && $0.sessionId.hasPrefix("01a20001") && $0.relation == "source" }))

        let betaPacket = try XCTUnwrap(firstPass.first(where: { $0.item.project == "BetaProj" }))
        XCTAssertTrue(betaPacket.sessions.contains(where: { $0.agent == "codex" && $0.sessionId.hasPrefix("01a20002") && $0.relation == "project" }))
        XCTAssertFalse(betaPacket.sessions.contains(where: { $0.sessionId.contains("agy99999") }))

        // Unchanged fingerprints must be skipped on the next 5-min poll
        let prevFP = Dictionary(uniqueKeysWithValues: firstPass.map { ($0.item.todoKey, $0.fingerprint) })
        let secondPass = TodoCompletionPoller.collectChangedCandidates(
            openTodos: parsed.items,
            runningTodoKeys: [runningKey],
            baselineTs: baselineTs,
            previousFingerprints: prevFP,
            vaultPath: vault.path,
            homeDir: tmp,
            includeGitCommits: false
        )
        XCTAssertTrue(secondPass.isEmpty)

        // Bumping codexBeta mtime re-triggers BetaProj only
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(baselineTs + 240))], ofItemAtPath: codexBeta.path)
        let thirdPass = TodoCompletionPoller.collectChangedCandidates(
            openTodos: parsed.items,
            runningTodoKeys: [runningKey],
            baselineTs: baselineTs,
            previousFingerprints: prevFP,
            vaultPath: vault.path,
            homeDir: tmp,
            includeGitCommits: false
        )
        XCTAssertEqual(thirdPass.map(\.item.project), ["BetaProj"])
    }

    func testTodoCompletionMultiCLIFallbackAndStrictParsing() throws {
        for agent in TodoCompletionPoller.defaultCLIFallbackOrder {
            let cmd = TodoCompletionPoller.buildVerificationCommand(
                agent: agent,
                executable: "/usr/local/bin/\(agent)",
                prompt: "PROMPT",
                outputFile: "/tmp/out.txt"
            )
            XCTAssertFalse(cmd.arguments.isEmpty, "expected args for \(agent)")
            XCTAssertTrue(cmd.arguments.contains("PROMPT"))
        }

        let itemA = TodoItem(id: 1, section: "personal", project: "P1", text: "任务 A", done: false)
        let itemB = TodoItem(id: 2, section: "project", project: "P2", text: "任务 B", done: false)
        let itemC = TodoItem(id: 3, section: "project", project: "P3", text: "任务 C", done: false)
        let candidates = [
            TodoEvidencePacket(item: itemA, fingerprint: "fpA", sessions: []),
            TodoEvidencePacket(item: itemB, fingerprint: "fpB", sessions: []),
            TodoEvidencePacket(item: itemC, fingerprint: "fpC", sessions: [])
        ]

        final class CallRecorder: @unchecked Sendable {
            var calls: [String] = []
        }
        let recorder = CallRecorder()
        let result = TodoCompletionPoller.verifyCandidates(
            candidates: candidates,
            cliOrder: ["codex", "claude", "pi", "opencode"],
            executableResolver: { agent, _ in "/mock/bin/\(agent)" },
            commandRunner: { executable, _, _, _, _, _ in
                let name = URL(fileURLWithPath: executable).lastPathComponent
                recorder.calls.append(name)
                if name == "codex" {
                    return TodoCLIExecutionOutput(exitCode: 1, output: "", stderr: "quota exceeded")
                }
                if name == "claude" {
                    return TodoCLIExecutionOutput(exitCode: 0, output: "Sorry, cannot parse", stderr: "")
                }
                let json = """
                ```json
                {
                  "results": [
                    {"todoKey": "\(itemA.todoKey)", "completed": true, "confidence": "HIGH", "reason": "已合并部署并线上验收通过"},
                    {"todoKey": "\(itemB.todoKey)", "completed": true, "confidence": "medium", "reason": "仅部分子项完成"},
                    {"todoKey": "\(itemC.todoKey)", "completed": false, "confidence": "high", "reason": "仍有阻塞项"},
                    {"todoKey": "unknown_key_1234", "completed": true, "confidence": "high", "reason": "未知 key 应忽略"}
                  ]
                }
                ```
                """
                return TodoCLIExecutionOutput(exitCode: 0, output: json, stderr: "")
            }
        )

        XCTAssertEqual(recorder.calls, ["codex", "claude", "pi"])
        XCTAssertEqual(result.attemptedCLIs, ["codex", "claude", "pi"])
        XCTAssertEqual(result.cliUsed, "pi")
        XCTAssertEqual(result.completedVerdicts.map(\.todoKey), [itemA.todoKey])
        XCTAssertEqual(result.checkedFingerprints, [
            itemA.todoKey: "fpA",
            itemB.todoKey: "fpB",
            itemC.todoKey: "fpC"
        ])

        // When every CLI fails, checkedFingerprints remains empty so next poll retries
        let failResult = TodoCompletionPoller.verifyCandidates(
            candidates: candidates,
            cliOrder: ["codex", "claude"],
            executableResolver: { agent, _ in "/mock/bin/\(agent)" },
            commandRunner: { _, _, _, _, _, _ in
                TodoCLIExecutionOutput(exitCode: 1, output: "", stderr: "unavailable")
            }
        )
        XCTAssertTrue(failResult.checkedFingerprints.isEmpty)
        XCTAssertTrue(failResult.completedVerdicts.isEmpty)
        XCTAssertFalse(failResult.errorDetail.isEmpty)
    }

    func testTodoCompletionSafeMarkdownWriteback() throws {
        let md = """
        ## 待你亲自处理
        - [ ] **[Alpha]** 子项1和子项2全部完成 — 来源：2026-11-27 codex (01a20001)
        - [ ] **[Beta]** 运行中的待办 — 来源：2026-11-27 codex (01a20002)

        ## 进行中 / 未收尾项目任务
        - [ ] **[Gamma]** 仅完成一半的待办 — 来源：2026-11-27 codex (01a20003)
        """
        let items = TodoMarkdownParser.parse(md).items
        XCTAssertEqual(items.count, 3)

        let verdicts = [
            TodoCompletionVerdict(todoKey: items[0].todoKey, completed: true, confidence: "high", reason: "已上线"),
            TodoCompletionVerdict(todoKey: items[1].todoKey, completed: true, confidence: "high", reason: "运行中应跳过"),
            TodoCompletionVerdict(todoKey: items[2].todoKey, completed: true, confidence: "medium", reason: "置信度不足")
        ]
        let applied = TodoCompletionPoller.applyAutoCompletions(
            to: md,
            verdicts: verdicts,
            runningTodoKeys: [items[1].todoKey]
        )
        XCTAssertEqual(applied.completedKeys, [items[0].todoKey])
        XCTAssertTrue(applied.updatedMarkdown.contains("- [x] **[Alpha]** 子项1和子项2全部完成"))
        XCTAssertTrue(applied.updatedMarkdown.contains("- [ ] **[Beta]** 运行中的待办"))
        XCTAssertTrue(applied.updatedMarkdown.contains("- [ ] **[Gamma]** 仅完成一半的待办"))
    }
}
