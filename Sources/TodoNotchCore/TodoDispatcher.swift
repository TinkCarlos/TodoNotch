import Foundation

public enum ConversationTracker {
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


public final class TodoDispatchRunner: @unchecked Sendable {
    public struct BridgeReplyEvidence: Equatable, Sendable {
        public let offset: UInt64
        public let length: Int
        public let stepIndex: Int
    }

    public struct BridgeResult: Equatable, Sendable {
        public let status: String
        public let conversationId: String
        public let error: String
        public let replyEvidence: BridgeReplyEvidence?
        public let updatedAt: Int64?

        public init(
            status: String, conversationId: String, error: String,
            replyEvidence: BridgeReplyEvidence? = nil, updatedAt: Int64? = nil
        ) {
            self.status = status
            self.conversationId = conversationId
            self.error = error
            self.replyEvidence = replyEvidence
            self.updatedAt = updatedAt
        }
    }

    public static func defaultBridgeDir(
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDir.appendingPathComponent("Library/Application Support/TodoNotch/bridge")
    }

    public static let unconfirmedAntigravitySummary = "Antigravity Desktop did not confirm the final state"

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

}
