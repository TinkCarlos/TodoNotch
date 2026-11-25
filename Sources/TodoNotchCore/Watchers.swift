import Foundation
import SQLite3

public struct DiscoveredSnapshot: Sendable {
    public let tasks: [MonitoredTask]
    public let newEvents: [RunEvent]
}

public final class TaskDiscoveryService: @unchecked Sendable {
    public let homeDir: URL
    public let inboxDir: URL

    public init(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        inboxDir: URL? = nil
    ) {
        self.homeDir = homeDir
        if let inboxDir {
            self.inboxDir = inboxDir
        } else {
            self.inboxDir = homeDir
                .appendingPathComponent("Library/Application Support/TodoNotch/inbox")
        }
    }

    public func ensureInboxDir() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: inboxDir.path) {
            try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    public func scanAll() -> DiscoveredSnapshot {
        var allTasks: [MonitoredTask] = []
        var allEvents: [RunEvent] = []

        let (agyTasks, agyEvents) = scanAntigravity()
        allTasks.append(contentsOf: agyTasks)
        allEvents.append(contentsOf: agyEvents)

        let (codexTasks, codexEvents) = scanCodex()
        allTasks.append(contentsOf: codexTasks)
        allEvents.append(contentsOf: codexEvents)

        let (claudeTasks, claudeEvents) = scanClaude()
        allTasks.append(contentsOf: claudeTasks)
        allEvents.append(contentsOf: claudeEvents)

        let (wbTasks, wbEvents) = scanWorkBuddy()
        allTasks.append(contentsOf: wbTasks)
        allEvents.append(contentsOf: wbEvents)

        let (zcodeTasks, zcodeEvents) = scanZCode()
        allTasks.append(contentsOf: zcodeTasks)
        allEvents.append(contentsOf: zcodeEvents)

        let launchdTasks = scanLaunchAgents()
        allTasks.append(contentsOf: launchdTasks)

        let inboxEvents = drainInbox()
        allEvents.append(contentsOf: inboxEvents)

        return DiscoveredSnapshot(tasks: allTasks, newEvents: allEvents)
    }

    // MARK: - Antigravity Read-Only Watcher

    public func scanAntigravity() -> ([MonitoredTask], [RunEvent]) {
        let fm = FileManager.default
        let sidecarsDir = homeDir.appendingPathComponent(".gemini/config/sidecars")
        let dataRoot = homeDir.appendingPathComponent(".gemini/antigravity/sidecar_data")
        guard let dirs = try? fm.contentsOfDirectory(at: sidecarsDir, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var tasks: [MonitoredTask] = []
        var events: [RunEvent] = []
        let now = Int64(Date().timeIntervalSince1970)

        for dir in dirs {
            let cfgURL = dir.appendingPathComponent("sidecar.json")
            guard let data = try? Data(contentsOf: cfgURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["builtin"] as? String) == "schedule" else {
                continue
            }
            let id = dir.lastPathComponent
            let name = (json["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
            let args = json["args"] as? [String] ?? []
            let cronExpr = args.first ?? ""
            let taskKey = "antigravity:\(id)"
            let defaultLevel: NotifyLevel = (id == "daily-todo-reminder") ? .priority : .normal

            // Read sidecar.log tail (read-only) for last 7 days of runs, next_due_at, and latest status
            let logURL = dataRoot.appendingPathComponent(id).appendingPathComponent("logs/sidecar.log")
            let parsedLog = parseAntigravityLog(logURL, now: now)

            let task = MonitoredTask(
                taskKey: taskKey,
                source: .antigravity,
                nativeId: id,
                displayName: name,
                scheduleExpr: cronExpr,
                sourceStatus: "active",
                notifyLevel: defaultLevel,
                configPath: cfgURL.path,
                lastRunAt: parsedLog.lastCompletedAt,
                lastRunStatus: parsedLog.status,
                nextDueAt: parsedLog.nextDueAt,
                updatedAt: now
            )
            tasks.append(task)

            for run in parsedLog.runs {
                let marker = run.conversationId ?? String(run.completedAt)
                let summary = run.status == .error
                    ? "执行失败"
                    : "执行完成"
                events.append(RunEvent(
                    eventId: "\(taskKey):\(marker):\(run.completedAt)",
                    taskKey: taskKey,
                    taskName: name,
                    source: .antigravity,
                    status: run.status,
                    summary: summary,
                    logPath: fm.fileExists(atPath: logURL.path) ? logURL.path : "",
                    occurredAt: run.completedAt,
                    createdAt: now
                ))
            }
        }
        return (tasks, events)
    }

    private struct AgyRunEntry {
        let completedAt: Int64
        let status: RunStatus
        let conversationId: String?
    }

    private struct AgyLogSummary {
        var lastCompletedAt: Int64?
        var nextDueAt: Int64?
        var status: RunStatus = .unknown
        var runs: [AgyRunEntry] = []
    }

    private func parseAntigravityLog(_ url: URL, now: Int64) -> AgyLogSummary {
        var out = AgyLogSummary()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return out }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start: UInt64 = size > 262_144 ? size - 262_144 : 0
        try? fh.seek(toOffset: start)
        guard let raw = try? fh.readToEnd(), let text = String(data: raw, encoding: .utf8) else { return out }

        let utcFmt = DateFormatter()
        utcFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        utcFmt.timeZone = TimeZone(secondsFromGMT: 0)
        let sevenDaysAgo = now - 7 * 86400
        var lastConvId: String?

        for line in text.components(separatedBy: .newlines) {
            if line.contains("\"conversationId\""),
               let r = line.range(of: #""conversationId"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                let match = String(line[r])
                if let q1 = match.lastIndex(of: "\"") {
                    let sub = match[..<q1]
                    if let q0 = sub.lastIndex(of: "\"") {
                        lastConvId = String(sub[sub.index(after: q0)...])
                    }
                }
            }
            if line.contains("[schedule] Command completed successfully") {
                out.status = .success
                let prefix = String(line.prefix(19))
                if let d = utcFmt.date(from: prefix) {
                    let ts = Int64(d.timeIntervalSince1970)
                    out.lastCompletedAt = ts
                    if ts >= sevenDaysAgo {
                        out.runs.append(AgyRunEntry(completedAt: ts, status: .success, conversationId: lastConvId))
                    }
                }
            } else if line.contains("[schedule] Command failed") || line.contains("[schedule] Error") {
                out.status = .error
                let prefix = String(line.prefix(19))
                if let d = utcFmt.date(from: prefix) {
                    let ts = Int64(d.timeIntervalSince1970)
                    out.lastCompletedAt = ts
                    if ts >= sevenDaysAgo {
                        out.runs.append(AgyRunEntry(completedAt: ts, status: .error, conversationId: lastConvId))
                    }
                }
            } else if line.contains("Next execution scheduled"),
                      let atRange = line.range(of: #"\(at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) UTC\)"#, options: .regularExpression) {
                let frag = String(line[atRange])
                let cleaned = frag
                    .replacingOccurrences(of: "(at ", with: "")
                    .replacingOccurrences(of: " UTC)", with: "")
                if let d = utcFmt.date(from: cleaned) {
                    out.nextDueAt = Int64(d.timeIntervalSince1970)
                }
            }
        }
        return out
    }

    // MARK: - Codex Read-Only Watcher (TOML + codex.db RO)

    public func scanCodex() -> ([MonitoredTask], [RunEvent]) {
        let fm = FileManager.default
        let autoDir = homeDir.appendingPathComponent(".codex/automations")
        guard let dirs = try? fm.contentsOfDirectory(at: autoDir, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        let dbMeta = readCodexDBReadOnly()
        var tasks: [MonitoredTask] = []
        var events: [RunEvent] = []
        let now = Int64(Date().timeIntervalSince1970)

        for dir in dirs {
            let tomlURL = dir.appendingPathComponent("automation.toml")
            guard let text = try? String(contentsOf: tomlURL, encoding: .utf8) else { continue }
            let fields = parseSimpleTOML(text)
            let id = fields["id"] ?? dir.lastPathComponent
            let name = fields["name"] ?? id
            let rawStatus = (fields["status"] ?? "PAUSED").lowercased()
            let sourceStatus = rawStatus == "active" ? "active" : "paused"
            let rrule = fields["rrule"] ?? ""
            let taskKey = "codex:\(id)"
            let meta = dbMeta[id]

            tasks.append(MonitoredTask(
                taskKey: taskKey,
                source: .codex,
                nativeId: id,
                displayName: name,
                scheduleExpr: rrule,
                sourceStatus: sourceStatus,
                notifyLevel: .normal,
                configPath: tomlURL.path,
                lastRunAt: meta?.lastRunAt,
                lastRunStatus: meta?.lastStatus ?? .unknown,
                nextDueAt: meta?.nextRunAt,
                updatedAt: now
            ))

            if let run = meta?.latestRun {
                events.append(RunEvent(
                    eventId: "\(taskKey):\(run.threadId):\(run.updatedAt)",
                    taskKey: taskKey,
                    taskName: name,
                    source: .codex,
                    status: run.status,
                    summary: run.summary.isEmpty ? "Codex 定时任务已更新" : run.summary,
                    occurredAt: run.updatedAt,
                    createdAt: now
                ))
            }
        }
        return (tasks, events)
    }

    private struct CodexDBMeta {
        struct LatestRun {
            let threadId: String
            let status: RunStatus
            let summary: String
            let updatedAt: Int64
        }
        var lastRunAt: Int64?
        var nextRunAt: Int64?
        var lastStatus: RunStatus = .unknown
        var latestRun: LatestRun?
    }

    private func readCodexDBReadOnly() -> [String: CodexDBMeta] {
        let dbPath = homeDir.appendingPathComponent(".codex/sqlite/codex.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        var out: [String: CodexDBMeta] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, last_run_at, next_run_at FROM automations;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cId = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: cId)
                let lr = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : normalizeUnixSeconds(sqlite3_column_int64(stmt, 1))
                let nr = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : normalizeUnixSeconds(sqlite3_column_int64(stmt, 2))
                out[id] = CodexDBMeta(lastRunAt: lr, nextRunAt: nr)
            }
            sqlite3_finalize(stmt)
        }

        if sqlite3_prepare_v2(
            db,
            "SELECT automation_id, thread_id, status, COALESCE(inbox_summary, inbox_title, ''), updated_at FROM automation_runs ORDER BY updated_at DESC LIMIT 50;",
            -1, &stmt, nil
        ) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cAid = sqlite3_column_text(stmt, 0),
                      let cTid = sqlite3_column_text(stmt, 1) else { continue }
                let aid = String(cString: cAid)
                if out[aid]?.latestRun != nil { continue }
                let tid = String(cString: cTid)
                let stRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0).lowercased() } ?? ""
                let summary = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let updated = normalizeUnixSeconds(sqlite3_column_int64(stmt, 4))
                let status: RunStatus
                if stRaw.contains("fail") || stRaw.contains("err") {
                    status = .error
                } else if stRaw.contains("run") || stRaw.contains("pend") {
                    status = .running
                } else {
                    status = .success
                }
                var m = out[aid] ?? CodexDBMeta()
                m.lastStatus = status
                m.latestRun = CodexDBMeta.LatestRun(threadId: tid, status: status, summary: summary, updatedAt: updated)
                out[aid] = m
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    private func normalizeUnixSeconds(_ val: Int64) -> Int64 {
        // Handle millisecond timestamps cleanly
        return val > 10_000_000_000 ? val / 1000 : val
    }

    private func parseSimpleTOML(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            if !["id", "name", "status", "rrule", "target_thread_id", "updated_at"].contains(key) { continue }
            var val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            out[key] = val
        }
        return out
    }

    // MARK: - WorkBuddy Read-Only Watcher (~/.workbuddy/workbuddy.db & ~/.workbuddy-ai/workbuddy.db)

    public func scanWorkBuddy() -> ([MonitoredTask], [RunEvent]) {
        let candidates = [
            homeDir.appendingPathComponent(".workbuddy/workbuddy.db"),
            homeDir.appendingPathComponent(".workbuddy-ai/workbuddy.db")
        ]
        var tasksByKey: [String: MonitoredTask] = [:]
        var eventsById: [String: RunEvent] = [:]
        let now = Int64(Date().timeIntervalSince1970)
        let sevenDaysAgo = now - 7 * 86400

        for dbURL in candidates where FileManager.default.fileExists(atPath: dbURL.path) {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)

            var namesById: [String: String] = [:]
            var stmt: OpaquePointer?
            let autoSQL = """
            SELECT id, name, status, schedule_type, rrule, scheduled_at, last_run_at, next_run_at
            FROM automations
            WHERE deleted_at IS NULL;
            """
            if sqlite3_prepare_v2(db, autoSQL, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cId = sqlite3_column_text(stmt, 0) else { continue }
                    let id = String(cString: cId)
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
                    let rawStatus = sqlite3_column_text(stmt, 2).map { String(cString: $0).lowercased() } ?? "paused"
                    let schedType = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                    let rrule = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    let scheduledAt = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    let lastRunAt = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : normalizeUnixSeconds(sqlite3_column_int64(stmt, 6))
                    let nextRunAt = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : normalizeUnixSeconds(sqlite3_column_int64(stmt, 7))

                    let sourceStatus = (rawStatus == "active" || rawStatus == "enabled" || rawStatus == "running") ? "active" : "paused"
                    let scheduleExpr = !rrule.isEmpty ? rrule : (!scheduledAt.isEmpty ? scheduledAt : schedType)
                    let taskKey = "workbuddy:\(id)"
                    namesById[id] = name.isEmpty ? id : name

                    if tasksByKey[taskKey] == nil {
                        tasksByKey[taskKey] = MonitoredTask(
                            taskKey: taskKey,
                            source: .workbuddy,
                            nativeId: id,
                            displayName: name.isEmpty ? id : name,
                            scheduleExpr: scheduleExpr,
                            sourceStatus: sourceStatus,
                            notifyLevel: .normal,
                            configPath: dbURL.path,
                            lastRunAt: lastRunAt,
                            lastRunStatus: .unknown,
                            nextDueAt: nextRunAt,
                            updatedAt: now
                        )
                    }
                }
                sqlite3_finalize(stmt)
            }

            let runsSQL = """
            SELECT thread_id, automation_id, status, COALESCE(thread_title, ''), result_success, COALESCE(failure_code, ''), updated_at
            FROM automation_runs
            ORDER BY updated_at DESC
            LIMIT 100;
            """
            if sqlite3_prepare_v2(db, runsSQL, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cTid = sqlite3_column_text(stmt, 0),
                          let cAid = sqlite3_column_text(stmt, 1) else { continue }
                    let tid = String(cString: cTid)
                    let aid = String(cString: cAid)
                    let stRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0).lowercased() } ?? ""
                    let title = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                    let hasRes = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                    let resOk = hasRes ? sqlite3_column_int64(stmt, 4) != 0 : true
                    let failCode = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    let updatedAt = normalizeUnixSeconds(sqlite3_column_int64(stmt, 6))

                    let status: RunStatus
                    if !resOk || !failCode.isEmpty || stRaw.contains("fail") || stRaw.contains("err") {
                        status = .error
                    } else if stRaw.contains("run") || stRaw.contains("pend") {
                        status = .running
                    } else {
                        status = .success
                    }

                    let taskKey = "workbuddy:\(aid)"
                    if var existing = tasksByKey[taskKey], existing.lastRunStatus == .unknown {
                        existing.lastRunStatus = status
                        if existing.lastRunAt == nil { existing.lastRunAt = updatedAt }
                        tasksByKey[taskKey] = existing
                    }

                    if updatedAt >= sevenDaysAgo {
                        let evId = "\(taskKey):\(tid):\(updatedAt)"
                        if eventsById[evId] == nil {
                            let summary = !title.isEmpty
                                ? title
                                : (!failCode.isEmpty ? "失败：\(failCode)" : (status == .error ? "执行失败" : "执行完成"))
                            eventsById[evId] = RunEvent(
                                eventId: evId,
                                taskKey: taskKey,
                                taskName: namesById[aid] ?? aid,
                                source: .workbuddy,
                                status: status,
                                summary: summary,
                                logPath: homeDir.appendingPathComponent(".workbuddy/logs/automation.log").path,
                                occurredAt: updatedAt,
                                createdAt: now
                            )
                        }
                    }
                }
                sqlite3_finalize(stmt)
            }
        }

        return (Array(tasksByKey.values), Array(eventsById.values))
    }

    // MARK: - Claude Read-Only Watcher (~/.claude/scheduled-tasks & Claude Desktop sessions)

    public func scanClaude() -> ([MonitoredTask], [RunEvent]) {
        let fm = FileManager.default
        let now = Int64(Date().timeIntervalSince1970)
        var tasksByKey: [String: MonitoredTask] = [:]
        var eventsById: [String: RunEvent] = [:]

        // 1. ~/.claude/scheduled-tasks/ (subfolders with SKILL.md or task.json, plus top-level *.json)
        let schedDir = homeDir.appendingPathComponent(".claude/scheduled-tasks")
        if let entries = try? fm.contentsOfDirectory(at: schedDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    let skillURL = entry.appendingPathComponent("SKILL.md")
                    let jsonURL = entry.appendingPathComponent("task.json")
                    if fm.fileExists(atPath: jsonURL.path) {
                        ingestJSONTaskFile(jsonURL, source: .claude, now: now, tasksByKey: &tasksByKey, eventsById: &eventsById)
                    } else if let md = try? String(contentsOf: skillURL, encoding: .utf8) {
                        let meta = parseFrontmatter(md)
                        let id = entry.lastPathComponent
                        let name = meta["name"] ?? id
                        let sched = meta["schedule"] ?? meta["cron"] ?? meta["rrule"] ?? ""
                        let rawStatus = (meta["status"] ?? meta["enabled"] ?? "active").lowercased()
                        let sourceStatus = (rawStatus == "false" || rawStatus == "paused" || rawStatus == "disabled") ? "paused" : "active"
                        let key = "claude:\(id)"
                        tasksByKey[key] = MonitoredTask(
                            taskKey: key,
                            source: .claude,
                            nativeId: id,
                            displayName: name,
                            scheduleExpr: sched,
                            sourceStatus: sourceStatus,
                            notifyLevel: .normal,
                            configPath: skillURL.path,
                            updatedAt: now
                        )
                    }
                } else if entry.pathExtension.lowercased() == "json" {
                    ingestJSONTaskFile(entry, source: .claude, now: now, tasksByKey: &tasksByKey, eventsById: &eventsById)
                }
            }
        }

        // 2. ~/.claude/scheduled_tasks.json & ~/.claude/scheduled-tasks.json
        for name in ["scheduled_tasks.json", "scheduled-tasks.json"] {
            let fileURL = homeDir.appendingPathComponent(".claude").appendingPathComponent(name)
            if fm.fileExists(atPath: fileURL.path) {
                ingestJSONTaskFile(fileURL, source: .claude, now: now, tasksByKey: &tasksByKey, eventsById: &eventsById)
            }
        }

        // 3. Claude Desktop / Cowork local-agent-mode-sessions/**/scheduled_tasks.json (max depth 3)
        let appSupportBases = [
            homeDir.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions"),
            homeDir.appendingPathComponent("Library/Application Support/Claude-3p/local-agent-mode-sessions")
        ]
        for base in appSupportBases where fm.fileExists(atPath: base.path) {
            for fileURL in findMatchingJSONFiles(under: base, names: ["scheduled_tasks.json", "scheduled-tasks.json"], maxDepth: 3) {
                ingestJSONTaskFile(fileURL, source: .claude, now: now, tasksByKey: &tasksByKey, eventsById: &eventsById)
            }
        }

        return (Array(tasksByKey.values), Array(eventsById.values))
    }

    // MARK: - ZCode Read-Only Watcher (~/.zcode/cli/db/db.sqlite + ~/.zcode/v2 JSON/SQLite)

    public func scanZCode() -> ([MonitoredTask], [RunEvent]) {
        let fm = FileManager.default
        let now = Int64(Date().timeIntervalSince1970)
        let sevenDaysAgo = now - 7 * 86400
        var tasksByKey: [String: MonitoredTask] = [:]
        var eventsById: [String: RunEvent] = [:]

        // 1. ~/.zcode/cli/db/db.sqlite (workflow_definition + workflow_run, plus optional automations/scheduled_tasks tables)
        let cliDB = homeDir.appendingPathComponent(".zcode/cli/db/db.sqlite")
        if fm.fileExists(atPath: cliDB.path) {
            var db: OpaquePointer?
            if sqlite3_open_v2(cliDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                defer { sqlite3_close(db) }
                sqlite3_busy_timeout(db, 1000)

                var namesById: [String: String] = [:]
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT id, name, enabled, COALESCE(script_path, ''), COALESCE(meta_json, ''), time_updated FROM workflow_definition;", -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let cId = sqlite3_column_text(stmt, 0) else { continue }
                        let id = String(cString: cId)
                        let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? id
                        let enabled = sqlite3_column_int64(stmt, 2) != 0
                        let scriptPath = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                        let metaRaw = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                        var sched = ""
                        if let data = metaRaw.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            sched = (obj["cron"] as? String) ?? (obj["schedule"] as? String) ?? (obj["rrule"] as? String) ?? ""
                        }
                        let key = "zcode:\(id)"
                        namesById[id] = name.isEmpty ? id : name
                        tasksByKey[key] = MonitoredTask(
                            taskKey: key,
                            source: .zcode,
                            nativeId: id,
                            displayName: name.isEmpty ? id : name,
                            scheduleExpr: sched,
                            sourceStatus: enabled ? "active" : "paused",
                            notifyLevel: .normal,
                            configPath: scriptPath.isEmpty ? cliDB.path : scriptPath,
                            updatedAt: now
                        )
                    }
                    sqlite3_finalize(stmt)
                }

                if sqlite3_prepare_v2(db, "SELECT id, COALESCE(definition_id, ''), COALESCE(name, ''), status, COALESCE(failure_json, ''), COALESCE(time_completed, time_updated, time_created) FROM workflow_run ORDER BY COALESCE(time_completed, time_updated, time_created) DESC LIMIT 100;", -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let cRunId = sqlite3_column_text(stmt, 0) else { continue }
                        let runId = String(cString: cRunId)
                        let defId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? runId
                        let runName = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                        let stRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0).lowercased() } ?? ""
                        let failJson = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                        let ts = normalizeUnixSeconds(sqlite3_column_int64(stmt, 5))

                        let status: RunStatus
                        if !failJson.isEmpty || stRaw.contains("fail") || stRaw.contains("err") {
                            status = .error
                        } else if stRaw.contains("run") || stRaw.contains("pend") {
                            status = .running
                        } else {
                            status = .success
                        }

                        let taskKey = "zcode:\(defId)"
                        if var existing = tasksByKey[taskKey], existing.lastRunStatus == .unknown {
                            existing.lastRunStatus = status
                            existing.lastRunAt = ts
                            tasksByKey[taskKey] = existing
                        }
                        if ts >= sevenDaysAgo {
                            let evId = "\(taskKey):\(runId):\(ts)"
                            eventsById[evId] = RunEvent(
                                eventId: evId,
                                taskKey: taskKey,
                                taskName: namesById[defId] ?? (runName.isEmpty ? defId : runName),
                                source: .zcode,
                                status: status,
                                summary: status == .error ? "执行失败" : "执行完成",
                                occurredAt: ts,
                                createdAt: now
                            )
                        }
                    }
                    sqlite3_finalize(stmt)
                }
            }
        }

        // 2. ~/.zcode/v2/{automations,scheduled-tasks,scheduled_tasks}.json & ~/.zcode/automations/*.json
        for rel in [
            ".zcode/v2/automations.json",
            ".zcode/v2/scheduled-tasks.json",
            ".zcode/v2/scheduled_tasks.json",
            ".zcode/v2/bot-config.v3.json"
        ] {
            let fileURL = homeDir.appendingPathComponent(rel)
            if fm.fileExists(atPath: fileURL.path) {
                ingestJSONTaskFile(fileURL, source: .zcode, now: now, tasksByKey: &tasksByKey, eventsById: &eventsById)
            }
        }
        let zcodeAutoDir = homeDir.appendingPathComponent(".zcode/automations")
        if let files = try? fm.contentsOfDirectory(at: zcodeAutoDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension.lowercased() == "json" {
                ingestJSONTaskFile(f, source: .zcode, now: now, tasksByKey: &tasksByKey, eventsById: &eventsById)
            }
        }

        return (Array(tasksByKey.values), Array(eventsById.values))
    }

    // MARK: - Shared JSON / Frontmatter Helpers for Claude & ZCode

    private func ingestJSONTaskFile(
        _ url: URL,
        source: TaskSource,
        now: Int64,
        tasksByKey: inout [String: MonitoredTask],
        eventsById: inout [String: RunEvent]
    ) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        var items: [[String: Any]] = []
        if let arr = root as? [[String: Any]] {
            items = arr
        } else if let dict = root as? [String: Any] {
            if let arr = dict["tasks"] as? [[String: Any]] {
                items = arr
            } else if let arr = dict["scheduledTasks"] as? [[String: Any]] {
                items = arr
            } else if let arr = dict["automations"] as? [[String: Any]] {
                items = arr
            } else if let arr = dict["bots"] as? [[String: Any]] {
                // Only include bots that actually have a schedule/cron
                items = arr.filter { $0["cron"] != nil || $0["schedule"] != nil || $0["rrule"] != nil }
            } else if dict["id"] != nil || dict["name"] != nil || dict["cron"] != nil || dict["schedule"] != nil {
                items = [dict]
            }
        }

        let sevenDaysAgo = now - 7 * 86400
        for obj in items {
            let id = (obj["id"] as? String)
                ?? (obj["taskId"] as? String)
                ?? (obj["name"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            guard !id.isEmpty else { continue }
            let name = (obj["name"] as? String)
                ?? (obj["title"] as? String)
                ?? id
            let sched = (obj["cronExpression"] as? String)
                ?? (obj["cron"] as? String)
                ?? (obj["rrule"] as? String)
                ?? (obj["schedule"] as? String)
                ?? ""
            let enabledBool = obj["enabled"] as? Bool
            let statusStr = (obj["status"] as? String)?.lowercased()
            let isPaused = (enabledBool == false)
                || statusStr == "paused"
                || statusStr == "disabled"
                || statusStr == "inactive"
            let sourceStatus = isPaused ? "paused" : "active"

            let lastRunAt = parseFlexibleTimestamp(obj["lastRunAt"] ?? obj["last_run_at"])
            let nextDueAt = parseFlexibleTimestamp(obj["nextRunAt"] ?? obj["next_run_at"])
            var lastStatus: RunStatus = .unknown
            if let st = (obj["lastRunStatus"] as? String ?? obj["last_run_status"] as? String)?.lowercased() {
                lastStatus = mapRunStatus(st)
            }

            let taskKey = "\(source.rawValue):\(id)"

            if let runs = obj["runs"] as? [[String: Any]] {
                for r in runs {
                    let ts = parseFlexibleTimestamp(r["completedAt"] ?? r["updatedAt"] ?? r["occurredAt"] ?? r["timestamp"] ?? r["created_at"]) ?? now
                    let st = mapRunStatus((r["status"] as? String ?? "success").lowercased())
                    if lastStatus == .unknown { lastStatus = st }
                    guard ts >= sevenDaysAgo else { continue }
                    let runId = (r["id"] as? String) ?? String(ts)
                    let summary = (r["summary"] as? String) ?? (r["error"] as? String) ?? (st == .error ? "执行失败" : "执行完成")
                    let evId = "\(taskKey):\(runId):\(ts)"
                    eventsById[evId] = RunEvent(
                        eventId: evId,
                        taskKey: taskKey,
                        taskName: name,
                        source: source,
                        status: st,
                        summary: summary,
                        occurredAt: ts,
                        createdAt: now
                    )
                }
            } else if let lr = lastRunAt, lr >= sevenDaysAgo {
                let st = lastStatus == .unknown ? .success : lastStatus
                let evId = "\(taskKey):last:\(lr)"
                eventsById[evId] = RunEvent(
                    eventId: evId,
                    taskKey: taskKey,
                    taskName: name,
                    source: source,
                    status: st,
                    summary: st == .error ? "执行失败" : "执行完成",
                    occurredAt: lr,
                    createdAt: now
                )
            }

            tasksByKey[taskKey] = MonitoredTask(
                taskKey: taskKey,
                source: source,
                nativeId: id,
                displayName: name,
                scheduleExpr: sched,
                sourceStatus: sourceStatus,
                notifyLevel: .normal,
                configPath: url.path,
                lastRunAt: lastRunAt,
                lastRunStatus: lastStatus,
                nextDueAt: nextDueAt,
                updatedAt: now
            )
        }
    }

    private func mapRunStatus(_ raw: String) -> RunStatus {
        if raw.contains("fail") || raw.contains("err") { return .error }
        if raw.contains("run") || raw.contains("pend") { return .running }
        if raw.contains("miss") { return .missed }
        if raw.contains("attn") || raw.contains("warn") { return .attention }
        return .success
    }

    private func parseFlexibleTimestamp(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return normalizeUnixSeconds(i) }
        if let i = value as? Int { return normalizeUnixSeconds(Int64(i)) }
        if let d = value as? Double { return normalizeUnixSeconds(Int64(d)) }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int64(trimmed) { return normalizeUnixSeconds(i) }
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let dt = isoFrac.date(from: trimmed) { return Int64(dt.timeIntervalSince1970) }
            let iso = ISO8601DateFormatter()
            if let dt = iso.date(from: trimmed) { return Int64(dt.timeIntervalSince1970) }
        }
        return nil
    }

    private func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let k = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var v = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v
        }
        return out
    }

    private func findMatchingJSONFiles(under root: URL, names: Set<String>, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return
            }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    walk(entry, depth: depth + 1)
                } else if names.contains(entry.lastPathComponent.lowercased()) {
                    results.append(entry)
                }
            }
        }
        walk(root, depth: 0)
        return results
    }

    // MARK: - LaunchAgents (Lmemory jobs only by default)

    public func scanLaunchAgents() -> [MonitoredTask] {
        let fm = FileManager.default
        let agentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        guard let files = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [MonitoredTask] = []
        let now = Int64(Date().timeIntervalSince1970)
        for url in files where url.pathExtension == "plist" {
            let name = url.lastPathComponent.lowercased()
            guard name.contains("lmemory") else { continue }
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = dict["Label"] as? String else {
                continue
            }
            var sched = ""
            if let cal = dict["StartCalendarInterval"] as? [String: Any],
               let h = cal["Hour"] as? Int, let m = cal["Minute"] as? Int {
                sched = String(format: "每日 %02d:%02d", h, m)
            }
            out.append(MonitoredTask(
                taskKey: "launchd:\(label)",
                source: .launchd,
                nativeId: label,
                displayName: "Lmemory 每日维护",
                scheduleExpr: sched,
                sourceStatus: "active",
                notifyLevel: .normal,
                configPath: url.path,
                updatedAt: now
            ))
        }
        return out
    }

    // MARK: - Local Drop-in Inbox (API-LOCAL-01)

    public func drainInbox() -> [RunEvent] {
        ensureInboxDir()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        var out: [RunEvent] = []
        let rejectedDir = inboxDir.appendingPathComponent("rejected")
        let now = Int64(Date().timeIntervalSince1970)

        for url in files where url.pathExtension == "json" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= 65536,
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventId = obj["event_id"] as? String, !eventId.isEmpty,
                  let taskId = obj["task_id"] as? String, !taskId.isEmpty,
                  let statusRaw = obj["status"] as? String,
                  let status = RunStatus(rawValue: statusRaw) else {
                try? fm.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
                try? fm.moveItem(at: url, to: rejectedDir.appendingPathComponent(url.lastPathComponent))
                continue
            }
            let src = TaskSource(rawValue: (obj["source"] as? String) ?? "custom") ?? .custom
            let taskName = (obj["task_name"] as? String) ?? taskId
            let summary = (obj["summary"] as? String) ?? ""
            let artifactPath = (obj["artifact_path"] as? String) ?? ""
            let logPath = (obj["log_path"] as? String) ?? ""
            out.append(RunEvent(
                eventId: eventId,
                taskKey: "\(src.rawValue):\(taskId)",
                taskName: taskName,
                source: src,
                status: status,
                summary: summary,
                artifactPath: artifactPath,
                logPath: logPath,
                occurredAt: now,
                createdAt: now
            ))
            try? fm.removeItem(at: url)
        }
        return out
    }

    // MARK: - Lmemory Health Monitor

    public func readLmemoryHealth(configuredVault: String) -> LmemoryHealth {
        let vault = resolveVaultPath(configuredVault: configuredVault)
        guard !vault.isEmpty else {
            return LmemoryHealth(state: .missing, detail: "Lmemory 未安装或未配置知识库 — 点击一键部署")
        }
        let nightlyURL = URL(fileURLWithPath: vault).appendingPathComponent("90 系统文件/自动化/夜间维护.md")
        guard let text = try? String(contentsOf: nightlyURL, encoding: .utf8) else {
            return LmemoryHealth(state: .unknown, detail: "Lmemory 已连接（暂无维护日志）", vaultPath: vault)
        }
        var status = ""
        var at = ""
        var lane = ""
        for line in text.components(separatedBy: .newlines).prefix(20) {
            if line.hasPrefix("nightly:") { status = line.replacingOccurrences(of: "nightly:", with: "").trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("nightly_at:") { at = line.replacingOccurrences(of: "nightly_at:", with: "").trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("lane:") { lane = line.replacingOccurrences(of: "lane:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        if status == "failed" {
            return LmemoryHealth(
                state: .failed,
                detail: "Lmemory 维护失败（\(at.prefix(16)) · \(lane)）— 点击查看日志",
                logPath: nightlyURL.path,
                vaultPath: vault
            )
        }
        return LmemoryHealth(
            state: .healthy,
            detail: "Lmemory 同步正常（最近维护 \(at.prefix(16))）",
            logPath: nightlyURL.path,
            vaultPath: vault
        )
    }

    public func resolveVaultPath(configuredVault: String) -> String {
        let fm = FileManager.default
        if !configuredVault.isEmpty && fm.fileExists(atPath: configuredVault) {
            return configuredVault
        }
        // Read from Lmemory's own state/plist if present (never hardcode a personal path)
        let plistURL = homeDir.appendingPathComponent("Library/LaunchAgents/local.dsh-lmemory.daily-evolution.plist")
        if let data = try? Data(contentsOf: plistURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let env = dict["EnvironmentVariables"] as? [String: String],
           let v = env["OBSIDIAN_VAULT"], fm.fileExists(atPath: v) {
            return v
        }
        return ""
    }
}
