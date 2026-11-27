import AppKit
import ApplicationServices
import CryptoKit
import OSLog
import TodoNotchCore

@MainActor
enum DesktopTaskNavigation {
    private typealias Rules = DesktopNavigationRules
    private typealias Result = (stage: Rules.Stage, outcome: Rules.Outcome)
    private static let log = Logger(subsystem: "com.libo.TodoNotch", category: "DesktopNavigation")

    static func open(_ task: MonitoredTask, store: SQLiteStore) async -> DesktopNavigationRules.Outcome {
        let (stage, outcome) = await navigate(task)
        let source = task.source.rawValue
        let taskKey = SHA256.hash(data: Data(task.taskKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        log.notice("source=\(source, privacy: .public) taskKey=\(taskKey, privacy: .public) stage=\(stage.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
        store.appendAudit(action: "desktop_navigation", target: taskKey, result: outcome.rawValue,
                          detail: "source=\(source) stage=\(stage.rawValue)")
        return outcome
    }

    private static func navigate(_ task: MonitoredTask) async -> Result {
        guard !Task.isCancelled else { return (.validation, .cancelled) }
        guard Rules.isValidNativeId(task.nativeId) else { return (.validation, .invalidTaskId) }

        let workspace = NSWorkspace.shared
        switch task.source {
        case .codex:
            let bundleID = "com.openai.codex"
            guard let url = Rules.codexURL(nativeId: task.nativeId) else { return (.validation, .invalidTaskId) }
            guard workspace.urlForApplication(withBundleIdentifier: bundleID) != nil else {
                return (.applicationLookup, .appNotInstalled)
            }
            guard let handler = workspace.urlsForApplications(toOpen: url).first(where: {
                Bundle(url: $0)?.bundleIdentifier == bundleID
            }) else { return (.deepLink, .deepLinkRejected) }
            let options = NSWorkspace.OpenConfiguration()
            guard !Task.isCancelled else { return (.deepLink, .cancelled) }
            do {
                _ = try await workspace.open([url], withApplicationAt: handler, configuration: options)
                return (.deepLink, .accepted)
            } catch {
                return (.deepLink, .deepLinkRejected)
            }
        case .antigravity:
            return await openAntigravityTask(task.nativeId, displayName: task.displayName, workspace: workspace)
        default:
            return (.validation, .unsupportedSource)
        }
    }

    private static func openAntigravityTask(
        _ nativeId: String, displayName: String, workspace: NSWorkspace
    ) async -> Result {
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: "com.google.antigravity") else {
            return (.applicationLookup, .appNotInstalled)
        }
        guard !Task.isCancelled else { return (.accessibility, .cancelled) }
        guard AXIsProcessTrusted() else {
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            return (.accessibility, .needsAccessibility)
        }

        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        guard !Task.isCancelled else { return (.launch, .cancelled) }
        guard let app = try? await workspace.openApplication(at: appURL, configuration: options) else {
            return (.launch, Task.isCancelled ? .cancelled : .launchFailed)
        }
        guard !Task.isCancelled else { return (.launch, .cancelled) }

        let pid = app.processIdentifier
        let worker = Task.detached(priority: .userInitiated) {
            await navigateAntigravity(nativeId, displayName: displayName, pid: pid)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private struct ResultSnapshot {
        let rows: [(element: AXUIElement, row: Rules.Row)]
        let isEmpty: Bool

        func matches(_ other: Self) -> Bool {
            isEmpty == other.isEmpty && rows.count == other.rows.count
                && zip(rows, other.rows).allSatisfy { CFEqual($0.element, $1.element) && $0.row == $1.row }
        }
    }

    private nonisolated static func navigateAntigravity(
        _ nativeId: String, displayName: String, pid: pid_t
    ) async -> Result {
        guard !Task.isCancelled else { return (.webArea, .cancelled) }
        let root = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(root, 0.25)
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let deadline = ContinuousClock.now + .seconds(12)
        var lastAction = ContinuousClock.now - .seconds(2)
        var lastSubmittedSearch: (query: String, at: ContinuousClock.Instant)?
        var searchContext: (window: AXUIElement, page: AXUIElement)?
        var emptyQuery = ""
        var resultsScope: AXUIElement?
        var lastSnapshot: (value: ResultSnapshot, since: ContinuousClock.Instant)?
        var openedRow = false
        var stage: Rules.Stage = .webArea

        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let window = frontWindow(root), let (page, url) = localPage(window, deadline: deadline) {
                if Rules.detailMatches(url, nativeId: nativeId) {
                    return (.taskDetail, Task.isCancelled ? .cancelled : .opened)
                }
                if openedRow {
                    if url.path.hasPrefix("/sidecars/") {
                        return (.taskDetail, Task.isCancelled ? .cancelled : .wrongTask)
                    }
                    try? await Task.sleep(for: .milliseconds(110))
                    continue
                }

                let sameContext = searchContext.map { CFEqual($0.window, window) && CFEqual($0.page, page) } ?? false
                if !sameContext || url.path != "/sidecars" {
                    searchContext = (window, page)
                    emptyQuery = "tn-" + UUID().uuidString.prefix(16).lowercased()
                    resultsScope = nil
                    lastSnapshot = nil
                    lastSubmittedSearch = nil
                }

                if ContinuousClock.now - lastAction >= .milliseconds(450) {
                    if url.path == "/sidecars" {
                        // A new URL can arrive before the renderer replaces its result rows.
                        if resultsScope == nil, Rules.isFilteredList(url, query: emptyQuery),
                           let marker = find(in: page, limit: 520, deadline: deadline, where: {
                               isEmptyResultsLabel($0, for: emptyQuery)
                           }) {
                            resultsScope = resultScope(containing: marker, in: page)
                        }
                        let requiredQuery = resultsScope == nil ? emptyQuery : nativeId
                        stage = resultsScope == nil ? .emptyFilter : .taskFilter
                        let isExactFilter = Rules.isFilteredList(url, query: requiredQuery)
                        if !isExactFilter {
                            lastSnapshot = nil
                            let mayRetry = lastSubmittedSearch.map {
                                $0.query != requiredQuery || ContinuousClock.now - $0.at >= .milliseconds(1500)
                            } ?? true
                            if mayRetry,
                               let search = find(in: page, limit: 260, deadline: deadline, where: isAutomationSearch),
                               !Task.isCancelled, ContinuousClock.now < deadline,
                               AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, requiredQuery as CFString) == .success {
                                lastSubmittedSearch = (requiredQuery, ContinuousClock.now)
                                lastAction = ContinuousClock.now
                            }
                        } else if let resultsScope {
                            guard let snapshot = readResults(
                                in: resultsScope, url: url, query: nativeId, emptyQuery: emptyQuery, deadline: deadline
                            ) else {
                                lastSnapshot = nil
                                try? await Task.sleep(for: .milliseconds(110))
                                continue
                            }
                            let now = ContinuousClock.now
                            if lastSnapshot?.value.matches(snapshot) != true { lastSnapshot = (snapshot, now) }
                            let decision = Rules.decideRows(
                                snapshot.rows.map(\.row), nativeId: nativeId, expectedName: displayName,
                                sawEmptyBarrier: true, isExactFilter: isExactFilter,
                                isStable: lastSnapshot.map { now - $0.since >= .milliseconds(220) } ?? false,
                                isEmptyResult: snapshot.isEmpty
                            )
                            if decision != .wait,
                               let currentWindow = frontWindow(root), CFEqual(currentWindow, window),
                               let (currentPage, currentURL) = localPage(currentWindow, deadline: deadline),
                               CFEqual(currentPage, page), Rules.isFilteredList(currentURL, query: nativeId),
                               !Task.isCancelled, ContinuousClock.now < deadline {
                                switch decision {
                                case .ambiguous: return (.taskFilter, .ambiguousMatches)
                                case .notFound: return (.taskFilter, .notFound)
                                case .press(let rowIndex):
                                    if snapshot.rows.indices.contains(rowIndex) {
                                        // An AX timeout can occur after delivery. Don't press the result a second time.
                                        _ = press(snapshot.rows[rowIndex].element, deadline: deadline)
                                        openedRow = true
                                        stage = .taskDetail
                                    }
                                case .wait: break
                                }
                            }
                        }
                    } else {
                        stage = .sidebar
                        if let entry = find(in: page, limit: 100, deadline: deadline, where: { element in
                            let role = attribute(element, kAXRoleAttribute) as? String
                            guard role == kAXButtonRole || role == "AXLink" else { return false }
                            return ["Automations", "自动化", "定时任务"].contains(label(element))
                        }), press(entry, deadline: deadline) {
                            lastAction = ContinuousClock.now
                        }
                    }
                }
            } else {
                lastSnapshot = nil
            }
            try? await Task.sleep(for: .milliseconds(110))
        }
        return (stage, Task.isCancelled ? .cancelled : .timedOut)
    }

    private nonisolated static func frontWindow(_ root: AXUIElement) -> AXUIElement? {
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = attribute(root, key), CFGetTypeID(window) == AXUIElementGetTypeID() {
                return (window as! AXUIElement)
            }
        }
        return (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    private nonisolated static func localPage(
        _ window: AXUIElement, deadline: ContinuousClock.Instant
    ) -> (AXUIElement, URL)? {
        var found: URL?
        let pages = findMatches(in: window, limit: 32, count: 1, deadline: deadline) { element in
            guard let role = requiredRole(element) else { return nil }
            guard role == "AXWebArea" else { return false }
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) {
            case .success:
                guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)),
                      let scheme = url.scheme, ["http", "https"].contains(scheme),
                      let host = url.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return false }
                found = url
                return true
            case .noValue, .attributeUnsupported:
                return false
            default:
                return nil
            }
        }
        guard let page = pages?.first, let found else { return nil }
        return (page, found)
    }

    private nonisolated static func resultScope(containing marker: AXUIElement, in page: AXUIElement) -> AXUIElement {
        var element = marker
        for _ in 0..<20 {
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            element = parent as! AXUIElement
            if CFEqual(element, page) { break }
            if requiredRole(element) == kAXScrollAreaRole { return element }
        }
        // shortcut: Chromium may flatten the list container. Scan the page for the row's own controls in that case.
        return page
    }

    private nonisolated static func readResults(
        in scope: AXUIElement, url: URL, query: String, emptyQuery: String, deadline: ContinuousClock.Instant
    ) -> ResultSnapshot? {
        var rows: [(element: AXUIElement, row: Rules.Row)] = []
        var isEmpty = false
        var showingBarrier = false
        guard findMatches(in: scope, limit: 1500, count: 1, deadline: deadline, where: { element in
            guard let role = requiredRole(element) else { return nil }
            switch role {
            case kAXButtonRole, "AXLink":
                guard readRow(element, url: url, deadline: deadline, rows: &rows) else { return nil }
            case kAXStaticTextRole, kAXGroupRole, "AXParagraph":
                if isEmptyResultsLabel(element, for: emptyQuery) { showingBarrier = true }
                if isEmptyResultsLabel(element, for: query) { isEmpty = true }
            default: break
            }
            return false
        }) != nil, !showingBarrier else { return nil }
        return ResultSnapshot(rows: rows, isEmpty: isEmpty)
    }

    private nonisolated static func isEmptyResultsLabel(_ element: AXUIElement, for query: String) -> Bool {
        let text = label(element)
        guard text.localizedCaseInsensitiveContains(query), let role = requiredRole(element),
              [kAXStaticTextRole, kAXGroupRole, "AXParagraph"].contains(role) else { return false }
        if Rules.isEmptyResults(text, query: query) { return true }
        guard role == kAXStaticTextRole else { return false }

        // Chromium can expose the words and echoed query as separate static-text siblings.
        guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(),
              let siblings = attribute(parent as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              !siblings.isEmpty, siblings.count <= 12,
              siblings.allSatisfy({ requiredRole($0) == kAXStaticTextRole }) else { return false }
        return Rules.isEmptyResults(siblings.map(label).joined(separator: " "), query: query)
    }

    private nonisolated static func press(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private nonisolated static func readRow(
        _ element: AXUIElement, url: URL, deadline: ContinuousClock.Instant,
        rows: inout [(element: AXUIElement, row: Rules.Row)]
    ) -> Bool {
        var names: [String] = []
        var toggleLabels: [String] = []
        var detailLink: URL?

        var rawURL: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &rawURL) {
        case .success:
            detailLink = rawURL as? URL ?? (rawURL as? String).flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            guard detailLink != nil else { return false }
        case .noValue, .attributeUnsupported: break
        default: return false
        }

        // Automation cards contain a titled switch. Toolbar, sidebar and nested action buttons do not.
        guard findMatches(in: element, limit: 96, count: 1, deadline: deadline, where: { child in
            guard let role = requiredRole(child) else { return nil }
            if role == kAXStaticTextRole {
                guard let text = strictLabel(child) else { return nil }
                if !text.isEmpty { names.append(text) }
            } else if [kAXCheckBoxRole, "AXSwitch", "AXToggle"].contains(role) {
                guard let text = strictLabel(child) else { return nil }
                toggleLabels.append(text)
            }
            return false
        }) != nil else { return false }
        let nameAndKind = names.lazy.compactMap { name in
            Rules.rowKind(name: name, toggleLabels: toggleLabels).map { (name, $0) }
        }.first
        let directID = detailLink.flatMap { link in
            link.scheme == url.scheme && link.host == url.host && link.port == url.port
                && Rules.detailMatches(link, nativeId: link.lastPathComponent) ? link.lastPathComponent : nil
        }
        guard let identifier = stringAttribute(element, kAXIdentifierAttribute),
              let domID = stringAttribute(element, "AXDOMIdentifier") else { return false }
        let identifiers = [domID, identifier]
        let hasLocalRowIdentifier = identifiers.contains { $0 == "sidecar-row" || $0.hasPrefix("sidecar-row-") }
        let hasCloudRowIdentifier = identifiers.contains("cloud-trigger-row")
        guard directID != nil || nameAndKind != nil || hasLocalRowIdentifier || hasCloudRowIdentifier else { return true }

        let id = directID ?? identifiers.lazy.compactMap(Rules.exposedRowID).first
        let isLocal = nameAndKind?.1 != .cloud && !hasCloudRowIdentifier && (detailLink == nil || directID != nil)
        rows.append((element, Rules.Row(name: nameAndKind?.0 ?? names.first ?? "", nativeId: id, isLocal: isLocal)))
        return true
    }

    private nonisolated static func isAutomationSearch(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String
        guard role == kAXTextFieldRole || role == "AXSearchField" else { return false }
        return ["Search", "搜索"].contains(attribute(element, kAXPlaceholderValueAttribute) as? String ?? "")
    }

    private nonisolated static func label(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            let raw = attribute(element, key)
            if let text = raw as? String ?? (raw as? NSAttributedString)?.string, !text.isEmpty { return text }
        }
        return ""
    }

    private nonisolated static func strictLabel(_ element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let text = stringAttribute(element, key) else { return nil }
            if !text.isEmpty { return text }
        }
        return ""
    }

    private nonisolated static func requiredRole(_ element: AXUIElement) -> String? {
        guard let role = stringAttribute(element, kAXRoleAttribute), !role.isEmpty else { return nil }
        return role
    }

    private nonisolated static func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, key as CFString, &value) {
        case .success: return value as? String ?? (value as? NSAttributedString)?.string ?? ""
        case .noValue, .attributeUnsupported: return ""
        default: return nil
        }
    }

    private nonisolated static func find(
        in root: AXUIElement, limit: Int, deadline: ContinuousClock.Instant,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        findMatches(in: root, limit: limit, count: 1, deadline: deadline) { matches($0) }?.first
    }

    // Return nil on an incomplete scan, so an unseen second matching row cannot be mistaken for uniqueness.
    private nonisolated static func findMatches(
        in root: AXUIElement, limit: Int, count: Int, deadline: ContinuousClock.Instant,
        where matches: (AXUIElement) -> Bool?
    ) -> [AXUIElement]? {
        var pending = [root]
        var found: [AXUIElement] = []
        var index = 0
        while index < pending.count {
            guard index < limit, ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            let element = pending[index]
            index += 1
            guard let isMatch = matches(element) else { return nil }
            if isMatch {
                found.append(element)
                if found.count == count { return found }
            }
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) {
            case .success:
                guard let children = value as? [AXUIElement] else { return nil }
                pending.append(contentsOf: children)
            case .noValue, .attributeUnsupported:
                break
            default:
                return nil
            }
        }
        return found
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
