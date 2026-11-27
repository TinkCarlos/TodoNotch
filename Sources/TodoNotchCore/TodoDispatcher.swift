import Foundation
import os
import SQLite3
import Darwin

// MARK: - Target Resolution

public struct ResolvedTodoTarget: Equatable, Sendable {
    public let agent: String
    public let sessionId: String
    public let sessionExists: Bool
    public let cwd: String
    public let transcriptPath: String
    public let excerptPath: String

    public init(
        agent: String,
        sessionId: String,
        sessionExists: Bool,
        cwd: String,
        transcriptPath: String,
        excerptPath: String
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.sessionExists = sessionExists
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.excerptPath = excerptPath
    }
}

public enum TodoTargetResolver {
    public static func resolve(
        item: TodoItem,
        vaultPath: String,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ResolvedTodoTarget {
        let primary = item.sources.last
        var agent = primary?.agent ?? defaultAvailableAgent(homeDir: homeDir)
        let prefix = primary?.sessionPrefix ?? ""

        var fullSessionId = prefix
        var cwd = ""
        var excerptPath = ""

        if !prefix.isEmpty, !vaultPath.isEmpty,
           let excerpt = findLmemoryExcerpt(prefix: prefix, vaultPath: vaultPath) {
            excerptPath = excerpt.path
            if !excerpt.agent.isEmpty {
                agent = excerpt.agent
            }
            if !excerpt.sessionId.isEmpty {
                fullSessionId = excerpt.sessionId
            }
            if !excerpt.projectRoot.isEmpty {
                cwd = excerpt.projectRoot
            }
        }

        let native = resolveNativeSession(
            agent: agent,
            sessionHint: fullSessionId,
            prefix: prefix,
            homeDir: homeDir
        )
        if !native.sessionId.isEmpty {
            fullSessionId = native.sessionId
        }
        if cwd.isEmpty, !native.cwd.isEmpty {
            cwd = native.cwd
        }

        let resolvedCwd = resolveWorkingDirectory(
            preferredCwd: cwd,
            project: item.project,
            homeDir: homeDir
        )

        return ResolvedTodoTarget(
            agent: agent,
            sessionId: fullSessionId,
            sessionExists: native.sessionExists,
            cwd: resolvedCwd,
            transcriptPath: native.transcriptPath,
            excerptPath: excerptPath
        )
    }

    private static func defaultAvailableAgent(homeDir: URL) -> String {
        let envPath = TodoDispatchRunner.buildEnvironment(homeDir: homeDir)["PATH"] ?? ""
        for candidate in ["antigravity", "codex", "claude", "cursor"] {
            if TodoDispatchRunner.resolveExecutable(agent: candidate, envPath: envPath) != nil {
                return candidate
            }
        }
        return "antigravity"
    }

    private static func resolveWorkingDirectory(preferredCwd: String, project: String, homeDir: URL) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !preferredCwd.isEmpty, fm.fileExists(atPath: preferredCwd, isDirectory: &isDir), isDir.boolValue {
            return preferredCwd
        }
        let cleanProj = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanProj.isEmpty {
            let candidate = homeDir.appendingPathComponent("projects/\(cleanProj)").path
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return homeDir.path
    }

    // MARK: Lmemory Excerpt Lookup

    private struct ExcerptMeta {
        let path: String
        let agent: String
        let sessionId: String
        let projectRoot: String
    }

    private static func findLmemoryExcerpt(prefix: String, vaultPath: String) -> ExcerptMeta? {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: vaultPath).appendingPathComponent("05 时间日志/会话摘录")
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let needleParenCN = "（\(prefix)"
        let needleParenEN = "(\(prefix)"
        let matches = urls.filter { url in
            guard url.pathExtension.lowercased() == "md" else { return false }
            let name = url.lastPathComponent
            return name.contains(needleParenCN) || name.contains(needleParenEN) || name.contains(prefix)
        }.sorted { a, b in
            let aParen = a.lastPathComponent.contains(needleParenCN) || a.lastPathComponent.contains(needleParenEN)
            let bParen = b.lastPathComponent.contains(needleParenCN) || b.lastPathComponent.contains(needleParenEN)
            if aParen != bParen { return aParen }
            let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ma > mb
        }

        guard let top = matches.first,
              let head = ConversationTracker.readHeadBytes(path: top.path, maxBytes: 4096) else {
            return nil
        }
        let meta = parseFrontmatter(head)
        return ExcerptMeta(
            path: top.path,
            agent: (meta["agent"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            sessionId: (meta["session"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            projectRoot: (meta["project_root"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func parseFrontmatter(_ text: String) -> [String: String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let endRange = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else {
            return [:]
        }
        let block = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<endRange.lowerBound]
        var result: [String: String] = [:]
        for line in block.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, (val.hasPrefix("'") && val.hasSuffix("'")) || (val.hasPrefix("\"") && val.hasSuffix("\"")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = val }
        }
        return result
    }

    // MARK: Agent-Native Session Lookup

    private struct NativeSessionInfo {
        var sessionId: String = ""
        var sessionExists: Bool = false
        var cwd: String = ""
        var transcriptPath: String = ""
    }

    private static func resolveNativeSession(
        agent: String,
        sessionHint: String,
        prefix: String,
        homeDir: URL
    ) -> NativeSessionInfo {
        let needle = sessionHint.isEmpty ? prefix : sessionHint
        guard !needle.isEmpty else { return NativeSessionInfo() }
        switch agent.lowercased() {
        case "antigravity":
            return resolveAntigravitySession(needle: needle, prefix: prefix, homeDir: homeDir)
        case "codex":
            return resolveCodexSession(needle: needle, prefix: prefix, homeDir: homeDir)
        case "claude":
            return resolveClaudeSession(needle: needle, prefix: prefix, homeDir: homeDir)
        case "cursor":
            return resolveCursorSession(needle: needle, prefix: prefix, homeDir: homeDir)
        case "pi":
            return resolvePiSession(needle: needle, prefix: prefix, homeDir: homeDir)
        case "opencode":
            return resolveOpenCodeSession(needle: needle, prefix: prefix, homeDir: homeDir)
        case "grok":
            return resolveGrokSession(needle: needle, prefix: prefix, homeDir: homeDir)
        case "qoder":
            return resolveQoderSession(needle: needle, prefix: prefix, homeDir: homeDir)
        default:
            return NativeSessionInfo()
        }
    }

    private static func resolveAntigravitySession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let desktopInfo = scanAntigravityStore(
            agyRoot: homeDir.appendingPathComponent(".gemini/antigravity"),
            needle: needle,
            prefix: prefix
        )
        if desktopInfo.sessionExists {
            return desktopInfo
        }
        return scanAntigravityStore(
            agyRoot: homeDir.appendingPathComponent(".gemini/antigravity-cli"),
            needle: needle,
            prefix: prefix
        )
    }

    private static func scanAntigravityStore(agyRoot: URL, needle: String, prefix: String) -> NativeSessionInfo {
        let fm = FileManager.default
        let brainDir = agyRoot.appendingPathComponent("brain")
        let convDir = agyRoot.appendingPathComponent("conversations")
        let searchPrefix = prefix.isEmpty ? needle : prefix

        var matchedId = ""
        var transcriptPath = ""
        if let dirs = try? fm.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let hit = dirs.first(where: { $0.lastPathComponent == needle }) ??
                dirs.first(where: { $0.lastPathComponent.hasPrefix(searchPrefix) })
            if let hit {
                matchedId = hit.lastPathComponent
                let tPath = hit.appendingPathComponent(".system_generated/logs/transcript.jsonl").path
                if fm.fileExists(atPath: tPath) {
                    transcriptPath = tPath
                }
            }
        }

        var dbExists = false
        if let dbs = try? fm.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let hit = dbs.first(where: { $0.lastPathComponent == "\(needle).db" }) ??
                dbs.first(where: { $0.pathExtension == "db" && $0.deletingPathExtension().lastPathComponent.hasPrefix(searchPrefix) })
            if let hit {
                dbExists = true
                if matchedId.isEmpty {
                    matchedId = hit.deletingPathExtension().lastPathComponent
                }
            }
        }

        return NativeSessionInfo(
            sessionId: matchedId,
            sessionExists: dbExists || !transcriptPath.isEmpty,
            cwd: "",
            transcriptPath: transcriptPath
        )
    }

    private static func resolveCodexSession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let fm = FileManager.default
        let sessionsDir = homeDir.appendingPathComponent(".codex/sessions")
        let searchToken = prefix.isEmpty ? needle : prefix
        var info = NativeSessionInfo()

        // Search recent 14 day folders first for speed, then fallback to enumerator
        let cal = Calendar.current
        var candidateFile: URL?
        for dayOffset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let dayDir = sessionsDir
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
            if let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                if let hit = files.first(where: { $0.pathExtension == "jsonl" && ($0.lastPathComponent.contains(needle) || $0.lastPathComponent.contains("-\(searchToken)")) }) {
                    candidateFile = hit
                    break
                }
            }
        }

        if candidateFile == nil, let enumerator = fm.enumerator(at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let name = url.lastPathComponent
                if name.contains(needle) || name.contains("-\(searchToken)") {
                    candidateFile = url
                    break
                }
            }
        }

        if let file = candidateFile {
            info.transcriptPath = file.path
            info.sessionExists = true
            if let head = ConversationTracker.readHeadBytes(path: file.path, maxBytes: 16_384) {
                for line in head.components(separatedBy: "\n") where !line.isEmpty {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["type"] as? String == "session_meta",
                          let pl = obj["payload"] as? [String: Any] else {
                        continue
                    }
                    if let sid = (pl["id"] as? String) ?? (pl["session_id"] as? String), !sid.isEmpty {
                        info.sessionId = sid
                    }
                    if let cwd = pl["cwd"] as? String, !cwd.isEmpty {
                        info.cwd = cwd
                    }
                    break
                }
            }
        }

        // Fallback to read-only codex.db catalog and state_5.sqlite when rollout file is absent, compressed, or cwd missing
        if !info.sessionExists || info.cwd.isEmpty {
            let dbPath = homeDir.appendingPathComponent(".codex/sqlite/codex.db").path
            if fm.fileExists(atPath: dbPath) {
                var db: OpaquePointer?
                if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                    defer { sqlite3_close(db) }
                    let sql = "SELECT thread_id, COALESCE(cwd, '') FROM local_thread_catalog WHERE thread_id LIKE ? LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        defer { sqlite3_finalize(stmt) }
                        let pattern = "\(searchToken)%"
                        sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            if let c0 = sqlite3_column_text(stmt, 0) {
                                let tid = String(cString: c0)
                                if info.sessionId.isEmpty { info.sessionId = tid }
                                info.sessionExists = true
                            }
                            if let c1 = sqlite3_column_text(stmt, 1) {
                                let cwd = String(cString: c1)
                                if info.cwd.isEmpty && !cwd.isEmpty { info.cwd = cwd }
                            }
                        }
                    }
                }
            }
        }

        if !info.sessionExists || info.cwd.isEmpty || info.transcriptPath.isEmpty {
            let stateDbPath = homeDir.appendingPathComponent(".codex/state_5.sqlite").path
            if fm.fileExists(atPath: stateDbPath) {
                var db: OpaquePointer?
                if sqlite3_open_v2(stateDbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                    defer { sqlite3_close(db) }
                    let sql = "SELECT id, COALESCE(cwd, ''), COALESCE(rollout_path, '') FROM threads WHERE id LIKE ? LIMIT 1;"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        defer { sqlite3_finalize(stmt) }
                        let pattern = "\(searchToken)%"
                        sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            if let c0 = sqlite3_column_text(stmt, 0) {
                                let tid = String(cString: c0)
                                if info.sessionId.isEmpty { info.sessionId = tid }
                                info.sessionExists = true
                            }
                            if let c1 = sqlite3_column_text(stmt, 1) {
                                let cwd = String(cString: c1)
                                if info.cwd.isEmpty && !cwd.isEmpty { info.cwd = cwd }
                            }
                            if let c2 = sqlite3_column_text(stmt, 2) {
                                let rolloutPath = String(cString: c2)
                                if info.transcriptPath.isEmpty && !rolloutPath.isEmpty && fm.fileExists(atPath: rolloutPath) {
                                    info.transcriptPath = rolloutPath
                                }
                            }
                        }
                    }
                }
            }
        }

        return info
    }

    private static func resolveClaudeSession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let fm = FileManager.default
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")
        let searchToken = prefix.isEmpty ? needle : prefix
        var info = NativeSessionInfo()

        guard let projDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return info
        }
        for dir in projDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            if let hit = files.first(where: {
                $0.pathExtension == "jsonl" &&
                ($0.deletingPathExtension().lastPathComponent == needle || $0.deletingPathExtension().lastPathComponent.hasPrefix(searchToken))
            }) {
                info.transcriptPath = hit.path
                info.sessionExists = true
                info.sessionId = hit.deletingPathExtension().lastPathComponent
                if let head = ConversationTracker.readHeadBytes(path: hit.path, maxBytes: 8192) {
                    for line in head.components(separatedBy: "\n").prefix(15) where !line.isEmpty {
                        if let data = line.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if let sid = obj["sessionId"] as? String, !sid.isEmpty { info.sessionId = sid }
                            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { info.cwd = cwd }
                            if !info.cwd.isEmpty { break }
                        }
                    }
                }
                break
            }
        }
        return info
    }

    private static func resolveCursorSession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let fm = FileManager.default
        let projectsDir = homeDir.appendingPathComponent(".cursor/projects")
        let searchToken = prefix.isEmpty ? needle : prefix
        var info = NativeSessionInfo()

        guard let projDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return info
        }
        for projDir in projDirs {
            let transcriptsDir = projDir.appendingPathComponent("agent-transcripts")
            guard let chatDirs = try? fm.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            if let hitDir = chatDirs.first(where: { $0.lastPathComponent == needle || $0.lastPathComponent.hasPrefix(searchToken) }) {
                info.sessionId = hitDir.lastPathComponent
                info.sessionExists = true
                if let files = try? fm.contentsOfDirectory(at: hitDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                   let jsonl = files.first(where: { $0.pathExtension == "jsonl" }) {
                    info.transcriptPath = jsonl.path
                }
                break
            }
        }
        return info
    }

    private static func resolvePiSession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let fm = FileManager.default
        let sessionsDir = homeDir.appendingPathComponent(".pi/agent/sessions")
        let searchToken = prefix.isEmpty ? needle : prefix
        var info = NativeSessionInfo()

        guard let enumerator = fm.enumerator(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return info
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let fullPath = url.path
            let matchesPath = fullPath.contains(needle) || fullPath.contains(searchToken)
            if let head = ConversationTracker.readHeadBytes(path: fullPath, maxBytes: 2048) {
                let firstLine = head.components(separatedBy: .newlines).first ?? ""
                if let data = firstLine.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["type"] as? String == "session" {
                    let sid = (obj["id"] as? String) ?? ""
                    let cwd = (obj["cwd"] as? String) ?? ""
                    if matchesPath || sid == needle || sid.hasPrefix(searchToken) {
                        info.sessionId = sid.isEmpty ? needle : sid
                        info.cwd = cwd
                        info.transcriptPath = fullPath
                        info.sessionExists = true
                        break
                    }
                }
            }
            if matchesPath {
                info.sessionId = needle
                info.transcriptPath = fullPath
                info.sessionExists = true
                break
            }
        }
        return info
    }

    private static func resolveOpenCodeSession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let dbPath = homeDir.appendingPathComponent(".local/share/opencode/opencode.db").path
        var info = NativeSessionInfo()
        guard FileManager.default.fileExists(atPath: dbPath) else { return info }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return info }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, COALESCE(directory, '') FROM session_v2 WHERE id = ? OR id LIKE ? ORDER BY rowid DESC LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            let searchToken = prefix.isEmpty ? needle : prefix
            let pattern = "\(searchToken)%"
            sqlite3_bind_text(stmt, 1, needle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let c0 = sqlite3_column_text(stmt, 0) {
                    info.sessionId = String(cString: c0)
                    info.sessionExists = !info.sessionId.isEmpty
                }
                if let c1 = sqlite3_column_text(stmt, 1) {
                    info.cwd = String(cString: c1)
                }
            }
        }
        return info
    }

    private static func resolveGrokSession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let fm = FileManager.default
        let searchToken = prefix.isEmpty ? needle : prefix
        var info = NativeSessionInfo()
        let sessionsDir = homeDir.appendingPathComponent(".grok/sessions")
        if let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           let hit = files.first(where: { $0.lastPathComponent.contains(needle) || $0.lastPathComponent.contains(searchToken) }) {
            info.sessionId = hit.deletingPathExtension().lastPathComponent
            info.transcriptPath = hit.path
            info.sessionExists = true
        }
        return info
    }

    private static func resolveQoderSession(needle: String, prefix: String, homeDir: URL) -> NativeSessionInfo {
        let fm = FileManager.default
        let searchToken = prefix.isEmpty ? needle : prefix
        var info = NativeSessionInfo()
        for dirName in [".qoder/projects", ".qoder-cn/projects"] {
            let root = homeDir.appendingPathComponent(dirName)
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                    let stem = url.deletingPathExtension().lastPathComponent
                    if stem == needle || stem.hasPrefix(searchToken) {
                        info.sessionId = stem
                        info.transcriptPath = url.path
                        info.sessionExists = true
                        return info
                    }
                }
            }
        }
        return info
    }
}

// MARK: - Conversation Reader & Completion Tracker

public enum ConversationTracker {
    public static func readHeadBytes(path: String, maxBytes: Int = 16_384) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func readTailBytes(path: String, maxBytes: Int = 524_288) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        if fileSize == 0 { return "" }
        let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    public static func fileMtime(_ path: String) -> Int64 {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let d = attrs[.modificationDate] as? Date else {
            return 0
        }
        return Int64(d.timeIntervalSince1970)
    }

    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static func readConversationTurns(
        agent: String,
        transcriptPath: String,
        excerptPath: String,
        logPath: String,
        maxTurns: Int = 6,
        fallbackPrompt: String = ""
    ) -> [ConversationTurn] {
        var rawTurns: [(String, String)] = []

        if !transcriptPath.isEmpty, FileManager.default.fileExists(atPath: transcriptPath),
           let tail = readTailBytes(path: transcriptPath) {
            switch agent.lowercased() {
            case "antigravity":
                rawTurns = parseAntigravityTurns(tail)
            case "codex":
                rawTurns = parseCodexTurns(tail)
            default:
                rawTurns = parseClaudeOrCursorTurns(tail)
            }
        }

        if rawTurns.isEmpty, !excerptPath.isEmpty,
           let excerptText = try? String(contentsOfFile: excerptPath, encoding: .utf8) {
            rawTurns = parseLmemoryExcerptTurns(excerptText)
        }

        if rawTurns.isEmpty, !logPath.isEmpty,
           let logTail = readTailBytes(path: logPath, maxBytes: 32_768) {
            let extracted = extractAssistantTextFromLog(logTail)
            if !extracted.isEmpty {
                let cleanPrompt = fallbackPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanPrompt.isEmpty {
                    rawTurns = [("user", cleanPrompt), ("assistant", extracted)]
                } else {
                    rawTurns = [("assistant", extracted)]
                }
            }
        }

        let sliced = Array(rawTurns.suffix(maxTurns))
        return sliced.enumerated().map { idx, pair in
            ConversationTurn(id: idx, role: pair.0, text: pair.1)
        }
    }

    private static func parseAntigravityTurns(_ tail: String) -> [(String, String)] {
        var events: [(String, String)] = []
        for line in tail.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let typ = obj["type"] as? String,
                  let content = obj["content"] as? String else {
                continue
            }
            if typ == "USER_INPUT" {
                let cleaned = cleanUserText(content)
                if !cleaned.isEmpty, !isSystemNoise(cleaned) {
                    events.append(("user", cleaned))
                }
            } else if typ == "PLANNER_RESPONSE" {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    events.append(("assistant", trimmed))
                }
            }
        }
        return coalesceSequentialTurns(events)
    }

    private static func parseCodexTurns(_ tail: String) -> [(String, String)] {
        var events: [(String, String)] = []
        for line in tail.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let typ = obj["type"] as? String,
                  let pl = obj["payload"] as? [String: Any] else {
                continue
            }
            if typ == "response_item", pl["type"] as? String == "message",
               let role = pl["role"] as? String {
                let txt = extractContentText(pl["content"])
                if txt.isEmpty { continue }
                if role == "user" {
                    let cleaned = cleanUserText(txt)
                    if !cleaned.isEmpty, !isSystemNoise(cleaned) {
                        events.append(("user", cleaned))
                    }
                } else if role == "assistant" {
                    events.append(("assistant", txt))
                }
            } else if typ == "event_msg", let et = pl["type"] as? String {
                if et == "user_message", let msg = pl["message"] as? String {
                    let cleaned = cleanUserText(msg)
                    if !cleaned.isEmpty, !isSystemNoise(cleaned) {
                        events.append(("user", cleaned))
                    }
                } else if et == "agent_message", let msg = pl["message"] as? String {
                    let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { events.append(("assistant", trimmed)) }
                } else if et == "task_complete", let msg = pl["last_agent_message"] as? String {
                    let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { events.append(("assistant", trimmed)) }
                }
            }
        }
        return coalesceSequentialTurns(events)
    }

    private static func parseClaudeOrCursorTurns(_ tail: String) -> [(String, String)] {
        var events: [(String, String)] = []
        for line in tail.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let msg = (obj["message"] as? [String: Any]) ?? obj
            let rawRole = (obj["role"] as? String) ?? (msg["role"] as? String) ?? (obj["type"] as? String) ?? ""
            guard rawRole == "user" || rawRole == "assistant" else { continue }
            let txt = extractContentText(msg["content"])
            if txt.isEmpty { continue }
            if rawRole == "user" {
                let cleaned = cleanUserText(txt)
                if !cleaned.isEmpty, !isSystemNoise(cleaned) {
                    events.append(("user", cleaned))
                }
            } else {
                events.append(("assistant", txt))
            }
        }
        return coalesceSequentialTurns(events)
    }

    private static func parseLmemoryExcerptTurns(_ text: String) -> [(String, String)] {
        var turns: [(String, String)] = []
        var currentRole: String?
        var currentBuf: [String] = []

        func flush() {
            guard let r = currentRole else { return }
            let body = currentBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { turns.append((r, body)) }
            currentRole = nil
            currentBuf = []
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- **问**") || trimmed.hasPrefix("- **Q**") {
                flush()
                currentRole = "user"
                if let idx = trimmed.firstIndex(of: "：") ?? trimmed.firstIndex(of: ":") {
                    currentBuf.append(String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces))
                }
            } else if trimmed.hasPrefix("**答**") || trimmed.hasPrefix("**A**") {
                flush()
                currentRole = "assistant"
                if let idx = trimmed.firstIndex(of: "：") ?? trimmed.firstIndex(of: ":") {
                    currentBuf.append(String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces))
                }
            } else if currentRole != nil {
                currentBuf.append(trimmed)
            }
        }
        flush()
        return turns
    }

    static func parseTrailingJSONObject(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        for line in trimmed.components(separatedBy: .newlines).reversed() {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.hasPrefix("{"), clean.hasSuffix("}"),
                  let data = clean.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return obj
        }
        return nil
    }

    static func extractDeniedActions(from obj: [String: Any]) -> [String] {
        guard let arr = obj["denied_actions"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            let name = (item["display_name"] as? String) ?? (item["action"] as? String) ?? ""
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func extractAssistantTextFromLog(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let obj = parseTrailingJSONObject(from: trimmed) {
            for key in ["result", "response", "text", "message", "content"] {
                if let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let denied = extractDeniedActions(from: obj)
            if !denied.isEmpty {
                return "权限受限被拦截（\(denied.joined(separator: ", "))），无法在无头模式下自动继续"
            }
        }
        return String(trimmed.suffix(800))
    }

    private static func coalesceSequentialTurns(_ events: [(String, String)]) -> [(String, String)] {
        var out: [(String, String)] = []
        for (role, text) in events {
            if let last = out.last, last.0 == role {
                if last.1 == text { continue }
                // Keep the latest assistant summary/message when multiple chunks appear in same turn
                out[out.count - 1] = (role, role == "assistant" ? text : "\(last.1)\n\(text)")
            } else {
                out.append((role, text))
            }
        }
        return out
    }

    private static func extractContentText(_ content: Any?) -> String {
        if let s = content as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = content as? [Any] {
            var parts: [String] = []
            for item in arr {
                if let dict = item as? [String: Any], let t = dict["text"] as? String {
                    parts.append(t)
                } else if let s = item as? String {
                    parts.append(s)
                }
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func cleanUserText(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["USER_REQUEST", "user_request"] {
            if let start = s.range(of: "<\(tag)>"),
               let end = s.range(of: "</\(tag)>", range: start.upperBound..<s.endIndex) {
                s = String(s[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if let marker = s.range(of: "## My request:") {
            s = String(s[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private static func isSystemNoise(_ text: String) -> Bool {
        let prefixes = [
            "# AGENTS.md", "<environment_context", "<permissions instructions",
            "<collaboration_mode", "<turn_aborted", "<system-reminder",
            "<user_instructions", "<task-notification", "<SYSTEM_MESSAGE>"
        ]
        return prefixes.contains { text.hasPrefix($0) }
    }

    // MARK: Completion Evaluation

    public static func evaluateCompletion(
        exitCode: Int32?,
        latestAssistantReply: String,
        hasPendingUserTurn: Bool,
        deniedActions: [String] = []
    ) -> TodoDispatchStatus {
        if let code = exitCode, code != 0 {
            return .failed
        }
        if !deniedActions.isEmpty {
            return .needsAttention
        }
        if exitCode == nil && hasPendingUserTurn {
            return .running
        }
        let reply = latestAssistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty {
            return .needsAttention
        }

        let lower = reply.lowercased()
        let blockerCues = [
            "需要你", "请确认", "请登录", "请提供", "请拍板", "请先", "等待你",
            "阻塞", "无法完成", "未能完成", "尚未完成", "需要人工", "授权", "扫码",
            "尚未保存", "尚未修改", "还未修改", "未能保存", "拒绝访问", "拒绝操作",
            "需要手动", "待保存", "需要在原任务", "无法修改", "未能修改",
            "权限受限被拦截", "auto-denied", "no output produced", "permission that headless mode",
            "please confirm", "need your", "blocked", "cannot complete", "waiting for user",
            "action required", "human input"
        ]
        if blockerCues.contains(where: { lower.contains($0) }) {
            return .needsAttention
        }

        let endsWithQuestion = reply.hasSuffix("？") || reply.hasSuffix("?")
        let completionCues = [
            "已完成", "已修复", "已提交", "已部署", "已关闭", "已解决", "已更新",
            "completed", "finished", "resolved", "done"
        ]
        if endsWithQuestion && !completionCues.contains(where: { lower.contains($0) }) {
            return .needsAttention
        }
        return .completed
    }
}

// MARK: - Headless CLI Dispatch Runner

public struct ScheduledTaskSpec: Equatable, Sendable {
    public let agent: String
    public let sessionId: String
    public let sessionExists: Bool
    public let cwd: String
    public let prompt: String
    public let accessGrants: [String]

    public init(
        agent: String,
        sessionId: String,
        sessionExists: Bool,
        cwd: String,
        prompt: String,
        accessGrants: [String] = []
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.sessionExists = sessionExists
        self.cwd = cwd
        self.prompt = prompt
        self.accessGrants = accessGrants
    }
}

public final class TodoDispatchRunner: @unchecked Sendable {
    private final class ActiveRunHandle: @unchecked Sendable {
        let dispatchId: String
        var cancelled: Bool = false
        var pid: Int32 = 0
        var onCancel: (@Sendable () -> Void)?

        init(dispatchId: String) {
            self.dispatchId = dispatchId
        }
    }

    private let runsLock = NSLock()
    private var activeRuns: [String: ActiveRunHandle] = [:]

    public init() {}

    public func isActive(recordKey: String, dispatchId: String? = nil) -> Bool {
        runsLock.lock()
        defer { runsLock.unlock() }
        guard let handle = activeRuns[recordKey] else { return false }
        if let dispatchId, !dispatchId.isEmpty {
            return handle.dispatchId == dispatchId
        }
        return true
    }

    @discardableResult
    public func cancel(recordKey: String, dispatchId: String? = nil, fallbackPid: Int32 = 0) -> Bool {
        runsLock.lock()
        let handle = activeRuns[recordKey]
        if let dispatchId, handle?.dispatchId != dispatchId {
            runsLock.unlock()
            return false
        }
        var cancelAction: (@Sendable () -> Void)?
        var activePid: Int32 = 0
        if let handle {
            handle.cancelled = true
            cancelAction = handle.onCancel
            activePid = handle.pid
        }
        runsLock.unlock()

        if let cancelAction {
            cancelAction()
            return true
        }
        let targetPid = activePid > 0 ? activePid : fallbackPid
        if targetPid > 0 && ConversationTracker.isProcessAlive(targetPid) {
            Self.terminatePidGracefully(targetPid)
            return true
        }
        return handle != nil
    }

    private func registerRun(recordKey: String, dispatchId: String) -> Bool {
        runsLock.lock()
        defer { runsLock.unlock() }
        guard activeRuns[recordKey] == nil else { return false }
        activeRuns[recordKey] = ActiveRunHandle(dispatchId: dispatchId)
        return true
    }

    private func updateRunCancel(recordKey: String, dispatchId: String, pid: Int32 = 0, onCancel: @escaping @Sendable () -> Void) {
        runsLock.lock()
        var alreadyCancelled = false
        if let handle = activeRuns[recordKey], handle.dispatchId == dispatchId {
            if pid > 0 { handle.pid = pid }
            handle.onCancel = onCancel
            alreadyCancelled = handle.cancelled
        }
        runsLock.unlock()
        if alreadyCancelled {
            onCancel()
        }
    }

    private func isCancelled(recordKey: String, dispatchId: String) -> Bool {
        runsLock.lock()
        defer { runsLock.unlock() }
        guard let handle = activeRuns[recordKey], handle.dispatchId == dispatchId else { return false }
        return handle.cancelled
    }

    private func clearCancelRequest(recordKey: String, dispatchId: String) {
        runsLock.lock()
        defer { runsLock.unlock() }
        if let handle = activeRuns[recordKey], handle.dispatchId == dispatchId {
            handle.cancelled = false
        }
    }

    private func unregisterRun(recordKey: String, dispatchId: String) {
        runsLock.lock()
        if activeRuns[recordKey]?.dispatchId == dispatchId {
            activeRuns.removeValue(forKey: recordKey)
        }
        runsLock.unlock()
    }

    public static func collectDescendantPids(of rootPid: Int32) -> [Int32] {
        guard rootPid > 0 else { return [] }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        var childrenByParent: [Int32: [Int32]] = [:]
        for line in out.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else {
                continue
            }
            childrenByParent[ppid, default: []].append(pid)
        }
        var visited: Set<Int32> = [rootPid]
        var queue: [Int32] = [rootPid]
        var descendants: [Int32] = []
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            for child in childrenByParent[cur] ?? [] where visited.insert(child).inserted {
                descendants.append(child)
                queue.append(child)
            }
        }
        return descendants
    }

    @discardableResult
    public static func terminateProcessTreeAndWait(_ rootPid: Int32, graceSeconds: TimeInterval = 1.5) -> Bool {
        guard rootPid > 0 else { return true }
        return terminateProcessTreeAndWait(
            rootPid, ownedGroup: getpgid(rootPid) == rootPid ? rootPid : nil,
            rootRunning: true, graceSeconds: graceSeconds
        )
    }

    private static func terminateProcessTreeAndWait(
        _ rootPid: Int32, ownedGroup: Int32?, rootRunning: Bool, graceSeconds: TimeInterval = 1.5
    ) -> Bool {
        func groupIsAlive() -> Bool {
            guard let ownedGroup else { return false }
            return Darwin.kill(-ownedGroup, 0) == 0
        }
        let descendants = rootRunning ? collectDescendantPids(of: rootPid) : []
        let initialTree = Array(descendants.reversed()) + (rootRunning ? [rootPid] : [])
        // Keep using the group confirmed at launch after the server process exits.
        if let ownedGroup { Darwin.kill(-ownedGroup, SIGTERM) }
        for pid in initialTree {
            Darwin.kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(max(0.1, graceSeconds))
        while Date() < deadline {
            if !groupIsAlive() && initialTree.allSatisfy({ !ConversationTracker.isProcessAlive($0) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let ownedGroup, groupIsAlive() { Darwin.kill(-ownedGroup, SIGKILL) }
        let remaining = (rootRunning ? collectDescendantPids(of: rootPid) : []).reversed() + initialTree
        var seen = Set<Int32>()
        let uniqueRemaining = remaining.filter { seen.insert($0).inserted && ConversationTracker.isProcessAlive($0) }
        for pid in uniqueRemaining {
            Darwin.kill(pid, SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(0.5)
        while Date() < killDeadline {
            if !groupIsAlive() && uniqueRemaining.allSatisfy({ !ConversationTracker.isProcessAlive($0) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !groupIsAlive() && uniqueRemaining.allSatisfy { !ConversationTracker.isProcessAlive($0) }
    }

    private static func terminatePidGracefully(_ pid: Int32) {
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = terminateProcessTreeAndWait(pid, graceSeconds: 1.5)
        }
    }

    private static func stoppedRecord(
        recordKey: String,
        dispatchId: String,
        project: String,
        displayText: String,
        agent: String,
        sessionId: String,
        cwd: String,
        transcriptPath: String,
        logPath: String,
        startedAt: Int64
    ) -> TodoDispatchRecord {
        let now = Int64(Date().timeIntervalSince1970)
        return TodoDispatchRecord(
            todoKey: recordKey,
            dispatchId: dispatchId,
            project: project,
            todoText: displayText,
            agent: agent,
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: transcriptPath,
            logPath: logPath,
            status: .stopped,
            summary: "已手动停止",
            dispatchedAt: startedAt,
            updatedAt: now,
            lastTranscriptMtime: ConversationTracker.fileMtime(transcriptPath),
            pid: 0
        )
    }

    public static func buildEnvironment(homeDir: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var extraDirs: [String] = [
            homeDir.appendingPathComponent(".local/bin").path,
            homeDir.appendingPathComponent(".grok/bin").path,
            homeDir.appendingPathComponent(".local/share/fnm/aliases/default/bin").path
        ]

        let fnmVersions = homeDir.appendingPathComponent(".local/share/fnm/node-versions")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: fnmVersions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for d in dirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                extraDirs.append(d.appendingPathComponent("installation/bin").path)
            }
        }
        let nvmVersions = homeDir.appendingPathComponent(".nvm/versions/node")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: nvmVersions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for d in dirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                extraDirs.append(d.appendingPathComponent("bin").path)
            }
        }
        extraDirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])

        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = (extraDirs + existing).filter { dir in
            !dir.isEmpty && seen.insert(dir).inserted
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    public static func resolveExecutable(agent: String, envPath: String) -> String? {
        let binName: String
        switch agent.lowercased() {
        case "antigravity": binName = "agy"
        case "codex": binName = "codex"
        case "claude": binName = "claude"
        case "cursor": binName = "cursor-agent"
        case "pi": binName = "pi"
        case "opencode": binName = "opencode"
        case "grok": binName = "grok"
        case "qoder": binName = "qoderclicn"
        default: binName = "agy"
        }
        let fm = FileManager.default
        for dir in envPath.split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(binName)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func buildCommand(
        agent: String,
        executable: String,
        target: ResolvedTodoTarget,
        prompt: String,
        outputFile: String,
        accessGrants: [String] = []
    ) -> (executable: String, arguments: [String]) {
        let canResume = target.sessionExists && !target.sessionId.isEmpty
        switch agent.lowercased() {
        case "codex":
            if canResume {
                return (executable, ["exec", "resume", "--json", "--skip-git-repo-check", "-o", outputFile, target.sessionId, prompt])
            }
            return (executable, ["exec", "--json", "--skip-git-repo-check", "-C", target.cwd, "-o", outputFile, prompt])
        case "claude":
            if canResume {
                return (executable, ["--resume", target.sessionId, "--output-format", "json", "-p", prompt])
            }
            return (executable, ["--output-format", "json", "-p", prompt])
        case "cursor":
            if canResume {
                return (executable, ["--resume", target.sessionId, "-p", prompt])
            }
            return (executable, ["-p", prompt])
        case "pi":
            if canResume {
                return (executable, ["--mode", "json", "--session", target.sessionId, "-p", prompt])
            }
            return (executable, ["--mode", "json", "-p", prompt])
        case "opencode":
            if canResume {
                return (executable, ["run", "--format", "json", "-s", target.sessionId, prompt])
            }
            return (executable, ["run", "--format", "json", prompt])
        case "grok":
            if canResume {
                return (executable, ["--output-format", "json", "--cwd", target.cwd, "--resume", target.sessionId, "-p", prompt])
            }
            return (executable, ["--output-format", "json", "--cwd", target.cwd, "-p", prompt])
        case "qoder":
            if canResume {
                return (executable, ["--resume", target.sessionId, "-w", target.cwd, "-p", prompt])
            }
            return (executable, ["-w", target.cwd, "-p", prompt])
        default: // antigravity: --print consumes the next argument as prompt, so keep --print <prompt> last
            var args: [String] = []
            if canResume {
                args.append(contentsOf: ["--conversation", target.sessionId])
            }
            var mergedGrants: [String] = []
            var seenGrants = Set<String>()
            func appendGrant(_ grant: String) {
                if !grant.isEmpty && seenGrants.insert(grant).inserted {
                    mergedGrants.append(grant)
                }
            }
            for grant in accessGrants {
                appendGrant(grant)
            }
            for baseline in [
                "mcp(lmemory/lmemory_ask)",
                "mcp(lmemory/lmemory_status)",
                "mcp(lmemory/*)",
                "mcp(agy-dart_fast/*)",
                "mcp(agy-dart_context/*)",
                "mcp(codegraph/*)",
                "mcp(gemini-api_gemini-api-docs/*)"
            ] {
                appendGrant(baseline)
            }
            if !target.cwd.isEmpty {
                appendGrant("read_file(\(target.cwd))")
                appendGrant("write_file(\(target.cwd))")
            }
            let skillsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/config/skills").path
            appendGrant("read_file(\(skillsDir))")

            if let settingsData = try? JSONSerialization.data(
                withJSONObject: ["permissions": ["allow": mergedGrants]],
                options: [.withoutEscapingSlashes]
            ), let settingsJSON = String(data: settingsData, encoding: .utf8) {
                args.append(contentsOf: ["--settings", settingsJSON])
            }
            args.append(contentsOf: ["--output-format", "json", "--print", prompt])
            return (executable, args)
        }
    }

    public static func buildCodexForkCommand(
        executable: String,
        sessionId: String,
        prompt: String,
        outputFile: String
    ) -> (executable: String, arguments: [String]) {
        (executable, ["exec", "fork", "--json", "--skip-git-repo-check", "-o", outputFile, sessionId, prompt])
    }

    public static func isCodexResumeConflictError(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("already has an active writer")
            || lower.contains("thread-store conflict")
            || lower.contains("thread/resume failed")
            || lower.contains("no such thread")
            || lower.contains("not found")
    }

    public static func extractProcessErrorSummary(from data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        for line in lines.reversed() {
            let lower = line.lowercased()
            if lower.contains("error:") || lower.contains("error ") || lower.contains("failed") {
                return String(line.prefix(240))
            }
        }
        return String(lines[lines.count - 1].prefix(240))
    }

    public static func buildPrompt(item: TodoItem, target: ResolvedTodoTarget) -> String {
        let cleanTask = TodoMarkdownParser.stripSourceSuffix(item.text)
        var prompt = "请直接处理以下待办事项并给出明确执行结果：\n[\(item.project)] \(cleanTask)"
        if !target.sessionExists, !target.excerptPath.isEmpty {
            prompt += "\n（原会话上下文摘录可参考：\(target.excerptPath)）"
        }
        return prompt
    }

    public static func extractScheduledTaskSpec(
        task: MonitoredTask,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ScheduledTaskSpec? {
        let fm = FileManager.default
        guard !task.configPath.isEmpty, fm.fileExists(atPath: task.configPath) else { return nil }

        func validDirOrHome(_ rawPath: String) -> String {
            var isDir: ObjCBool = false
            if !rawPath.isEmpty, fm.fileExists(atPath: rawPath, isDirectory: &isDir), isDir.boolValue {
                return rawPath
            }
            return homeDir.path
        }

        switch task.source {
        case .antigravity:
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: task.configPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let args = json["args"] as? [String],
                  let dashIdx = args.firstIndex(of: "--") else {
                return nil
            }
            let prompt = args.dropFirst(dashIdx + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            var cwd = ""
            var grants: [String] = []
            if let perms = json["agent_permissions"] as? [String: Any] {
                if let uris = perms["workspace_uris"] as? [String],
                   let first = uris.first {
                    cwd = URL(string: first)?.path ?? first.replacingOccurrences(of: "file://", with: "")
                }
                if let g = perms["access_grants"] as? [String] {
                    grants = g
                }
            }
            return ScheduledTaskSpec(
                agent: "antigravity",
                sessionId: "",
                sessionExists: false,
                cwd: validDirOrHome(cwd),
                prompt: prompt,
                accessGrants: grants
            )

        case .codex:
            guard let raw = try? String(contentsOfFile: task.configPath, encoding: .utf8) else { return nil }
            let prompt = extractTOMLStringField(raw, key: "prompt")
            guard !prompt.isEmpty else { return nil }
            let threadId = extractTOMLStringField(raw, key: "target_thread_id")
            var resolvedCwd = extractTOMLFirstArrayString(raw, key: "cwds")
            if resolvedCwd.isEmpty, !threadId.isEmpty {
                let resolved = TodoTargetResolver.resolve(
                    item: TodoItem(
                        id: 0,
                        section: "personal",
                        project: task.displayName,
                        text: task.displayName,
                        done: false,
                        sources: [TodoSourceRef(agent: "codex", sessionPrefix: threadId)]
                    ),
                    vaultPath: "",
                    homeDir: homeDir
                )
                if !resolved.cwd.isEmpty {
                    resolvedCwd = resolved.cwd
                }
            }
            return ScheduledTaskSpec(
                agent: "codex",
                sessionId: threadId,
                sessionExists: !threadId.isEmpty,
                cwd: validDirOrHome(resolvedCwd),
                prompt: prompt
            )

        case .claude:
            guard let raw = try? String(contentsOfFile: task.configPath, encoding: .utf8) else { return nil }
            let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            var body = normalized
            if normalized.hasPrefix("---\n"),
               let end = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) {
                body = String(normalized[end.upperBound...])
            }
            let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            return ScheduledTaskSpec(
                agent: "claude",
                sessionId: "",
                sessionExists: false,
                cwd: homeDir.path,
                prompt: prompt
            )

        default:
            return nil
        }
    }

    private static func extractTOMLStringField(_ toml: String, key: String) -> String {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        // Multi-line basic/literal strings first, then single-line basic/literal strings (allowing trailing comments)
        if let multiRe = try? NSRegularExpression(pattern: #"(?ms)^\s*\#(escapedKey)\s*=\s*"""\n?(.*?)"""(?:\s*#[^\n]*)?\s*$"#),
           let m = multiRe.firstMatch(in: toml, range: NSRange(toml.startIndex..<toml.endIndex, in: toml)),
           let r = Range(m.range(at: 1), in: toml) {
            return unescapeTOMLBasicString(String(toml[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let multiLitRe = try? NSRegularExpression(pattern: #"(?ms)^\s*\#(escapedKey)\s*=\s*'''\n?(.*?)'''(?:\s*#[^\n]*)?\s*$"#),
           let m = multiLitRe.firstMatch(in: toml, range: NSRange(toml.startIndex..<toml.endIndex, in: toml)),
           let r = Range(m.range(at: 1), in: toml) {
            return String(toml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let singleRe = try? NSRegularExpression(pattern: #"(?m)^\s*\#(escapedKey)\s*=\s*"((?:\\.|[^"\\])*)"(?:\s*#.*)?\s*$"#),
           let m = singleRe.firstMatch(in: toml, range: NSRange(toml.startIndex..<toml.endIndex, in: toml)),
           let r = Range(m.range(at: 1), in: toml) {
            return unescapeTOMLBasicString(String(toml[r]))
        }
        if let singleLitRe = try? NSRegularExpression(pattern: #"(?m)^\s*\#(escapedKey)\s*=\s*'([^'\n]*)'(?:\s*#.*)?\s*$"#),
           let m = singleLitRe.firstMatch(in: toml, range: NSRange(toml.startIndex..<toml.endIndex, in: toml)),
           let r = Range(m.range(at: 1), in: toml) {
            return String(toml[r])
        }
        return ""
    }

    private static func extractTOMLFirstArrayString(_ toml: String, key: String) -> String {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        if let re = try? NSRegularExpression(pattern: #"(?ms)^\s*\#(escapedKey)\s*=\s*\[\s*"((?:\\.|[^"\\])*)""#),
           let m = re.firstMatch(in: toml, range: NSRange(toml.startIndex..<toml.endIndex, in: toml)),
           let r = Range(m.range(at: 1), in: toml) {
            return unescapeTOMLBasicString(String(toml[r]))
        }
        if let litRe = try? NSRegularExpression(pattern: #"(?ms)^\s*\#(escapedKey)\s*=\s*\[\s*'([^'\n]*)'"#),
           let m = litRe.firstMatch(in: toml, range: NSRange(toml.startIndex..<toml.endIndex, in: toml)),
           let r = Range(m.range(at: 1), in: toml) {
            return String(toml[r])
        }
        return ""
    }

    private static func unescapeTOMLBasicString(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        while let ch = iter.next() {
            if ch == "\\", let esc = iter.next() {
                switch esc {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default:
                    out.append(esc)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    public func dispatch(
        item: TodoItem,
        vaultPath: String,
        logDir: URL,
        dispatchId: String = UUID().uuidString.lowercased(),
        requireDesktopSession: Bool = false,
        onStarted: @escaping @Sendable (TodoDispatchRecord) -> Void,
        onCompleted: @escaping @Sendable (TodoDispatchRecord) -> Void
    ) {
        guard registerRun(recordKey: item.todoKey, dispatchId: dispatchId) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let complete: @Sendable (TodoDispatchRecord) -> Void = { record in
                self.unregisterRun(recordKey: item.todoKey, dispatchId: dispatchId)
                onCompleted(record)
            }
            let target = TodoTargetResolver.resolve(item: item, vaultPath: vaultPath)
            let cleanText = TodoMarkdownParser.stripSourceSuffix(item.text)
            let prompt = Self.buildPrompt(item: item, target: target)
            self.executeRun(
                recordKey: item.todoKey,
                dispatchId: dispatchId,
                project: item.project,
                displayText: cleanText,
                target: target,
                prompt: prompt,
                vaultPath: vaultPath,
                logDir: logDir,
                requireDesktopSession: requireDesktopSession,
                allowAntigravityNewSessionFallback: true,
                onStarted: onStarted,
                onCompleted: complete
            )
        }
    }

    public func dispatchScheduledTask(
        task: MonitoredTask,
        logDir: URL,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        dispatchId: String = UUID().uuidString.lowercased(),
        requireDesktopSession: Bool = false,
        onStarted: @escaping @Sendable (TodoDispatchRecord) -> Void,
        onCompleted: @escaping @Sendable (TodoDispatchRecord) -> Void
    ) {
        guard registerRun(recordKey: task.taskKey, dispatchId: dispatchId) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let complete: @Sendable (TodoDispatchRecord) -> Void = { record in
                self.unregisterRun(recordKey: task.taskKey, dispatchId: dispatchId)
                onCompleted(record)
            }
            guard let spec = Self.extractScheduledTaskSpec(task: task, homeDir: homeDir) else {
                let now = Int64(Date().timeIntervalSince1970)
                complete(TodoDispatchRecord(
                    todoKey: task.taskKey,
                    dispatchId: dispatchId,
                    project: task.displayName,
                    todoText: task.displayName,
                    agent: task.source.rawValue,
                    sessionId: "",
                    cwd: homeDir.path,
                    status: .failed,
                    summary: "Unsupported or empty scheduled task config",
                    dispatchedAt: now,
                    updatedAt: now
                ))
                return
            }
            var targetTranscript = ""
            var targetCwd = spec.cwd
            if spec.sessionExists && !spec.sessionId.isEmpty {
                let resolved = TodoTargetResolver.resolve(
                    item: TodoItem(
                        id: 0,
                        section: "personal",
                        project: task.displayName,
                        text: task.displayName,
                        done: false,
                        sources: [TodoSourceRef(agent: spec.agent, sessionPrefix: spec.sessionId)]
                    ),
                    vaultPath: "",
                    homeDir: homeDir
                )
                if !resolved.transcriptPath.isEmpty {
                    targetTranscript = resolved.transcriptPath
                }
                if targetCwd == homeDir.path && !resolved.cwd.isEmpty {
                    targetCwd = resolved.cwd
                }
            }
            let target = ResolvedTodoTarget(
                agent: spec.agent,
                sessionId: spec.sessionId,
                sessionExists: spec.sessionExists,
                cwd: targetCwd,
                transcriptPath: targetTranscript,
                excerptPath: ""
            )
            self.executeRun(
                recordKey: task.taskKey,
                dispatchId: dispatchId,
                project: task.displayName,
                displayText: String(spec.prompt.prefix(240)),
                target: target,
                prompt: spec.prompt,
                vaultPath: "",
                logDir: logDir,
                requireDesktopSession: requireDesktopSession,
                allowAntigravityNewSessionFallback: spec.sessionExists,
                accessGrants: spec.accessGrants,
                sidecarId: task.source == .antigravity ? task.nativeId : "",
                homeDir: homeDir,
                onStarted: onStarted,
                onCompleted: complete
            )
        }
    }

    public struct BridgeReplyEvidence: Equatable, Sendable {
        public let offset: UInt64
        public let length: Int
        public let stepIndex: Int
    }

    public struct BridgeResult: Equatable, Sendable {
        public let status: String
        public let conversationId: String
        public let error: String
        public let bridgeInstance: String
        public let stopRequestId: String
        public let replyEvidence: BridgeReplyEvidence?
        public let updatedAt: Int64?

        public init(
            status: String, conversationId: String, error: String, bridgeInstance: String = "",
            stopRequestId: String = "", replyEvidence: BridgeReplyEvidence? = nil, updatedAt: Int64? = nil
        ) {
            self.status = status
            self.conversationId = conversationId
            self.error = error
            self.bridgeInstance = bridgeInstance
            self.stopRequestId = stopRequestId
            self.replyEvidence = replyEvidence
            self.updatedAt = updatedAt
        }
    }

    public static func defaultBridgeDir(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDir.appendingPathComponent("Library/Application Support/TodoNotch/bridge")
    }

    public static func isAntigravityBridgeHealthy(
        bridgeDir: URL = defaultBridgeDir(),
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Bool {
        let statusURL = bridgeDir.appendingPathComponent("agy-bridge-status.json")
        guard let data = try? Data(contentsOf: statusURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ready"] as? Bool) == true,
              let pid = (obj["pid"] as? NSNumber)?.int32Value,
              let updatedAt = (obj["updated_at"] as? NSNumber)?.int64Value else {
            return false
        }
        guard (now - updatedAt) <= 30 else { return false }
        return ConversationTracker.isProcessAlive(pid)
    }

    private static func bridgeStopOwner(bridgeDir: URL) -> String? {
        let statusURL = bridgeDir.appendingPathComponent("agy-bridge-status.json")
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (status["stop_protocol"] as? Int) == 2,
              let instance = status["bridge_instance"] as? String,
              UUID(uuidString: instance) != nil else { return nil }
        return instance
    }

    public static func isLegacyAntigravityBridgeHealthy(bridgeDir: URL = defaultBridgeDir()) -> Bool {
        bridgeStopOwner(bridgeDir: bridgeDir) == nil && isAntigravityBridgeHealthy(bridgeDir: bridgeDir)
    }

    public static let unconfirmedAntigravitySummary = "Antigravity Desktop did not confirm the final state"

    public static func canStopAntigravityBridgeDispatch(dispatchId: String, bridgeDir: URL = defaultBridgeDir()) -> Bool {
        guard UUID(uuidString: dispatchId) != nil,
              isAntigravityBridgeHealthy(bridgeDir: bridgeDir),
              let owner = bridgeStopOwner(bridgeDir: bridgeDir),
              let result = readBridgeResult(bridgeDir: bridgeDir, dispatchId: dispatchId) else { return false }
        return ["starting", "running"].contains(result.status) && result.bridgeInstance == owner
    }

    private static func bridgeStopPath(bridgeDir: URL, dispatchId: String) -> URL {
        bridgeDir.appendingPathComponent("stops/\(dispatchId).json")
    }

    public static func requestAntigravityBridgeStop(
        dispatchId: String,
        bridgeDir: URL = defaultBridgeDir(),
        expectedOwner: String? = nil
    ) -> String? {
        guard UUID(uuidString: dispatchId) != nil,
              isAntigravityBridgeHealthy(bridgeDir: bridgeDir),
              let owner = bridgeStopOwner(bridgeDir: bridgeDir) else { return nil }
        if let expectedOwner {
            guard owner == expectedOwner else { return nil }
        } else {
            guard let result = readBridgeResult(bridgeDir: bridgeDir, dispatchId: dispatchId),
                  ["starting", "running"].contains(result.status), result.bridgeInstance == owner else { return nil }
        }
        let path = bridgeStopPath(bridgeDir: bridgeDir, dispatchId: dispatchId)
        if let data = try? Data(contentsOf: path),
           let pending = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           pending["bridge_instance"] == owner,
           let existing = pending["stop_request_id"], UUID(uuidString: existing) != nil {
            return existing
        }
        let requestId = UUID().uuidString.lowercased()
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let payload = try JSONSerialization.data(withJSONObject: [
                "bridge_instance": owner, "stop_request_id": requestId
            ])
            try payload.write(to: path, options: .atomic)
            return requestId
        } catch {
            return nil
        }
    }

    public static func readBridgeResult(
        bridgeDir: URL = defaultBridgeDir(),
        dispatchId: String
    ) -> BridgeResult? {
        let resURL = bridgeDir.appendingPathComponent("results/\(dispatchId).json")
        guard let data = try? Data(contentsOf: resURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var replyEvidence: BridgeReplyEvidence?
        if let reply = obj["reply_evidence"] as? [String: Any],
           let offset = reply["offset"] as? UInt64,
           let length = reply["length"] as? Int, (1...4_194_304).contains(length),
           let step = reply["step_index"] as? Int, step >= 0 {
            replyEvidence = BridgeReplyEvidence(offset: offset, length: length, stepIndex: step)
        }
        return BridgeResult(
            status: (obj["status"] as? String) ?? "",
            conversationId: (obj["conversation_id"] as? String) ?? "",
            error: (obj["error"] as? String) ?? "",
            bridgeInstance: (obj["bridge_instance"] as? String) ?? "",
            stopRequestId: (obj["stop_request_id"] as? String) ?? "",
            replyEvidence: replyEvidence,
            updatedAt: (obj["updated_at"] as? NSNumber)?.int64Value
        )
    }

    public static let missingAntigravityReplySummary = "Antigravity reported completion without a confirmed reply for this run"

    public static func antigravityCompletion(
        _ result: BridgeResult, transcriptPath: String
    ) -> (status: TodoDispatchStatus, summary: String, reply: String) {
        guard let evidence = result.replyEvidence,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath)) else {
            return (.needsAttention, missingAntigravityReplySummary, "")
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: evidence.offset)) != nil,
              let data = try? handle.read(upToCount: evidence.length), data.count == evidence.length,
              let step = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (step["step_index"] as? Int) == evidence.stepIndex,
              ["PLANNER_RESPONSE", "NOTIFY_USER"].contains(step["type"] as? String ?? ""),
              (step["status"] as? String) == "DONE",
              let reply = step["content"] as? String, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (.needsAttention, missingAntigravityReplySummary, "")
        }
        let status = ConversationTracker.evaluateCompletion(exitCode: 0, latestAssistantReply: reply, hasPendingUserTurn: false)
        return (status, String(reply.replacingOccurrences(of: "\n", with: " ").prefix(240)), reply)
    }

    public static func extractCodexThreadId(fromJSONL text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let tid = (obj["thread_id"] as? String) ?? (obj["session_id"] as? String), !tid.isEmpty {
                return tid
            }
            if let pl = obj["payload"] as? [String: Any],
               let tid = (pl["thread_id"] as? String) ?? (pl["id"] as? String), !tid.isEmpty {
                return tid
            }
        }
        return ""
    }

    public static func parseCodexAppServerThreadResponse(_ obj: [String: Any]) -> (threadId: String, path: String, source: String)? {
        guard let result = obj["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String, !id.isEmpty else {
            return nil
        }
        return (
            threadId: id,
            path: (thread["path"] as? String) ?? "",
            source: (thread["source"] as? String) ?? ""
        )
    }

    public static func parseCodexAppServerTurnCompleted(_ obj: [String: Any]) -> (turnId: String, status: String, assistantText: String, errorMessage: String)? {
        guard obj["method"] as? String == "turn/completed",
              let params = obj["params"] as? [String: Any],
              let turn = params["turn"] as? [String: Any],
              let status = turn["status"] as? String else {
            return nil
        }
        let turnId = (turn["id"] as? String) ?? ""
        let errorMsg = (turn["error"] as? [String: Any])?["message"] as? String ?? ""
        var latestText = ""
        if let items = turn["items"] as? [[String: Any]] {
            for item in items where (item["type"] as? String) == "agentMessage" {
                if let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { latestText = trimmed }
                }
            }
        }
        return (turnId: turnId, status: status, assistantText: latestText, errorMessage: errorMsg)
    }

    public static func buildCodexAppServerThreadParams(
        method: String,
        threadId: String?,
        cwd: String
    ) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": "never"
        ]
        if method == "thread/resume" || method == "thread/fork" {
            params["excludeTurns"] = true
            if let threadId, !threadId.isEmpty {
                params["threadId"] = threadId
            }
        }
        if method == "thread/fork" || method == "thread/start" {
            params["ephemeral"] = false
            params["threadSource"] = "user"
        }
        return params
    }

    public static func formatCodexThreadTitle(project: String, startedAt: Int64) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm"
        let timeStr = df.string(from: Date(timeIntervalSince1970: TimeInterval(startedAt)))
        let cleanProj = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "[TodoNotch] "
        let suffix = " \(timeStr)"
        let maxBodyLen = max(1, 80 - prefix.count - suffix.count)
        let body = String((cleanProj.isEmpty ? "Codex" : cleanProj).prefix(maxBodyLen))
        return "\(prefix)\(body)\(suffix)"
    }

    private func executeRun(
        recordKey: String,
        dispatchId: String,
        project: String,
        displayText: String,
        target: ResolvedTodoTarget,
        prompt: String,
        vaultPath: String,
        logDir: URL,
        requireDesktopSession: Bool,
        allowAntigravityNewSessionFallback: Bool,
        accessGrants: [String] = [],
        sidecarId: String = "",
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        bridgeDir: URL? = nil,
        onStarted: @escaping @Sendable (TodoDispatchRecord) -> Void,
        onCompleted: @escaping @Sendable (TodoDispatchRecord) -> Void
    ) {
        let now = Int64(Date().timeIntervalSince1970)
        let activeBridgeDir = bridgeDir ?? Self.defaultBridgeDir(homeDir: homeDir)

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFileURL = logDir.appendingPathComponent("\(dispatchId).log")
        if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
            onCompleted(Self.stoppedRecord(
                recordKey: recordKey, dispatchId: dispatchId, project: project, displayText: displayText,
                agent: target.agent, sessionId: target.sessionId, cwd: target.cwd,
                transcriptPath: target.transcriptPath, logPath: logFileURL.path, startedAt: now
            ))
            return
        }

        let bridgeOwner = target.agent == "antigravity" ? Self.bridgeStopOwner(bridgeDir: activeBridgeDir) : nil
        if target.agent == "antigravity",
           Self.isAntigravityBridgeHealthy(bridgeDir: activeBridgeDir, now: now),
           !requireDesktopSession || bridgeOwner != nil {
            executeViaAntigravityBridge(
                dispatchId: dispatchId,
                recordKey: recordKey,
                project: project,
                displayText: displayText,
                target: target,
                prompt: prompt,
                sidecarId: sidecarId,
                homeDir: homeDir,
                bridgeDir: activeBridgeDir,
                bridgeOwner: bridgeOwner,
                logFileURL: logFileURL,
                startedAt: now,
                onStarted: onStarted,
                onCompleted: onCompleted
            )
            return
        }

        if requireDesktopSession && target.agent == "antigravity" {
            onCompleted(TodoDispatchRecord(
                todoKey: recordKey, dispatchId: dispatchId, project: project, todoText: displayText,
                agent: target.agent, sessionId: "", cwd: target.cwd, status: .failed,
                summary: "Open Antigravity Desktop and enable the updated TodoNotch bridge to run this task",
                dispatchedAt: now, updatedAt: now
            ))
            return
        }

        let env = Self.buildEnvironment(homeDir: homeDir)
        let outputFileURL = logDir.appendingPathComponent("\(dispatchId)-last.txt")

        guard let executable = Self.resolveExecutable(agent: target.agent, envPath: env["PATH"] ?? "") else {
            let failRec = TodoDispatchRecord(
                todoKey: recordKey,
                dispatchId: dispatchId,
                project: project,
                todoText: displayText,
                agent: target.agent,
                sessionId: target.sessionId,
                cwd: target.cwd,
                transcriptPath: target.transcriptPath,
                logPath: logFileURL.path,
                status: .failed,
                summary: "CLI not found for \(target.agent)",
                dispatchedAt: now,
                updatedAt: now
            )
            onCompleted(failRec)
            return
        }

        if target.agent == "codex",
           executeViaCodexAppServer(
               executable: executable,
               env: env,
               dispatchId: dispatchId,
               recordKey: recordKey,
               project: project,
               displayText: displayText,
               target: target,
               prompt: prompt,
               vaultPath: vaultPath,
               homeDir: homeDir,
               logFileURL: logFileURL,
               startedAt: now,
               onStarted: onStarted,
               onCompleted: onCompleted
           ) {
            return
        }

        if requireDesktopSession && target.agent == "codex" {
            onCompleted(TodoDispatchRecord(
                todoKey: recordKey, dispatchId: dispatchId, project: project, todoText: displayText,
                agent: target.agent, sessionId: "", cwd: target.cwd, status: .failed,
                summary: "Could not start Codex app-server for a desktop session",
                dispatchedAt: now, updatedAt: now
            ))
            return
        }

        let cmd = Self.buildCommand(
            agent: target.agent,
            executable: executable,
            target: target,
            prompt: prompt,
            outputFile: outputFileURL.path,
            accessGrants: accessGrants
        )

        var preRunTranscriptMtime = ConversationTracker.fileMtime(target.transcriptPath)
        var initialRec = TodoDispatchRecord(
            todoKey: recordKey,
            dispatchId: dispatchId,
            project: project,
            todoText: displayText,
            agent: target.agent,
            sessionId: target.sessionId,
            cwd: target.cwd,
            transcriptPath: target.transcriptPath,
            logPath: logFileURL.path,
            status: .running,
            summary: "",
            dispatchedAt: now,
            updatedAt: now,
            lastTranscriptMtime: preRunTranscriptMtime,
            pid: 0
        )


        func attachTreeCancel(pid: Int32, proc: Process?) {
            guard pid > 0 || proc != nil else { return }
            self.updateRunCancel(recordKey: recordKey, dispatchId: dispatchId, pid: pid) {
                DispatchQueue.global(qos: .utility).async {
                    if pid > 0 {
                        _ = Self.terminateProcessTreeAndWait(pid, graceSeconds: 1.5)
                    } else if let proc, proc.isRunning {
                        proc.terminate()
                    }
                }
            }
        }

        var (exitCode, stdoutData) = self.runProcess(
            executable: cmd.executable,
            arguments: cmd.arguments,
            cwd: target.cwd,
            env: env,
            logFileURL: logFileURL,
            onLaunched: { pid, proc in
                initialRec.pid = pid
                attachTreeCancel(pid: pid, proc: proc)
                onStarted(initialRec)
            }
        )

        var activeTarget = target
        if !isCancelled(recordKey: recordKey, dispatchId: dispatchId),
           allowAntigravityNewSessionFallback,
           exitCode != 0, target.agent == "antigravity", target.sessionExists,
           let outStr = String(data: stdoutData, encoding: .utf8),
           outStr.lowercased().contains("not_found") {
            activeTarget = ResolvedTodoTarget(
                agent: target.agent,
                sessionId: "",
                sessionExists: false,
                cwd: target.cwd,
                transcriptPath: "",
                excerptPath: target.excerptPath
            )
            preRunTranscriptMtime = 0
            let fallbackItem = TodoItem(id: 0, section: "personal", project: project, text: displayText, done: false, todoKey: recordKey)
            let fallbackPrompt = Self.buildPrompt(item: fallbackItem, target: activeTarget)
            let retryCmd = Self.buildCommand(
                agent: activeTarget.agent,
                executable: executable,
                target: activeTarget,
                prompt: fallbackPrompt,
                outputFile: outputFileURL.path,
                accessGrants: accessGrants
            )
            (exitCode, stdoutData) = self.runProcess(
                executable: retryCmd.executable,
                arguments: retryCmd.arguments,
                cwd: activeTarget.cwd,
                env: env,
                logFileURL: logFileURL,
                onLaunched: { pid, proc in
                    initialRec.pid = pid
                    initialRec.sessionId = ""
                    attachTreeCancel(pid: pid, proc: proc)
                    onStarted(initialRec)
                }
            )
        } else if !isCancelled(recordKey: recordKey, dispatchId: dispatchId),
                  exitCode != 0, target.agent == "codex", target.sessionExists {
            // Codex Desktop (ChatGPT.app) holds an active writer lock on open threads.
            // Fall back to `codex exec fork` (keeps thread context), then fresh `codex exec`.
            let outStr = String(decoding: stdoutData, as: UTF8.self)
            if Self.isCodexResumeConflictError(outStr) {
                activeTarget = ResolvedTodoTarget(
                    agent: "codex",
                    sessionId: "",
                    sessionExists: false,
                    cwd: target.cwd,
                    transcriptPath: "",
                    excerptPath: target.excerptPath
                )
                preRunTranscriptMtime = 0
                let forkCmd = Self.buildCodexForkCommand(
                    executable: executable,
                    sessionId: target.sessionId,
                    prompt: prompt,
                    outputFile: outputFileURL.path
                )
                (exitCode, stdoutData) = self.runProcess(
                    executable: forkCmd.executable,
                    arguments: forkCmd.arguments,
                    cwd: activeTarget.cwd,
                    env: env,
                    logFileURL: logFileURL,
                    onLaunched: { pid, proc in
                        initialRec.pid = pid
                        initialRec.sessionId = ""
                        attachTreeCancel(pid: pid, proc: proc)
                        onStarted(initialRec)
                    }
                )
                if !isCancelled(recordKey: recordKey, dispatchId: dispatchId), exitCode != 0 {
                    let freshCmd = Self.buildCommand(
                        agent: "codex",
                        executable: executable,
                        target: activeTarget,
                        prompt: prompt,
                        outputFile: outputFileURL.path
                    )
                    (exitCode, stdoutData) = self.runProcess(
                        executable: freshCmd.executable,
                        arguments: freshCmd.arguments,
                        cwd: activeTarget.cwd,
                        env: env,
                        logFileURL: logFileURL,
                        onLaunched: { pid, proc in
                            initialRec.pid = pid
                            initialRec.sessionId = ""
                            attachTreeCancel(pid: pid, proc: proc)
                            onStarted(initialRec)
                        }
                    )
                }
            }
        }

        let parsedMeta = self.parseProcessOutput(
            agent: activeTarget.agent,
            stdoutData: stdoutData,
            outputFileURL: outputFileURL
        )
        var finalSessionId = parsedMeta.sessionId.isEmpty ? activeTarget.sessionId : parsedMeta.sessionId
        var finalTranscript = activeTarget.transcriptPath
        if !finalSessionId.isEmpty, (finalTranscript.isEmpty || !FileManager.default.fileExists(atPath: finalTranscript)) {
            let fakeRef = TodoSourceRef(agent: activeTarget.agent, sessionPrefix: finalSessionId)
            let fakeItem = TodoItem(id: 0, section: "personal", project: project, text: displayText, done: false, sources: [fakeRef], todoKey: recordKey)
            let refreshed = TodoTargetResolver.resolve(item: fakeItem, vaultPath: vaultPath, homeDir: homeDir)
            if !refreshed.transcriptPath.isEmpty { finalTranscript = refreshed.transcriptPath }
            if !refreshed.sessionId.isEmpty { finalSessionId = refreshed.sessionId }
        }

        if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
            onCompleted(Self.stoppedRecord(
                recordKey: recordKey,
                dispatchId: dispatchId,
                project: project,
                displayText: displayText,
                agent: activeTarget.agent,
                sessionId: finalSessionId,
                cwd: activeTarget.cwd,
                transcriptPath: finalTranscript,
                logPath: logFileURL.path,
                startedAt: initialRec.dispatchedAt
            ))
            return
        }

        let transcriptUpdated = !finalTranscript.isEmpty && ConversationTracker.fileMtime(finalTranscript) > preRunTranscriptMtime
        let skipStaleTranscript = exitCode != 0 && parsedMeta.assistantText.isEmpty && !transcriptUpdated

        let turns = ConversationTracker.readConversationTurns(
            agent: activeTarget.agent,
            transcriptPath: skipStaleTranscript ? "" : finalTranscript,
            excerptPath: activeTarget.excerptPath,
            logPath: logFileURL.path,
            maxTurns: 6,
            fallbackPrompt: prompt
        )
        let latestAssistant: String
        if skipStaleTranscript {
            latestAssistant = ""
        } else if !parsedMeta.assistantText.isEmpty {
            latestAssistant = parsedMeta.assistantText
        } else {
            latestAssistant = turns.last(where: { $0.role == "assistant" })?.text ?? ""
        }
        let hasPendingUser = turns.last?.role == "user"

        let finalStatus = ConversationTracker.evaluateCompletion(
            exitCode: exitCode,
            latestAssistantReply: latestAssistant,
            hasPendingUserTurn: hasPendingUser,
            deniedActions: parsedMeta.deniedActions
        )
        let summaryText: String
        if !latestAssistant.isEmpty {
            summaryText = String(latestAssistant.replacingOccurrences(of: "\n", with: " ").prefix(240))
        } else if exitCode != 0 {
            let errSummary = Self.extractProcessErrorSummary(from: stdoutData)
            summaryText = errSummary.isEmpty ? "Exit code \(exitCode)" : errSummary
        } else {
            summaryText = "Completed"
        }

        let doneTime = Int64(Date().timeIntervalSince1970)
        let completedRec = TodoDispatchRecord(
            todoKey: recordKey,
            dispatchId: dispatchId,
            project: project,
            todoText: displayText,
            agent: activeTarget.agent,
            sessionId: finalSessionId,
            cwd: activeTarget.cwd,
            transcriptPath: finalTranscript,
            logPath: logFileURL.path,
            status: finalStatus,
            summary: summaryText,
            dispatchedAt: initialRec.dispatchedAt,
            updatedAt: doneTime,
            lastTranscriptMtime: ConversationTracker.fileMtime(finalTranscript),
            pid: 0
        )
        onCompleted(completedRec)
    }

    /// Runs Codex via official `codex app-server` JSON-RPC so threads are created with
    /// `source = "vscode"` and appear live in Codex Desktop's sidebar.
    /// Returns `false` only if spawning `codex app-server` itself fails.
    private static func readCodexPipe(
        _ handle: FileHandle, process: Process, drainUntil: inout ContinuousClock.Instant?
    ) -> Data {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            if !process.isRunning {
                let deadline = drainUntil ?? ContinuousClock.now + .milliseconds(250)
                drainUntil = deadline
                if ContinuousClock.now >= deadline { return Data() }
            }
            let result = Darwin.poll(&descriptor, 1, 100)
            if result > 0 { return handle.availableData }
            if result < 0, errno != EINTR { return Data() }
        }
    }

    private func executeViaCodexAppServer(
        executable: String,
        env: [String: String],
        dispatchId: String,
        recordKey: String,
        project: String,
        displayText: String,
        target: ResolvedTodoTarget,
        prompt: String,
        vaultPath: String,
        homeDir: URL,
        logFileURL: URL,
        startedAt: Int64,
        onStarted: @escaping @Sendable (TodoDispatchRecord) -> Void,
        onCompleted: @escaping @Sendable (TodoDispatchRecord) -> Void
    ) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["app-server"]
        var isDir: ObjCBool = false
        if !target.cwd.isEmpty, FileManager.default.fileExists(atPath: target.cwd, isDirectory: &isDir), isDir.boolValue {
            proc.currentDirectoryURL = URL(fileURLWithPath: target.cwd)
        }
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return false
        }

        final class LockedLines: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) {
                lock.lock()
                lines.append(line)
                lock.unlock()
            }
            func joined() -> String {
                lock.lock()
                defer { lock.unlock() }
                return lines.isEmpty ? "" : (lines.joined(separator: "\n") + "\n")
            }
        }

        final class CodexInput: @unchecked Sendable {
            private struct StopState {
                var requested = false
                var turn: (threadId: String, turnId: String)?
            }

            private let lock = NSLock()
            private let stopState = OSAllocatedUnfairLock(initialState: StopState())
            private let stdin: FileHandle
            private let terminate: @Sendable () -> Void

            init(stdin: FileHandle, terminate: @escaping @Sendable () -> Void) {
                self.stdin = stdin
                self.terminate = terminate
            }

            func send(_ payload: [String: Any]) throws {
                lock.lock()
                defer { lock.unlock() }
                try write(payload)
            }

            func startTurn(_ payload: [String: Any]) throws -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !stopState.withLock({ $0.requested }) else { return false }
                try write(payload)
                return true
            }

            func identifyTurn(threadId: String, turnId: String) {
                guard !threadId.isEmpty, !turnId.isEmpty else { return }
                let shouldInterrupt = stopState.withLock { state in
                    guard state.turn == nil else { return false }
                    state.turn = (threadId, turnId)
                    return state.requested
                }
                if shouldInterrupt { interrupt(threadId: threadId, turnId: turnId) }
            }

            func stop() {
                let (firstRequest, turn) = stopState.withLock { state in
                    guard !state.requested else { return (false, state.turn) }
                    state.requested = true
                    return (true, state.turn)
                }
                guard firstRequest else { return }
                // Arm the timeout before touching a pipe that might be blocked by the server.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: terminate)
                if let turn { interrupt(threadId: turn.threadId, turnId: turn.turnId) }
            }

            func close() {
                lock.lock()
                defer { lock.unlock() }
                try? stdin.close()
            }

            private func interrupt(threadId: String, turnId: String) {
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    try? send(["id": 98, "method": "turn/interrupt", "params": [
                        "threadId": threadId, "turnId": turnId
                    ]])
                }
            }

            private func write(_ payload: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
                data.append(0x0A)
                try stdin.write(contentsOf: data)
            }
        }

        let pid = proc.processIdentifier
        let ownedGroup = getpgid(pid) == pid ? pid : nil
        let cleanupStarted = OSAllocatedUnfairLock(initialState: false)
        let cleanupFinished = DispatchGroup()
        let cleanupSucceeded = OSAllocatedUnfairLock(initialState: true)
        cleanupFinished.enter()
        let terminate: @Sendable () -> Void = {
            guard cleanupStarted.withLock({ started in
                guard !started else { return false }
                started = true
                return true
            }) else { return }
            defer { cleanupFinished.leave() }
            let running = proc.isRunning
            guard running || ownedGroup.map({ Darwin.kill(-$0, 0) == 0 }) == true else { return }
            let terminated = Self.terminateProcessTreeAndWait(pid, ownedGroup: ownedGroup, rootRunning: running)
            cleanupSucceeded.withLock { $0 = terminated }
        }
        proc.terminationHandler = { _ in
            DispatchQueue.global(qos: .utility).async(execute: terminate)
        }
        if !proc.isRunning { DispatchQueue.global(qos: .utility).async(execute: terminate) }
        let input = CodexInput(stdin: stdinPipe.fileHandleForWriting, terminate: terminate)
        updateRunCancel(recordKey: recordKey, dispatchId: dispatchId, pid: pid) { input.stop() }

        let logBuffer = LockedLines()
        func appendLog(_ line: String) {
            logBuffer.append(String(line.prefix(4096)))
        }
        func flushLogs() {
            try? Data(logBuffer.joined().utf8).write(to: logFileURL, options: .atomic)
        }

        let stderrGroup = DispatchGroup()
        stderrGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            var stderr = Data()
            var drainUntil: ContinuousClock.Instant?
            while true {
                let chunk = Self.readCodexPipe(stderrPipe.fileHandleForReading, process: proc, drainUntil: &drainUntil)
                if chunk.isEmpty { break }
                stderr.append(contentsOf: chunk.prefix(max(0, 4096 - stderr.count)))
            }
            let errText = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !errText.isEmpty { logBuffer.append("[stderr] \\(errText)") }
            stderrGroup.leave()
        }

        func sendRPC(_ payload: [String: Any]) throws {
            try input.send(payload)
        }

        var readBuffer = Data()
        var scanOffset = 0
        var stdoutDrainUntil: ContinuousClock.Instant?
        func readNextJSONObject() -> [String: Any]? {
            let fh = stdoutPipe.fileHandleForReading
            while true {
                let searchStart = readBuffer.index(readBuffer.startIndex, offsetBy: min(scanOffset, readBuffer.count))
                if let nlIdx = readBuffer[searchStart...].firstIndex(of: 0x0A) {
                    let lineData = readBuffer.subdata(in: readBuffer.startIndex..<nlIdx)
                    readBuffer.removeSubrange(readBuffer.startIndex...nlIdx)
                    scanOffset = 0
                    if lineData.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
                    let previewData = lineData.prefix(16_384)
                    appendLog(String(decoding: previewData, as: UTF8.self))
                    if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        return obj
                    }
                    continue
                }
                scanOffset = readBuffer.count
                let chunk = Self.readCodexPipe(fh, process: proc, drainUntil: &stdoutDrainUntil)
                if chunk.isEmpty {
                    if !readBuffer.isEmpty {
                        let tail = readBuffer
                        readBuffer.removeAll(keepingCapacity: false)
                        scanOffset = 0
                        if !tail.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                            appendLog(String(decoding: tail.prefix(16_384), as: UTF8.self))
                            if let obj = try? JSONSerialization.jsonObject(with: tail) as? [String: Any] {
                                return obj
                            }
                        }
                    }
                    return nil
                }
                readBuffer.append(chunk)
            }
        }

        var streamedAgentMessage = ""
        var startedTurnId = ""
        var completedTurn: (turnId: String, status: String, assistantText: String, errorMessage: String)?
        var topLevelError = ""

        func processNotification(_ msg: [String: Any], targetThreadId: String = "") {
            let method = (msg["method"] as? String) ?? ""
            if method == "turn/started",
               let params = msg["params"] as? [String: Any],
               let turn = params["turn"] as? [String: Any],
               let tid = turn["id"] as? String, !tid.isEmpty {
                let eventThread = (params["threadId"] as? String) ?? ""
                if targetThreadId.isEmpty || eventThread.isEmpty || eventThread == targetThreadId {
                    if startedTurnId.isEmpty {
                        startedTurnId = tid
                        input.identifyTurn(threadId: eventThread.isEmpty ? targetThreadId : eventThread, turnId: tid)
                    }
                }
            } else if method == "item/completed",
               let params = msg["params"] as? [String: Any],
               let item = params["item"] as? [String: Any],
               (item["type"] as? String) == "agentMessage",
               let text = item["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { streamedAgentMessage = trimmed }
            } else if let parsedTurn = Self.parseCodexAppServerTurnCompleted(msg) {
                let eventThread = ((msg["params"] as? [String: Any])?["threadId"] as? String) ?? ""
                let threadMatches = targetThreadId.isEmpty || eventThread.isEmpty || eventThread == targetThreadId
                let turnMatches = parsedTurn.turnId.isEmpty || startedTurnId.isEmpty || parsedTurn.turnId == startedTurnId
                if threadMatches && turnMatches && parsedTurn.status != "inProgress" {
                    completedTurn = parsedTurn
                }
            } else if method == "error",
                      let params = msg["params"] as? [String: Any],
                      let errObj = params["error"] as? [String: Any],
                      let errMsg = errObj["message"] as? String, !errMsg.isEmpty {
                topLevelError = errMsg
            }
        }

        func readUntilResponse(id targetId: Int, targetThreadId: String = "") -> [String: Any]? {
            while let msg = readNextJSONObject() {
                if let respId = (msg["id"] as? NSNumber)?.intValue, respId == targetId {
                    return msg
                }
                processNotification(msg, targetThreadId: targetThreadId)
            }
            return nil
        }

        func rpcErrorMessage(_ resp: [String: Any]?) -> String {
            guard let resp else { return "codex app-server closed unexpectedly" }
            if let err = resp["error"] as? [String: Any] {
                return (err["message"] as? String) ?? "JSON-RPC error"
            }
            return ""
        }

        @discardableResult
        func cleanupProcess() -> Bool {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: terminate)
            input.close()
            proc.waitUntilExit()
            terminate()
            cleanupFinished.wait()
            proc.terminationHandler = nil
            _ = stderrGroup.wait(timeout: .now() + 1.0)
            flushLogs()
            return cleanupSucceeded.withLock { $0 }
        }

        func publishStop(cleanedUp: Bool, sessionId: String, transcriptPath: String) {
            var record = Self.stoppedRecord(
                recordKey: recordKey,
                dispatchId: dispatchId,
                project: project,
                displayText: displayText,
                agent: "codex",
                sessionId: sessionId,
                cwd: target.cwd,
                transcriptPath: transcriptPath,
                logPath: logFileURL.path,
                startedAt: startedAt
            )
            if !cleanedUp {
                record.status = .failed
                record.summary = "Codex stopped responding but child-process cleanup could not be confirmed"
            }
            onCompleted(record)
        }

        func finishStopped(sessionId: String = target.sessionId, transcriptPath: String = target.transcriptPath) {
            publishStop(cleanedUp: cleanupProcess(), sessionId: sessionId, transcriptPath: transcriptPath)
        }

        func finishWithFailure(
            _ message: String, treatCancelAsStopped: Bool = true,
            sessionId: String = target.sessionId, transcriptPath: String = target.transcriptPath
        ) {
            if treatCancelAsStopped && isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
                finishStopped(sessionId: sessionId, transcriptPath: transcriptPath)
                return
            }
            cleanupProcess()
            let doneTime = Int64(Date().timeIntervalSince1970)
            onCompleted(TodoDispatchRecord(
                todoKey: recordKey,
                dispatchId: dispatchId,
                project: project,
                todoText: displayText,
                agent: "codex",
                sessionId: sessionId,
                cwd: target.cwd,
                transcriptPath: transcriptPath,
                logPath: logFileURL.path,
                status: .failed,
                summary: String(message.prefix(240)),
                dispatchedAt: startedAt,
                updatedAt: doneTime,
                lastTranscriptMtime: ConversationTracker.fileMtime(transcriptPath),
                pid: 0
            ))
        }

        do {
            // 1. Initialize handshake
            try sendRPC([
                "id": 1,
                "method": "initialize",
                "params": ["clientInfo": ["name": "todonotch", "title": "TodoNotch", "version": "1.0.0"]]
            ])
            guard let initResp = readUntilResponse(id: 1), initResp["error"] == nil else {
                finishWithFailure("Codex app-server initialize failed: \(rpcErrorMessage(nil))")
                return true
            }
            if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
                finishStopped()
                return true
            }
            try sendRPC(["method": "initialized", "params": [:]])

            // 2. Resume -> fork -> start thread (excludeTurns keeps metadata fast; always yields source = "vscode")
            var threadResp: [String: Any]?
            var createdNewOrForkedThread = false
            if target.sessionExists && !target.sessionId.isEmpty {
                try sendRPC([
                    "id": 2,
                    "method": "thread/resume",
                    "params": Self.buildCodexAppServerThreadParams(method: "thread/resume", threadId: target.sessionId, cwd: target.cwd)
                ])
                let r2 = readUntilResponse(id: 2)
                if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
                    finishStopped()
                    return true
                }
                if r2 != nil && r2?["error"] == nil {
                    threadResp = r2
                } else {
                    try sendRPC([
                        "id": 3,
                        "method": "thread/fork",
                        "params": Self.buildCodexAppServerThreadParams(method: "thread/fork", threadId: target.sessionId, cwd: target.cwd)
                    ])
                    let r3 = readUntilResponse(id: 3)
                    if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
                        finishStopped()
                        return true
                    }
                    if r3 != nil && r3?["error"] == nil {
                        threadResp = r3
                        createdNewOrForkedThread = true
                    } else {
                        try sendRPC([
                            "id": 4,
                            "method": "thread/start",
                            "params": Self.buildCodexAppServerThreadParams(method: "thread/start", threadId: nil, cwd: target.cwd)
                        ])
                        threadResp = readUntilResponse(id: 4)
                        createdNewOrForkedThread = true
                    }
                }
            } else {
                try sendRPC([
                    "id": 2,
                    "method": "thread/start",
                    "params": Self.buildCodexAppServerThreadParams(method: "thread/start", threadId: nil, cwd: target.cwd)
                ])
                threadResp = readUntilResponse(id: 2)
                createdNewOrForkedThread = true
            }

            if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
                finishStopped()
                return true
            }

            guard let resp = threadResp, resp["error"] == nil,
                  let threadInfo = Self.parseCodexAppServerThreadResponse(resp) else {
                finishWithFailure("Codex thread setup failed: \(rpcErrorMessage(threadResp))")
                return true
            }

            let finalSessionId = threadInfo.threadId
            if createdNewOrForkedThread {
                try? sendRPC([
                    "id": 6,
                    "method": "thread/name/set",
                    "params": [
                        "threadId": finalSessionId,
                        "name": Self.formatCodexThreadTitle(project: project, startedAt: startedAt)
                    ]
                ])
                _ = readUntilResponse(id: 6)
                if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
                    finishStopped(sessionId: finalSessionId)
                    return true
                }
            }
            var finalTranscript = threadInfo.path
            if finalTranscript.isEmpty || !FileManager.default.fileExists(atPath: finalTranscript) {
                let fakeRef = TodoSourceRef(agent: "codex", sessionPrefix: finalSessionId)
                let fakeItem = TodoItem(id: 0, section: "personal", project: project, text: displayText, done: false, sources: [fakeRef], todoKey: recordKey)
                let resolved = TodoTargetResolver.resolve(item: fakeItem, vaultPath: vaultPath, homeDir: homeDir)
                if !resolved.transcriptPath.isEmpty { finalTranscript = resolved.transcriptPath }
            }
            let preRunMtime = ConversationTracker.fileMtime(finalTranscript)
            flushLogs()

            onStarted(TodoDispatchRecord(
                todoKey: recordKey,
                dispatchId: dispatchId,
                project: project,
                todoText: displayText,
                agent: "codex",
                sessionId: finalSessionId,
                cwd: target.cwd,
                transcriptPath: finalTranscript,
                logPath: logFileURL.path,
                status: .running,
                summary: "",
                dispatchedAt: startedAt,
                updatedAt: startedAt,
                lastTranscriptMtime: preRunMtime,
                pid: pid
            ))

            // The start response may arrive after the user clicks Stop. Keep reading to get its turn ID.
            guard try input.startTurn([
                "id": 5,
                "method": "turn/start",
                "params": [
                    "threadId": finalSessionId,
                    "cwd": target.cwd,
                    "approvalPolicy": "never",
                    "input": [["type": "text", "text": prompt]]
                ]
            ]) else {
                finishStopped(sessionId: finalSessionId, transcriptPath: finalTranscript)
                return true
            }
            let turnStartResp = readUntilResponse(id: 5, targetThreadId: finalSessionId)
            if turnStartResp == nil || turnStartResp?["error"] != nil {
                finishWithFailure(
                    "Codex turn/start failed: \(rpcErrorMessage(turnStartResp))",
                    treatCancelAsStopped: false,
                    sessionId: finalSessionId,
                    transcriptPath: finalTranscript
                )
                return true
            }
            if let turnObj = (turnStartResp?["result"] as? [String: Any])?["turn"] as? [String: Any],
               let tid = turnObj["id"] as? String, !tid.isEmpty, startedTurnId.isEmpty {
                startedTurnId = tid
                input.identifyTurn(threadId: finalSessionId, turnId: tid)
            }

            while completedTurn == nil {
                guard let msg = readNextJSONObject() else { break }
                processNotification(msg, targetThreadId: finalSessionId)
            }

            if proc.isRunning, completedTurn != nil {
                try? sendRPC([
                    "id": 7,
                    "method": "thread/unsubscribe",
                    "params": ["threadId": finalSessionId]
                ])
            }
            let cleanedUp = cleanupProcess()

            if finalTranscript.isEmpty || !FileManager.default.fileExists(atPath: finalTranscript) {
                let fakeRef = TodoSourceRef(agent: "codex", sessionPrefix: finalSessionId)
                let fakeItem = TodoItem(id: 0, section: "personal", project: project, text: displayText, done: false, sources: [fakeRef], todoKey: recordKey)
                let resolved = TodoTargetResolver.resolve(item: fakeItem, vaultPath: vaultPath, homeDir: homeDir)
                if !resolved.transcriptPath.isEmpty { finalTranscript = resolved.transcriptPath }
            }

            if completedTurn?.status == "interrupted" {
                publishStop(cleanedUp: cleanedUp, sessionId: finalSessionId, transcriptPath: finalTranscript)
                return true
            }

            let turnFailed = (completedTurn?.status == "failed" || completedTurn?.status == "interrupted")
            let exitCode: Int32 = turnFailed ? 1 : (completedTurn?.status == "completed" ? 0 : 1)
            let transcriptUpdated = !finalTranscript.isEmpty && ConversationTracker.fileMtime(finalTranscript) > preRunMtime
            let skipStale = exitCode != 0 && streamedAgentMessage.isEmpty && (completedTurn?.assistantText.isEmpty ?? true) && !transcriptUpdated

            let turns = ConversationTracker.readConversationTurns(
                agent: "codex",
                transcriptPath: skipStale ? "" : finalTranscript,
                excerptPath: target.excerptPath,
                logPath: logFileURL.path,
                maxTurns: 6,
                fallbackPrompt: prompt
            )
            let replyFromRpc = (completedTurn?.assistantText.isEmpty == false) ? completedTurn!.assistantText : streamedAgentMessage
            let latestAssistant: String
            if !replyFromRpc.isEmpty {
                latestAssistant = replyFromRpc
            } else if !skipStale {
                latestAssistant = turns.last(where: { $0.role == "assistant" })?.text ?? ""
            } else {
                latestAssistant = ""
            }

            let hasPendingUser = turns.last?.role == "user"
            let finalStatus = ConversationTracker.evaluateCompletion(
                exitCode: exitCode,
                latestAssistantReply: latestAssistant,
                hasPendingUserTurn: hasPendingUser,
                deniedActions: []
            )
            let stopUnconfirmed = isCancelled(recordKey: recordKey, dispatchId: dispatchId)
                && completedTurn?.status != "completed"
            let errText = [completedTurn?.errorMessage ?? "", topLevelError]
                .first(where: { !$0.isEmpty }) ?? ""
            let summaryText: String
            if stopUnconfirmed {
                summaryText = "Codex exited without confirming the interruption"
            } else if !latestAssistant.isEmpty {
                summaryText = String(latestAssistant.replacingOccurrences(of: "\n", with: " ").prefix(240))
            } else if !errText.isEmpty {
                summaryText = String(errText.prefix(240))
            } else {
                summaryText = exitCode == 0 ? "Completed" : "Codex turn did not complete"
            }

            let doneTime = Int64(Date().timeIntervalSince1970)
            onCompleted(TodoDispatchRecord(
                todoKey: recordKey,
                dispatchId: dispatchId,
                project: project,
                todoText: displayText,
                agent: "codex",
                sessionId: finalSessionId,
                cwd: target.cwd,
                transcriptPath: finalTranscript,
                logPath: logFileURL.path,
                status: stopUnconfirmed ? .failed : finalStatus,
                summary: summaryText,
                dispatchedAt: startedAt,
                updatedAt: doneTime,
                lastTranscriptMtime: ConversationTracker.fileMtime(finalTranscript),
                pid: 0
            ))
            return true
        } catch {
            if isCancelled(recordKey: recordKey, dispatchId: dispatchId) {
                finishStopped()
                return true
            }
            finishWithFailure("Codex app-server write failed: \(error.localizedDescription)")
            return true
        }
    }

    private func executeViaAntigravityBridge(
        dispatchId: String,
        recordKey: String,
        project: String,
        displayText: String,
        target: ResolvedTodoTarget,
        prompt: String,
        sidecarId: String,
        homeDir: URL,
        bridgeDir: URL,
        bridgeOwner: String?,
        logFileURL: URL,
        startedAt: Int64,
        onStarted: @escaping @Sendable (TodoDispatchRecord) -> Void,
        onCompleted: @escaping @Sendable (TodoDispatchRecord) -> Void
    ) {
        let requestsDir = bridgeDir.appendingPathComponent("requests")
        try? FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)

        let stopFile = Self.bridgeStopPath(bridgeDir: bridgeDir, dispatchId: dispatchId)
        let stopSent = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        updateRunCancel(recordKey: recordKey, dispatchId: dispatchId) {
            let token = Self.requestAntigravityBridgeStop(
                dispatchId: dispatchId, bridgeDir: bridgeDir, expectedOwner: bridgeOwner
            )
            stopSent.withLock { $0 = token ?? "" }
        }

        func readOwnedResult() -> BridgeResult? {
            guard let result = Self.readBridgeResult(bridgeDir: bridgeDir, dispatchId: dispatchId),
                  bridgeOwner == nil || result.bridgeInstance == bridgeOwner else { return nil }
            return result
        }

        func bridgeStillOwnsRun() -> Bool {
            Self.isAntigravityBridgeHealthy(bridgeDir: bridgeDir)
                && bridgeOwner == Self.bridgeStopOwner(bridgeDir: bridgeDir)
        }

        let reqPayload: [String: Any] = [
            "dispatch_id": dispatchId,
            "bridge_instance": bridgeOwner ?? "",
            "record_key": recordKey,
            "mode": (target.sessionExists && !target.sessionId.isEmpty) ? "resume" : "new",
            "session_id": target.sessionId,
            "project_name": project,
            "cwd": target.cwd,
            "title": String(project.prefix(60)),
            "prompt": prompt,
            "sidecar_id": sidecarId
        ]
        let reqTmp = requestsDir.appendingPathComponent(".\(dispatchId).tmp.json")
        let reqFinal = requestsDir.appendingPathComponent("\(dispatchId).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: reqPayload)
            try data.write(to: reqTmp, options: .atomic)
            try FileManager.default.moveItem(at: reqTmp, to: reqFinal)
        } catch {
            try? FileManager.default.removeItem(at: reqTmp)
            try? FileManager.default.removeItem(at: stopFile)
            onCompleted(TodoDispatchRecord(
                todoKey: recordKey, dispatchId: dispatchId, project: project, todoText: displayText,
                agent: "antigravity", sessionId: "", cwd: target.cwd, status: .failed,
                summary: "Could not submit the request to Antigravity Desktop",
                dispatchedAt: startedAt, updatedAt: startedAt
            ))
            return
        }

        // The bridge may acknowledge a request before the native conversation exists.
        var initialResult: BridgeResult?
        let acceptDeadline = Date().addingTimeInterval(35)
        while Date() < acceptDeadline {
            if let res = readOwnedResult(),
               (!res.conversationId.isEmpty || res.status == "failed" || res.status == "stopped") {
                initialResult = res
                break
            }
            if !bridgeStillOwnsRun() { break }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let convId = initialResult?.conversationId ?? (target.sessionExists ? target.sessionId : "")
        let transcriptPath: String
        if !convId.isEmpty {
            transcriptPath = homeDir
                .appendingPathComponent(".gemini/antigravity/brain/\(convId)/.system_generated/logs/transcript.jsonl")
                .path
        } else {
            transcriptPath = target.transcriptPath
        }

        var startedRec = TodoDispatchRecord(
            todoKey: recordKey,
            dispatchId: dispatchId,
            project: project,
            todoText: displayText,
            agent: "antigravity",
            sessionId: convId,
            cwd: target.cwd,
            transcriptPath: transcriptPath,
            logPath: logFileURL.path,
            status: .running,
            summary: "",
            dispatchedAt: startedAt,
            updatedAt: startedAt,
            lastTranscriptMtime: ConversationTracker.fileMtime(transcriptPath),
            pid: 0
        )
        onStarted(startedRec)

        var finalResult = initialResult
        let runDeadline = Date().addingTimeInterval(1800)
        while Date() < runDeadline {
            if let latest = readOwnedResult() { finalResult = latest }
            if let status = finalResult?.status, !["starting", "running"].contains(status) { break }
            if !bridgeStillOwnsRun() { break }

            if let latest = finalResult, !latest.conversationId.isEmpty, latest.conversationId != startedRec.sessionId {
                startedRec.sessionId = latest.conversationId
                startedRec.transcriptPath = homeDir
                    .appendingPathComponent(".gemini/antigravity/brain/\(latest.conversationId)/.system_generated/logs/transcript.jsonl").path
                onStarted(startedRec)
            }
            if let token = stopSent.withLock({ $0 }) {
                let rejected = finalResult?.status == "running" && finalResult?.stopRequestId == token
                if token.isEmpty || rejected {
                    clearCancelRequest(recordKey: recordKey, dispatchId: dispatchId)
                    startedRec.summary = finalResult?.error.isEmpty == false && rejected
                        ? finalResult!.error : "The Antigravity bridge could not accept the stop request"
                    onStarted(startedRec)
                    startedRec.summary = ""
                    stopSent.withLock { if $0 == token { $0 = nil } }
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        // A terminal receipt can be committed just before a replacement bridge updates its heartbeat.
        if let latest = readOwnedResult() { finalResult = latest }
        if (try? FileManager.default.removeItem(at: reqFinal)) != nil, finalResult == nil {
            finalResult = BridgeResult(status: "failed", conversationId: "", error: "Antigravity Desktop did not claim this request")
        }
        try? FileManager.default.removeItem(at: stopFile)
        let finalConvId = finalResult?.conversationId.isEmpty == false ? finalResult!.conversationId : startedRec.sessionId
        let finalTranscript = !finalConvId.isEmpty
            ? homeDir.appendingPathComponent(".gemini/antigravity/brain/\(finalConvId)/.system_generated/logs/transcript.jsonl").path
            : transcriptPath

        if finalResult?.status == "stopped" {
            let logLines = [
                "bridge_mode: antigravity_desktop",
                "conversation_id: \(finalConvId)",
                "status: stopped"
            ].joined(separator: "\n")
            try? Data(logLines.utf8).write(to: logFileURL, options: .atomic)
            onCompleted(Self.stoppedRecord(
                recordKey: recordKey,
                dispatchId: dispatchId,
                project: project,
                displayText: displayText,
                agent: "antigravity",
                sessionId: finalConvId,
                cwd: target.cwd,
                transcriptPath: finalTranscript,
                logPath: logFileURL.path,
                startedAt: startedAt
            ))
            return
        }

        let status: TodoDispatchStatus
        let summaryText: String
        let latestAssistant: String
        if let result = finalResult, result.status == "completed" {
            (status, summaryText, latestAssistant) = Self.antigravityCompletion(result, transcriptPath: finalTranscript)
        } else if let result = finalResult, result.status == "failed" {
            status = .failed
            summaryText = result.error.isEmpty ? "Antigravity Desktop failed" : String(result.error.prefix(240))
            latestAssistant = ""
        } else {
            status = .needsAttention
            summaryText = Self.unconfirmedAntigravitySummary
            latestAssistant = ""
        }

        let bridgeError = latestAssistant.isEmpty ? summaryText : ""
        let logLines = [
            "bridge_mode: antigravity_desktop",
            "conversation_id: \(finalConvId)",
            "status: \(status.rawValue)",
            bridgeError.isEmpty ? "" : "error: \(bridgeError)",
            latestAssistant.isEmpty ? "" : "\n--- Assistant ---\n\(latestAssistant)"
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        try? Data(logLines.utf8).write(to: logFileURL, options: .atomic)

        let doneTime = Int64(Date().timeIntervalSince1970)
        onCompleted(TodoDispatchRecord(
            todoKey: recordKey,
            dispatchId: dispatchId,
            project: project,
            todoText: displayText,
            agent: "antigravity",
            sessionId: finalConvId,
            cwd: target.cwd,
            transcriptPath: finalTranscript,
            logPath: logFileURL.path,
            status: status,
            summary: summaryText,
            dispatchedAt: startedAt,
            updatedAt: doneTime,
            lastTranscriptMtime: ConversationTracker.fileMtime(finalTranscript),
            pid: 0
        ))
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        cwd: String,
        env: [String: String],
        logFileURL: URL,
        onLaunched: (Int32, Process?) -> Void
    ) -> (Int32, Data) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
            onLaunched(proc.processIdentifier, proc)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            try? data.write(to: logFileURL, options: .atomic)
            return (proc.terminationStatus, data)
        } catch {
            let msg = "Launch failed: \(error.localizedDescription)\n"
            let data = Data(msg.utf8)
            try? data.write(to: logFileURL, options: .atomic)
            onLaunched(0, nil)
            return (-1, data)
        }
    }

    private func parseProcessOutput(
        agent: String,
        stdoutData: Data,
        outputFileURL: URL
    ) -> (sessionId: String, assistantText: String, deniedActions: [String]) {
        let raw = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if agent == "codex" {
            let tid = Self.extractCodexThreadId(fromJSONL: raw)
            if let outText = try? String(contentsOf: outputFileURL, encoding: .utf8) {
                let trimmed = outText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return (tid, trimmed, [])
                }
            }
            return (tid, "", [])
        }
        guard !raw.isEmpty else { return ("", "", []) }
        if let obj = ConversationTracker.parseTrailingJSONObject(from: raw) {
            let sid = (obj["session_id"] as? String)
                ?? (obj["sessionID"] as? String)
                ?? (obj["sessionId"] as? String)
                ?? (obj["conversation_id"] as? String)
                ?? (obj["conversationId"] as? String)
                ?? ""
            var text = ""
            for key in ["result", "response", "text", "message", "content"] {
                if let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if text.isEmpty {
                text = extractMultiLineAgentText(fromJSONL: raw)
            }
            let denied = ConversationTracker.extractDeniedActions(from: obj)
            if text.isEmpty && !denied.isEmpty {
                text = "权限受限被拦截（\(denied.joined(separator: ", "))），无法在无头模式下自动继续"
            }
            let fallbackSid = sid.isEmpty ? Self.extractCodexThreadId(fromJSONL: raw) : sid
            return (fallbackSid, text, denied)
        }
        return (Self.extractCodexThreadId(fromJSONL: raw), raw, [])
    }

    private func extractMultiLineAgentText(fromJSONL raw: String) -> String {
        var latest = ""
        for line in raw.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.hasPrefix("{"),
                  let data = clean.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let part = obj["part"] as? [String: Any],
               part["type"] as? String == "text",
               let t = part["text"] as? String, !t.isEmpty {
                latest = t.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let msg = obj["message"] as? [String: Any],
                      msg["role"] as? String == "assistant",
                      let arr = msg["content"] as? [[String: Any]] {
                let joined = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { latest = joined }
            }
        }
        return latest
    }
}
