import Cocoa
import SwiftUI
import TodoNotchCore

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FloatingPanel: NSPanel {
    var allowsKey: Bool = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    var onDirectLeftClick: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let handler = onDirectLeftClick {
            handler()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class MultiScreenCoordinator {
    private let vm: AppViewModel
    private let earWidth: CGFloat = 30
    private var pillPanels: [UInt32: FloatingPanel] = [:]
    private var toastPanel: FloatingPanel!
    private var mainPanel: FloatingPanel!
    private var isMainVisible = false

    init(vm: AppViewModel) {
        self.vm = vm
        setupToastPanel()
        setupMainPanel()
        rebuildPillPanels()
    }

    private func displayID(for screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func activeScreen() -> NSScreen {
        if vm.config.screenMode.hasPrefix("locked:"),
           let idStr = vm.config.screenMode.split(separator: ":").last,
           let targetId = UInt32(idStr),
           let locked = NSScreen.screens.first(where: { displayID(for: $0) == targetId }) {
            return locked
        }
        // Focused screen (active window / cursor screen)
        return NSScreen.main ?? NSScreen.screens.first!
    }

    private func notchGeometry(for screen: NSScreen) -> (rect: NSRect, physicalWidth: CGFloat) {
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let physicalWidth = max(0, right.minX - left.maxX)
            let notchHeight = max(left.height, right.height)
            let totalWidth = physicalWidth + earWidth * 2
            let centerX = (left.maxX + right.minX) / 2.0
            return (
                NSRect(x: centerX - totalWidth / 2.0, y: frame.maxY - notchHeight, width: totalWidth, height: notchHeight),
                physicalWidth
            )
        } else {
            let barHeight = max(24, frame.maxY - screen.visibleFrame.maxY)
            let pillWidth: CGFloat = 86
            return (
                NSRect(x: frame.midX - pillWidth / 2.0, y: frame.maxY - barHeight, width: pillWidth, height: barHeight),
                0
            )
        }
    }

    private func anchorTopY(for screen: NSScreen) -> CGFloat {
        let f = screen.frame
        let barHeight = screen.auxiliaryTopLeftArea?.height ?? max(24, f.maxY - screen.visibleFrame.maxY)
        return f.maxY - barHeight - 8
    }

    func rebuildPillPanels() {
        for p in pillPanels.values { p.orderOut(nil) }
        pillPanels.removeAll()

        let screensToShow: [NSScreen]
        if vm.config.screenMode.hasPrefix("locked:"),
           let idStr = vm.config.screenMode.split(separator: ":").last,
           let targetId = UInt32(idStr),
           let locked = NSScreen.screens.first(where: { displayID(for: $0) == targetId }) {
            screensToShow = [locked]
        } else {
            screensToShow = NSScreen.screens
        }

        for screen in screensToShow {
            let geom = notchGeometry(for: screen)
            let panel = FloatingPanel(
                contentRect: geom.rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.allowsKey = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.onDirectLeftClick = { [weak self] in
                self?.toggleMainPanel()
            }
            panel.contentView = FirstMouseHostingView(rootView: NotchPillView(
                vm: vm,
                physicalNotchWidth: geom.physicalWidth,
                earWidth: earWidth
            ) { [weak self] in
                self?.toggleMainPanel()
            })
            panel.orderFrontRegardless()
            pillPanels[displayID(for: screen)] = panel
        }
    }

    private func setupToastPanel() {
        let s = activeScreen()
        let rect = NSRect(x: s.frame.midX - 180, y: anchorTopY(for: s) - 50, width: 360, height: 50)
        toastPanel = FloatingPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toastPanel.allowsKey = false // Never steals keyboard focus (AC-09)
        toastPanel.isOpaque = false
        toastPanel.backgroundColor = .clear
        toastPanel.hasShadow = true
        toastPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 3)
        toastPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        toastPanel.contentView = NSHostingView(rootView: LightToastView(vm: vm) { [weak self] in
            self?.showMainPanel()
        })
    }

    private func setupMainPanel() {
        let s = activeScreen()
        let rect = NSRect(x: s.frame.midX - 240, y: anchorTopY(for: s) - 560, width: 480, height: 560)
        mainPanel = FloatingPanel(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        mainPanel.allowsKey = true
        mainPanel.isOpaque = false
        mainPanel.backgroundColor = .clear
        mainPanel.hasShadow = true
        mainPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 4)
        mainPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        mainPanel.onEscape = { [weak self] in self?.hideMainPanel() }
        mainPanel.contentView = NSHostingView(rootView: MainOverlayView(vm: vm) { [weak self] in
            self?.hideMainPanel()
        })
    }

    func showToastPanel() {
        guard !isMainVisible else { return }
        let s = activeScreen()
        let rect = NSRect(x: s.frame.midX - 180, y: anchorTopY(for: s) - 50, width: 360, height: 50)
        toastPanel.setFrame(rect, display: true)
        toastPanel.orderFrontRegardless()
    }

    func hideToastPanel() {
        toastPanel.orderOut(nil)
    }

    func toggleMainPanel() {
        if isMainVisible { hideMainPanel() } else { showMainPanel() }
    }

    func showMainPanel() {
        hideToastPanel()
        vm.loadTodosMarkdown()
        let s = activeScreen()
        let rect = NSRect(x: s.frame.midX - 240, y: anchorTopY(for: s) - 560, width: 480, height: 560)
        mainPanel.setFrame(rect, display: true)
        mainPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isMainVisible = true
    }

    func hideMainPanel() {
        mainPanel.orderOut(nil)
        isMainVisible = false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var vm: AppViewModel!
    private var coordinator: MultiScreenCoordinator!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        vm = AppViewModel()
        coordinator = MultiScreenCoordinator(vm: vm)

        vm.onRequestShowMainPopup = { [weak self] in self?.coordinator.showMainPanel() }
        vm.onRequestShowToast = { [weak self] in self?.coordinator.showToastPanel() }
        vm.onRequestHideToast = { [weak self] in self?.coordinator.hideToastPanel() }
        vm.onScreenModeChanged = { [weak self] in self?.coordinator.rebuildPillPanels() }

        setupStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if CommandLine.arguments.contains("--popup") {
            coordinator.showMainPanel()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TodoNotch")
            btn.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开待办与定时任务中枢", action: #selector(menuOpen), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "切换专注勿扰", action: #selector(menuToggleFocus), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Lmemory 一键引导 / 修复", action: #selector(menuOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 TodoNotch", action: #selector(menuQuit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func handleScreenChange() { coordinator.rebuildPillPanels() }
    @objc private func menuOpen() { coordinator.showMainPanel() }
    @objc private func menuToggleFocus() { vm.toggleFocusMode() }
    @objc private func menuOnboarding() { vm.prepareOnboarding(); coordinator.showMainPanel() }
    @objc private func menuRefresh() { vm.refreshAllNow() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
