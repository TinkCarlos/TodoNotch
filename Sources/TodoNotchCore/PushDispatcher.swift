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

    public func send(kind: WebhookKind, urlString: String, title: String, body: String, lang: AppLanguage = .zhHans) async throws {
        guard ValidationHelpers.isValidWebhookURL(urlString), let url = URL(string: urlString) else {
            throw PushError.invalidConfig(L10n.webhookInvalidURL(lang))
        }
        let payload = buildPayload(kind: kind, title: title, body: body, lang: lang)
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard jsonData.count <= 16_384 else {
            throw PushError.invalidConfig(L10n.webhookPayloadTooLarge(lang))
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw PushError.network(L10n.webhookInvalidResponse(lang))
            }
            guard (200...299).contains(http.statusCode) else {
                // Never include full URL (contains embedded secret token) in error string
                throw PushError.network(L10n.webhookHTTPStatus(http.statusCode, lang))
            }
        } catch let err as PushError {
            throw err
        } catch {
            throw PushError.network(L10n.webhookNetworkUnreachable(lang))
        }
    }

    public func buildPayload(kind: WebhookKind, title: String, body: String, lang: AppLanguage = .zhHans) -> [String: Any] {
        let text = lang == .zhHans ? "【\(title)】\n\(body)" : "[\(title)]\n\(body)"
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

    public func dispatch(event: RunEvent, config: AppConfig, lang: AppLanguage = .zhHans) async {
        guard config.webhookEnabled else { return }
        do {
            guard let url = secrets.loadSecret(account: SecretAccount.webhookURL), !url.isEmpty else {
                throw PushError.missingSecret(L10n.webhookMissingInKeychain(lang))
            }
            try await webhook.send(
                kind: config.webhookKind,
                urlString: url,
                title: L10n.displayTaskName(event.taskName, source: event.source, lang: lang),
                body: L10n.displayEventSummary(event.summary, status: event.status, lang: lang),
                lang: lang
            )
            store.appendAudit(action: "push_webhook", target: event.taskKey, result: "ok", detail: "sent via \(config.webhookKind.rawValue)")
            store.updateEventPush(eventId: event.eventId, status: "sent", error: "")
        } catch {
            let msg = error.localizedDescription
            store.appendAudit(action: "push_webhook", target: event.taskKey, result: "failed", detail: msg)
            store.updateEventPush(eventId: event.eventId, status: "failed", error: "Webhook: \(msg)")
        }
    }

    public func sendTestWebhook(config: AppConfig, lang: AppLanguage = .zhHans) async -> Result<String, Error> {
        do {
            guard let url = secrets.loadSecret(account: SecretAccount.webhookURL), !url.isEmpty else {
                throw PushError.missingSecret(L10n.webhookEnterURLFirst(lang))
            }
            try await webhook.send(
                kind: config.webhookKind,
                urlString: url,
                title: L10n.webhookTestTitle(lang),
                body: L10n.webhookTestBody(lang),
                lang: lang
            )
            store.appendAudit(action: "push_webhook", target: "test", result: "ok", detail: "test webhook succeeded")
            return .success(L10n.webhookTestSent(config.webhookKind, lang))
        } catch {
            store.appendAudit(action: "push_webhook", target: "test", result: "failed", detail: error.localizedDescription)
            return .failure(error)
        }
    }
}
