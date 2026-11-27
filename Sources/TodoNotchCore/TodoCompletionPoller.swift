import Foundation

public struct TodoEvidenceSession: Equatable, Sendable {
    public let agent: String
    public let sessionId: String
    public let mtime: Int64
    public let relation: String // "source" | "project"
    public let turns: [ConversationTurn]

    public init(
        agent: String,
        sessionId: String,
        mtime: Int64,
        relation: String,
        turns: [ConversationTurn]
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.mtime = mtime
        self.relation = relation
        self.turns = turns
    }
}

public struct TodoEvidencePacket: Equatable, Sendable {
    public let item: TodoItem
    public let fingerprint: String
    public let sessions: [TodoEvidenceSession]
    public let recentGitCommits: [String]

    public init(
        item: TodoItem,
        fingerprint: String,
        sessions: [TodoEvidenceSession],
        recentGitCommits: [String] = []
    ) {
        self.item = item
        self.fingerprint = fingerprint
        self.sessions = sessions
        self.recentGitCommits = recentGitCommits
    }
}

public struct TodoCompletionVerdict: Equatable, Sendable {
    public let todoKey: String
    public let completed: Bool
    public let confidence: String
    public let reason: String

    public init(todoKey: String, completed: Bool, confidence: String, reason: String) {
        self.todoKey = todoKey
        self.completed = completed
        self.confidence = confidence
        self.reason = reason
    }
}

public struct TodoCompletionPollResult: Equatable, Sendable {
    public let cliUsed: String
    public let checkedFingerprints: [String: String]
    public let completedVerdicts: [TodoCompletionVerdict]
    public let attemptedCLIs: [String]
    public let errorDetail: String

    public init(
        cliUsed: String = "",
        checkedFingerprints: [String: String] = [:],
        completedVerdicts: [TodoCompletionVerdict] = [],
        attemptedCLIs: [String] = [],
        errorDetail: String = ""
    ) {
        self.cliUsed = cliUsed
        self.checkedFingerprints = checkedFingerprints
        self.completedVerdicts = completedVerdicts
        self.attemptedCLIs = attemptedCLIs
        self.errorDetail = errorDetail
    }
}

public struct TodoCLIExecutionOutput: Sendable {
    public let exitCode: Int32
    public let output: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, output: String, stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public enum TodoCompletionPoller {
    public static let promptMarker = "[TodoNotch-Completion-Check]"
    public static let defaultCLIFallbackOrder: [String] = [
        "codex", "claude", "pi", "opencode", "cursor", "grok", "qoder", "antigravity"
    ]

    public typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ workingDirectory: URL,
        _ outputFile: String?,
        _ timeoutSeconds: TimeInterval
    ) -> TodoCLIExecutionOutput

    private struct ScannedSession: Sendable {
        let agent: String
        let sessionId: String
        let project: String
        let mtime: Int64
        let transcriptPath: String
        let excerptPath: String
    }

    public static func parseTodoBaselineTimestamp(
        markdown: String,
        fileMtime: Int64,
        overlapSeconds: Int64 = 600,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Int64 {
        let meta = TodoTargetResolver.parseFrontmatter(markdown)
        var parsedTs: Int64 = 0
        if let raw = meta["updated_at"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let fmtFrac = ISO8601DateFormatter()
            fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmtStd = ISO8601DateFormatter()
            fmtStd.formatOptions = [.withInternetDateTime]
            if let date = fmtFrac.date(from: raw) ?? fmtStd.date(from: raw) {
                parsedTs = Int64(date.timeIntervalSince1970)
            }
        }
        let base = parsedTs > 0 ? parsedTs : (fileMtime > 0 ? fileMtime : max(0, now - 86_400))
        return max(0, base - max(0, overlapSeconds))
    }

    public static func collectChangedCandidates(
        openTodos: [TodoItem],
        runningTodoKeys: Set<String>,
        baselineTs: Int64,
        previousFingerprints: [String: String],
        vaultPath: String,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeGitCommits: Bool = true
    ) -> [TodoEvidencePacket] {
        let eligible = openTodos.filter { !$0.done && !runningTodoKeys.contains($0.todoKey) }
        guard !eligible.isEmpty else { return [] }

        let recentSessions = scanRecentSessions(baselineTs: baselineTs, vaultPath: vaultPath, homeDir: homeDir)
        let sessionsByProj = Dictionary(grouping: recentSessions.filter {
            let p = $0.project.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !p.isEmpty && p != "unknown" && p != "综合"
        }, by: { $0.project.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        var gitCache: [String: [String]] = [:]
        var packets: [TodoEvidencePacket] = []

        for item in eligible {
            var sessionCandidates: [(agent: String, sessionId: String, mtime: Int64, relation: String, transcriptPath: String, excerptPath: String)] = []
            var seenSessionKeys = Set<String>()
            var fallbackCwd = ""

            for src in item.sources {
                let singleItem = TodoItem(
                    id: item.id,
                    section: item.section,
                    project: item.project,
                    text: item.text,
                    done: item.done,
                    sources: [src],
                    todoKey: item.todoKey
                )
                let resolved = TodoTargetResolver.resolve(item: singleItem, vaultPath: vaultPath, homeDir: homeDir)
                if fallbackCwd.isEmpty && !resolved.cwd.isEmpty {
                    fallbackCwd = resolved.cwd
                }
                let tPath = preferredAntigravityTranscriptPath(
                    agent: resolved.agent,
                    transcriptPath: resolved.transcriptPath
                )
                let tMtime = ConversationTracker.fileMtime(tPath)
                let eMtime = ConversationTracker.fileMtime(resolved.excerptPath)
                let mtime = max(tMtime, eMtime)
                let sid = resolved.sessionId.isEmpty ? src.sessionPrefix : resolved.sessionId
                let dedupKey = "\(resolved.agent.lowercased())|\(sid.lowercased())"
                if mtime > 0 && seenSessionKeys.insert(dedupKey).inserted {
                    sessionCandidates.append((
                        agent: resolved.agent.lowercased(),
                        sessionId: sid,
                        mtime: mtime,
                        relation: "source",
                        transcriptPath: tPath,
                        excerptPath: resolved.excerptPath
                    ))
                }
            }

            let projKey = item.project.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let projMatches = sessionsByProj[projKey] {
                var addedProj = 0
                for s in projMatches.sorted(by: { $0.mtime > $1.mtime }) {
                    let dedupKey = "\(s.agent.lowercased())|\(s.sessionId.lowercased())"
                    if seenSessionKeys.contains(dedupKey) { continue }
                    seenSessionKeys.insert(dedupKey)
                    sessionCandidates.append((
                        agent: s.agent,
                        sessionId: s.sessionId,
                        mtime: s.mtime,
                        relation: "project",
                        transcriptPath: s.transcriptPath,
                        excerptPath: s.excerptPath
                    ))
                    addedProj += 1
                    if addedProj >= 3 { break }
                }
            }

            var commits: [String] = []
            if includeGitCommits {
                let gitDir = resolveGitDirectory(project: item.project, preferredCwd: fallbackCwd, homeDir: homeDir)
                if !gitDir.isEmpty {
                    if let cached = gitCache[gitDir] {
                        commits = cached
                    } else {
                        let fetched = readRecentGitCommits(repoDir: gitDir, sinceTs: baselineTs)
                        gitCache[gitDir] = fetched
                        commits = fetched
                    }
                }
            }

            let hasUpdatedSession = sessionCandidates.contains { $0.mtime >= baselineTs }
            guard hasUpdatedSession || !commits.isEmpty else { continue }

            let sortedForFP = sessionCandidates
                .filter { $0.mtime >= baselineTs || $0.relation == "source" }
                .sorted { ($0.agent, $0.sessionId) < ($1.agent, $1.sessionId) }
            let commitHashes = commits.map { String($0.split(separator: " ", maxSplits: 1).first ?? "") }
            let fp = makeEvidenceFingerprint(
                todoKey: item.todoKey,
                sessions: sortedForFP.map { ($0.agent, $0.sessionId, $0.mtime) },
                commitHashes: commitHashes
            )
            if previousFingerprints[item.todoKey] == fp {
                continue
            }

            let orderedSessions = sessionCandidates
                .filter { $0.mtime >= baselineTs || $0.relation == "source" }
                .sorted { lhs, rhs in
                    let lUpdated = lhs.mtime >= baselineTs
                    let rUpdated = rhs.mtime >= baselineTs
                    if lUpdated != rUpdated { return lUpdated }
                    if lhs.relation != rhs.relation { return lhs.relation == "source" }
                    return lhs.mtime > rhs.mtime
                }
                .prefix(4)

            var evidenceSessions: [TodoEvidenceSession] = []
            for s in orderedSessions {
                let rawTurns = ConversationTracker.readConversationTurns(
                    agent: s.agent,
                    transcriptPath: s.transcriptPath,
                    excerptPath: s.excerptPath,
                    logPath: "",
                    maxTurns: 4
                )
                if rawTurns.contains(where: { $0.text.contains(promptMarker) }) {
                    continue
                }
                let clippedTurns = rawTurns.map { turn in
                    ConversationTurn(
                        id: turn.id,
                        role: turn.role,
                        text: turn.role == "user" ? clipHead(turn.text, limit: 600) : clipTail(turn.text, limit: 1600)
                    )
                }
                guard !clippedTurns.isEmpty else { continue }
                evidenceSessions.append(TodoEvidenceSession(
                    agent: s.agent,
                    sessionId: s.sessionId,
                    mtime: s.mtime,
                    relation: s.relation,
                    turns: clippedTurns
                ))
            }

            guard !evidenceSessions.isEmpty || !commits.isEmpty else { continue }
            packets.append(TodoEvidencePacket(
                item: item,
                fingerprint: fp,
                sessions: evidenceSessions,
                recentGitCommits: commits
            ))
        }

        return packets
    }

    public static func buildVerificationCommand(
        agent: String,
        executable: String,
        prompt: String,
        outputFile: String
    ) -> (executable: String, arguments: [String], readsOutputFile: Bool) {
        switch agent.lowercased() {
        case "codex":
            return (executable, [
                "exec", "--ephemeral", "-s", "read-only", "--skip-git-repo-check",
                "--color", "never", "-o", outputFile, prompt
            ], true)
        case "claude":
            return (executable, [
                "-p", "--no-session-persistence", "--tools", "", "--output-format", "text", prompt
            ], false)
        case "pi":
            return (executable, [
                "-p", "--no-session", "--no-tools", "--no-mcp", "--mode", "text", prompt
            ], false)
        case "opencode":
            return (executable, ["run", "--archived", "--format", "default", prompt], false)
        case "cursor":
            return (executable, ["-p", "--mode", "plan", "--output-format", "text", prompt], false)
        case "grok":
            return (executable, [
                "--output-format", "text", "--tools", "", "--max-turns", "1", "-p", prompt
            ], false)
        case "qoder":
            return (executable, [
                "-p", "--no-session-persistence", "--tools", "", "-o", "text", prompt
            ], false)
        default: // antigravity
            return (executable, [
                "--print", "--disable-slash-commands", "--output-format", "text", prompt
            ], false)
        }
    }

    public static func buildVerificationPrompt(candidates: [TodoEvidencePacket]) -> String {
        var lines: [String] = [
            promptMarker,
            "你是待办完成度只读核验助手。禁止调用任何工具、禁止执行命令或修改任何文件，仅根据下面给出的待办描述和最新真实会话/提交证据判断是否整条已完成。",
            "",
            "严格判定规则（宁可漏判，绝不误标）：",
            "1. 只有当证据明确证明该待办里的**全部**要求均已完成、上线/提交/交付或被明确取消时，才可返回 completed: true 且 confidence: \"high\"。",
            "2. 复合待办只要有任意子项仍阻塞、待确认、待提交/推送/部署、待验收或无证据证明完成，必须返回 completed: false。",
            "3. 若最新回复结尾仍出现「待你确认」「请拍板」「下一步」「未推送」「仍需」「暂未」「阻塞」等未闭环信号，必须返回 completed: false。",
            "4. 只输出严格 JSON，不要附加解释或 Markdown 标题之外的内容，格式如下：",
            "{\"results\":[{\"todoKey\":\"...\",\"completed\":false,\"confidence\":\"high|medium|low\",\"reason\":\"<=40字中文理由\"}]}",
            "",
            "待核验条目："
        ]

        for (idx, packet) in candidates.enumerated() {
            let cleanDesc = TodoMarkdownParser.stripSourceSuffix(packet.item.text)
            lines.append("### [\(idx + 1)] todoKey=\(packet.item.todoKey) | project=\(packet.item.project)")
            lines.append("待办原文: \(cleanDesc)")
            if !packet.recentGitCommits.isEmpty {
                lines.append("近期 Git 提交:")
                for c in packet.recentGitCommits {
                    lines.append("  - \(c)")
                }
            }
            if !packet.sessions.isEmpty {
                lines.append("相关会话近期轮次:")
                for s in packet.sessions {
                    let shortId = String(s.sessionId.prefix(8))
                    lines.append("  * [\(s.relation)] \(s.agent) (\(shortId))")
                    for t in s.turns {
                        let roleTag = t.role == "user" ? "用户" : "助手"
                        lines.append("    \(roleTag): \(t.text.replacingOccurrences(of: "\n", with: " "))")
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func parseVerificationResponse(
        _ raw: String,
        allowedKeys: Set<String>
    ) -> [TodoCompletionVerdict]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidatesToParse: [String] = [trimmed]
        if let fencedRange = trimmed.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) {
            let block = String(trimmed[fencedRange])
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidatesToParse.insert(block, at: 0)
        }
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace < lastBrace {
            candidatesToParse.append(String(trimmed[firstBrace...lastBrace]))
        }

        for jsonText in candidatesToParse {
            guard let data = jsonText.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["results"] as? [[String: Any]] else {
                continue
            }
            var verdicts: [TodoCompletionVerdict] = []
            var seen = Set<String>()
            for row in arr {
                guard let key = (row["todoKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      allowedKeys.contains(key),
                      seen.insert(key).inserted else {
                    continue
                }
                let completed = (row["completed"] as? Bool) ?? false
                let conf = ((row["confidence"] as? String) ?? "low")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let reason = String(((row["reason"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(120))
                verdicts.append(TodoCompletionVerdict(
                    todoKey: key,
                    completed: completed,
                    confidence: conf,
                    reason: reason
                ))
            }
            return verdicts
        }
        return nil
    }

    public static func verifyCandidates(
        candidates: [TodoEvidencePacket],
        cliOrder: [String] = defaultCLIFallbackOrder,
        environment: [String: String] = TodoDispatchRunner.buildEnvironment(),
        timeoutSeconds: TimeInterval = 90,
        executableResolver: ((String, String) -> String?)? = nil,
        commandRunner: CommandRunner? = nil
    ) -> TodoCompletionPollResult {
        guard !candidates.isEmpty else { return TodoCompletionPollResult() }

        let resolveExec = executableResolver ?? { agent, envPath in
            TodoDispatchRunner.resolveExecutable(agent: agent, envPath: envPath)
        }
        let runCommand = commandRunner ?? defaultCommandRunner
        let envPath = environment["PATH"] ?? ""
        let availableCLIs: [(agent: String, executable: String)] = cliOrder.compactMap { agent in
            guard let bin = resolveExec(agent, envPath) else { return nil }
            return (agent, bin)
        }
        guard !availableCLIs.isEmpty else {
            return TodoCompletionPollResult(errorDetail: "No supported Agent CLI found on PATH")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todonotch-poll-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var checkedFingerprints: [String: String] = [:]
        var completedVerdicts: [TodoCompletionVerdict] = []
        var attemptedCLIs: [String] = []
        var usedCLIs: [String] = []
        var errors: [String] = []

        let batchSize = 8
        var idx = 0
        while idx < candidates.count {
            let end = min(candidates.count, idx + batchSize)
            let batch = Array(candidates[idx..<end])
            idx = end

            let prompt = buildVerificationPrompt(candidates: batch)
            let allowedKeys = Set(batch.map { $0.item.todoKey })
            var batchVerdicts: [TodoCompletionVerdict]?

            for cli in availableCLIs {
                if !attemptedCLIs.contains(cli.agent) {
                    attemptedCLIs.append(cli.agent)
                }
                let outFile = workDir.appendingPathComponent("out-\(cli.agent)-\(UUID().uuidString).txt").path
                defer { try? FileManager.default.removeItem(atPath: outFile) }
                let spec = buildVerificationCommand(
                    agent: cli.agent,
                    executable: cli.executable,
                    prompt: prompt,
                    outputFile: outFile
                )
                let execOut = runCommand(
                    spec.executable,
                    spec.arguments,
                    environment,
                    workDir,
                    spec.readsOutputFile ? outFile : nil,
                    timeoutSeconds
                )
                if execOut.timedOut {
                    errors.append("\(cli.agent): timed out")
                    continue
                }
                if execOut.exitCode != 0 {
                    let msg = execOut.stderr.isEmpty ? execOut.output : execOut.stderr
                    errors.append("\(cli.agent): rc=\(execOut.exitCode) \(String(msg.prefix(100)))")
                    continue
                }
                if let parsed = parseVerificationResponse(execOut.output, allowedKeys: allowedKeys) {
                    batchVerdicts = parsed
                    if !usedCLIs.contains(cli.agent) {
                        usedCLIs.append(cli.agent)
                    }
                    break
                } else {
                    errors.append("\(cli.agent): invalid JSON output")
                }
            }

            if let verdicts = batchVerdicts {
                for packet in batch {
                    checkedFingerprints[packet.item.todoKey] = packet.fingerprint
                }
                for v in verdicts where v.completed && v.confidence == "high" {
                    completedVerdicts.append(v)
                }
            }
        }

        return TodoCompletionPollResult(
            cliUsed: usedCLIs.joined(separator: ","),
            checkedFingerprints: checkedFingerprints,
            completedVerdicts: completedVerdicts,
            attemptedCLIs: attemptedCLIs,
            errorDetail: completedVerdicts.isEmpty && checkedFingerprints.isEmpty
                ? errors.joined(separator: "; ")
                : ""
        )
    }

    public static func applyAutoCompletions(
        to markdown: String,
        verdicts: [TodoCompletionVerdict],
        runningTodoKeys: Set<String>
    ) -> (updatedMarkdown: String, completedKeys: [String]) {
        var current = markdown
        var completedKeys: [String] = []
        for verdict in verdicts {
            guard verdict.completed,
                  verdict.confidence == "high",
                  !runningTodoKeys.contains(verdict.todoKey) else {
                continue
            }
            if let next = TodoMarkdownParser.toggleTodo(in: current, todoKey: verdict.todoKey) {
                current = next
                completedKeys.append(verdict.todoKey)
            }
        }
        return (current, completedKeys)
    }

    // MARK: - Private Helpers

    private static let defaultCommandRunner: CommandRunner = { executable, arguments, environment, workingDirectory, outputFile, timeoutSeconds in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = environment
        proc.currentDirectoryURL = workingDirectory
        proc.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        final class PipeAccumulator: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            func string() -> String {
                lock.lock()
                defer { lock.unlock() }
                return String(decoding: data, as: UTF8.self)
            }
        }

        let outBuf = PipeAccumulator()
        let errBuf = PipeAccumulator()
        let ioGroup = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let chunk = outHandle.readDataToEndOfFile()
            outBuf.append(chunk)
            ioGroup.leave()
        }
        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let chunk = errHandle.readDataToEndOfFile()
            errBuf.append(chunk)
            ioGroup.leave()
        }

        do {
            try proc.run()
        } catch {
            return TodoCLIExecutionOutput(exitCode: -1, output: "", stderr: error.localizedDescription, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(max(1.0, timeoutSeconds))
        var timedOut = false
        while proc.isRunning {
            if Date() >= deadline {
                timedOut = true
                _ = TodoDispatchRunner.terminateProcessTreeAndWait(proc.processIdentifier, graceSeconds: 1.0)
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !timedOut {
            proc.waitUntilExit()
        }
        _ = ioGroup.wait(timeout: .now() + 2.0)

        var output = outBuf.string()
        if let outputFile,
           let fileText = try? String(contentsOfFile: outputFile, encoding: .utf8),
           !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = fileText
        }
        return TodoCLIExecutionOutput(
            exitCode: timedOut ? -1 : proc.terminationStatus,
            output: output,
            stderr: errBuf.string(),
            timedOut: timedOut
        )
    }

    private static func preferredAntigravityTranscriptPath(agent: String, transcriptPath: String) -> String {
        guard agent.lowercased() == "antigravity", !transcriptPath.isEmpty else { return transcriptPath }
        let url = URL(fileURLWithPath: transcriptPath)
        if url.lastPathComponent == "transcript.jsonl" {
            let full = url.deletingLastPathComponent().appendingPathComponent("transcript_full.jsonl").path
            if FileManager.default.fileExists(atPath: full),
               ConversationTracker.fileMtime(full) >= ConversationTracker.fileMtime(transcriptPath) {
                return full
            }
        }
        return transcriptPath
    }

    private static func scanRecentSessions(
        baselineTs: Int64,
        vaultPath: String,
        homeDir: URL
    ) -> [ScannedSession] {
        let fm = FileManager.default
        var byKey: [String: ScannedSession] = [:]

        func record(_ session: ScannedSession) {
            guard !session.sessionId.isEmpty, session.mtime >= baselineTs else { return }
            let key = "\(session.agent.lowercased())|\(session.sessionId.lowercased())"
            if let existing = byKey[key] {
                let mergedTranscript = !session.transcriptPath.isEmpty ? session.transcriptPath : existing.transcriptPath
                let mergedExcerpt = !session.excerptPath.isEmpty ? session.excerptPath : existing.excerptPath
                let mergedProj = (existing.project == "unknown" || existing.project.isEmpty) ? session.project : existing.project
                let newerMtime = max(existing.mtime, session.mtime)
                byKey[key] = ScannedSession(
                    agent: existing.agent,
                    sessionId: existing.sessionId,
                    project: mergedProj,
                    mtime: newerMtime,
                    transcriptPath: mergedTranscript,
                    excerptPath: mergedExcerpt
                )
            } else {
                byKey[key] = session
            }
        }

        // 1. Lmemory excerpts
        if !vaultPath.isEmpty {
            let excerptsDir = URL(fileURLWithPath: vaultPath).appendingPathComponent("05 时间日志/会话摘录")
            if let urls = try? fm.contentsOfDirectory(
                at: excerptsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for url in urls where url.pathExtension.lowercased() == "md" {
                    let mtime = ConversationTracker.fileMtime(url.path)
                    guard mtime >= baselineTs,
                          let head = ConversationTracker.readHeadBytes(path: url.path, maxBytes: 4096),
                          !head.contains(promptMarker) else {
                        continue
                    }
                    let meta = TodoTargetResolver.parseFrontmatter(head)
                    if (meta["type"] ?? "").lowercased() == "correction" { continue }
                    let agent = (meta["agent"] ?? "other").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let sessionId = (meta["session"] ?? url.deletingPathExtension().lastPathComponent)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    var project = (meta["project"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if project.isEmpty || project == "-" {
                        let root = (meta["project_root"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        project = root.isEmpty ? "unknown" : URL(fileURLWithPath: root).lastPathComponent
                    }
                    record(ScannedSession(
                        agent: agent,
                        sessionId: sessionId,
                        project: project,
                        mtime: mtime,
                        transcriptPath: "",
                        excerptPath: url.path
                    ))
                }
            }
        }

        // 2. Codex sessions (today and yesterday)
        let codexDir = homeDir.appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        let nowDate = Date()
        for dayOffset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: nowDate) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let dayDir = codexDir
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
            guard let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for file in files where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
                let mtime = ConversationTracker.fileMtime(file.path)
                guard mtime >= baselineTs,
                      let head = ConversationTracker.readHeadBytes(path: file.path, maxBytes: 8192),
                      !head.contains(promptMarker) else {
                    continue
                }
                var sid = ""
                var cwd = ""
                var skipAutomated = false
                for line in head.components(separatedBy: "\n") where !line.isEmpty {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["type"] as? String == "session_meta",
                          let pl = obj["payload"] as? [String: Any] else {
                        continue
                    }
                    sid = (pl["id"] as? String) ?? (pl["session_id"] as? String) ?? ""
                    cwd = (pl["cwd"] as? String) ?? ""
                    let src = ((pl["source"] as? String) ?? "").lowercased()
                    let origin = ((pl["originator"] as? String) ?? "").lowercased()
                    if origin.contains("exec") || src.contains("subagent") || src.contains("thread_spawn") {
                        skipAutomated = true
                    }
                    break
                }
                if skipAutomated { continue }
                if sid.isEmpty {
                    sid = extractUUIDSuffix(from: file.deletingPathExtension().lastPathComponent)
                }
                let project = cwd.isEmpty ? "unknown" : URL(fileURLWithPath: cwd).lastPathComponent
                record(ScannedSession(
                    agent: "codex",
                    sessionId: sid,
                    project: project,
                    mtime: mtime,
                    transcriptPath: file.path,
                    excerptPath: ""
                ))
            }
        }

        // 3. Antigravity transcripts
        let agyBrain = homeDir.appendingPathComponent(".gemini/antigravity/brain")
        if let convDirs = try? fm.contentsOfDirectory(at: agyBrain, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for convDir in convDirs {
                let logsDir = convDir.appendingPathComponent(".system_generated/logs")
                let fullPath = logsDir.appendingPathComponent("transcript_full.jsonl").path
                let stdPath = logsDir.appendingPathComponent("transcript.jsonl").path
                let chosen = fm.fileExists(atPath: fullPath) ? fullPath : stdPath
                guard fm.fileExists(atPath: chosen) else { continue }
                let mtime = ConversationTracker.fileMtime(chosen)
                guard mtime >= baselineTs else { continue }
                let head = ConversationTracker.readHeadBytes(path: chosen, maxBytes: 8192) ?? ""
                let tail = ConversationTracker.readTailBytes(path: chosen, maxBytes: 16_384) ?? ""
                if head.contains(promptMarker) || tail.contains(promptMarker) { continue }
                let project = extractProjectName(from: head + "\n" + tail) ?? "unknown"
                record(ScannedSession(
                    agent: "antigravity",
                    sessionId: convDir.lastPathComponent,
                    project: project,
                    mtime: mtime,
                    transcriptPath: chosen,
                    excerptPath: ""
                ))
            }
        }

        // 4. Claude Code & Cursor transcripts
        let claudeDir = homeDir.appendingPathComponent(".claude/projects")
        if let projDirs = try? fm.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for projDir in projDirs {
                guard let files = try? fm.contentsOfDirectory(at: projDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                for file in files where file.pathExtension == "jsonl" {
                    let mtime = ConversationTracker.fileMtime(file.path)
                    guard mtime >= baselineTs,
                          let head = ConversationTracker.readHeadBytes(path: file.path, maxBytes: 8192),
                          !head.contains(promptMarker) else {
                        continue
                    }
                    var sid = file.deletingPathExtension().lastPathComponent
                    var cwd = ""
                    var skip = false
                    for line in head.components(separatedBy: "\n").prefix(15) where !line.isEmpty {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if (obj["isSidechain"] as? Bool) == true || (obj["entrypoint"] as? String) == "sdk" {
                            skip = true
                            break
                        }
                        if let s = obj["sessionId"] as? String, !s.isEmpty { sid = s }
                        if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                    }
                    if skip { continue }
                    let project = cwd.isEmpty ? "unknown" : URL(fileURLWithPath: cwd).lastPathComponent
                    record(ScannedSession(
                        agent: "claude",
                        sessionId: sid,
                        project: project,
                        mtime: mtime,
                        transcriptPath: file.path,
                        excerptPath: ""
                    ))
                }
            }
        }

        let cursorDir = homeDir.appendingPathComponent(".cursor/projects")
        if let projDirs = try? fm.contentsOfDirectory(at: cursorDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for projDir in projDirs {
                let transcriptsDir = projDir.appendingPathComponent("agent-transcripts")
                guard let chatDirs = try? fm.contentsOfDirectory(at: transcriptsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                for chatDir in chatDirs {
                    guard let files = try? fm.contentsOfDirectory(at: chatDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                        continue
                    }
                    for file in files where file.pathExtension == "jsonl" {
                        let mtime = ConversationTracker.fileMtime(file.path)
                        guard mtime >= baselineTs,
                              let head = ConversationTracker.readHeadBytes(path: file.path, maxBytes: 8192),
                              !head.contains(promptMarker) else {
                            continue
                        }
                        let sid = file.deletingPathExtension().lastPathComponent
                        var cwd = ""
                        for line in head.components(separatedBy: "\n").prefix(10) where !line.isEmpty {
                            if let data = line.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let c = obj["cwd"] as? String, !c.isEmpty {
                                cwd = c
                                break
                            }
                        }
                        let fallbackProj = projDir.lastPathComponent.split(separator: "-").last.map(String.init) ?? "unknown"
                        let project = cwd.isEmpty ? fallbackProj : URL(fileURLWithPath: cwd).lastPathComponent
                        record(ScannedSession(
                            agent: "cursor",
                            sessionId: sid,
                            project: project,
                            mtime: mtime,
                            transcriptPath: file.path,
                            excerptPath: ""
                        ))
                    }
                }
            }
        }

        return Array(byKey.values)
    }

    private static func extractUUIDSuffix(from name: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9a-f]{8}-[0-9a-f-]{27})$"#, options: [.caseInsensitive]) else {
            return ""
        }
        let nsRange = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: name) else {
            return ""
        }
        return String(name[r])
    }

    private static func extractProjectName(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"/Users/[^/\s]+/projects/([^/\s)'"`]+)"#) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    private static func resolveGitDirectory(project: String, preferredCwd: String, homeDir: URL) -> String {
        let fm = FileManager.default
        let cleanProj = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanProj.isEmpty && cleanProj != "综合" && cleanProj != "unknown" {
            let direct = homeDir.appendingPathComponent("projects/\(cleanProj)").path
            if fm.fileExists(atPath: (direct as NSString).appendingPathComponent(".git")) {
                return direct
            }
        }
        if !preferredCwd.isEmpty && fm.fileExists(atPath: (preferredCwd as NSString).appendingPathComponent(".git")) {
            return preferredCwd
        }
        return ""
    }

    private static func readRecentGitCommits(repoDir: String, sinceTs: Int64) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repoDir, "log", "--since=@\(sinceTs)", "--format=%h %cs %s", "-n", "5"]
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning {
            if Date() >= deadline {
                _ = TodoDispatchRunner.terminateProcessTreeAndWait(proc.processIdentifier, graceSeconds: 0.3)
                return []
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard proc.terminationStatus == 0 else { return [] }
        let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func makeEvidenceFingerprint(
        todoKey: String,
        sessions: [(agent: String, sessionId: String, mtime: Int64)],
        commitHashes: [String]
    ) -> String {
        let sessPart = sessions.map { "\($0.agent):\($0.sessionId):\($0.mtime)" }.joined(separator: ";")
        let gitPart = commitHashes.joined(separator: ",")
        let canonical = "\(todoKey)|\(sessPart)|\(gitPart)"
        var hash: UInt64 = 14695981039346656037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private static func clipHead(_ text: String, limit: Int) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if normalized.count <= limit { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private static func clipTail(_ text: String, limit: Int) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= limit { return normalized }
        return "…" + String(normalized.suffix(limit))
    }
}
