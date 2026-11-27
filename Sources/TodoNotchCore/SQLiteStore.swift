import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum EventInsertResult: Equatable, Sendable {
    case inserted
    case duplicate
    case failed
}

public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.libo.TodoNotch.db")
    public let path: String

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw NSError(domain: "SQLiteStore", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.db = handle
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sql error"
            sqlite3_free(errMsg)
            throw NSError(domain: "SQLiteStore", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func migrate() throws {
        try queue.sync {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=2000;")
            // Strictly NO FOREIGN KEY constraints per engineering standard
            try exec("""
            CREATE TABLE IF NOT EXISTS monitored_tasks (
              task_key        TEXT PRIMARY KEY,
              source          TEXT NOT NULL,
              native_id       TEXT NOT NULL,
              display_name    TEXT NOT NULL,
              schedule_expr   TEXT NOT NULL DEFAULT '',
              source_status   TEXT NOT NULL DEFAULT 'active',
              notify_level    TEXT NOT NULL DEFAULT 'normal',
              config_path     TEXT NOT NULL,
              last_run_at     INTEGER,
              last_run_status TEXT NOT NULL DEFAULT 'unknown',
              next_due_at     INTEGER,
              updated_at      INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_source_status ON monitored_tasks (source, source_status);
            CREATE INDEX IF NOT EXISTS idx_tasks_due ON monitored_tasks (source_status, next_due_at);

            CREATE TABLE IF NOT EXISTS run_events (
              event_id        TEXT PRIMARY KEY,
              task_key        TEXT NOT NULL,
              task_name       TEXT NOT NULL,
              source          TEXT NOT NULL,
              status          TEXT NOT NULL,
              summary         TEXT NOT NULL,
              artifact_path   TEXT NOT NULL DEFAULT '',
              log_path        TEXT NOT NULL DEFAULT '',
              is_read         INTEGER NOT NULL DEFAULT 0,
              push_status     TEXT NOT NULL DEFAULT 'skipped',
              push_error      TEXT NOT NULL DEFAULT '',
              occurred_at     INTEGER NOT NULL,
              created_at      INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_events_occurred ON run_events (occurred_at DESC);
            CREATE INDEX IF NOT EXISTS idx_events_unread ON run_events (is_read, status, occurred_at DESC);
            CREATE INDEX IF NOT EXISTS idx_events_task ON run_events (task_key, occurred_at DESC);

            CREATE TABLE IF NOT EXISTS app_settings (
              key        TEXT PRIMARY KEY,
              value      TEXT NOT NULL,
              updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS audit_logs (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              action     TEXT NOT NULL,
              target     TEXT NOT NULL,
              result     TEXT NOT NULL,
              detail     TEXT NOT NULL,
              created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs (created_at DESC);

            CREATE TABLE IF NOT EXISTS todo_dispatches (
              todo_key              TEXT PRIMARY KEY,
              dispatch_id           TEXT NOT NULL,
              project               TEXT NOT NULL,
              todo_text             TEXT NOT NULL,
              agent                 TEXT NOT NULL,
              session_id            TEXT NOT NULL,
              cwd                   TEXT NOT NULL,
              transcript_path       TEXT NOT NULL DEFAULT '',
              log_path              TEXT NOT NULL DEFAULT '',
              status                TEXT NOT NULL,
              summary               TEXT NOT NULL DEFAULT '',
              dispatched_at         INTEGER NOT NULL,
              updated_at            INTEGER NOT NULL,
              last_transcript_mtime INTEGER NOT NULL DEFAULT 0,
              pid                   INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_dispatches_status ON todo_dispatches (status, updated_at DESC);
            PRAGMA user_version = 2;
            """)
        }
    }

    // MARK: - Monitored Tasks

    public func upsertTask(_ task: MonitoredTask, preserveNotifyLevel: Bool = true) {
        queue.sync {
            let sql: String
            if preserveNotifyLevel {
                sql = """
                INSERT INTO monitored_tasks (
                  task_key, source, native_id, display_name, schedule_expr, source_status,
                  notify_level, config_path, last_run_at, last_run_status, next_due_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(task_key) DO UPDATE SET
                  display_name = excluded.display_name,
                  schedule_expr = excluded.schedule_expr,
                  source_status = excluded.source_status,
                  config_path = excluded.config_path,
                  last_run_at = COALESCE(excluded.last_run_at, monitored_tasks.last_run_at),
                  last_run_status = CASE WHEN excluded.last_run_status != 'unknown' THEN excluded.last_run_status ELSE monitored_tasks.last_run_status END,
                  next_due_at = COALESCE(excluded.next_due_at, monitored_tasks.next_due_at),
                  updated_at = excluded.updated_at;
                """
            } else {
                sql = """
                INSERT OR REPLACE INTO monitored_tasks (
                  task_key, source, native_id, display_name, schedule_expr, source_status,
                  notify_level, config_path, last_run_at, last_run_status, next_due_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, task.taskKey)
            bindText(stmt, 2, task.source.rawValue)
            bindText(stmt, 3, task.nativeId)
            bindText(stmt, 4, task.displayName)
            bindText(stmt, 5, task.scheduleExpr)
            bindText(stmt, 6, task.sourceStatus)
            bindText(stmt, 7, task.notifyLevel.rawValue)
            bindText(stmt, 8, task.configPath)
            if let lr = task.lastRunAt { sqlite3_bind_int64(stmt, 9, lr) } else { sqlite3_bind_null(stmt, 9) }
            bindText(stmt, 10, task.lastRunStatus.rawValue)
            if let nd = task.nextDueAt { sqlite3_bind_int64(stmt, 11, nd) } else { sqlite3_bind_null(stmt, 11) }
            sqlite3_bind_int64(stmt, 12, task.updatedAt)
            sqlite3_step(stmt)
        }
    }

    public func updateTaskNotifyLevel(taskKey: String, level: NotifyLevel) {
        queue.sync {
            let sql = "UPDATE monitored_tasks SET notify_level = ?, updated_at = ? WHERE task_key = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, level.rawValue)
            sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970))
            bindText(stmt, 3, taskKey)
            sqlite3_step(stmt)
        }
    }

    public func listTasks() -> [MonitoredTask] {
        queue.sync {
            let sql = """
            SELECT task_key, source, native_id, display_name, schedule_expr, source_status,
                   notify_level, config_path, last_run_at, last_run_status, next_due_at, updated_at
            FROM monitored_tasks
            WHERE source_status != 'removed'
            ORDER BY CASE source_status WHEN 'active' THEN 0 ELSE 1 END,
                     CASE notify_level WHEN 'priority' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
                     display_name ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [MonitoredTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(MonitoredTask(
                    taskKey: colText(stmt, 0),
                    source: TaskSource(rawValue: colText(stmt, 1)) ?? .custom,
                    nativeId: colText(stmt, 2),
                    displayName: colText(stmt, 3),
                    scheduleExpr: colText(stmt, 4),
                    sourceStatus: colText(stmt, 5),
                    notifyLevel: NotifyLevel(rawValue: colText(stmt, 6)) ?? .normal,
                    configPath: colText(stmt, 7),
                    lastRunAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8),
                    lastRunStatus: RunStatus(rawValue: colText(stmt, 9)) ?? .unknown,
                    nextDueAt: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 10),
                    updatedAt: sqlite3_column_int64(stmt, 11)
                ))
            }
            return out
        }
    }

    public func markRemovedExcept(source: TaskSource, activeKeys: Set<String>) {
        queue.sync {
            let existing = fetchKeys(source: source)
            let now = Int64(Date().timeIntervalSince1970)
            for key in existing where !activeKeys.contains(key) {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE monitored_tasks SET source_status = 'removed', updated_at = ? WHERE task_key = ?;", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, now)
                    bindText(stmt, 2, key)
                    sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
    }

    private func fetchKeys(source: TaskSource) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT task_key FROM monitored_tasks WHERE source = ?;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, source.rawValue)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(colText(stmt, 0)) }
        return out
    }

    // MARK: - Run Events (Idempotent + Rolling Retention)

    public func persistEvent(_ ev: RunEvent) -> EventInsertResult {
        queue.sync {
            switch writeEventLocked(ev) {
            case .some(true): return .inserted
            case .some(false): return .duplicate
            case .none: return .failed
            }
        }
    }

    /// An existing event ID produces no duplicate notification.
    @discardableResult
    public func insertEventIfNew(_ ev: RunEvent) -> Bool {
        persistEvent(ev) == .inserted
    }

    private func writeEventLocked(_ ev: RunEvent, replacingUnconfirmed: Bool = false) -> Bool? {
        let conflict = replacingUnconfirmed ? """
            DO UPDATE SET status = excluded.status, summary = excluded.summary,
                artifact_path = excluded.artifact_path, log_path = excluded.log_path,
                occurred_at = excluded.occurred_at
            WHERE run_events.task_key = excluded.task_key AND run_events.source = excluded.source
                AND run_events.status = 'attention' AND run_events.summary = ?
            """ : "DO NOTHING"
        let sql = """
        INSERT INTO run_events (
          event_id, task_key, task_name, source, status, summary,
          artifact_path, log_path, is_read, push_status, push_error, occurred_at, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(event_id) \(conflict);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, ev.eventId)
        bindText(stmt, 2, ev.taskKey)
        bindText(stmt, 3, ev.taskName)
        bindText(stmt, 4, ev.source.rawValue)
        bindText(stmt, 5, ev.status.rawValue)
        bindText(stmt, 6, ev.summary)
        bindText(stmt, 7, ev.artifactPath)
        bindText(stmt, 8, ev.logPath)
        sqlite3_bind_int(stmt, 9, ev.isRead ? 1 : 0)
        bindText(stmt, 10, ev.pushStatus)
        bindText(stmt, 11, ev.pushError)
        sqlite3_bind_int64(stmt, 12, ev.occurredAt)
        sqlite3_bind_int64(stmt, 13, ev.createdAt)
        if replacingUnconfirmed { bindText(stmt, 14, TodoDispatchRunner.unconfirmedAntigravitySummary) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        let changed = sqlite3_changes(db) > 0
        if changed { pruneEventsLocked(now: ev.createdAt) }
        return changed
    }

    private static let unconfirmedAntigravityHistory = """
    source = 'antigravity' AND status = 'attention' AND summary = ?1
      AND event_id GLOB 'dispatch:*'
    """

    private func pruneEventsLocked(now: Int64) {
        let pending = Self.unconfirmedAntigravityHistory
        // Pending dispatches are correlation records. Ordinary history limits apply once their receipts arrive.
        let sql = """
        DELETE FROM run_events
        WHERE NOT (\(pending))
          AND (occurred_at < ?2 OR event_id NOT IN (
            SELECT event_id FROM run_events
            WHERE NOT (\(pending)) AND occurred_at >= ?2
            ORDER BY occurred_at DESC, event_id DESC LIMIT 500
          ));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, TodoDispatchRunner.unconfirmedAntigravitySummary)
        sqlite3_bind_int64(stmt, 2, now - 30 * 86400)
        sqlite3_step(stmt)
    }

    public func listUnconfirmedAntigravityHistory() -> [RunEvent] {
        queue.sync {
            let sql = """
            SELECT event_id, task_key, task_name, source, status, summary, artifact_path, log_path,
                   is_read, push_status, push_error, occurred_at, created_at
            FROM run_events
            WHERE \(Self.unconfirmedAntigravityHistory);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, TodoDispatchRunner.unconfirmedAntigravitySummary)
            return readEventRows(stmt)
        }
    }

    public func repairUnconfirmedAntigravityHistory(_ event: RunEvent) -> Bool {
        guard event.source == .antigravity, event.eventId.hasPrefix("dispatch:") else { return false }
        return queue.sync {
            // An old run may no longer occupy the task's latest-dispatch row.
            writeEventLocked(event, replacingUnconfirmed: true) == true
        }
    }

    public func updateEventPush(eventId: String, status: String, error: String) {
        queue.sync {
            let sql = "UPDATE run_events SET push_status = ?, push_error = ? WHERE event_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, status)
            bindText(stmt, 2, error)
            bindText(stmt, 3, eventId)
            sqlite3_step(stmt)
        }
    }

    public func markEventRead(eventId: String) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE run_events SET is_read = 1 WHERE event_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, eventId)
            sqlite3_step(stmt)
        }
    }

    public func markAllEventsRead() {
        queue.sync {
            try? exec("UPDATE run_events SET is_read = 1 WHERE is_read = 0;")
        }
    }

    public func listEvents(limit: Int = 60) -> [RunEvent] {
        queue.sync {
            let sql = """
            SELECT event_id, task_key, task_name, source, status, summary,
                   artifact_path, log_path, is_read, push_status, push_error, occurred_at, created_at
            FROM run_events ORDER BY occurred_at DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            return readEventRows(stmt)
        }
    }

    public func listRecentWeekEvents(taskKey: String, now: Int64 = Int64(Date().timeIntervalSince1970)) -> [RunEvent] {
        queue.sync {
            let cutoff = now - 7 * 86400
            let sql = """
            SELECT event_id, task_key, task_name, source, status, summary,
                   artifact_path, log_path, is_read, push_status, push_error, occurred_at, created_at
            FROM run_events
            WHERE task_key = ? AND occurred_at >= ?
            ORDER BY occurred_at DESC LIMIT 30;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, taskKey)
            sqlite3_bind_int64(stmt, 2, cutoff)
            return readEventRows(stmt)
        }
    }

    public func listAllRecentWeekEvents(now: Int64 = Int64(Date().timeIntervalSince1970)) -> [RunEvent] {
        queue.sync {
            let cutoff = now - 7 * 86400
            let sql = """
            SELECT event_id, task_key, task_name, source, status, summary,
                   artifact_path, log_path, is_read, push_status, push_error, occurred_at, created_at
            FROM run_events
            WHERE occurred_at >= ?
            ORDER BY occurred_at DESC LIMIT 400;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoff)
            return readEventRows(stmt)
        }
    }

    private func readEventRows(_ stmt: OpaquePointer?) -> [RunEvent] {
        var out: [RunEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(RunEvent(
                eventId: colText(stmt, 0),
                taskKey: colText(stmt, 1),
                taskName: colText(stmt, 2),
                source: TaskSource(rawValue: colText(stmt, 3)) ?? .custom,
                status: RunStatus(rawValue: colText(stmt, 4)) ?? .unknown,
                summary: colText(stmt, 5),
                artifactPath: colText(stmt, 6),
                logPath: colText(stmt, 7),
                isRead: sqlite3_column_int(stmt, 8) != 0,
                pushStatus: colText(stmt, 9),
                pushError: colText(stmt, 10),
                occurredAt: sqlite3_column_int64(stmt, 11),
                createdAt: sqlite3_column_int64(stmt, 12)
            ))
        }
        return out
    }

    public func unreadCounts() -> [RunStatus: Int] {
        queue.sync {
            let sql = "SELECT status, COUNT(*) FROM run_events WHERE is_read = 0 GROUP BY status;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var out: [RunStatus: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let st = RunStatus(rawValue: colText(stmt, 0)) {
                    out[st] = Int(sqlite3_column_int(stmt, 1))
                }
            }
            return out
        }
    }

    // MARK: - Settings & Audit Logs

    public func setSetting(_ key: String, value: String) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
            sqlite3_step(stmt)
        }
    }

    public func getAllSettings() -> [String: String] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT key, value FROM app_settings;", -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var out: [String: String] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[colText(stmt, 0)] = colText(stmt, 1)
            }
            return out
        }
    }

    public func loadConfig() -> AppConfig {
        let m = getAllSettings()
        return AppConfig(
            vaultPath: m["vault_path"] ?? "",
            onboardingDone: m["onboarding_done"] == "1",
            screenMode: m["screen_mode"] ?? "all",
            dndEnabled: m["dnd_enabled"] == "1",
            dndStart: m["dnd_start"] ?? "22:00",
            dndEnd: m["dnd_end"] ?? "08:30",
            focusMode: m["focus_mode"] == "1",
            webhookEnabled: m["webhook_enabled"] == "1",
            webhookKind: WebhookKind(rawValue: m["webhook_kind"] ?? "") ?? .feishu,
            languageMode: LanguageMode(rawValue: m["language_mode"] ?? "") ?? .auto,
            detectedIPCountry: m["detected_ip_country"] ?? ""
        )
    }

    public func saveConfig(_ cfg: AppConfig) {
        setSetting("vault_path", value: cfg.vaultPath)
        setSetting("onboarding_done", value: cfg.onboardingDone ? "1" : "0")
        setSetting("screen_mode", value: cfg.screenMode)
        setSetting("dnd_enabled", value: cfg.dndEnabled ? "1" : "0")
        setSetting("dnd_start", value: cfg.dndStart)
        setSetting("dnd_end", value: cfg.dndEnd)
        setSetting("focus_mode", value: cfg.focusMode ? "1" : "0")
        setSetting("webhook_enabled", value: cfg.webhookEnabled ? "1" : "0")
        setSetting("webhook_kind", value: cfg.webhookKind.rawValue)
        setSetting("language_mode", value: cfg.languageMode.rawValue)
        setSetting("detected_ip_country", value: cfg.detectedIPCountry)
    }

    public func appendAudit(action: String, target: String, result: String, detail: String) {
        queue.sync {
            let now = Int64(Date().timeIntervalSince1970)
            let sql = "INSERT INTO audit_logs (action, target, result, detail, created_at) VALUES (?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, action)
            bindText(stmt, 2, target)
            bindText(stmt, 3, result)
            bindText(stmt, 4, String(detail.prefix(500)))
            sqlite3_bind_int64(stmt, 5, now)
            sqlite3_step(stmt)
            try? exec("DELETE FROM audit_logs WHERE created_at < \(now - 30 * 86400);")
        }
    }

    public func listAuditCount() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM audit_logs;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    // MARK: - Todo Dispatches

    public func upsertTodoDispatch(_ rec: TodoDispatchRecord) {
        queue.sync { _ = upsertTodoDispatchLocked(rec) }
    }

    private func upsertTodoDispatchLocked(_ rec: TodoDispatchRecord) -> Bool {
        let sql = """
        INSERT OR REPLACE INTO todo_dispatches (
          todo_key, dispatch_id, project, todo_text, agent, session_id, cwd,
          transcript_path, log_path, status, summary, dispatched_at, updated_at,
          last_transcript_mtime, pid
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, rec.todoKey)
        bindText(stmt, 2, rec.dispatchId)
        bindText(stmt, 3, rec.project)
        bindText(stmt, 4, String(rec.todoText.prefix(500)))
        bindText(stmt, 5, rec.agent)
        bindText(stmt, 6, rec.sessionId)
        bindText(stmt, 7, rec.cwd)
        bindText(stmt, 8, rec.transcriptPath)
        bindText(stmt, 9, rec.logPath)
        bindText(stmt, 10, rec.status.rawValue)
        bindText(stmt, 11, String(rec.summary.prefix(500)))
        sqlite3_bind_int64(stmt, 12, rec.dispatchedAt)
        sqlite3_bind_int64(stmt, 13, rec.updatedAt)
        sqlite3_bind_int64(stmt, 14, rec.lastTranscriptMtime)
        sqlite3_bind_int(stmt, 15, rec.pid)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        try? exec("DELETE FROM todo_dispatches WHERE updated_at < \(rec.updatedAt - 30 * 86400);")
        return true
    }

    /// Keep state and a pending or final history entry together, keyed by the native dispatch.
    public func saveAntigravityDispatchAndHistory(_ rec: TodoDispatchRecord, event: RunEvent) -> Bool {
        guard rec.agent == "antigravity", event.source == .antigravity,
              event.eventId == "dispatch:\(rec.dispatchId)",
              event.taskKey == rec.todoKey || event.taskKey == "dispatch:\(rec.todoKey)" else { return false }
        return queue.sync {
            do {
                try exec("BEGIN IMMEDIATE;")
            } catch {
                return false
            }
            var committed = false
            defer { if !committed { try? exec("ROLLBACK;") } }
            var stmt: OpaquePointer?
            let sql = "SELECT 1 FROM todo_dispatches WHERE todo_key = ? AND dispatch_id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            bindText(stmt, 1, rec.todoKey)
            bindText(stmt, 2, rec.dispatchId)
            let current = sqlite3_step(stmt) == SQLITE_ROW
            sqlite3_finalize(stmt)
            guard current, upsertTodoDispatchLocked(rec), writeEventLocked(event, replacingUnconfirmed: true) != nil else {
                return false
            }
            do {
                try exec("COMMIT;")
                committed = true
                return true
            } catch {
                return false
            }
        }
    }

    public func listTodoDispatches() -> [TodoDispatchRecord] {
        queue.sync {
            let sql = """
            SELECT todo_key, dispatch_id, project, todo_text, agent, session_id, cwd,
                   transcript_path, log_path, status, summary, dispatched_at, updated_at,
                   last_transcript_mtime, pid
            FROM todo_dispatches
            ORDER BY updated_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [TodoDispatchRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(readDispatchRow(stmt))
            }
            return out
        }
    }

    public func getTodoDispatch(todoKey: String) -> TodoDispatchRecord? {
        queue.sync {
            let sql = """
            SELECT todo_key, dispatch_id, project, todo_text, agent, session_id, cwd,
                   transcript_path, log_path, status, summary, dispatched_at, updated_at,
                   last_transcript_mtime, pid
            FROM todo_dispatches WHERE todo_key = ? LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, todoKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readDispatchRow(stmt)
        }
    }

    public func deleteTodoDispatch(todoKey: String) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM todo_dispatches WHERE todo_key = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, todoKey)
            sqlite3_step(stmt)
        }
    }

    private func readDispatchRow(_ stmt: OpaquePointer?) -> TodoDispatchRecord {
        TodoDispatchRecord(
            todoKey: colText(stmt, 0),
            dispatchId: colText(stmt, 1),
            project: colText(stmt, 2),
            todoText: colText(stmt, 3),
            agent: colText(stmt, 4),
            sessionId: colText(stmt, 5),
            cwd: colText(stmt, 6),
            transcriptPath: colText(stmt, 7),
            logPath: colText(stmt, 8),
            status: TodoDispatchStatus(rawValue: colText(stmt, 9)) ?? .failed,
            summary: colText(stmt, 10),
            dispatchedAt: sqlite3_column_int64(stmt, 11),
            updatedAt: sqlite3_column_int64(stmt, 12),
            lastTranscriptMtime: sqlite3_column_int64(stmt, 13),
            pid: sqlite3_column_int(stmt, 14)
        )
    }

    // MARK: - Helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ val: String) {
        sqlite3_bind_text(stmt, idx, val, -1, SQLITE_TRANSIENT)
    }

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cstr)
    }
}
