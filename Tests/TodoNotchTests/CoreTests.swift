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
}
