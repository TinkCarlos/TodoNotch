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
        var triedLabels: [String: Int] = [:]
        var stage = "web area"
        var lastTypedSearch: ContinuousClock.Instant?
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let window = frontWindow(root),
               let (page, url) = localPage(window, deadline: deadline) {
                if url.path == detailPath {
                    log.info("Opened automation \(task.nativeId, privacy: .public)")
                    return .opened
                }
                if ContinuousClock.now - lastAction >= .milliseconds(450) {
                    if url.path == "/sidecars" {
                        stage = "automation search"
                        let filteredURL = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.contains { $0.name == "q" && $0.value == task.nativeId } == true
                        let search = find(in: page, limit: 260, deadline: deadline, where: isAutomationSearch)
                        if !filteredURL, let search {
                            if lastTypedSearch.map({ ContinuousClock.now - $0 >= .milliseconds(1500) }) ?? true,
                               submitSearch(task.nativeId, field: search, application: root, pid: pid) {
                                lastTypedSearch = ContinuousClock.now
                                lastAction = ContinuousClock.now
                            }
                        } else if filteredURL {
                            stage = "automation row"
                            var offered: [String: Int] = [:]
                            if let row = find(in: page, limit: 520, deadline: deadline, where: { element in
                                guard attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
                                      matchesTaskRow(element, name: task.displayName, deadline: deadline) else { return false }
                                let key = label(element)
                                offered[key, default: 0] += 1
                                return offered[key, default: 0] > triedLabels[key, default: 0]
                            }), press(row) {
                                triedLabels[label(row), default: 0] += 1
                                lastAction = ContinuousClock.now
                            }
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
        let page = find(in: window, limit: 32, deadline: deadline) { element in
            guard attribute(element, kAXRoleAttribute) as? String == "AXWebArea" else { return false }
            let value = attribute(element, kAXURLAttribute)
            guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)),
                  let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return false }
            found = url
            return true
        }
        guard let page, let found else { return nil }
        return (page, found)
    }

    private nonisolated static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private nonisolated static func matchesTaskRow(
        _ element: AXUIElement, name: String, deadline: ContinuousClock.Instant
    ) -> Bool {
        let caption = label(element)
        guard caption == name || caption.hasPrefix(name + " ") || caption.isEmpty else { return false }
        let firstText = find(in: element, limit: 16, deadline: deadline) {
            attribute($0, kAXRoleAttribute) as? String == kAXStaticTextRole
        }
        return firstText.map { label($0) == name } ?? false
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
            if let text = attribute(element, key) as? String, !text.isEmpty { return text }
        }
        return ""
    }

    private nonisolated static func find(
        in root: AXUIElement, limit: Int, deadline: ContinuousClock.Instant,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var pending = [root]
        var index = 0
        while index < pending.count, index < limit, ContinuousClock.now < deadline, !Task.isCancelled {
            let element = pending[index]
            index += 1
            if matches(element) { return element }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], pending.count < limit {
                pending.append(contentsOf: children.prefix(limit - pending.count))
            }
        }
        return nil
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
