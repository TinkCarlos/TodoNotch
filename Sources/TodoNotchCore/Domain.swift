import Foundation

// MARK: - Core Enums & Entities

public enum TaskSource: String, Codable, CaseIterable, Sendable {
    case antigravity
    case codex
    case claude
    case workbuddy
    case zcode
    case launchd
    case custom
}

public enum NotifyLevel: String, Codable, CaseIterable, Sendable {
    case priority
    case normal
    case muted
}

public enum RunStatus: String, Codable, Sendable {
    case unknown
    case running
    case stopped
    case success
    case attention
    case error
    case missed
}

public enum RobotMood: String, Equatable, Sendable {
    case idle
    case running
    case success
    case attention
    case error
    case overdue
}

public struct RobotPresentation: Equatable, Sendable {
    public let mood: RobotMood
    public let showMutedBadge: Bool
    public let animateIdle: Bool

    public init(mood: RobotMood, showMutedBadge: Bool, animateIdle: Bool) {
        self.mood = mood
        self.showMutedBadge = showMutedBadge
        self.animateIdle = animateIdle
    }
}

public struct MonitoredTask: Identifiable, Equatable, Sendable {
    public var id: String { taskKey }
    public let taskKey: String
    public let source: TaskSource
    public let nativeId: String
    public var displayName: String
    public var scheduleExpr: String
    public var sourceStatus: String // active / paused / removed
    public var notifyLevel: NotifyLevel
    public var configPath: String
    public var lastRunAt: Int64?
    public var lastRunStatus: RunStatus
    public var nextDueAt: Int64?
    public var updatedAt: Int64

    public init(
        taskKey: String,
        source: TaskSource,
        nativeId: String,
        displayName: String,
        scheduleExpr: String = "",
        sourceStatus: String = "active",
        notifyLevel: NotifyLevel = .normal,
        configPath: String = "",
        lastRunAt: Int64? = nil,
        lastRunStatus: RunStatus = .unknown,
        nextDueAt: Int64? = nil,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.taskKey = taskKey
        self.source = source
        self.nativeId = nativeId
        self.displayName = displayName
        self.scheduleExpr = scheduleExpr
        self.sourceStatus = sourceStatus
        self.notifyLevel = notifyLevel
        self.configPath = configPath
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.nextDueAt = nextDueAt
        self.updatedAt = updatedAt
    }
}

public struct RunEvent: Identifiable, Equatable, Sendable {
    public var id: String { eventId }
    public let eventId: String
    public let taskKey: String
    public let taskName: String
    public let source: TaskSource
    public let status: RunStatus
    public let summary: String
    public let artifactPath: String
    public let logPath: String
    public var isRead: Bool
    public var pushStatus: String // skipped / pending / sent / failed
    public var pushError: String
    public let occurredAt: Int64
    public let createdAt: Int64

    public init(
        eventId: String,
        taskKey: String,
        taskName: String,
        source: TaskSource,
        status: RunStatus,
        summary: String,
        artifactPath: String = "",
        logPath: String = "",
        isRead: Bool = false,
        pushStatus: String = "skipped",
        pushError: String = "",
        occurredAt: Int64 = Int64(Date().timeIntervalSince1970),
        createdAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.eventId = eventId
        self.taskKey = taskKey
        self.taskName = taskName
        self.source = source
        self.status = status
        self.summary = String(summary.prefix(500))
        self.artifactPath = artifactPath
        self.logPath = logPath
        self.isRead = isRead
        self.pushStatus = pushStatus
        self.pushError = pushError
        self.occurredAt = occurredAt
        self.createdAt = createdAt
    }
}

public struct TodoSourceRef: Equatable, Hashable, Sendable {
    public let agent: String
    public let sessionPrefix: String

    public init(agent: String, sessionPrefix: String) {
        self.agent = agent
        self.sessionPrefix = sessionPrefix
    }
}

public enum TodoDispatchStatus: String, Codable, Equatable, Sendable {
    case running
    case completed
    case needsAttention = "needs_attention"
    case failed
    case stopped
}

public struct TodoDispatchRecord: Identifiable, Equatable, Sendable {
    public var id: String { todoKey }
    public let todoKey: String
    public let dispatchId: String
    public let project: String
    public let todoText: String
    public let agent: String
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String
    public var logPath: String
    public var status: TodoDispatchStatus
    public var summary: String
    public let dispatchedAt: Int64
    public var updatedAt: Int64
    public var lastTranscriptMtime: Int64
    public var pid: Int32

    public init(
        todoKey: String,
        dispatchId: String,
        project: String,
        todoText: String,
        agent: String,
        sessionId: String,
        cwd: String,
        transcriptPath: String = "",
        logPath: String = "",
        status: TodoDispatchStatus,
        summary: String = "",
        dispatchedAt: Int64,
        updatedAt: Int64,
        lastTranscriptMtime: Int64 = 0,
        pid: Int32 = 0
    ) {
        self.todoKey = todoKey
        self.dispatchId = dispatchId
        self.project = project
        self.todoText = todoText
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.logPath = logPath
        self.status = status
        self.summary = summary
        self.dispatchedAt = dispatchedAt
        self.updatedAt = updatedAt
        self.lastTranscriptMtime = lastTranscriptMtime
        self.pid = pid
    }
}

public struct ConversationTurn: Identifiable, Equatable, Sendable {
    public let id: Int
    public let role: String // "user" | "assistant"
    public let text: String

    public init(id: Int, role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct TodoItem: Identifiable, Equatable, Sendable {
    public let id: Int // 0-based line index in 每日待办.md
    public let section: String // personal / project
    public let project: String
    public let text: String
    public let done: Bool
    public let todoKey: String
    public let sources: [TodoSourceRef]

    public init(
        id: Int,
        section: String,
        project: String,
        text: String,
        done: Bool,
        sources: [TodoSourceRef] = [],
        todoKey: String? = nil
    ) {
        self.id = id
        self.section = section
        self.project = project
        self.text = text
        self.done = done
        self.sources = sources
        self.todoKey = todoKey ?? TodoMarkdownParser.makeTodoKey(project: project, text: text)
    }
}

public struct LmemoryHealth: Equatable, Sendable {
    public enum State: String, Sendable {
        case healthy
        case failed
        case missing
        case unknown
    }
    public let state: State
    public let detail: String
    public let logPath: String
    public let vaultPath: String

    public init(state: State, detail: String, logPath: String = "", vaultPath: String = "") {
        self.state = state
        self.detail = detail
        self.logPath = logPath
        self.vaultPath = vaultPath
    }
}

public enum WebhookKind: String, Codable, CaseIterable, Sendable {
    case feishu
    case wecom
    case dingtalk
    case bark
    case generic
}

public struct AppConfig: Equatable, Sendable {
    public var vaultPath: String
    public var onboardingDone: Bool
    public var screenMode: String // "all" or "locked:<displayID>"
    public var dndEnabled: Bool
    public var dndStart: String // "HH:mm"
    public var dndEnd: String   // "HH:mm"
    public var focusMode: Bool
    public var webhookEnabled: Bool
    public var webhookKind: WebhookKind
    public var languageMode: LanguageMode
    public var detectedIPCountry: String

    public init(
        vaultPath: String = "",
        onboardingDone: Bool = false,
        screenMode: String = "all",
        dndEnabled: Bool = false,
        dndStart: String = "22:00",
        dndEnd: String = "08:30",
        focusMode: Bool = false,
        webhookEnabled: Bool = false,
        webhookKind: WebhookKind = .feishu,
        languageMode: LanguageMode = .auto,
        detectedIPCountry: String = ""
    ) {
        self.vaultPath = vaultPath
        self.onboardingDone = onboardingDone
        self.screenMode = screenMode
        self.dndEnabled = dndEnabled
        self.dndStart = dndStart
        self.dndEnd = dndEnd
        self.focusMode = focusMode
        self.webhookEnabled = webhookEnabled
        self.webhookKind = webhookKind
        self.languageMode = languageMode
        self.detectedIPCountry = detectedIPCountry
    }
}

// MARK: - Domain State Machines & Policies

public enum RobotStateMachine {
    /// Strict priority: overdue(cry) > error > attention > running > success(5s) > idle.
    /// DND preserves highest-priority color and overlays a muted badge.
    public static func compute(
        unreadErrors: Int,
        unreadMissed: Int,
        unreadAttention: Int,
        openPersonalTodos: Int,
        overdueTodos: Int = 0,
        runningTasks: Int,
        recentSuccessUntil: Date?,
        isDND: Bool,
        reduceMotion: Bool,
        now: Date = Date()
    ) -> RobotPresentation {
        let mood: RobotMood
        if unreadMissed > 0 || overdueTodos > 0 {
            mood = .overdue
        } else if unreadErrors > 0 {
            mood = .error
        } else if unreadAttention > 0 || openPersonalTodos > 0 {
            mood = .attention
        } else if runningTasks > 0 {
            mood = .running
        } else if let until = recentSuccessUntil, now < until {
            mood = .success
        } else {
            mood = .idle
        }
        let animate = !reduceMotion && !isDND
        return RobotPresentation(mood: mood, showMutedBadge: isDND, animateIdle: animate)
    }
}

public enum DNDPolicy {
    public static func parseMinutes(_ hhmm: String) -> Int? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else {
            return nil
        }
        return h * 60 + m
    }

    public static func validateRange(start: String, end: String, lang: AppLanguage = .zhHans) -> String? {
        guard let s = parseMinutes(start), let e = parseMinutes(end) else {
            return lang == .zhHans ? "时间格式须为 HH:mm（24 小时制）" : "Format must be HH:mm (24-hour)"
        }
        if s == e {
            return lang == .zhHans ? "开始与结束时间不能相同" : "Start and end time cannot be identical"
        }
        return nil
    }

    public static func isActive(
        dndEnabled: Bool,
        focusMode: Bool,
        start: String,
        end: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        if focusMode { return true }
        guard dndEnabled, let s = parseMinutes(start), let e = parseMinutes(end), s != e else {
            return false
        }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let cur = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if s < e {
            return cur >= s && cur < e
        } else {
            // Cross-midnight window, e.g. 22:00 - 08:30
            return cur >= s || cur < e
        }
    }
}

public enum MissedRunCalculator {
    /// Returns tasks that are genuinely overdue after excluding sleep intervals and 5-min wake grace.
    public static func findMissedTasks(
        tasks: [MonitoredTask],
        now: Int64,
        wakeGraceUntil: Int64,
        overlappedSleepSeconds: (Int64, Int64) -> Int64,
        overdueThreshold: Int64 = 900
    ) -> [MonitoredTask] {
        if now < wakeGraceUntil { return [] }
        var missed: [MonitoredTask] = []
        for task in tasks {
            guard task.sourceStatus == "active",
                  task.lastRunStatus != .running,
                  let due = task.nextDueAt,
                  due > 0,
                  now > due else {
                continue
            }
            if let lastRun = task.lastRunAt, lastRun >= due {
                continue
            }
            let sleepOverlap = max(0, overlappedSleepSeconds(due, now))
            let effectiveDelay = (now - due) - sleepOverlap
            if effectiveDelay > overdueThreshold {
                missed.append(task)
            }
        }
        return missed
    }
}

public enum NotificationAction: Equatable, Sendable {
    case silentOnly
    case lightToast
    case fullPopup(pushExternal: Bool)
}

public enum NotificationPolicy {
    public static func decide(
        eventStatus: RunStatus,
        taskLevel: NotifyLevel,
        isDND: Bool
    ) -> NotificationAction {
        if taskLevel == .muted || eventStatus == .stopped { return .silentOnly }
        if isDND { return .silentOnly }
        if eventStatus == .error || eventStatus == .missed || eventStatus == .attention || taskLevel == .priority {
            return .fullPopup(pushExternal: true)
        }
        if eventStatus == .success {
            return .lightToast
        }
        return .silentOnly
    }
}

public enum TodoMarkdownParser {
    public static func parse(_ content: String) -> (items: [TodoItem], updatedLabel: String) {
        var parsed: [TodoItem] = []
        var section = "personal"
        var updated = ""
        let lines = content.components(separatedBy: "\n")
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("updated_at:") {
                updated = line.replacingOccurrences(of: "updated_at:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "T", with: " ")
                    .prefix(16)
                    .description
            } else if line.hasPrefix("## ") {
                if line.contains("亲自处理") {
                    section = "personal"
                } else if line.contains("进行中") || line.contains("未收尾") {
                    section = "project"
                } else if line.contains("消项") || line.contains("完成") {
                    section = "done"
                }
            } else if section != "done" && (line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")) {
                let done = !line.hasPrefix("- [ ] ")
                let body = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                let (proj, cleanText) = splitProject(body)
                let sources = parseSources(from: cleanText)
                let todoKey = makeTodoKey(project: proj, text: cleanText)
                parsed.append(TodoItem(id: idx, section: section, project: proj, text: cleanText, done: done, sources: sources, todoKey: todoKey))
            }
        }
        return (parsed, updated)
    }

    public static func stripSourceSuffix(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(pattern: #"\s*[—\-]+\s*来源[：:].*$"#) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func makeTodoKey(project: String, text: String) -> String {
        let normProj = project.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = stripSourceSuffix(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let head = String(stripped.prefix(80)).lowercased()
        let canonical = "\(normProj)|\(head)"
        var hash: UInt64 = 14695981039346656037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    public static func parseSources(from text: String) -> [TodoSourceRef] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(antigravity|codex|claude|cursor|pi|opencode|grok|qoder)\s*\(([^)]+)\)"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        var refs: [TodoSourceRef] = []
        let seps = CharacterSet(charactersIn: "/,、 ")
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let agentRange = Range(match.range(at: 1), in: text),
                  let idsRange = Range(match.range(at: 2), in: text) else {
                continue
            }
            let agent = String(text[agentRange]).lowercased()
            let rawIds = String(text[idsRange])
            for rawToken in rawIds.components(separatedBy: seps) {
                let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' \t\n"))
                if token.count >= 4,
                   token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) {
                    let ref = TodoSourceRef(agent: agent, sessionPrefix: token)
                    if !refs.contains(ref) {
                        refs.append(ref)
                    }
                }
            }
        }
        return refs
    }

    public static func splitProject(_ raw: String) -> (String, String) {
        let stripped = raw.replacingOccurrences(of: "**[", with: "[").replacingOccurrences(of: "]**", with: "]")
        if stripped.hasPrefix("["), let closeIdx = stripped.firstIndex(of: "]") {
            let proj = String(stripped[stripped.index(after: stripped.startIndex)..<closeIdx])
            let rest = String(stripped[stripped.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
            return (proj, rest)
        }
        return ("综合", raw)
    }

    public static func toggleLine(in content: String, lineIndex: Int) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard lineIndex >= 0 && lineIndex < lines.count else { return nil }
        if lines[lineIndex].contains("- [ ] ") {
            lines[lineIndex] = lines[lineIndex].replacingOccurrences(of: "- [ ] ", with: "- [x] ")
        } else if lines[lineIndex].contains("- [x] ") {
            lines[lineIndex] = lines[lineIndex].replacingOccurrences(of: "- [x] ", with: "- [ ] ")
        } else if lines[lineIndex].contains("- [X] ") {
            lines[lineIndex] = lines[lineIndex].replacingOccurrences(of: "- [X] ", with: "- [ ] ")
        } else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    public static func toggleTodo(in content: String, todoKey: String, preferredLineIndex: Int? = nil) -> String? {
        let matches = parse(content).items.filter { !$0.done && $0.todoKey == todoKey }
        if let preferredLineIndex, matches.contains(where: { $0.id == preferredLineIndex }) {
            return toggleLine(in: content, lineIndex: preferredLineIndex)
        }
        if matches.count == 1 {
            return toggleLine(in: content, lineIndex: matches[0].id)
        }
        return nil
    }
}

public enum ValidationHelpers {
    public static func isValidWebhookURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" { return !host.isEmpty }
        if scheme == "http" && (host == "localhost" || host == "127.0.0.1") { return true }
        return false
    }

    public static func maskSecretURL(_ raw: String, lang: AppLanguage = .zhHans) -> String {
        guard let url = URL(string: raw), let host = url.host else { return L10n.maskedConfiguredFallback(lang) }
        let suffix = raw.count > 4 ? String(raw.suffix(4)) : "****"
        return "\(url.scheme ?? "https")://\(host)/...****\(suffix)"
    }
}
