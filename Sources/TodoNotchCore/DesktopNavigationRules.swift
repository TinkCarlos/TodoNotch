import Foundation

public enum DesktopNavigationRules {
    public enum Stage: String, Sendable {
        case validation, applicationLookup, accessibility, launch, deepLink
        case webArea, sidebar, emptyFilter, taskFilter, taskDetail
    }

    public enum Outcome: String, CaseIterable, Sendable {
        case opened, accepted, cancelled, needsAccessibility, appNotInstalled, launchFailed, deepLinkRejected
        case invalidTaskId, unsupportedSource, ambiguousMatches, notFound, timedOut, wrongTask

        public var presentation: Presentation {
            switch self {
            case .opened, .accepted: .closePanel
            case .cancelled: .none
            case .needsAccessibility: .accessibilityToast
            case .ambiguousMatches: .warningToast
            default: .errorToast
            }
        }
    }

    public enum Presentation: Equatable, Sendable {
        case closePanel, none, accessibilityToast, warningToast, errorToast
    }

    public struct Row: Equatable, Sendable {
        public let name: String
        public let nativeId: String?
        public let isLocal: Bool

        public init(name: String, nativeId: String? = nil, isLocal: Bool = true) {
            self.name = name
            self.nativeId = nativeId
            self.isLocal = isLocal
        }
    }

    public enum RowDecision: Equatable, Sendable {
        case wait, press(Int), ambiguous, notFound
    }

    public static func isValidNativeId(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        return id.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 48...57, 65...90, 95, 97...122: true
            default: false
            }
        }
    }

    public static func codexURL(nativeId: String) -> URL? {
        guard isValidNativeId(nativeId) else { return nil }
        return URL(string: "codex://automations/\(nativeId)?automationSource=local")
    }

    public static func detailMatches(_ url: URL, nativeId: String) -> Bool {
        guard isValidNativeId(nativeId) else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/sidecars/\(nativeId)"
    }

    public static func isFilteredList(_ url: URL, query: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == "/sidecars" else { return false }
        let queries = components.queryItems?.filter { $0.name == "q" } ?? []
        return queries.count == 1 && queries.first?.value == query
    }

    public static func isEmptyResults(_ text: String, query: String) -> Bool {
        guard isValidNativeId(query) else { return false }
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let english = normalized.lowercased()
        if english.hasPrefix("no "), let match = english.range(of: " match ") {
            let echo = english[match.upperBound...].trimmingCharacters(in: .whitespaces)
            let value = query.lowercased()
            if echo == value || echo == value + "." { return true }
            for (open, close) in [("“", "”"), ("\"", "\""), ("‘", "’"), ("'", "'")] where echo.hasPrefix(open) {
                let content = echo.dropFirst()
                guard let end = content.lastIndex(of: Character(close)),
                      ["", "."].contains(String(content[content.index(after: end)...])) else { continue }
                if content[..<end].trimmingCharacters(in: .whitespaces) == value { return true }
            }
        }

        let pattern = "(?<![A-Za-z0-9._-])" + NSRegularExpression.escapedPattern(for: query) + "(?![A-Za-z0-9._-])"
        guard let echo = normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return false }
        let message = (normalized[..<echo.lowerBound] + normalized[echo.upperBound...])
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        return ["没有", "未找到", "找不到", "未发现", "无匹配", "沒有", "無符合", "無相符"]
            .contains(where: message.hasPrefix)
            && ["匹配", "符合", "相符", "结果", "結果"].contains(where: message.contains)
    }

    public enum RowKind: Equatable, Sendable {
        case local, cloud
    }

    public static func rowKind(name: String, toggleLabels: [String]) -> RowKind? {
        guard !name.isEmpty else { return nil }
        if ["Pause \(name)", "Resume \(name)", "暂停 \(name)", "恢复 \(name)", "暂停\(name)", "恢复\(name)"]
            .contains(where: toggleLabels.contains) { return .local }
        if ["Enable \(name)", "启用 \(name)", "启用\(name)", "啟用 \(name)", "啟用\(name)"]
            .contains(where: toggleLabels.contains) { return .cloud }
        return nil
    }

    public static func exposedRowID(_ identifier: String) -> String? {
        let prefix = "sidecar-row-"
        let id = identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : identifier
        guard isValidNativeId(id), !["sidecar-row", "cloud-trigger-row", "automation-row"].contains(identifier) else { return nil }
        return id
    }

    // A complete stable snapshot is required. Multiple local candidates (e.g. prefix-overlapping IDs)
    // require an exact unique displayName match; renamed tasks still work when only one local row exists.
    public static func decideRows(
        _ rows: [Row], nativeId: String, expectedName: String? = nil,
        sawEmptyBarrier: Bool, isExactFilter: Bool,
        isStable: Bool, isEmptyResult: Bool
    ) -> RowDecision {
        guard sawEmptyBarrier, isExactFilter, isStable else { return .wait }
        if isEmptyResult { return rows.isEmpty ? .notFound : .wait }
        if rows.isEmpty { return .wait }
        let local = rows.enumerated().filter {
            $0.element.isLocal && ($0.element.nativeId == nil || $0.element.nativeId == nativeId)
        }
        if local.isEmpty { return .notFound }
        if local.count == 1 { return .press(local[0].offset) }
        if let expectedName, !expectedName.isEmpty {
            let byName = local.filter { $0.element.name == expectedName }
            if byName.count == 1 { return .press(byName[0].offset) }
        }
        return .ambiguous
    }
}
