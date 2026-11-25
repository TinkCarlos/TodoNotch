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

    public var zhLabel: String {
        switch self {
        case .priority: return "重点"
        case .normal: return "普通"
        case .muted: return "静音"
        }
    }
}

public enum RunStatus: String, Codable, Sendable {
    case unknown
    case running
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

public struct TodoItem: Identifiable, Equatable, Sendable {
    public let id: Int // 0-based line index in 每日待办.md
    public let section: String // personal / project
    public let project: String
    public let text: String
    public let done: Bool

    public init(id: Int, section: String, project: String, text: String, done: Bool) {
        self.id = id
        self.section = section
        self.project = project
        self.text = text
        self.done = done
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

    public var zhLabel: String {
        switch self {
        case .feishu: return "飞书"
        case .wecom: return "企业微信"
        case .dingtalk: return "钉钉"
        case .bark: return "Bark"
        case .generic: return "通用 JSON"
        }
    }
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

    public init(
        vaultPath: String = "",
        onboardingDone: Bool = false,
        screenMode: String = "all",
        dndEnabled: Bool = false,
        dndStart: String = "22:00",
        dndEnd: String = "08:30",
        focusMode: Bool = false,
        webhookEnabled: Bool = false,
        webhookKind: WebhookKind = .feishu
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

    public static func validateRange(start: String, end: String) -> String? {
        guard let s = parseMinutes(start), let e = parseMinutes(end) else {
            return "时间格式须为 HH:mm（24 小时制）"
        }
        if s == e {
            return "开始与结束时间不能相同"
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
        if taskLevel == .muted { return .silentOnly }
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
                parsed.append(TodoItem(id: idx, section: section, project: proj, text: cleanText, done: done))
            }
        }
        return (parsed, updated)
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

    public static func maskSecretURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host else { return "已配置（已脱敏）" }
        let suffix = raw.count > 4 ? String(raw.suffix(4)) : "****"
        return "\(url.scheme ?? "https")://\(host)/...****\(suffix)"
    }
}
