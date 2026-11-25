import Foundation

// MARK: - Webhook Client (HTTPS POST, Keychain URL)

public enum PushError: LocalizedError, Sendable {
    case missingSecret(String)
    case invalidConfig(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingSecret(let m): return m
        case .invalidConfig(let m): return m
        case .network(let m): return m
        }
    }
}

public struct WebhookHTTPClient: Sendable {
    public init() {}

    public func send(kind: WebhookKind, urlString: String, title: String, body: String) async throws {
        guard ValidationHelpers.isValidWebhookURL(urlString), let url = URL(string: urlString) else {
            throw PushError.invalidConfig("Webhook URL 不合法（仅允许 https:// 或 localhost）")
        }
        let payload = buildPayload(kind: kind, title: title, body: body)
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard jsonData.count <= 16_384 else {
            throw PushError.invalidConfig("Webhook 载荷超过 16 KB 上限")
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw PushError.network("Webhook 未收到有效 HTTP 响应")
            }
            guard (200...299).contains(http.statusCode) else {
                // Never include full URL (contains embedded secret token) in error string
                throw PushError.network("Webhook 返回 HTTP \(http.statusCode)")
            }
        } catch let err as PushError {
            throw err
        } catch {
            throw PushError.network("Webhook 网络不可达或超时")
        }
    }

    public func buildPayload(kind: WebhookKind, title: String, body: String) -> [String: Any] {
        let text = "【\(title)】\n\(body)"
        switch kind {
        case .feishu:
            return ["msg_type": "text", "content": ["text": text]]
        case .wecom:
            return ["msgtype": "markdown", "markdown": ["content": "**\(title)**\n\(body)"]]
        case .dingtalk:
            return ["msgtype": "markdown", "markdown": ["title": title, "text": "### \(title)\n\(body)"]]
        case .bark:
            return ["title": title, "body": body, "group": "TodoNotch"]
        case .generic:
            return ["source": "TodoNotch", "title": title, "body": body, "timestamp": Int64(Date().timeIntervalSince1970)]
        }
    }
}

// MARK: - Push Dispatcher (Webhook)

public actor PushDispatcher {
    private let store: SQLiteStore
    private let secrets: SecretStoreProtocol
    private let webhook = WebhookHTTPClient()

    public init(store: SQLiteStore, secrets: SecretStoreProtocol) {
        self.store = store
        self.secrets = secrets
    }

    public func dispatch(event: RunEvent, config: AppConfig) async {
        guard config.webhookEnabled else { return }
        do {
            guard let url = secrets.loadSecret(account: SecretAccount.webhookURL), !url.isEmpty else {
                throw PushError.missingSecret("未在钥匙串配置 Webhook URL")
            }
            try await webhook.send(kind: config.webhookKind, urlString: url, title: event.taskName, body: event.summary)
            store.appendAudit(action: "push_webhook", target: event.taskKey, result: "ok", detail: "已推送至 \(config.webhookKind.zhLabel)")
            store.updateEventPush(eventId: event.eventId, status: "sent", error: "")
        } catch {
            let msg = error.localizedDescription
            store.appendAudit(action: "push_webhook", target: event.taskKey, result: "failed", detail: msg)
            store.updateEventPush(eventId: event.eventId, status: "failed", error: "Webhook: \(msg)")
        }
    }

    public func sendTestWebhook(config: AppConfig) async -> Result<String, Error> {
        do {
            guard let url = secrets.loadSecret(account: SecretAccount.webhookURL), !url.isEmpty else {
                throw PushError.missingSecret("请先输入并保存 Webhook URL")
            }
            try await webhook.send(kind: config.webhookKind, urlString: url, title: "TodoNotch 测试通知", body: "Webhook 通道连接正常，定时任务异常与重点通知将推送至此。")
            store.appendAudit(action: "push_webhook", target: "test", result: "ok", detail: "测试 Webhook 成功")
            return .success("测试消息已推送至 \(config.webhookKind.zhLabel)")
        } catch {
            store.appendAudit(action: "push_webhook", target: "test", result: "failed", detail: error.localizedDescription)
            return .failure(error)
        }
    }
}
