import AppKit
import ApplicationServices
import OSLog
import TodoNotchCore

@MainActor
enum DesktopTaskNavigation {
    enum Result: Sendable {
        case opened
        case needsAccessibility
        case unavailable
    }

    static func open(_ task: MonitoredTask) async -> Result {
        guard !task.nativeId.isEmpty, task.nativeId != ".", task.nativeId != "..",
              task.nativeId.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return .unavailable
        }

        switch task.source {
        case .antigravity:
            return await openAntigravityTask(task)
        default:
            return .unavailable
        }
    }

    private static func openAntigravityTask(_ task: MonitoredTask) async -> Result {
        guard AXIsProcessTrusted() else {
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            return .needsAccessibility
        }

        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: "com.google.antigravity") else {
            return .unavailable
        }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        guard let app = try? await workspace.openApplication(at: appURL, configuration: options) else {
            return .unavailable
        }

        let pid = app.processIdentifier
        let worker = Task.detached(priority: .userInitiated) { await navigateAntigravity(task, pid: pid) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func navigateAntigravity(_ task: MonitoredTask, pid: pid_t) async -> Result {
        let log = Logger(subsystem: "com.libo.TodoNotch", category: "DesktopNavigation")
        let root = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(root, 0.25)
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let detailPath = "/sidecars/\(task.nativeId)"
        let deadline = ContinuousClock.now + .seconds(12)
        var lastAction = ContinuousClock.now - .seconds(2)
        var lastTypedSearch: (query: String, at: ContinuousClock.Instant)?
        var searchContext: (window: AXUIElement, page: AXUIElement)?
        var emptyQuery = ""
        var sawEmptyResults = false
        var openedRow = false
        var stage = "web area"
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let window = frontWindow(root),
               let (page, url) = localPage(window, deadline: deadline) {
                if url.path == detailPath {
                    log.info("Opened automation \(task.nativeId, privacy: .public)")
                    return .opened
                }

                let sameContext = searchContext.map { CFEqual($0.window, window) && CFEqual($0.page, page) } ?? false
                if !sameContext, !openedRow {
                    searchContext = (window, page)
                    emptyQuery = "tn-" + UUID().uuidString.prefix(16).lowercased()
                    sawEmptyResults = false
                    lastTypedSearch = nil
                }

                if !openedRow, ContinuousClock.now - lastAction >= .milliseconds(450) {
                    if url.path == "/sidecars" {
                        let query = searchQuery(url)
                        // The renderer can expose the new URL before replacing its result rows.
                        // Observe this navigation's unique empty list before requesting the real filter.
                        if !sawEmptyResults, query == emptyQuery,
                           hasEmptyResults(in: page, for: emptyQuery, deadline: deadline) {
                            sawEmptyResults = true
                        }
                        let requiredQuery = sawEmptyResults ? task.nativeId : emptyQuery
                        stage = sawEmptyResults ? "filtered automation results" : "empty automation results"
                        if query != requiredQuery {
                            let mayRetry = lastTypedSearch.map {
                                $0.query != requiredQuery || ContinuousClock.now - $0.at >= .milliseconds(1500)
                            } ?? true
                            if mayRetry,
                               let search = find(in: page, limit: 260, deadline: deadline, where: isAutomationSearch),
                               submitSearch(requiredQuery, field: search, application: root, pid: pid) {
                                lastTypedSearch = (requiredQuery, ContinuousClock.now)
                                lastAction = ContinuousClock.now
                            }
                        } else if sawEmptyResults,
                                  let candidates = findMatches(in: page, limit: 1500, count: 2, deadline: deadline, where: { element in
                                      guard let role = requiredRole(element) else { return nil }
                                      if role == kAXButtonRole {
                                          return matchesTaskRow(element, name: task.displayName, deadline: deadline)
                                      }
                                      return isEmptyResultsLabel(element, for: emptyQuery)
                                  }),
                                  candidates.count == 1,
                                  requiredRole(candidates[0]) == kAXButtonRole,
                                  let currentWindow = frontWindow(root), CFEqual(currentWindow, window),
                                  let (currentPage, currentURL) = localPage(currentWindow, deadline: deadline),
                                  CFEqual(currentPage, page), currentURL.path == "/sidecars",
                                  searchQuery(currentURL) == task.nativeId,
                                  !Task.isCancelled, ContinuousClock.now < deadline,
                                  press(candidates[0]) {
                            openedRow = true
                            stage = "automation detail"
                        }
                    } else {
                        stage = "automations sidebar"
                        if let entry = find(in: page, limit: 100, deadline: deadline, where: { element in
                            let role = attribute(element, kAXRoleAttribute) as? String
                            guard role == kAXButtonRole || role == "AXLink" else { return false }
                            return ["Automations", "自动化", "定时任务"].contains(label(element))
                        }), press(entry) {
                            lastAction = ContinuousClock.now
                        }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(110))
        }
        log.notice("Could not open automation \(task.nativeId, privacy: .public), stage \(stage, privacy: .public)")
        return .unavailable
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
                      let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return false }
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

    private nonisolated static func searchQuery(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
    }

    private nonisolated static func hasEmptyResults(
        in page: AXUIElement, for query: String, deadline: ContinuousClock.Instant
    ) -> Bool {
        // A readable marker is sufficient here. The final row and page scans require complete reads.
        var pending = [page]
        var index = 0
        while index < pending.count, index < 520, ContinuousClock.now < deadline, !Task.isCancelled {
            let element = pending[index]
            index += 1
            if isEmptyResultsLabel(element, for: query) { return true }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], pending.count < 520 {
                pending.append(contentsOf: children.prefix(520 - pending.count))
            }
        }
        return false
    }

    private nonisolated static func isEmptyResultsLabel(_ element: AXUIElement, for query: String) -> Bool {
        let text = label(element)
        guard text.contains(query), let role = requiredRole(element),
              role != kAXButtonRole, role != kAXTextFieldRole, role != "AXSearchField", role != "AXLink" else { return false }
        if isEmptyResultsText(text, for: query) { return true }

        // Chromium can expose the words and the echoed query as separate static-text siblings.
        guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(),
              let siblings = attribute(parent as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              !siblings.isEmpty, siblings.count <= 8,
              siblings.allSatisfy({ requiredRole($0) == kAXStaticTextRole }) else { return false }
        return isEmptyResultsText(siblings.map(label).joined(separator: " "), for: query)
    }

    private nonisolated static func isEmptyResultsText(_ text: String, for query: String) -> Bool {
        text.hasPrefix("No ") && text.contains(" match ") && text.contains(query)
    }

    private nonisolated static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private nonisolated static func matchesTaskRow(
        _ element: AXUIElement, name: String, deadline: ContinuousClock.Instant
    ) -> Bool? {
        guard let caption = strictLabel(element) else { return nil }
        guard caption == name || caption.hasPrefix(name + " ") || caption.isEmpty else { return false }
        guard let texts = findMatches(in: element, limit: 16, count: 1, deadline: deadline, where: {
            requiredRole($0).map { $0 == kAXStaticTextRole }
        }) else { return nil }
        guard let firstText = texts.first else { return false }
        return strictLabel(firstText).map { $0 == name }
    }

    // Chromium's AXValue setter can change the field without notifying the renderer's search handler.
    private nonisolated static func submitSearch(
        _ text: String, field: AXUIElement, application: AXUIElement, pid: pid_t
    ) -> Bool {
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              let focused = attribute(application, kAXFocusedUIElementAttribute), CFEqual(focused, field),
              let select = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let selectUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false),
              let input = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let inputUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
        select.flags = .maskCommand
        selectUp.flags = .maskCommand
        let codeUnits = Array(text.utf16)
        codeUnits.withUnsafeBufferPointer {
            input.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            inputUp.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        for event in [select, selectUp, input, inputUp] { event.postToPid(pid) }
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
        case .success: return value as? String ?? ""
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
                if let children = value as? [AXUIElement] { pending.append(contentsOf: children) }
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
