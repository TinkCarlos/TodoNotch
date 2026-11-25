import Cocoa
import SwiftUI
import TodoNotchCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var tasks: [MonitoredTask] = []
    @Published var events: [RunEvent] = []
    @Published var todos: [TodoItem] = []
    @Published var todoUpdatedLabel: String = ""
    @Published var health: LmemoryHealth = LmemoryHealth(state: .unknown, detail: "正在检测 Lmemory 状态…")
    @Published var config: AppConfig = AppConfig()
    @Published var robotPresentation: RobotPresentation = RobotPresentation(mood: .idle, showMutedBadge: false, animateIdle: true)

    // Light toast state
    @Published var toastVisible = false
    @Published var toastTitle = ""
    @Published var toastSummary = ""
    @Published var toastCoalescedCount = 0
    @Published var toastHovered = false

    // Inline feedback messages
    @Published var inlineNotice: String = ""
    @Published var webhookURLDraft: String = ""
    @Published var maskedWebhookPreview: String = ""
    @Published var settingsStatusMsg: String = ""
    @Published var dndErrorMsg: String = ""

    // Onboarding state
    @Published var showOnboarding = false
    @Published var detectedEnv: LmemoryEnvironment?
    @Published var deployResults: [DeployAgentResult] = []
    @Published var isDeploying = false

    let store: SQLiteStore
    let secrets: SecretStoreProtocol
    let discovery: TaskDiscoveryService
    let pushDispatcher: PushDispatcher
    let installer: LmemoryInstallerService

    var onRequestShowMainPopup: (() -> Void)?
    var onRequestShowToast: (() -> Void)?
    var onRequestHideToast: (() -> Void)?
    var onScreenModeChanged: (() -> Void)?

    private var recentSuccessUntil: Date?
    private var toastDismissWork: DispatchWorkItem?
    private var lastTriggerMtime: Date?
    private var lastTodoMtime: Date?
    private var sleepStartedAt: Int64?
    private var sleepIntervals: [(Int64, Int64)] = []
    private var wakeGraceUntil: Int64 = 0
    private var tickCounter = 0

    var personalTodosOpen: [TodoItem] { todos.filter { $0.section == "personal" && !$0.done } }
    var projectTodosOpen: [TodoItem] { todos.filter { $0.section == "project" && !$0.done } }
    var unreadAlertEvents: [RunEvent] { events.filter { !$0.isRead && ($0.status == .error || $0.status == .missed) } }
    var totalBadgeCount: Int {
        unreadAlertEvents.count + personalTodosOpen.count + projectTodosOpen.count
    }

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TodoNotch")
        let dbPath = appSupport.appendingPathComponent("state.sqlite3").path
        do {
            self.store = try SQLiteStore(path: dbPath)
        } catch {
            // Corruption fallback: backup and recreate cleanly
            let bak = dbPath + ".corrupt-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.moveItem(atPath: dbPath, toPath: bak)
            self.store = (try? SQLiteStore(path: dbPath)) ?? (try! SQLiteStore(path: ":memory:"))
        }
        self.secrets = KeychainSecretStore()
        self.discovery = TaskDiscoveryService()
        self.pushDispatcher = PushDispatcher(store: store, secrets: secrets)
        self.installer = LmemoryInstallerService(store: store)

        self.config = store.loadConfig()
        if self.config.vaultPath.isEmpty {
            let resolved = discovery.resolveVaultPath(configuredVault: "")
            if !resolved.isEmpty {
                self.config.vaultPath = resolved
                store.saveConfig(self.config)
            }
        }
        refreshSecretPreviews()
        reloadFromLocalState()
        setupSleepObservers()
        startBackgroundTimers()
        detectedEnv = installer.detectEnvironment(configuredVault: config.vaultPath)
        if !config.onboardingDone {
            runFirstInstallBootstrap()
        }
    }

    /// Runs automatically once on a fresh install:
    /// 1) Backs up & idempotently deploys Lmemory to all detected Agents (preserving existing Vault)
    /// 2) Auto-discovers all Agent scheduled automations
    /// 3) Runs initial 7-day cross-agent conversation scan to bootstrap 每日待办.md if missing
    private func runFirstInstallBootstrap() {
        guard let env = detectedEnv else { return }
        isDeploying = true
        let vault = config.vaultPath.isEmpty
            ? (env.existingVault ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/LmemoryVault").path)
            : config.vaultPath
        let inst = installer
        let st = store
        let scannerPath = Bundle.main.path(forResource: "scan_todos", ofType: "py")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("projects/TodoNotch/scan_todos.py").path
        let todoOutPath = URL(fileURLWithPath: vault).appendingPathComponent("05 时间日志/每日待办.md").path
        let lastScanOut = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TodoNotch/initial-scan.json").path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. Auto-backup & idempotent Lmemory deploy
            let results = inst.deploy(env: env, vaultPath: vault)

            // 2. Initial 7-day cross-agent conversation scan & todo bootstrap
            var scanSummary = "未找到 scan_todos.py"
            if FileManager.default.fileExists(atPath: scannerPath) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                proc.arguments = [
                    scannerPath,
                    "--sync-lmemory",
                    "--hours", "168",
                    "--out", lastScanOut,
                    "--bootstrap-todo-md", todoOutPath
                ]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    scanSummary = proc.terminationStatus == 0
                        ? "初始 7 天多 Agent 对话扫描完成（rc=0）"
                        : "初始扫描返回 rc=\(proc.terminationStatus): \(out.prefix(120))"
                } catch {
                    scanSummary = "初始扫描异常：\(error.localizedDescription)"
                }
            }
            st.appendAudit(action: "initial_todo_scan", target: todoOutPath, result: "ok", detail: scanSummary)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deployResults = results
                self.isDeploying = false
                if self.config.vaultPath.isEmpty { self.config.vaultPath = vault }
                self.config.onboardingDone = true
                self.store.saveConfig(self.config)
                self.detectedEnv = self.installer.detectEnvironment(configuredVault: self.config.vaultPath)
                self.loadTodosMarkdown()
                self.runFullDiscovery(isInitialSeed: false)
            }
        }
    }

    private func setupSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleepStartedAt = Int64(Date().timeIntervalSince1970)
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Int64(Date().timeIntervalSince1970)
                if let start = self.sleepStartedAt, now > start {
                    self.sleepIntervals.append((start, now))
                    if self.sleepIntervals.count > 20 { self.sleepIntervals.removeFirst() }
                }
                self.sleepStartedAt = nil
                self.wakeGraceUntil = now + 300 // 5-min wake grace
            }
        }
    }

    private func startBackgroundTimers() {
        // Initial async discovery
        runFullDiscovery(isInitialSeed: true)
        // Fast 3s timer for inbox / legacy .trigger / 每日待办.md; 30s full discovery; 60s missed-run check
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tickCounter += 1
                self.checkTodoFileAndLegacyTrigger()
                self.drainInboxAsync()
                if self.tickCounter % 10 == 0 {
                    self.runFullDiscovery(isInitialSeed: false)
                }
                if self.tickCounter % 20 == 0 {
                    self.checkMissedRuns()
                }
                self.recomputeRobot()
            }
        }
    }

    func reloadFromLocalState() {
        self.tasks = store.listTasks()
        self.events = store.listEvents(limit: 80)
        loadTodosMarkdown()
        self.health = discovery.readLmemoryHealth(configuredVault: config.vaultPath)
        recomputeRobot()
    }

    func refreshAllNow() {
        runFullDiscovery(isInitialSeed: false)
        loadTodosMarkdown()
    }

    // MARK: - Discovery & Event Ingestion

    private func runFullDiscovery(isInitialSeed: Bool) {
        let disc = self.discovery
        let vault = self.config.vaultPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = disc.scanAll()
            let health = disc.readLmemoryHealth(configuredVault: vault)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.health = health
                var bySource: [TaskSource: Set<String>] = [
                    .antigravity: [], .codex: [], .claude: [], .workbuddy: [], .zcode: [], .launchd: []
                ]
                for t in snap.tasks {
                    self.store.upsertTask(t, preserveNotifyLevel: true)
                    bySource[t.source, default: []].insert(t.taskKey)
                }
                for (src, keys) in bySource {
                    self.store.markRemovedExcept(source: src, activeKeys: keys)
                }
                self.tasks = self.store.listTasks()

                for ev in snap.newEvents {
                    self.ingestEvent(ev, suppressPopup: isInitialSeed)
                }
                self.events = self.store.listEvents(limit: 80)
                self.recomputeRobot()
            }
        }
    }

    private func drainInboxAsync() {
        let disc = self.discovery
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let incoming = disc.drainInbox()
            guard !incoming.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for ev in incoming {
                    self.ingestEvent(ev, suppressPopup: false)
                }
                self.loadTodosMarkdown()
                self.events = self.store.listEvents(limit: 80)
                self.recomputeRobot()
            }
        }
    }

    private func ingestEvent(_ ev: RunEvent, suppressPopup: Bool) {
        guard store.insertEventIfNew(ev) else { return }
        guard !suppressPopup else { return }

        let taskLevel = tasks.first(where: { $0.taskKey == ev.taskKey })?.notifyLevel ?? .normal
        let dnd = isDNDActiveNow()
        let action = NotificationPolicy.decide(eventStatus: ev.status, taskLevel: taskLevel, isDND: dnd)

        switch action {
        case .silentOnly:
            break
        case .lightToast:
            recentSuccessUntil = Date().addingTimeInterval(5.5)
            triggerLightToast(title: ev.taskName, summary: ev.summary)
        case .fullPopup(let pushExternal):
            onRequestShowMainPopup?()
            if pushExternal {
                let cfg = config
                Task.detached { [pushDispatcher] in
                    await pushDispatcher.dispatch(event: ev, config: cfg)
                }
            }
        }
    }

    private func checkMissedRuns() {
        let now = Int64(Date().timeIntervalSince1970)
        let intervals = self.sleepIntervals
        let missed = MissedRunCalculator.findMissedTasks(
            tasks: tasks,
            now: now,
            wakeGraceUntil: wakeGraceUntil,
            overlappedSleepSeconds: { start, end in
                var total: Int64 = 0
                for (s0, s1) in intervals {
                    let lo = max(start, s0)
                    let hi = min(end, s1)
                    if hi > lo { total += (hi - lo) }
                }
                return total
            }
        )
        for task in missed {
            let due = task.nextDueAt ?? now
            let ev = RunEvent(
                eventId: "\(task.taskKey):missed:\(due)",
                taskKey: task.taskKey,
                taskName: task.displayName,
                source: task.source,
                status: .missed,
                summary: "任务已超过计划时间 15 分钟仍未观测到执行记录（疑似漏跑）",
                logPath: task.configPath,
                occurredAt: now,
                createdAt: now
            )
            ingestEvent(ev, suppressPopup: false)
        }
        if !missed.isEmpty {
            events = store.listEvents(limit: 80)
            recomputeRobot()
        }
    }

    // MARK: - Legacy .trigger & 每日待办.md Sync

    var todoMarkdownPath: String {
        let base = discovery.resolveVaultPath(configuredVault: config.vaultPath)
        guard !base.isEmpty else { return "" }
        return URL(fileURLWithPath: base).appendingPathComponent("05 时间日志/每日待办.md").path
    }

    private func checkTodoFileAndLegacyTrigger() {
        let fm = FileManager.default
        let todoPath = todoMarkdownPath
        if !todoPath.isEmpty,
           let mt = (try? fm.attributesOfItem(atPath: todoPath)[.modificationDate]) as? Date,
           mt != lastTodoMtime {
            loadTodosMarkdown()
        }
        let legacyTrigger = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/TodoNotch/.trigger").path
        if let tmt = (try? fm.attributesOfItem(atPath: legacyTrigger)[.modificationDate]) as? Date {
            if let prev = lastTriggerMtime, tmt != prev {
                lastTriggerMtime = tmt
                loadTodosMarkdown()
                if !isDNDActiveNow() {
                    onRequestShowMainPopup?()
                }
            } else if lastTriggerMtime == nil {
                lastTriggerMtime = tmt
            }
        }
    }

    func loadTodosMarkdown() {
        let path = todoMarkdownPath
        guard !path.isEmpty, let txt = try? String(contentsOfFile: path, encoding: .utf8) else {
            todos = []
            todoUpdatedLabel = path.isEmpty ? "未配置 Lmemory 知识库" : "暂无每日待办.md"
            return
        }
        lastTodoMtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let parsed = TodoMarkdownParser.parse(txt)
        todos = parsed.items
        todoUpdatedLabel = parsed.updatedLabel.isEmpty ? "已同步" : "更新于 \(parsed.updatedLabel)"
    }

    func toggleTodo(_ item: TodoItem) {
        let path = todoMarkdownPath
        guard !path.isEmpty,
              let txt = try? String(contentsOfFile: path, encoding: .utf8),
              let updated = TodoMarkdownParser.toggleLine(in: txt, lineIndex: item.id) else {
            showInlineNotice("无法写回每日待办.md，请检查文件是否存在")
            return
        }
        try? updated.write(toFile: path, atomically: true, encoding: .utf8)
        loadTodosMarkdown()
        recomputeRobot()
    }

    // MARK: - Light Toast Coalescing (5s + Hover Pause)

    func triggerLightToast(title: String, summary: String) {
        if toastVisible {
            toastCoalescedCount += 1
        } else {
            toastCoalescedCount = 0
        }
        toastTitle = title
        toastSummary = summary
        toastVisible = true
        onRequestShowToast?()
        scheduleToastDismiss(delay: 5.0)
    }

    func setToastHovered(_ hovered: Bool) {
        toastHovered = hovered
        if hovered {
            toastDismissWork?.cancel()
        } else if toastVisible {
            scheduleToastDismiss(delay: 2.0)
        }
    }

    func dismissToastNow() {
        toastDismissWork?.cancel()
        toastVisible = false
        toastCoalescedCount = 0
        onRequestHideToast?()
    }

    private func scheduleToastDismiss(delay: TimeInterval) {
        toastDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.toastHovered else { return }
                self.dismissToastNow()
            }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - User Actions & Settings

    func isDNDActiveNow() -> Bool {
        DNDPolicy.isActive(
            dndEnabled: config.dndEnabled,
            focusMode: config.focusMode,
            start: config.dndStart,
            end: config.dndEnd
        )
    }

    var overdueTodosCount: Int {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        let cutoffStr = fmt.string(from: cutoffDate)
        return (personalTodosOpen + projectTodosOpen).filter { item in
            if let r = item.text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                return String(item.text[r]) <= cutoffStr
            }
            return false
        }.count
    }

    func recomputeRobot() {
        let unread = store.unreadCounts()
        let running = tasks.filter { $0.lastRunStatus == .running }.count
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        robotPresentation = RobotStateMachine.compute(
            unreadErrors: unread[.error] ?? 0,
            unreadMissed: unread[.missed] ?? 0,
            unreadAttention: unread[.attention] ?? 0,
            openPersonalTodos: personalTodosOpen.count,
            overdueTodos: overdueTodosCount,
            runningTasks: running,
            recentSuccessUntil: recentSuccessUntil,
            isDND: isDNDActiveNow(),
            reduceMotion: reduceMotion
        )
    }

    func toggleFocusMode() {
        config.focusMode.toggle()
        store.saveConfig(config)
        recomputeRobot()
    }

    func recentWeekEvents(for taskKey: String) -> [RunEvent] {
        store.listRecentWeekEvents(taskKey: taskKey)
    }

    func cycleTaskLevel(_ task: MonitoredTask) {
        let next: NotifyLevel
        switch task.notifyLevel {
        case .normal: next = .priority
        case .priority: next = .muted
        case .muted: next = .normal
        }
        setTaskLevel(task, level: next)
    }

    func setTaskLevel(_ task: MonitoredTask, level: NotifyLevel) {
        store.updateTaskNotifyLevel(taskKey: task.taskKey, level: level)
        store.appendAudit(action: "task_level_change", target: task.taskKey, result: "ok", detail: "级别调整为 \(level.rawValue)")
        tasks = store.listTasks()
    }

    func markEventRead(_ event: RunEvent) {
        store.markEventRead(eventId: event.eventId)
        events = store.listEvents(limit: 80)
        recomputeRobot()
    }

    func markAllRead() {
        store.markAllEventsRead()
        events = store.listEvents(limit: 80)
        recomputeRobot()
    }

    func retryPush(for event: RunEvent) {
        let cfg = config
        Task {
            await pushDispatcher.dispatch(event: event, config: cfg)
            self.events = self.store.listEvents(limit: 80)
        }
    }

    func openFileSafely(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            showInlineNotice("原文件已移动或删除")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func showInlineNotice(_ msg: String) {
        inlineNotice = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.inlineNotice == msg { self?.inlineNotice = "" }
        }
    }

    func saveSettingsAndSecrets() {
        if config.dndEnabled, let err = DNDPolicy.validateRange(start: config.dndStart, end: config.dndEnd) {
            dndErrorMsg = err
            return
        }
        dndErrorMsg = ""

        if !webhookURLDraft.isEmpty {
            guard ValidationHelpers.isValidWebhookURL(webhookURLDraft) else {
                settingsStatusMsg = "Webhook URL 不合法（仅允许 https:// 或 localhost）"
                return
            }
            do {
                try secrets.saveSecret(webhookURLDraft, account: SecretAccount.webhookURL)
                webhookURLDraft = ""
            } catch {
                settingsStatusMsg = error.localizedDescription
                return
            }
        }
        store.saveConfig(config)
        refreshSecretPreviews()
        loadTodosMarkdown()
        health = discovery.readLmemoryHealth(configuredVault: config.vaultPath)
        recomputeRobot()
        onScreenModeChanged?()
        settingsStatusMsg = "设置已保存（敏感凭据已加密存入 macOS 钥匙串）"
    }

    func testWebhookNow() {
        saveSettingsAndSecrets()
        settingsStatusMsg = "正在发送测试 Webhook…"
        let cfg = config
        Task {
            let res = await pushDispatcher.sendTestWebhook(config: cfg)
            switch res {
            case .success(let m): settingsStatusMsg = m
            case .failure(let e): settingsStatusMsg = "测试失败：\(e.localizedDescription)"
            }
        }
    }

    private func refreshSecretPreviews() {
        if let raw = secrets.loadSecret(account: SecretAccount.webhookURL), !raw.isEmpty {
            maskedWebhookPreview = ValidationHelpers.maskSecretURL(raw)
        } else {
            maskedWebhookPreview = ""
        }
    }

    // MARK: - Onboarding & Lmemory Installer

    func prepareOnboarding() {
        detectedEnv = installer.detectEnvironment(configuredVault: config.vaultPath)
        if config.vaultPath.isEmpty, let v = detectedEnv?.existingVault {
            config.vaultPath = v
        }
        deployResults = []
        showOnboarding = true
    }

    func runOneClickDeploy() {
        guard let env = detectedEnv else { return }
        isDeploying = true
        let vault = config.vaultPath
        let inst = installer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = inst.deploy(env: env, vaultPath: vault)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deployResults = res
                self.isDeploying = false
                self.config.onboardingDone = true
                self.store.saveConfig(self.config)
                self.runFullDiscovery(isInitialSeed: false)
            }
        }
    }

    func finishOnboarding() {
        config.onboardingDone = true
        store.saveConfig(config)
        showOnboarding = false
    }
}
