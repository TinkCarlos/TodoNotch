import Cocoa
import SwiftUI
import TodoNotchCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var tasks: [MonitoredTask] = []
    @Published var events: [RunEvent] = []
    @Published var weekEventsByTask: [String: [RunEvent]] = [:]
    @Published var todos: [TodoItem] = []
    @Published var todoUpdatedLabel: String = ""
    @Published var selectedTodoKeys: Set<String> = []
    @Published var dispatchesByKey: [String: TodoDispatchRecord] = [:]
    @Published var stoppingKeys: Set<String> = []
    @Published var conversationTurnsByKey: [String: [ConversationTurn]] = [:]
    @Published var expandedTodoKey: String? = nil
    @Published var health: LmemoryHealth = LmemoryHealth(state: .unknown, detail: "")
    @Published var config: AppConfig = AppConfig()
    @Published var activeLanguage: AppLanguage = .zhHans
    @Published var robotPresentation: RobotPresentation = RobotPresentation(mood: .idle, showMutedBadge: false, animateIdle: true)

    // Light toast state
    @Published var toastVisible = false
    @Published var toastTitle = ""
    @Published var toastSummary = ""
    @Published var toastCoalescedCount = 0
    @Published var toastHovered = false
    @Published var toastToken = 0
    @Published private(set) var desktopNavigationToast: (title: String, message: String, presentation: DesktopNavigationRules.Presentation)?
    @Published private(set) var navigatingDesktopTaskKey: String?

    // Inline feedback & UI motion states
    @Published var inlineNotice: String = ""
    @Published var webhookURLDraft: String = ""
    @Published var maskedWebhookPreview: String = ""
    @Published var settingsStatusMsg: String = ""
    @Published var settingsStatusIsError: Bool = false
    @Published var dndErrorMsg: String = ""
    @Published var isRefreshing: Bool = false
    @Published var saveFeedbackActive: Bool = false

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
    let dispatchRunner = TodoDispatchRunner()

    var onRequestShowMainPopup: (() -> Void)?
    var onRequestShowToast: (() -> Void)?
    var onRequestHideToast: (() -> Void)?
    var onScreenModeChanged: (() -> Void)?
    var onLanguageChanged: (() -> Void)?

    private var recentSuccessUntil: Date?
    private var toastDismissTask: Task<Void, Never>?
    private var desktopNavigationToastDismissTask: Task<Void, Never>?
    private var inlineNoticeDismissTask: Task<Void, Never>?
    private var saveFeedbackWork: DispatchWorkItem?
    private var lastTriggerMtime: Date?
    private var lastTodoMtime: Date?
    private var sleepStartedAt: Int64?
    private var sleepIntervals: [(Int64, Int64)] = []
    private var wakeGraceUntil: Int64 = 0
    private var tickCounter = 0
    private var bridgeStopRequests: [String: String] = [:]

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
        self.activeLanguage = IPLanguageResolver.resolveEffective(
            mode: self.config.languageMode,
            detectedCountry: self.config.detectedIPCountry
        )
        self.health = LmemoryHealth(state: .unknown, detail: L10n.detectingHealth(self.activeLanguage))

        refreshSecretPreviews()
        reloadFromLocalState()
        setupSleepObservers()
        startBackgroundTimers()
        detectedEnv = installer.detectEnvironment(configuredVault: config.vaultPath)
        if !config.onboardingDone {
            runFirstInstallBootstrap()
        }
        if config.languageMode == .auto {
            detectIPCountryIfNeeded()
        }
    }

    // MARK: - Language & IP Auto-Detection (REQ-007)

    func detectIPCountryIfNeeded() {
        Task { [weak self] in
            guard let country = await IPLanguageResolver.fetchIPCountryCode(timeout: 3.0) else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.config.detectedIPCountry = country
                self.store.setSetting("detected_ip_country", value: country)
                // Manual lock strictly takes precedence over IP updates
                guard self.config.languageMode == .auto else { return }
                let resolved = IPLanguageResolver.resolveEffective(
                    mode: .auto,
                    detectedCountry: country
                )
                if resolved != self.activeLanguage {
                    self.activeLanguage = resolved
                    self.refreshSecretPreviews()
                    self.loadTodosMarkdown()
                    self.onLanguageChanged?()
                }
            }
        }
    }

    func setLanguageMode(_ mode: LanguageMode) {
        config.languageMode = mode
        store.saveConfig(config)
        let resolved = IPLanguageResolver.resolveEffective(
            mode: mode,
            detectedCountry: config.detectedIPCountry
        )
        activeLanguage = resolved
        dndErrorMsg = ""
        settingsStatusMsg = ""
        settingsStatusIsError = false
        refreshSecretPreviews()
        loadTodosMarkdown()
        onLanguageChanged?()
        if mode == .auto {
            detectIPCountryIfNeeded()
        }
    }

    func toggleQuickLanguage() {
        let next: LanguageMode = (activeLanguage == .zhHans) ? .en : .zhHans
        setLanguageMode(next)
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
        let lang = activeLanguage
        let st = store
        let scannerPath = Bundle.main.path(forResource: "scan_todos", ofType: "py")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("projects/TodoNotch/scan_todos.py").path
        let todoOutPath = URL(fileURLWithPath: vault).appendingPathComponent("05 时间日志/每日待办.md").path
        let lastScanOut = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TodoNotch/initial-scan.json").path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = inst.deploy(env: env, vaultPath: vault, lang: lang)

            var scanSummary = "scan_todos.py not found"
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
                        ? "Initial 7-day Agent scan completed (rc=0)"
                        : "Initial scan rc=\(proc.terminationStatus): \(out.prefix(120))"
                } catch {
                    scanSummary = "Initial scan error: \(error.localizedDescription)"
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
                self.wakeGraceUntil = now + 300
            }
        }
    }

    private func startBackgroundTimers() {
        runFullDiscovery(isInitialSeed: true)
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tickCounter += 1
                self.checkTodoFileAndLegacyTrigger()
                self.drainInboxAsync()
                if self.tickCounter % 3 == 0 {
                    self.reconcileDispatchesAsync()
                }
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
        rebuildWeekEventsCache()
        loadTodosMarkdown()
        let savedDispatches = store.listTodoDispatches()
        self.dispatchesByKey = Dictionary(uniqueKeysWithValues: savedDispatches.map { ($0.todoKey, $0) })
        self.health = discovery.readLmemoryHealth(configuredVault: config.vaultPath)
        recomputeRobot()
        reconcileDispatchesAsync()
    }

    func refreshAllNow() {
        isRefreshing = true
        runFullDiscovery(isInitialSeed: false)
        loadTodosMarkdown()
        reconcileDispatchesAsync()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.isRefreshing = false
        }
    }

    private func rebuildWeekEventsCache() {
        let all = store.listAllRecentWeekEvents()
        self.weekEventsByTask = Dictionary(grouping: all, by: \.taskKey)
    }

    /// Returns 7 slots (oldest -> today) representing daily worst status for the 7-day rhythm strip.
    func sevenDayRhythm(for taskKey: String, now: Date = Date(), calendar: Calendar = .current) -> [RunStatus?] {
        let evs = weekEventsByTask[taskKey] ?? []
        let todayStart = calendar.startOfDay(for: now)
        var slots: [RunStatus?] = Array(repeating: nil, count: 7)
        for ev in evs {
            let d = Date(timeIntervalSince1970: TimeInterval(ev.occurredAt))
            let evDay = calendar.startOfDay(for: d)
            let diff = calendar.dateComponents([.day], from: evDay, to: todayStart).day ?? 99
            guard diff >= 0 && diff < 7 else { continue }
            let idx = 6 - diff
            slots[idx] = higherSeverity(slots[idx], ev.status)
        }
        return slots
    }

    private func higherSeverity(_ a: RunStatus?, _ b: RunStatus) -> RunStatus {
        func rank(_ s: RunStatus?) -> Int {
            switch s {
            case .error, .missed: return 5
            case .attention: return 4
            case .running: return 3
            case .success: return 2
            case .stopped, .unknown: return 1
            case nil: return 0
            }
        }
        return rank(b) >= rank(a) ? b : (a ?? b)
    }

    // MARK: - Discovery & Event Ingestion

    private func runFullDiscovery(isInitialSeed: Bool) {
        let disc = self.discovery
        let vault = self.config.vaultPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = disc.scanAll(deferInboxDeletion: true)
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
                    _ = self.ingestEvent(ev, suppressPopup: isInitialSeed)
                }
                self.ingestPendingInbox(snap.pendingInbox, suppressPopup: isInitialSeed)
                self.events = self.store.listEvents(limit: 80)
                self.rebuildWeekEventsCache()
                self.recomputeRobot()
            }
        }
    }

    private func drainInboxAsync() {
        let disc = self.discovery
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let incoming = disc.readPendingInbox()
            guard !incoming.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ingestPendingInbox(incoming, suppressPopup: false)
                self.loadTodosMarkdown()
                self.events = self.store.listEvents(limit: 80)
                self.rebuildWeekEventsCache()
                self.recomputeRobot()
            }
        }
    }

    private func ingestPendingInbox(_ items: [PendingInboxEvent], suppressPopup: Bool) {
        for item in items {
            let result = ingestEvent(item.event, suppressPopup: suppressPopup)
            if result == .inserted || result == .duplicate {
                discovery.acknowledgeInboxFile(item.fileURL)
            }
        }
    }

    @discardableResult
    private func ingestEvent(_ ev: RunEvent, suppressPopup: Bool) -> EventInsertResult {
        let result = store.persistEvent(ev)
        guard result == .inserted else { return result }
        guard !suppressPopup else { return result }

        let taskLevel = tasks.first(where: { $0.taskKey == ev.taskKey })?.notifyLevel ?? .normal
        let dnd = isDNDActiveNow()
        let action = NotificationPolicy.decide(eventStatus: ev.status, taskLevel: taskLevel, isDND: dnd)

        switch action {
        case .silentOnly:
            break
        case .lightToast:
            recentSuccessUntil = Date().addingTimeInterval(5.5)
            triggerLightToast(
                title: L10n.displayTaskName(ev.taskName, source: ev.source, lang: activeLanguage),
                summary: L10n.displayEventSummary(ev.summary, status: ev.status, lang: activeLanguage)
            )
        case .fullPopup(let pushExternal):
            onRequestShowMainPopup?()
            if pushExternal {
                let cfg = config
                let lang = activeLanguage
                Task.detached { [pushDispatcher] in
                    await pushDispatcher.dispatch(event: ev, config: cfg, lang: lang)
                }
            }
        }
        return result
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
                summary: L10n.missedSummary(activeLanguage),
                logPath: task.configPath,
                occurredAt: now,
                createdAt: now
            )
            ingestEvent(ev, suppressPopup: false)
        }
        if !missed.isEmpty {
            events = store.listEvents(limit: 80)
            rebuildWeekEventsCache()
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
            todoUpdatedLabel = path.isEmpty ? L10n.noVaultConfigured(activeLanguage) : L10n.noTodoFile(activeLanguage)
            return
        }
        lastTodoMtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let parsed = TodoMarkdownParser.parse(txt)
        todos = parsed.items
        todoUpdatedLabel = parsed.updatedLabel.isEmpty
            ? L10n.syncedLabel(activeLanguage)
            : L10n.updatedAt(parsed.updatedLabel, activeLanguage)
    }

    func toggleTodo(_ item: TodoItem) {
        let path = todoMarkdownPath
        guard !path.isEmpty,
              let txt = try? String(contentsOfFile: path, encoding: .utf8),
              let updated = TodoMarkdownParser.toggleTodo(in: txt, todoKey: item.todoKey, preferredLineIndex: item.id) else {
            showInlineNotice(L10n.todoWritebackFailed(activeLanguage))
            loadTodosMarkdown()
            return
        }
        do {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            showInlineNotice(L10n.todoWritebackFailed(activeLanguage))
            loadTodosMarkdown()
            return
        }
        selectedTodoKeys.remove(item.todoKey)
        loadTodosMarkdown()
        recomputeRobot()
    }

    // MARK: - One-Click Todo Dispatch & Conversation Tracking

    func toggleTodoSelection(_ item: TodoItem) {
        if dispatchesByKey[item.todoKey]?.status == .running {
            return
        }
        if selectedTodoKeys.contains(item.todoKey) {
            selectedTodoKeys.remove(item.todoKey)
        } else {
            selectedTodoKeys.insert(item.todoKey)
        }
    }

    func clearTodoSelection() {
        selectedTodoKeys.removeAll()
    }

    func markSelectedTodosDone() {
        let targets = (personalTodosOpen + projectTodosOpen)
            .filter { selectedTodoKeys.contains($0.todoKey) }
            .sorted { $0.id > $1.id }
        guard !targets.isEmpty else { return }
        let path = todoMarkdownPath
        guard !path.isEmpty, var txt = try? String(contentsOfFile: path, encoding: .utf8) else {
            showInlineNotice(L10n.todoWritebackFailed(activeLanguage))
            loadTodosMarkdown()
            return
        }
        var matched = 0
        for item in targets {
            if let next = TodoMarkdownParser.toggleTodo(in: txt, todoKey: item.todoKey, preferredLineIndex: item.id) {
                txt = next
                matched += 1
            }
        }
        guard matched > 0 else {
            showInlineNotice(L10n.todoWritebackFailed(activeLanguage))
            loadTodosMarkdown()
            return
        }
        do {
            try txt.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            showInlineNotice(L10n.todoWritebackFailed(activeLanguage))
            loadTodosMarkdown()
            return
        }
        selectedTodoKeys.removeAll()
        loadTodosMarkdown()
        recomputeRobot()
    }

    func dispatchSelectedTodos() {
        let openItems = personalTodosOpen + projectTodosOpen
        let toDispatch = openItems.filter { selectedTodoKeys.contains($0.todoKey) }
        selectedTodoKeys.removeAll()
        for item in toDispatch { dispatchTodo(item) }
    }

    func dispatchTodo(_ item: TodoItem) {
        guard (personalTodosOpen + projectTodosOpen).contains(where: { $0.todoKey == item.todoKey }),
              dispatchesByKey[item.todoKey]?.status != .running else { return }
        guard preservePendingHistory(beforeRetrying: item.todoKey) else { return }
        selectedTodoKeys.remove(item.todoKey)
        let vault = config.vaultPath
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TodoNotch/dispatch-logs")

        let now = Int64(Date().timeIntervalSince1970)
        let placeholder = TodoDispatchRecord(
            todoKey: item.todoKey,
            dispatchId: UUID().uuidString.lowercased(),
            project: item.project,
            todoText: TodoMarkdownParser.stripSourceSuffix(item.text),
            agent: item.sources.last?.agent ?? "antigravity",
            sessionId: item.sources.last?.sessionPrefix ?? "",
            cwd: "",
            status: .running,
            summary: "",
            dispatchedAt: now,
            updatedAt: now,
            pid: 0
        )
        dispatchesByKey[item.todoKey] = placeholder
        store.upsertTodoDispatch(placeholder)
        recomputeRobot()

        dispatchRunner.dispatch(
            item: item,
            vaultPath: vault,
            logDir: logDir,
            dispatchId: placeholder.dispatchId,
            requireDesktopSession: true,
            onStarted: { [weak self] startedRec in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let current = self.dispatchesByKey[startedRec.todoKey],
                          current.dispatchId == startedRec.dispatchId, current.status == .running else { return }
                    if !startedRec.summary.isEmpty, self.stoppingKeys.remove(startedRec.todoKey) != nil {
                        self.showInlineNotice(L10n.stopFailedNotice(self.activeLanguage) + " " + startedRec.summary)
                    }
                    self.store.upsertTodoDispatch(startedRec)
                    self.dispatchesByKey[startedRec.todoKey] = startedRec
                    self.recomputeRobot()
                }
            },
            onCompleted: { [weak self] finishedRec in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.dispatchesByKey[finishedRec.todoKey]?.dispatchId == finishedRec.dispatchId else { return }
                    self.stoppingKeys.remove(finishedRec.todoKey)
                    if finishedRec.status == .stopped {
                        var stoppedRec = finishedRec
                        stoppedRec.status = .stopped
                        stoppedRec.pid = 0
                        if stoppedRec.summary.isEmpty || stoppedRec.summary == "已手动停止" {
                            stoppedRec.summary = L10n.taskStoppedSummary(self.activeLanguage)
                        }
                        self.store.upsertTodoDispatch(stoppedRec)
                        self.dispatchesByKey[stoppedRec.todoKey] = stoppedRec
                        self.store.appendAudit(
                            action: "dispatch_stop",
                            target: stoppedRec.todoKey,
                            result: "stopped",
                            detail: stoppedRec.dispatchId
                        )
                        if self.expandedTodoKey == stoppedRec.todoKey {
                            self.loadConversationTurnsAsync(for: item, dispatch: stoppedRec)
                        }
                        self.recordDispatchRun(stoppedRec)
                        self.recomputeRobot()
                        return
                    }
                    guard self.saveDispatchCompletion(finishedRec) else { return }
                    self.store.appendAudit(
                        action: "todo_dispatch",
                        target: "\(finishedRec.agent):\(finishedRec.sessionId)",
                        result: finishedRec.status.rawValue,
                        detail: finishedRec.summary
                    )
                    if self.expandedTodoKey == finishedRec.todoKey {
                        self.loadConversationTurnsAsync(for: item, dispatch: finishedRec)
                    }
                    self.recordDispatchRun(finishedRec)
                    self.recomputeRobot()
                }
            }
        )
    }

    func toggleConversationDrawer(for item: TodoItem) {
        if expandedTodoKey == item.todoKey {
            expandedTodoKey = nil
            return
        }
        expandedTodoKey = item.todoKey
        loadConversationTurnsAsync(for: item, dispatch: dispatchesByKey[item.todoKey])
    }

    func openConversationFile(for item: TodoItem) {
        let vault = config.vaultPath
        let dispatch = dispatchesByKey[item.todoKey]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = TodoTargetResolver.resolve(item: item, vaultPath: vault)
            let candidates = [
                dispatch?.transcriptPath ?? "",
                target.transcriptPath,
                dispatch?.logPath ?? "",
                target.excerptPath
            ]
            let chosen = candidates.first { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ?? ""
            Task { @MainActor [weak self] in
                self?.openFileSafely(chosen)
            }
        }
    }

    private func loadConversationTurnsAsync(for item: TodoItem, dispatch: TodoDispatchRecord?) {
        let vault = config.vaultPath
        let todoKey = item.todoKey
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = TodoTargetResolver.resolve(item: item, vaultPath: vault)
            let agent = dispatch?.agent ?? target.agent
            let transcript = (dispatch?.transcriptPath.isEmpty == false) ? dispatch!.transcriptPath : target.transcriptPath
            let logPath = dispatch?.logPath ?? ""
            let turns = ConversationTracker.readConversationTurns(
                agent: agent,
                transcriptPath: transcript,
                excerptPath: target.excerptPath,
                logPath: logPath,
                maxTurns: 6,
                fallbackPrompt: dispatch?.todoText ?? TodoMarkdownParser.stripSourceSuffix(item.text)
            )
            Task { @MainActor [weak self] in
                self?.conversationTurnsByKey[todoKey] = turns
            }
        }
    }

    // MARK: - Manual Scheduled Task Execution & Tracking

    func canRunScheduledTask(_ task: MonitoredTask) -> Bool {
        [.antigravity, .codex, .claude].contains(task.source) && !task.configPath.isEmpty
    }

    func dispatchScheduledTask(taskKey: String) {
        guard let task = tasks.first(where: { $0.taskKey == taskKey }) else { return }
        dispatchScheduledTask(task)
    }

    func dispatchScheduledTask(_ task: MonitoredTask) {
        guard canRunScheduledTask(task),
              dispatchesByKey[task.taskKey]?.status != .running else {
            return
        }
        guard preservePendingHistory(beforeRetrying: task.taskKey, task: task) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TodoNotch/dispatch-logs")
        let placeholder = TodoDispatchRecord(
            todoKey: task.taskKey,
            dispatchId: UUID().uuidString.lowercased(),
            project: task.displayName,
            todoText: task.displayName,
            agent: task.source.rawValue,
            sessionId: "",
            cwd: "",
            status: .running,
            summary: "",
            dispatchedAt: now,
            updatedAt: now,
            pid: 0
        )
        dispatchesByKey[task.taskKey] = placeholder
        store.upsertTodoDispatch(placeholder)
        recomputeRobot()

        dispatchRunner.dispatchScheduledTask(
            task: task,
            logDir: logDir,
            dispatchId: placeholder.dispatchId,
            requireDesktopSession: true,
            onStarted: { [weak self] startedRec in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let current = self.dispatchesByKey[startedRec.todoKey],
                          current.dispatchId == startedRec.dispatchId, current.status == .running else { return }
                    if !startedRec.summary.isEmpty, self.stoppingKeys.remove(startedRec.todoKey) != nil {
                        self.showInlineNotice(L10n.stopFailedNotice(self.activeLanguage) + " " + startedRec.summary)
                    }
                    self.store.upsertTodoDispatch(startedRec)
                    self.dispatchesByKey[startedRec.todoKey] = startedRec
                    self.recomputeRobot()
                }
            },
            onCompleted: { [weak self] finishedRec in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.dispatchesByKey[finishedRec.todoKey]?.dispatchId == finishedRec.dispatchId else { return }
                    self.stoppingKeys.remove(finishedRec.todoKey)
                    if finishedRec.status == .stopped {
                        var stoppedRec = finishedRec
                        stoppedRec.status = .stopped
                        stoppedRec.pid = 0
                        if stoppedRec.summary.isEmpty || stoppedRec.summary == "已手动停止" {
                            stoppedRec.summary = L10n.taskStoppedSummary(self.activeLanguage)
                        }
                        self.store.upsertTodoDispatch(stoppedRec)
                        self.dispatchesByKey[stoppedRec.todoKey] = stoppedRec
                        self.store.appendAudit(
                            action: "dispatch_stop",
                            target: task.taskKey,
                            result: "stopped",
                            detail: stoppedRec.dispatchId
                        )
                        self.loadTaskConversationTurnsAsync(for: task, dispatch: stoppedRec)
                        self.recordDispatchRun(stoppedRec, task: task)
                        self.recomputeRobot()
                        return
                    }
                    guard self.saveDispatchCompletion(finishedRec, task: task) else { return }
                    self.store.appendAudit(
                        action: "task_dispatch",
                        target: task.taskKey,
                        result: finishedRec.status.rawValue,
                        detail: finishedRec.summary
                    )
                    self.loadTaskConversationTurnsAsync(for: task, dispatch: finishedRec)

                    self.recordDispatchRun(finishedRec, task: task)
                    self.recomputeRobot()
                }
            }
        )
    }

    private func dispatchRunEvent(_ record: TodoDispatchRecord, task: MonitoredTask?) -> RunEvent? {
        let runStatus: RunStatus
        switch record.status {
        case .completed: runStatus = .success
        case .needsAttention: runStatus = .attention
        case .failed: runStatus = .error
        case .stopped: runStatus = .stopped
        case .running: return nil
        }
        let isScheduled = task != nil || record.todoKey.hasPrefix("\(record.agent):")
        return RunEvent(
            eventId: "dispatch:\(record.dispatchId)",
            taskKey: isScheduled ? record.todoKey : "dispatch:\(record.todoKey)",
            taskName: task?.displayName ?? (isScheduled ? record.project : "[\(record.project)] \(L10n.speakerAgent(record.agent))"),
            source: task?.source ?? TaskSource(rawValue: record.agent) ?? .custom,
            status: runStatus,
            summary: L10n.dispatchDoneSummary(record.status, summary: record.summary, lang: activeLanguage),
            artifactPath: record.transcriptPath,
            logPath: record.logPath,
            isRead: runStatus == .stopped || record.summary == TodoDispatchRunner.unconfirmedAntigravitySummary,
            occurredAt: record.updatedAt,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
    }

    private func preservePendingHistory(beforeRetrying key: String, task: MonitoredTask? = nil) -> Bool {
        guard let previous = dispatchesByKey[key], previous.agent == "antigravity",
              previous.summary == TodoDispatchRunner.unconfirmedAntigravitySummary else { return true }
        guard let event = dispatchRunEvent(previous, task: task),
              store.saveAntigravityDispatchAndHistory(previous, event: event) else {
            showInlineNotice(L10n.dispatchHistorySaveFailed(activeLanguage))
            return false
        }
        return true
    }

    private func saveDispatchCompletion(_ record: TodoDispatchRecord, task: MonitoredTask? = nil) -> Bool {
        if record.summary == TodoDispatchRunner.unconfirmedAntigravitySummary {
            guard let event = dispatchRunEvent(record, task: task),
                  store.saveAntigravityDispatchAndHistory(record, event: event) else { return false }
        } else {
            store.upsertTodoDispatch(record)
        }
        dispatchesByKey[record.todoKey] = record
        return true
    }

    private func recordDispatchRun(_ record: TodoDispatchRecord, task: MonitoredTask? = nil) {
        guard let event = dispatchRunEvent(record, task: task) else { return }
        if record.summary != TodoDispatchRunner.unconfirmedAntigravitySummary {
            ingestEvent(event, suppressPopup: false)
        }
        events = store.listEvents(limit: 80)
        rebuildWeekEventsCache()
    }

    func canStopDispatchDirectly(_ dispatch: TodoDispatchRecord?) -> Bool {
        guard let dispatch, dispatch.status == .running else { return false }
        if dispatchRunner.isActive(recordKey: dispatch.todoKey, dispatchId: dispatch.dispatchId) {
            return true
        }
        return dispatch.agent == "antigravity" && dispatch.pid == 0
            && TodoDispatchRunner.canStopAntigravityBridgeDispatch(dispatchId: dispatch.dispatchId)
    }

    func stopDispatch(forKey key: String) {
        guard let rec = dispatchesByKey[key],
              rec.status == .running,
              !stoppingKeys.contains(key) else { return }
        guard canStopDispatchDirectly(rec) else {
            showInlineNotice(L10n.stopFailedNotice(activeLanguage))
            return
        }
        stoppingKeys.insert(key)

        if dispatchRunner.cancel(recordKey: key, dispatchId: rec.dispatchId) {
            return
        }
        if rec.agent == "antigravity",
           let requestId = TodoDispatchRunner.requestAntigravityBridgeStop(dispatchId: rec.dispatchId) {
            bridgeStopRequests[key] = requestId
            return
        }
        stoppingKeys.remove(key)
        showInlineNotice(L10n.stopFailedNotice(activeLanguage))
    }

    func loadTaskConversationTurnsAsync(for task: MonitoredTask, dispatch: TodoDispatchRecord? = nil) {
        let rec = dispatch ?? dispatchesByKey[task.taskKey]
        guard let rec else { return }
        let key = task.taskKey
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let turns = ConversationTracker.readConversationTurns(
                agent: rec.agent,
                transcriptPath: rec.transcriptPath,
                excerptPath: "",
                logPath: rec.logPath,
                maxTurns: 6,
                fallbackPrompt: rec.todoText
            )
            Task { @MainActor [weak self] in
                self?.conversationTurnsByKey[key] = turns
            }
        }
    }

    private nonisolated static func antigravityTranscriptPath(_ conversationId: String) -> String? {
        guard UUID(uuidString: conversationId) != nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain/\(conversationId)/.system_generated/logs/transcript.jsonl").path
    }

    private nonisolated static func bridgeRunOutcome(
        _ result: TodoDispatchRunner.BridgeResult, transcriptPath: String, lang: AppLanguage
    ) -> (status: TodoDispatchStatus, historyStatus: RunStatus, summary: String)? {
        switch result.status {
        case "stopped":
            return (.stopped, .stopped, L10n.taskStoppedSummary(lang))
        case "failed":
            return (.failed, .error, result.error.isEmpty ? "Antigravity Desktop failed" : result.error)
        case "completed":
            let completion = TodoDispatchRunner.antigravityCompletion(result, transcriptPath: transcriptPath)
            return (completion.status, completion.status == .completed ? .success : .attention, completion.summary)
        default: return nil
        }
    }

    func reconcileDispatchesAsync() {
        let candidates = dispatchesByKey.values.filter { $0.status == .running || $0.status == .needsAttention }
        let store = self.store
        let vault = config.vaultPath
        let runner = dispatchRunner
        let langSnapshot = activeLanguage
        let itemsByKey = Dictionary((personalTodosOpen + projectTodosOpen).map { ($0.todoKey, $0) }, uniquingKeysWith: { first, _ in first })

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let trackedDispatches = Set(candidates.map(\.dispatchId))
            let historicalRepairs = store.listUnconfirmedAntigravityHistory().compactMap { event -> RunEvent? in
                let dispatchId = String(event.eventId.dropFirst("dispatch:".count))
                guard !trackedDispatches.contains(dispatchId),
                      UUID(uuidString: dispatchId) != nil,
                      let result = TodoDispatchRunner.readBridgeResult(dispatchId: dispatchId) else { return nil }
                let path = Self.antigravityTranscriptPath(result.conversationId) ?? event.artifactPath
                guard let outcome = Self.bridgeRunOutcome(result, transcriptPath: path, lang: langSnapshot) else { return nil }
                return RunEvent(
                    eventId: event.eventId, taskKey: event.taskKey, taskName: event.taskName, source: event.source,
                    status: outcome.historyStatus, summary: outcome.summary, artifactPath: path, logPath: event.logPath,
                    occurredAt: result.updatedAt ?? event.occurredAt
                )
            }

            var updates: [TodoDispatchRecord] = []
            var resolvedBridgeRuns: Set<String> = []
            var bridgeStopErrors: [String: (requestId: String, message: String)] = [:]
            for var rec in candidates {
                let mtime = ConversationTracker.fileMtime(rec.transcriptPath)
                let waitingForBridge = rec.agent == "antigravity"
                    && rec.summary == TodoDispatchRunner.unconfirmedAntigravitySummary
                if rec.status == .running || waitingForBridge {
                    if runner.isActive(recordKey: rec.todoKey, dispatchId: rec.dispatchId) {
                        continue
                    }
                    if rec.pid == 0, rec.agent == "antigravity",
                       let bridgeRes = TodoDispatchRunner.readBridgeResult(dispatchId: rec.dispatchId) {
                        if let path = Self.antigravityTranscriptPath(bridgeRes.conversationId) {
                            rec.sessionId = bridgeRes.conversationId
                            rec.transcriptPath = path
                        }
                        if let outcome = Self.bridgeRunOutcome(bridgeRes, transcriptPath: rec.transcriptPath, lang: langSnapshot) {
                            rec.status = outcome.status
                            rec.summary = outcome.summary
                            rec.lastTranscriptMtime = ConversationTracker.fileMtime(rec.transcriptPath)
                            rec.pid = 0
                            rec.updatedAt = max(rec.dispatchedAt, bridgeRes.updatedAt ?? Int64(Date().timeIntervalSince1970))
                            resolvedBridgeRuns.insert(rec.dispatchId)
                            updates.append(rec)
                            continue
                        }
                        if ["starting", "running"].contains(bridgeRes.status) {
                            let owned = TodoDispatchRunner.canStopAntigravityBridgeDispatch(dispatchId: rec.dispatchId)
                            let legacyActive = bridgeRes.bridgeInstance.isEmpty && TodoDispatchRunner.isLegacyAntigravityBridgeHealthy()
                                && Int64(Date().timeIntervalSince1970) - rec.dispatchedAt < 1800
                            if owned || legacyActive {
                                rec.status = .running
                                if owned, !bridgeRes.stopRequestId.isEmpty, !bridgeRes.error.isEmpty {
                                    bridgeStopErrors[rec.todoKey] = (bridgeRes.stopRequestId, bridgeRes.error)
                                }
                                updates.append(rec)
                                continue
                            }
                            rec.status = .needsAttention
                            rec.summary = TodoDispatchRunner.unconfirmedAntigravitySummary
                            rec.lastTranscriptMtime = mtime
                            resolvedBridgeRuns.insert(rec.dispatchId)
                            updates.append(rec)
                            continue
                        }
                    }

                    if rec.agent == "antigravity", rec.pid == 0 {
                        if !waitingForBridge, Int64(Date().timeIntervalSince1970) - rec.updatedAt > 60 {
                            rec.status = .needsAttention
                            rec.summary = TodoDispatchRunner.unconfirmedAntigravitySummary
                            rec.lastTranscriptMtime = mtime
                            resolvedBridgeRuns.insert(rec.dispatchId)
                            updates.append(rec)
                        }
                        continue
                    }
                    let alive = rec.pid > 0 && ConversationTracker.isProcessAlive(rec.pid)
                    let staleNoPid = rec.pid == 0 && (Int64(Date().timeIntervalSince1970) - rec.updatedAt > 60)
                    if staleNoPid && mtime <= rec.lastTranscriptMtime {
                        rec.status = .failed
                        if rec.summary.isEmpty {
                            rec.summary = "Task process is no longer running"
                        }
                        rec.lastTranscriptMtime = mtime
                        rec.pid = 0
                        rec.updatedAt = Int64(Date().timeIntervalSince1970)
                        updates.append(rec)
                        continue
                    }
                    if (!alive && rec.pid > 0) || staleNoPid {
                        let turns = ConversationTracker.readConversationTurns(
                            agent: rec.agent,
                            transcriptPath: rec.transcriptPath,
                            excerptPath: "",
                            logPath: rec.logPath,
                            maxTurns: 6,
                            fallbackPrompt: rec.todoText
                        )
                        let reply = turns.last(where: { $0.role == "assistant" })?.text ?? ""
                        let hasPendingUser = turns.last?.role == "user"
                        let nextStatus = ConversationTracker.evaluateCompletion(
                            exitCode: 0,
                            latestAssistantReply: reply,
                            hasPendingUserTurn: hasPendingUser
                        )
                        rec.status = nextStatus
                        if !reply.isEmpty {
                            rec.summary = String(reply.replacingOccurrences(of: "\n", with: " ").prefix(240))
                        }
                        rec.lastTranscriptMtime = mtime
                        rec.pid = 0
                        rec.updatedAt = Int64(Date().timeIntervalSince1970)
                        updates.append(rec)
                    }
                } else if rec.status == .needsAttention,
                          rec.summary != TodoDispatchRunner.missingAntigravityReplySummary,
                          mtime > rec.lastTranscriptMtime {
                    let excerpt = itemsByKey[rec.todoKey].map { TodoTargetResolver.resolve(item: $0, vaultPath: vault).excerptPath } ?? ""
                    let turns = ConversationTracker.readConversationTurns(
                        agent: rec.agent,
                        transcriptPath: rec.transcriptPath,
                        excerptPath: excerpt,
                        logPath: rec.logPath,
                        maxTurns: 6
                    )
                    if let reply = turns.last(where: { $0.role == "assistant" })?.text,
                       turns.last?.role == "assistant" {
                        let nextStatus = ConversationTracker.evaluateCompletion(
                            exitCode: nil,
                            latestAssistantReply: reply,
                            hasPendingUserTurn: false
                        )
                        rec.status = nextStatus
                        rec.summary = String(reply.replacingOccurrences(of: "\n", with: " ").prefix(240))
                        rec.lastTranscriptMtime = mtime
                        rec.updatedAt = Int64(Date().timeIntervalSince1970)
                        updates.append(rec)
                    }
                }
            }
            guard !updates.isEmpty || !historicalRepairs.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var reloadHistory = false
                for event in historicalRepairs {
                    if self.store.repairUnconfirmedAntigravityHistory(event) { reloadHistory = true }
                }
                for rec in updates {
                    guard let current = self.dispatchesByKey[rec.todoKey],
                          current.dispatchId == rec.dispatchId,
                          current.status == .running || current.status == .needsAttention else { continue }
                    if rec.status != .running {
                        self.bridgeStopRequests.removeValue(forKey: rec.todoKey)
                        self.stoppingKeys.remove(rec.todoKey)
                    } else if let error = bridgeStopErrors[rec.todoKey],
                              self.bridgeStopRequests[rec.todoKey] == error.requestId {
                        self.bridgeStopRequests.removeValue(forKey: rec.todoKey)
                        self.stoppingKeys.remove(rec.todoKey)
                        self.showInlineNotice(L10n.stopFailedNotice(self.activeLanguage) + " " + error.message)
                    }
                    if resolvedBridgeRuns.contains(rec.dispatchId) {
                        let task = self.tasks.first(where: { $0.taskKey == rec.todoKey })
                        guard let event = self.dispatchRunEvent(rec, task: task),
                              self.store.saveAntigravityDispatchAndHistory(rec, event: event) else { continue }
                        reloadHistory = true
                        if let task { self.loadTaskConversationTurnsAsync(for: task, dispatch: rec) }
                    } else {
                        self.store.upsertTodoDispatch(rec)
                    }
                    self.dispatchesByKey[rec.todoKey] = rec
                    if self.expandedTodoKey == rec.todoKey, let item = itemsByKey[rec.todoKey] {
                        self.loadConversationTurnsAsync(for: item, dispatch: rec)
                    }
                }
                if reloadHistory {
                    self.events = self.store.listEvents(limit: 80)
                    self.rebuildWeekEventsCache()
                }
                self.recomputeRobot()
            }
        }
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
        toastToken &+= 1
        guard desktopNavigationToast == nil else { return }
        onRequestShowToast?()
        if !toastHovered { scheduleToastDismiss(delay: .seconds(5)) }
    }

    func setToastHovered(_ hovered: Bool) {
        guard desktopNavigationToast == nil else { return }
        toastHovered = hovered
        if hovered {
            toastDismissTask?.cancel()
        } else if toastVisible {
            scheduleToastDismiss(delay: .seconds(2))
        }
    }

    func dismissToastNow() {
        toastDismissTask?.cancel()
        toastVisible = false
        toastHovered = false
        toastCoalescedCount = 0
        if desktopNavigationToast == nil { onRequestHideToast?() }
    }

    private func scheduleToastDismiss(delay: Duration) {
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.toastHovered else { return }
            self.dismissToastNow()
        }
    }

    func dismissDesktopNavigationToast() {
        guard desktopNavigationToast != nil else { return }
        desktopNavigationToastDismissTask?.cancel()
        desktopNavigationToast = nil
        onRequestHideToast?()
        if toastVisible {
            toastToken &+= 1
            onRequestShowToast?()
            scheduleToastDismiss(delay: .seconds(5))
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showDesktopNavigationToast(_ outcome: DesktopNavigationRules.Outcome, source: TaskSource) {
        guard let message = L10n.taskNavigationMessage(outcome, source: source, lang: activeLanguage) else { return }
        desktopNavigationToastDismissTask?.cancel()
        toastDismissTask?.cancel()
        toastHovered = false
        desktopNavigationToast = (L10n.taskNavigationTitle(outcome, activeLanguage), message, outcome.presentation)
        onRequestShowToast?()
        desktopNavigationToastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: outcome == .needsAccessibility ? .seconds(20) : .seconds(9))
            guard !Task.isCancelled else { return }
            self?.dismissDesktopNavigationToast()
        }
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
            + dispatchesByKey.values.filter { $0.status == .running }.count
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
        weekEventsByTask[taskKey] ?? store.listRecentWeekEvents(taskKey: taskKey)
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
        store.appendAudit(action: "task_level_change", target: task.taskKey, result: "ok", detail: "level -> \(level.rawValue)")
        tasks = store.listTasks()
    }

    func markEventRead(_ event: RunEvent) {
        store.markEventRead(eventId: event.eventId)
        events = store.listEvents(limit: 80)
        rebuildWeekEventsCache()
        recomputeRobot()
    }

    func markAllRead() {
        store.markAllEventsRead()
        events = store.listEvents(limit: 80)
        rebuildWeekEventsCache()
        recomputeRobot()
    }

    func retryPush(for event: RunEvent) {
        let cfg = config
        let lang = activeLanguage
        Task {
            await pushDispatcher.dispatch(event: event, config: cfg, lang: lang)
            self.events = self.store.listEvents(limit: 80)
            self.rebuildWeekEventsCache()
        }
    }

    private var desktopNavigation: Task<Void, Never>?

    func openScheduledTaskInDesktop(_ task: MonitoredTask, onOpened: @escaping @MainActor () -> Void) {
        guard navigatingDesktopTaskKey != task.taskKey else { return }
        let previous = desktopNavigation
        cancelDesktopNavigation()
        dismissDesktopNavigationToast()
        navigatingDesktopTaskKey = task.taskKey
        desktopNavigation = Task { [weak self] in
            guard let self else { return }
            // Let a cancelled worker finish stopping before the next request changes another app.
            await previous?.value
            let outcome = await DesktopTaskNavigation.open(task, store: self.store)
            guard !Task.isCancelled else { return }
            self.desktopNavigation = nil
            self.navigatingDesktopTaskKey = nil
            switch outcome.presentation {
            case .closePanel:
                onOpened()
            case .none:
                break
            case .warningToast, .errorToast, .accessibilityToast:
                self.showDesktopNavigationToast(outcome, source: task.source)
            }
        }
    }

    func cancelDesktopNavigation() {
        guard navigatingDesktopTaskKey != nil else { return }
        desktopNavigation?.cancel()
        navigatingDesktopTaskKey = nil
    }

    func openWorkBuddyApp() {
        let appPath = "/Applications/WorkBuddy.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            showInlineNotice(L10n.fileMissingNotice(activeLanguage))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
    }

    func openAntigravityDesktop(notice: Bool = true) {
        let appPath = "/Applications/Antigravity.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            showInlineNotice(L10n.fileMissingNotice(activeLanguage))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        if notice {
            showInlineNotice(L10n.antigravityStopInDesktopNotice(activeLanguage))
        }
    }

    func openFileSafely(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            showInlineNotice(L10n.fileMissingNotice(activeLanguage))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func showInlineNotice(_ msg: String) {
        inlineNoticeDismissTask?.cancel()
        inlineNotice = msg
        inlineNoticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(3500))
            guard !Task.isCancelled else { return }
            self?.inlineNotice = ""
        }
    }

    func saveSettingsAndSecrets() {
        if config.dndEnabled, let err = DNDPolicy.validateRange(start: config.dndStart, end: config.dndEnd, lang: activeLanguage) {
            dndErrorMsg = err
            settingsStatusMsg = ""
            settingsStatusIsError = false
            return
        }
        dndErrorMsg = ""

        if !webhookURLDraft.isEmpty {
            guard ValidationHelpers.isValidWebhookURL(webhookURLDraft) else {
                settingsStatusMsg = L10n.invalidWebhookNotice(activeLanguage)
                settingsStatusIsError = true
                return
            }
            do {
                try secrets.saveSecret(webhookURLDraft, account: SecretAccount.webhookURL)
                webhookURLDraft = ""
            } catch let nsErr as NSError where nsErr.domain == "KeychainSecretStore" {
                settingsStatusMsg = L10n.keychainWriteFailed(Int32(nsErr.code), activeLanguage)
                settingsStatusIsError = true
                return
            } catch {
                settingsStatusMsg = error.localizedDescription
                settingsStatusIsError = true
                return
            }
        }
        store.saveConfig(config)
        refreshSecretPreviews()
        loadTodosMarkdown()
        health = discovery.readLmemoryHealth(configuredVault: config.vaultPath)
        recomputeRobot()
        onScreenModeChanged?()
        settingsStatusMsg = L10n.settingsSavedNotice(activeLanguage)
        settingsStatusIsError = false
        triggerSaveButtonMorph()
    }

    private func triggerSaveButtonMorph() {
        saveFeedbackWork?.cancel()
        saveFeedbackActive = true
        let w = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveFeedbackActive = false }
        }
        saveFeedbackWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    func testWebhookNow() {
        saveSettingsAndSecrets()
        guard !settingsStatusIsError else { return }
        settingsStatusMsg = L10n.testingWebhookNotice(activeLanguage)
        settingsStatusIsError = false
        let cfg = config
        let lang = activeLanguage
        Task {
            let res = await pushDispatcher.sendTestWebhook(config: cfg, lang: lang)
            switch res {
            case .success(let m):
                settingsStatusMsg = m
                settingsStatusIsError = false
            case .failure(let e):
                settingsStatusMsg = L10n.testFailedPrefix(e.localizedDescription, lang)
                settingsStatusIsError = true
            }
        }
    }

    private func refreshSecretPreviews() {
        if let raw = secrets.loadSecret(account: SecretAccount.webhookURL), !raw.isEmpty {
            maskedWebhookPreview = ValidationHelpers.maskSecretURL(raw, lang: activeLanguage)
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
        let lang = activeLanguage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = inst.deploy(env: env, vaultPath: vault, lang: lang)
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
