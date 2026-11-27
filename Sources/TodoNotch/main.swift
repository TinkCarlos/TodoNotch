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
    private let mainPanelSize = NSSize(width: 476, height: 568)
    private let toastPanelSize = NSSize(width: 360, height: 52)
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

    private func anchorCenterX(for screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (left.maxX + right.minX) / 2.0
        }
        return screen.frame.midX
    }

    private func notchGeometry(for screen: NSScreen) -> (rect: NSRect, physicalWidth: CGFloat) {
        let frame = screen.frame
        let centerX = anchorCenterX(for: screen)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let physicalWidth = max(0, right.minX - left.maxX)
            let notchHeight = max(left.height, right.height)
            let totalWidth = physicalWidth + earWidth * 2
            return (
                NSRect(x: round(centerX - totalWidth / 2.0), y: frame.maxY - notchHeight, width: totalWidth, height: notchHeight),
                physicalWidth
            )
        } else {
            let barHeight = max(24, frame.maxY - screen.visibleFrame.maxY)
            let pillWidth: CGFloat = 86
            return (
                NSRect(x: round(centerX - pillWidth / 2.0), y: frame.maxY - barHeight, width: pillWidth, height: barHeight),
                0
            )
        }
    }

    private func anchorTopY(for screen: NSScreen) -> CGFloat {
        let f = screen.frame
        let barHeight = screen.auxiliaryTopLeftArea?.height ?? max(24, f.maxY - screen.visibleFrame.maxY)
        return f.maxY - barHeight - 8
    }

    private func centeredRect(size: NSSize, on screen: NSScreen) -> NSRect {
        let centerX = anchorCenterX(for: screen)
        let topY = anchorTopY(for: screen)
        return NSRect(
            x: round(centerX - size.width / 2.0),
            y: round(topY - size.height),
            width: size.width,
            height: size.height
        )
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
            let sid = displayID(for: screen)
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
                self?.toggleMainPanel(onDisplayID: sid)
            }
            panel.contentView = FirstMouseHostingView(rootView: NotchPillView(
                vm: vm,
                physicalNotchWidth: geom.physicalWidth,
                earWidth: earWidth
            ) { [weak self] in
                self?.toggleMainPanel(onDisplayID: sid)
            })
            panel.orderFrontRegardless()
            pillPanels[sid] = panel
        }
    }

    private func setupToastPanel() {
        let s = activeScreen()
        let rect = centeredRect(size: toastPanelSize, on: s)
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
        toastPanel.hidesOnDeactivate = false
        toastPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 3)
        toastPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        toastPanel.contentView = FirstMouseHostingView(rootView: LightToastView(vm: vm) { [weak self] in
            self?.showMainPanel()
        })
    }

    private func setupMainPanel() {
        let s = activeScreen()
        let rect = centeredRect(size: mainPanelSize, on: s)
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
        mainPanel.hidesOnDeactivate = true
        mainPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 4)
        mainPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        mainPanel.onEscape = { [weak self] in self?.hideMainPanel() }
        mainPanel.contentView = FirstMouseHostingView(rootView: MainOverlayView(vm: vm) { [weak self] in
            self?.hideMainPanel()
        })
    }

    func showToastPanel() {
        let navigationNotice = vm.desktopNavigationToast != nil
        guard !isMainVisible || !mainPanel.isVisible || navigationNotice else { return }
        toastPanel.level = NSWindow.Level(rawValue: mainPanel.level.rawValue + (navigationNotice ? 1 : -1))
        let s = activeScreen()
        let size = navigationNotice ? LightToastView.navigationSize : toastPanelSize
        let targetRect = centeredRect(size: size, on: s)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            toastPanel.alphaValue = 1
            toastPanel.setFrame(targetRect, display: true)
            toastPanel.orderFrontRegardless()
        } else {
            var startRect = targetRect
            startRect.origin.y += 8
            toastPanel.alphaValue = 0
            toastPanel.setFrame(startRect, display: true)
            toastPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toastPanel.animator().alphaValue = 1
                toastPanel.animator().setFrame(targetRect, display: true)
            }
        }
    }

    func hideToastPanel() {
        toastPanel.orderOut(nil)
    }

    func toggleMainPanel(onDisplayID displayID: UInt32? = nil) {
        if isMainVisible && mainPanel.isVisible { hideMainPanel() } else { showMainPanel(onDisplayID: displayID) }
    }

    func showMainPanel(onDisplayID displayID: UInt32? = nil) {
        if vm.desktopNavigationToast == nil { hideToastPanel() }
        vm.loadTodosMarkdown()
        let s = displayID.flatMap { targetId in
            NSScreen.screens.first(where: { self.displayID(for: $0) == targetId })
        } ?? activeScreen()
        let targetRect = centeredRect(size: mainPanelSize, on: s)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isMainVisible = true
        if reduceMotion {
            mainPanel.alphaValue = 1
            mainPanel.setFrame(targetRect, display: true)
            mainPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            var startRect = targetRect
            startRect.origin.y += 10
            mainPanel.alphaValue = 0
            mainPanel.setFrame(startRect, display: true)
            mainPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                mainPanel.animator().alphaValue = 1
                mainPanel.animator().setFrame(targetRect, display: true)
            }
        }
    }

    func mainApplicationDidDeactivate() {
        isMainVisible = false
        mainPanel.orderOut(nil)
    }

    func hideMainPanel() {
        vm.cancelDesktopNavigation()
        guard isMainVisible else { return }
        isMainVisible = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            mainPanel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                mainPanel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.isMainVisible else { return }
                    self.mainPanel.orderOut(nil)
                    self.mainPanel.alphaValue = 1
                }
            })
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var vm: AppViewModel!
    private var coordinator: MultiScreenCoordinator!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        vm = AppViewModel()
        coordinator = MultiScreenCoordinator(vm: vm)

        vm.onRequestShowMainPopup = { [weak self] in self?.coordinator.showMainPanel() }
        vm.onRequestShowToast = { [weak self] in self?.coordinator.showToastPanel() }
        vm.onRequestHideToast = { [weak self] in self?.coordinator.hideToastPanel() }
        vm.onScreenModeChanged = { [weak self] in self?.coordinator.rebuildPillPanels() }
        vm.onLanguageChanged = { [weak self] in self?.rebuildStatusMenu() }

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

    func applicationDidResignActive(_ notification: Notification) {
        coordinator?.mainApplicationDidDeactivate()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TodoNotch")
            btn.image?.isTemplate = true
        }
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let lang = vm.activeLanguage
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.menuOpenHub(lang), action: #selector(menuOpen), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: L10n.menuToggleFocus(lang), action: #selector(menuToggleFocus), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: L10n.menuOnboarding(lang), action: #selector(menuOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.menuRefresh(lang), action: #selector(menuRefresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.menuQuit(lang), action: #selector(menuQuit), keyEquivalent: "q"))
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
