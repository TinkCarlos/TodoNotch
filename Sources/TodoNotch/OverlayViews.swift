import SwiftUI
import TodoNotchCore

// MARK: - Option A Theme Tokens (Precision Graphite Top-Light Cockpit)

private enum ThemeA {
    static let canvasBg = Color(red: 11/255, green: 12/255, blue: 15/255)
    static let panelTop = Color(red: 20/255, green: 23/255, blue: 31/255)
    static let panelBottom = Color(red: 16/255, green: 18/255, blue: 24/255)
    static let barBg = Color(red: 14/255, green: 16/255, blue: 22/255)
    static let recessedBg = Color(red: 10/255, green: 11/255, blue: 14/255)

    static let hairline = Color.white.opacity(0.065)
    static let outerBorder = Color.white.opacity(0.11)
    static let topHighlight = Color.white.opacity(0.13)

    static let cobalt = Color(red: 59/255, green: 130/255, blue: 246/255)     // #3B82F6
    static let cobaltSoft = Color(red: 59/255, green: 130/255, blue: 246/255).opacity(0.18)
    static let cobaltText = Color(red: 147/255, green: 197/255, blue: 253/255)
    static let emerald = Color(red: 34/255, green: 197/255, blue: 94/255)     // #22C55E
    static let amber = Color(red: 245/255, green: 158/255, blue: 11/255)      // #F59E0B
    static let coralRed = Color(red: 239/255, green: 68/255, blue: 68/255)    // #EF4444

    static let textPrimary = Color(red: 243/255, green: 244/255, blue: 246/255)
    static let textSecondary = Color(red: 156/255, green: 163/255, blue: 175/255)
    static let textMuted = Color(red: 107/255, green: 114/255, blue: 128/255)
}

// MARK: - Tactile Button Style (Respects Reduce Motion)

struct TactilePressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((configuration.isPressed && !reduceMotion) ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.86 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

// MARK: - Notch / Top-Bar Pill (0px downward protrusion preserved)

struct NotchPillView: View {
    @ObservedObject var vm: AppViewModel
    let physicalNotchWidth: CGFloat
    let earWidth: CGFloat
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if physicalNotchWidth > 0 {
                HStack(spacing: 0) {
                    ZStack {
                        RobotFaceView(presentation: vm.robotPresentation, size: 19)
                    }
                    .frame(width: earWidth, alignment: .center)

                    Spacer().frame(width: physicalNotchWidth)

                    ZStack {
                        if vm.totalBadgeCount > 0 {
                            Text("\(vm.totalBadgeCount)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(vm.unreadAlertEvents.isEmpty ? ThemeA.amber : ThemeA.coralRed)
                                .lineLimit(1)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(ThemeA.emerald)
                        }
                    }
                    .frame(width: earWidth, alignment: .center)
                }
            } else {
                HStack(spacing: 6) {
                    RobotFaceView(presentation: vm.robotPresentation, size: 17)
                    if vm.totalBadgeCount > 0 {
                        Text("\(vm.totalBadgeCount)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(vm.unreadAlertEvents.isEmpty ? ThemeA.amber : ThemeA.coralRed)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ThemeA.emerald)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 11,
                bottomTrailingRadius: 11,
                topTrailingRadius: 0
            )
            .fill(Color.black)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 5s Non-Activating Light Toast with Dynamic Countdown Bar

struct LightToastView: View {
    @ObservedObject var vm: AppViewModel
    let onOpenMain: () -> Void

    static let navigationSize = CGSize(width: 400, height: 108)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1.0

    var body: some View {
        Group {
            if let notice = vm.desktopNavigationToast {
                navigationNotice(title: notice.title, message: notice.message, presentation: notice.presentation)
                    .frame(width: Self.navigationSize.width, height: Self.navigationSize.height)
            } else {
                completionToast
            }
        }
        .background(
            LinearGradient(
                colors: [Color(red: 23/255, green: 26/255, blue: 34/255), Color(red: 17/255, green: 19/255, blue: 25/255)],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.97)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [vm.toastHovered ? ThemeA.cobalt.opacity(0.65) : ThemeA.topHighlight, ThemeA.hairline],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        .preferredColorScheme(.dark)
    }

    private func navigationNotice(
        title: String, message: String, presentation: DesktopNavigationRules.Presentation
    ) -> some View {
        let error = presentation == .errorToast
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(error ? ThemeA.coralRed : ThemeA.amber)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ThemeA.textPrimary)
                Text(message).font(.system(size: 11))
                    .foregroundStyle(ThemeA.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if presentation == .accessibilityToast {
                    Button(L10n.taskNavigationOpenSettings(vm.activeLanguage)) {
                        vm.openAccessibilitySettings()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: vm.dismissDesktopNavigationToast) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ThemeA.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.taskNavigationDismiss(vm.activeLanguage))
            .help(L10n.taskNavigationDismiss(vm.activeLanguage))
        }
        .padding(.horizontal, 14)
    }

    private var completionToast: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(ThemeA.emerald)
                    .frame(width: 22, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(vm.toastTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(ThemeA.textPrimary)
                            .lineLimit(1)
                        if vm.toastCoalescedCount > 0 {
                            Text("+\(vm.toastCoalescedCount)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(ThemeA.emerald)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(ThemeA.emerald.opacity(0.16))
                                .overlay(Capsule().stroke(ThemeA.emerald.opacity(0.32), lineWidth: 0.75))
                                .clipShape(Capsule())
                        }
                    }
                    Text(vm.toastSummary)
                        .font(.system(size: 11))
                        .foregroundColor(ThemeA.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(ThemeA.textMuted)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)

            // Dynamic 5s / 2s countdown bar
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ThemeA.cobalt, ThemeA.emerald],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * progress), height: 2)
            }
            .frame(height: 2)
        }
        .frame(width: 360, height: 52)
        .contentShape(Rectangle())
        .onAppear { restartCountdown(duration: 5.0) }
        .onChange(of: vm.toastToken) { _, _ in restartCountdown(duration: 5.0) }
        .onChange(of: vm.toastHovered) { _, hovered in
            if hovered {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    progress = 1.0
                }
            } else if vm.toastVisible {
                restartCountdown(duration: 2.0)
            }
        }
        .onTapGesture {
            vm.dismissToastNow()
            onOpenMain()
        }
        .onHover { vm.setToastHovered($0) }
    }

    private func restartCountdown(duration: TimeInterval) {
        progress = 1.0
        guard !reduceMotion else { return }
        let token = vm.toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard vm.toastToken == token, vm.desktopNavigationToast == nil, !vm.toastHovered else { return }
            withAnimation(.linear(duration: duration)) {
                progress = 0.0
            }
        }
    }
}

// MARK: - Main Overlay Panel (Option A: Precision Graphite Top-Light Cockpit)

struct MainOverlayView: View {
    @ObservedObject var vm: AppViewModel
    let onClose: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabNS
    @Namespace private var filterNS

    @State private var activeTab = 0
    @State private var expandedTaskKey: String? = nil
    @State private var expandedPausedSources: Set<TaskSource> = []
    @State private var openDropdownId: String? = nil
    @State private var selectedSourceFilter: TaskSource? = nil
    @State private var refreshSpinCount = 0

    private var lang: AppLanguage { vm.activeLanguage }

    private static let shortDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            hairlineDivider
            slidingTabBar

            if !vm.inlineNotice.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                    Text(vm.inlineNotice)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundColor(ThemeA.amber)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(ThemeA.amber.opacity(0.11))
                .overlay(alignment: .bottom) { hairlineDivider }
            }

            Group {
                if activeTab == 0 {
                    scheduledTasksTab
                } else if activeTab == 1 {
                    unfinishedTodosTab
                } else {
                    settingsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            hairlineDivider
            footerBar
        }
        .frame(width: 476, height: 568)
        .background(
            LinearGradient(
                colors: [ThemeA.panelTop, ThemeA.panelBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [ThemeA.topHighlight, ThemeA.outerBorder, Color.black.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .onExitCommand(perform: onClose)
        .onChange(of: vm.showOnboarding) { _, show in
            if show {
                switchTab(2)
                vm.showOnboarding = false
            }
        }
        .preferredColorScheme(.dark)
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(ThemeA.hairline)
            .frame(height: 1)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 9) {
            RobotFaceView(presentation: vm.robotPresentation, size: 22)
            Text("TodoNotch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ThemeA.textPrimary)

            HStack(spacing: 5) {
                statChip(icon: "exclamationmark.triangle.fill", count: vm.unreadAlertEvents.count, color: ThemeA.coralRed)
                statChip(icon: "person.fill", count: vm.personalTodosOpen.count, color: ThemeA.amber)
                statChip(icon: "hammer.fill", count: vm.projectTodosOpen.count, color: ThemeA.cobalt)
            }

            Spacer(minLength: 4)

            // Quick manual language toggle (CN <-> EN)
            Button(action: {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    vm.toggleQuickLanguage()
                }
            }) {
                Text(lang == .zhHans ? "中" : "EN")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(ThemeA.textSecondary)
                    .frame(width: 26, height: 24)
                    .background(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(TactilePressStyle())
            .help(lang == .zhHans ? "切换为 English" : "Switch to 简体中文")

            Button(action: {
                if !reduceMotion {
                    withAnimation(.easeOut(duration: 0.55)) {
                        refreshSpinCount += 1
                    }
                }
                vm.refreshAllNow()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ThemeA.textSecondary)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(refreshSpinCount) * 360))
                    .frame(width: 26, height: 24)
                    .background(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(TactilePressStyle())
            .keyboardShortcut("r", modifiers: .command)
            .help(L10n.refreshHelp(lang))

            Button(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(ThemeA.textPrimary)
                    .frame(width: 26, height: 24)
                    .background(Color.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.11), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(TactilePressStyle())
            .help(L10n.collapseHelp(lang))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(ThemeA.barBg)
    }

    private func statChip(icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon).font(.system(size: 9))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .foregroundColor(count > 0 ? color : ThemeA.textMuted)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 3)
        .background(count > 0 ? color.opacity(0.14) : Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Sliding Indicator Tab Bar

    private var slidingTabBar: some View {
        HStack(spacing: 4) {
            tabButton(icon: "clock.arrow.circlepath", title: L10n.tabTasks(lang), idx: 0, badge: vm.tasks.filter { $0.sourceStatus == "active" }.count, shortcut: "1")
            tabButton(icon: "checklist", title: L10n.tabTodos(lang), idx: 1, badge: vm.unreadAlertEvents.count + vm.personalTodosOpen.count + vm.projectTodosOpen.count, shortcut: "2")
            tabButton(icon: "gearshape", title: L10n.tabSettings(lang), idx: 2, badge: 0, shortcut: "3")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(ThemeA.recessedBg.opacity(0.65))
        .overlay(alignment: .bottom) { hairlineDivider }
    }

    private func switchTab(_ idx: Int) {
        openDropdownId = nil
        if reduceMotion {
            activeTab = idx
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                activeTab = idx
            }
        }
    }

    private func tabButton(icon: String, title: String, idx: Int, badge: Int, shortcut: KeyEquivalent) -> some View {
        let selected = activeTab == idx
        return Button(action: { switchTab(idx) }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 0.5)
                        .background(selected ? ThemeA.cobalt.opacity(0.32) : Color.white.opacity(0.08))
                        .foregroundColor(selected ? .white : ThemeA.textSecondary)
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(selected ? ThemeA.textPrimary : ThemeA.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 29)
            .padding(.horizontal, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(ThemeA.cobaltSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(ThemeA.cobalt.opacity(0.45), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "activeTabIndicator", in: tabNS)
                } else {
                    Color.clear
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(TactilePressStyle(scale: 0.98))
        .keyboardShortcut(shortcut, modifiers: .command)
    }

    // MARK: - Tab 0: Scheduled Tasks (Hairline List + 2pt Left Accent + 7-Day Rhythm Strip)

    private var scheduledTasksTab: some View {
        let orderedSources: [TaskSource] = [.antigravity, .codex, .claude, .workbuddy, .zcode, .launchd, .custom]
        let presentSources = orderedSources.filter { src in vm.tasks.contains(where: { $0.source == src }) }
        let effectiveFilter = (presentSources.count > 1 && selectedSourceFilter.map { presentSources.contains($0) } == true) ? selectedSourceFilter : nil
        let visibleSources = effectiveFilter.map { [$0] } ?? presentSources

        return VStack(spacing: 0) {
            if presentSources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        sourceFilterChip(title: L10n.allFilter(lang), count: vm.tasks.count, source: nil)
                        ForEach(presentSources, id: \.self) { src in
                            let cnt = vm.tasks.filter { $0.source == src }.count
                            sourceFilterChip(title: L10n.sourceName(src, lang), count: cnt, source: src)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(ThemeA.recessedBg.opacity(0.42))
                .overlay(alignment: .bottom) { hairlineDivider }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.tasks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 24))
                                .foregroundColor(ThemeA.textMuted)
                            Text(L10n.noTasksFound(lang))
                                .font(.system(size: 12))
                                .foregroundColor(ThemeA.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 72)
                    } else {
                        ForEach(visibleSources, id: \.self) { src in
                            let groupTasks = vm.tasks.filter { $0.source == src }
                            let activeTasks = groupTasks.filter { $0.sourceStatus == "active" }
                            let pausedTasks = groupTasks.filter { $0.sourceStatus != "active" }
                            let pausedExpanded = expandedPausedSources.contains(src)
                            if !groupTasks.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 6) {
                                        Image(systemName: toolIcon(src))
                                            .font(.system(size: 10.5, weight: .bold))
                                        Text(L10n.sourceName(src, lang))
                                            .font(.system(size: 11, weight: .semibold))
                                        Spacer()
                                        Text("\(activeTasks.count)/\(groupTasks.count)")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .monospacedDigit()
                                            .foregroundColor(ThemeA.textMuted)
                                    }
                                    .foregroundColor(toolColor(src))
                                    .padding(.bottom, 6)

                                    VStack(spacing: 0) {
                                        ForEach(Array(activeTasks.enumerated()), id: \.element.id) { idx, task in
                                            if idx > 0 {
                                                hairlineDivider
                                            }
                                            taskHairlineRow(task)
                                        }

                                        if !pausedTasks.isEmpty {
                                            if !activeTasks.isEmpty {
                                                hairlineDivider
                                            }
                                            Button(action: {
                                                let toggle = {
                                                    if pausedExpanded {
                                                        expandedPausedSources.remove(src)
                                                    } else {
                                                        expandedPausedSources.insert(src)
                                                    }
                                                }
                                                if reduceMotion {
                                                    toggle()
                                                } else {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        toggle()
                                                    }
                                                }
                                            }) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "pause.circle")
                                                        .font(.system(size: 10.5))
                                                        .foregroundColor(ThemeA.textMuted)
                                                    Text(L10n.pausedTasksToggle(pausedTasks.count, lang))
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundColor(ThemeA.textSecondary)
                                                    Spacer()
                                                    Image(systemName: "chevron.right")
                                                        .font(.system(size: 9, weight: .semibold))
                                                        .foregroundColor(ThemeA.textMuted)
                                                        .rotationEffect(.degrees(pausedExpanded ? 90 : 0))
                                                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: pausedExpanded)
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7.5)
                                                .background(ThemeA.recessedBg.opacity(0.65))
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(TactilePressStyle(scale: 0.99))

                                            if pausedExpanded {
                                                ForEach(pausedTasks) { task in
                                                    hairlineDivider
                                                    taskHairlineRow(task)
                                                }
                                                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                                            }
                                        }
                                    }
                                    .overlay(alignment: .top) { hairlineDivider }
                                    .overlay(alignment: .bottom) { hairlineDivider }
                                }
                            }
                        }
                    }
                }
            .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .onChange(of: presentSources) { _, next in
            if next.count <= 1 || (selectedSourceFilter != nil && !next.contains(selectedSourceFilter!)) {
                selectedSourceFilter = nil
            }
        }
    }

    private func sourceFilterChip(title: String, count: Int, source: TaskSource?) -> some View {
        let selected = selectedSourceFilter == source
        return Button(action: {
            if reduceMotion {
                selectedSourceFilter = source
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedSourceFilter = source
                }
            }
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .opacity(selected ? 0.95 : 0.72)
            }
            .foregroundColor(selected ? .white : ThemeA.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ThemeA.cobalt)
                        .matchedGeometryEffect(id: "sourceFilterPill", in: filterNS)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.hairline, lineWidth: 0.8))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(TactilePressStyle(scale: 0.97))
    }

    private func taskHairlineRow(_ task: MonitoredTask) -> some View {
        let isExpanded = expandedTaskKey == task.taskKey
        let isActive = task.sourceStatus == "active"
        let dispatch = vm.dispatchesByKey[task.taskKey]
        let isManualRunning = dispatch?.status == .running
        let accentBarColor = isManualRunning
            ? ThemeA.cobalt
            : (isActive ? statusColor(task.lastRunStatus) : ThemeA.textMuted.opacity(0.45))
        let rhythm = vm.sevenDayRhythm(for: task.taskKey)

        let toggleExpand = {
            let willExpand = !isExpanded
            if reduceMotion {
                expandedTaskKey = willExpand ? task.taskKey : nil
            } else {
                withAnimation(.easeInOut(duration: 0.22)) {
                    expandedTaskKey = willExpand ? task.taskKey : nil
                }
            }
            if willExpand {
                vm.loadTaskConversationTurnsAsync(for: task)
            }
        }

        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                HStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 6) {
                            Text(L10n.displayTaskName(task.displayName, source: task.source, lang: lang))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(isActive ? ThemeA.textPrimary : ThemeA.textMuted)
                                .lineLimit(1)

                            if let dispatch {
                                let isStopping = vm.stoppingKeys.contains(task.taskKey) && dispatch.status == .running
                                let dColor = isStopping ? ThemeA.amber : dispatchStatusColor(dispatch.status)
                                HStack(spacing: 3.5) {
                                    Circle().fill(dColor).frame(width: 5, height: 5)
                                    Text(isStopping ? L10n.stoppingLabel(lang) : L10n.dispatchStatusLabel(dispatch.status, lang))
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundColor(dColor)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(dColor.opacity(0.14))
                                .clipShape(Capsule())
                            }
                        }

                        HStack(spacing: 6) {
                            Image(systemName: isActive ? "play.fill" : "pause.fill")
                                .font(.system(size: 7.5))
                                .foregroundColor(isActive ? ThemeA.emerald : ThemeA.textMuted)
                            if !task.scheduleExpr.isEmpty {
                                Text(L10n.displayScheduleExpr(task.scheduleExpr, source: task.source, lang: lang))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(ThemeA.textMuted)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    // 7-day execution rhythm micro-strip
                    HStack(spacing: 2.5) {
                        ForEach(0..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(rhythmColor(rhythm[i]))
                                .frame(width: 4.5, height: 11)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleExpand() }

                if vm.canRunScheduledTask(task) {
                    if isManualRunning {
                        if vm.canStopDispatchDirectly(dispatch) {
                            let isStopping = vm.stoppingKeys.contains(task.taskKey)
                            Button(action: {
                                vm.stopDispatch(forKey: task.taskKey)
                            }) {
                                Image(systemName: isStopping ? "hourglass" : "stop.fill")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(ThemeA.coralRed)
                                    .frame(width: 24, height: 24)
                                    .background(ThemeA.coralRed.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.coralRed.opacity(0.45), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(TactilePressStyle())
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .disabled(isStopping)
                            .opacity(isStopping ? 0.55 : 1.0)
                            .help(isStopping ? L10n.stoppingLabel(lang) : L10n.stopTaskHelp(lang))
                        } else {
                            Button(action: {
                                vm.openAntigravityDesktop(notice: true)
                            }) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(ThemeA.cobaltText)
                                    .frame(width: 24, height: 24)
                                    .background(ThemeA.cobalt.opacity(0.14))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.cobalt.opacity(0.35), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(TactilePressStyle())
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .help(L10n.openInAntigravityToStopHelp(lang))
                        }
                    } else {
                        Button(action: {
                            vm.dispatchScheduledTask(task)
                        }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(ThemeA.cobalt)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(TactilePressStyle())
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .help(L10n.runTaskNowHelp(lang))
                    }
                } else if task.source == .workbuddy {
                    Button(action: {
                        vm.openWorkBuddyApp()
                    }) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10.5))
                            .foregroundColor(ThemeA.cobaltText)
                            .frame(width: 24, height: 24)
                            .background(ThemeA.cobalt.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(TactilePressStyle())
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .help(L10n.openWorkBuddyHelp(lang))
                }

                Button(action: { vm.cycleTaskLevel(task) }) {
                    Image(systemName: levelIcon(task.notifyLevel))
                        .font(.system(size: 11))
                        .foregroundColor(levelColor(task.notifyLevel))
                        .frame(width: 24, height: 24)
                        .background(levelColor(task.notifyLevel).opacity(task.notifyLevel == .muted ? 0.08 : 0.13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    task.notifyLevel == .muted
                                        ? ThemeA.hairline
                                        : levelColor(task.notifyLevel).opacity(0.28),
                                    lineWidth: 0.75
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(TactilePressStyle())
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .help(L10n.taskLevelHelp(task.notifyLevel, lang))

                Button(action: { toggleExpand() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(ThemeA.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TactilePressStyle())
                .accessibilityIdentifier("expand-\(task.taskKey)")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 9.5)

            if isExpanded {
                let weekRuns = vm.recentWeekEvents(for: task.taskKey)
                let taskTurns = vm.conversationTurnsByKey[task.taskKey] ?? []
                VStack(alignment: .leading, spacing: 6) {
                    if let dispatch {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(L10n.latestManualRunLabel(lang))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(ThemeA.cobaltText)
                                let isStopping = vm.stoppingKeys.contains(task.taskKey) && dispatch.status == .running
                                Text(isStopping ? L10n.stoppingLabel(lang) : L10n.dispatchStatusLabel(dispatch.status, lang))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(isStopping ? ThemeA.amber : dispatchStatusColor(dispatch.status))
                                Spacer()
                                let openPath = !dispatch.transcriptPath.isEmpty ? dispatch.transcriptPath : dispatch.logPath
                                if !openPath.isEmpty {
                                    Button(action: { vm.openFileSafely(openPath) }) {
                                        Text(L10n.openFullTranscript(lang))
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundColor(ThemeA.cobaltText)
                                    }
                                    .buttonStyle(TactilePressStyle())
                                }
                            }
                            let latestReply = taskTurns.last(where: { $0.role == "assistant" })?.text
                            let showRunSummary = dispatch.status == .failed
                                || dispatch.summary == TodoDispatchRunner.unconfirmedAntigravitySummary
                                || dispatch.summary == TodoDispatchRunner.missingAntigravityReplySummary
                            let text = showRunSummary ? dispatch.summary : latestReply ?? dispatch.summary
                            if !text.isEmpty {
                                Text(text)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(ThemeA.textPrimary.opacity(0.9))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(7)
                        .background(ThemeA.recessedBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if weekRuns.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "tray").font(.system(size: 10))
                            Text(L10n.noWeekRuns(lang)).font(.system(size: 10.5))
                            Spacer(minLength: 4)
                            desktopTaskButton(for: task, accessibilityId: "desktop-task-empty-\(task.taskKey)")
                        }
                        .foregroundColor(ThemeA.textMuted)
                        .padding(.vertical, 3)
                    } else {
                        ForEach(weekRuns) { ev in
                            let dateStr = Self.shortDateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ev.occurredAt)))
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(statusColor(ev.status))
                                    .frame(width: 5.5, height: 5.5)
                                Text(dateStr)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(ThemeA.textMuted)
                                Text(L10n.displayEventSummary(ev.summary, status: ev.status, lang: lang))
                                    .font(.system(size: 11))
                                    .foregroundColor(ThemeA.textPrimary.opacity(0.88))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                desktopTaskButton(for: task, accessibilityId: "desktop-task-\(ev.eventId)", labelSuffix: dateStr)
                                if !ev.artifactPath.isEmpty {
                                    Button(action: { vm.openFileSafely(ev.artifactPath) }) {
                                        Image(systemName: "doc")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(ThemeA.cobaltText)
                                    }
                                    .buttonStyle(TactilePressStyle())
                                    .help(L10n.openArtifactHelp(lang))
                                }
                                if !ev.logPath.isEmpty {
                                    Button(action: { vm.openFileSafely(ev.logPath) }) {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(ThemeA.textSecondary)
                                    }
                                    .buttonStyle(TactilePressStyle())
                                    .help(L10n.openLogHelp(lang))
                                }
                                if ev.pushStatus == "failed" {
                                    Button(action: { vm.retryPush(for: ev) }) {
                                        Image(systemName: "arrow.clockwise.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(ThemeA.amber)
                                    }
                                    .buttonStyle(TactilePressStyle())
                                    .help(L10n.retryPushHelp(lang))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.leading, 11)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.11)).frame(width: 1)
                }
                .padding(.leading, 12)
                .padding(.bottom, 9)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isExpanded ? Color.white.opacity(0.03) : Color.white.opacity(0.015))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentBarColor)
                .frame(width: 2)
        }
    }

    @ViewBuilder
    private func desktopTaskButton(for task: MonitoredTask, accessibilityId: String, labelSuffix: String? = nil) -> some View {
        if task.source == .codex || task.source == .antigravity {
            let locating = vm.navigatingDesktopTaskKey == task.taskKey
            let help = locating ? L10n.taskNavigationInProgress(lang) : L10n.openDesktopTaskHelp(lang)
            let label = labelSuffix.map { "\(help) · \(task.displayName) · \($0)" } ?? "\(help) · \(task.displayName)"
            Button(action: { vm.openScheduledTaskInDesktop(task, onOpened: onClose) }) {
                if locating && !reduceMotion {
                    ProgressView().controlSize(.mini).frame(width: 13, height: 13)
                } else {
                    Image(systemName: locating ? "hourglass" : "arrow.up.right.square")
                        .font(.system(size: 10.5))
                        .foregroundColor(ThemeA.cobaltText)
                }
            }
            .buttonStyle(TactilePressStyle())
            .disabled(locating)
            .help(help)
            .accessibilityLabel(label)
            .accessibilityIdentifier(accessibilityId)
        }
    }

    private func rhythmColor(_ status: RunStatus?) -> Color {
        switch status {
        case .error, .missed: return ThemeA.coralRed
        case .attention: return ThemeA.amber
        case .running: return ThemeA.cobalt
        case .success: return ThemeA.emerald
        case .stopped, .unknown, nil: return Color.white.opacity(0.09)
        }
    }

    // MARK: - Tab 1: Alerts & Unfinished Todos

    private var unfinishedTodosTab: some View {
        VStack(spacing: 0) {
            if !vm.selectedTodoKeys.isEmpty {
                todoSelectionActionBar
                hairlineDivider
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !vm.unreadAlertEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            sectionLabel(icon: "exclamationmark.triangle.fill", title: L10n.alertsSection(lang), count: vm.unreadAlertEvents.count, color: ThemeA.coralRed)
                            ForEach(vm.unreadAlertEvents) { ev in
                                HStack(spacing: 9) {
                                    VStack(alignment: .leading, spacing: 2.5) {
                                        Text(L10n.displayTaskName(ev.taskName, source: ev.source, lang: lang))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(Color(red: 254/255, green: 226/255, blue: 226/255))
                                        Text(L10n.displayEventSummary(ev.summary, status: ev.status, lang: lang))
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(red: 252/255, green: 165/255, blue: 165/255))
                                    }
                                    Spacer(minLength: 4)
                                    if let matchedTask = vm.tasks.first(where: { $0.taskKey == ev.taskKey }),
                                       vm.canRunScheduledTask(matchedTask) {
                                        let alertDispatch = vm.dispatchesByKey[ev.taskKey]
                                        let isRunningAlert = alertDispatch?.status == .running
                                        let isStoppingAlert = isRunningAlert && vm.stoppingKeys.contains(ev.taskKey)
                                        if isRunningAlert {
                                            if vm.canStopDispatchDirectly(alertDispatch) {
                                                Button(action: { vm.stopDispatch(forKey: ev.taskKey) }) {
                                                    Image(systemName: isStoppingAlert ? "hourglass" : "stop.fill")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundColor(ThemeA.coralRed)
                                                        .frame(width: 25, height: 25)
                                                        .background(ThemeA.coralRed.opacity(0.18))
                                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.coralRed.opacity(0.45), lineWidth: 1))
                                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                                }
                                                .buttonStyle(TactilePressStyle())
                                                .disabled(isStoppingAlert)
                                                .opacity(isStoppingAlert ? 0.55 : 1.0)
                                                .help(isStoppingAlert ? L10n.stoppingLabel(lang) : L10n.stopTaskHelp(lang))
                                            } else {
                                                Button(action: { vm.openAntigravityDesktop(notice: true) }) {
                                                    Image(systemName: "arrow.up.right.square")
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundColor(ThemeA.cobaltText)
                                                        .frame(width: 25, height: 25)
                                                        .background(ThemeA.cobalt.opacity(0.14))
                                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.cobalt.opacity(0.35), lineWidth: 1))
                                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                                }
                                                .buttonStyle(TactilePressStyle())
                                                .help(L10n.openInAntigravityToStopHelp(lang))
                                            }
                                        } else {
                                            Button(action: { vm.dispatchScheduledTask(matchedTask) }) {
                                                Image(systemName: "play.fill")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(.white)
                                                    .frame(width: 25, height: 25)
                                                    .background(ThemeA.cobalt)
                                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                            }
                                            .buttonStyle(TactilePressStyle())
                                            .help(L10n.rerunAlertHelp(lang))
                                        }
                                    }
                                    if !ev.logPath.isEmpty {
                                        Button(action: { vm.openFileSafely(ev.logPath) }) {
                                            Image(systemName: "terminal")
                                                .font(.system(size: 11))
                                                .foregroundColor(ThemeA.textSecondary)
                                                .frame(width: 25, height: 25)
                                                .background(Color.white.opacity(0.05))
                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.hairline, lineWidth: 1))
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                        .buttonStyle(TactilePressStyle())
                                        .help(L10n.openLogHelp(lang))
                                    }
                                    Button(action: {
                                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                            vm.markEventRead(ev)
                                        }
                                    }) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundColor(ThemeA.emerald)
                                            .frame(width: 25, height: 25)
                                            .background(ThemeA.emerald.opacity(0.12))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.emerald.opacity(0.35), lineWidth: 1))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(TactilePressStyle())
                                    .help(L10n.markReadHelp(lang))
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .background(ThemeA.coralRed.opacity(0.09))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ThemeA.coralRed.opacity(0.28), lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }

                    if !vm.personalTodosOpen.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            sectionLabel(icon: "person.fill", title: L10n.personalSection(lang), count: vm.personalTodosOpen.count, color: ThemeA.amber)
                                .padding(.bottom, 6)
                            VStack(spacing: 0) {
                                ForEach(Array(vm.personalTodosOpen.enumerated()), id: \.element.id) { idx, item in
                                    if idx > 0 { hairlineDivider }
                                    todoHairlineRow(item, accent: ThemeA.amber)
                                }
                            }
                            .overlay(alignment: .top) { hairlineDivider }
                            .overlay(alignment: .bottom) { hairlineDivider }
                        }
                    }

                    if !vm.projectTodosOpen.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            sectionLabel(icon: "hammer.fill", title: L10n.projectSection(lang), count: vm.projectTodosOpen.count, color: ThemeA.cobalt)
                                .padding(.bottom, 6)
                            VStack(spacing: 0) {
                                ForEach(Array(vm.projectTodosOpen.enumerated()), id: \.element.id) { idx, item in
                                    if idx > 0 { hairlineDivider }
                                    todoHairlineRow(item, accent: ThemeA.cobalt)
                                }
                            }
                            .overlay(alignment: .top) { hairlineDivider }
                            .overlay(alignment: .bottom) { hairlineDivider }
                        }
                    }

                    if vm.unreadAlertEvents.isEmpty && vm.personalTodosOpen.isEmpty && vm.projectTodosOpen.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 28))
                                .foregroundColor(ThemeA.emerald)
                            Text(L10n.allClear(lang))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(ThemeA.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 72)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var todoSelectionActionBar: some View {
        HStack(spacing: 8) {
            Text(L10n.selectedCount(vm.selectedTodoKeys.count, lang))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(ThemeA.cobaltText)

            Spacer()

            Button(action: {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    vm.clearTodoSelection()
                }
            }) {
                Text(L10n.clearSelection(lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeA.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(TactilePressStyle())

            Button(action: {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    vm.markSelectedTodosDone()
                }
            }) {
                Text(L10n.markDoneSelected(lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeA.emerald)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ThemeA.emerald.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.emerald.opacity(0.32), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(TactilePressStyle())

            Button(action: {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    vm.dispatchSelectedTodos()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 9.5))
                    Text(L10n.executeSelected(vm.selectedTodoKeys.count, lang))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(ThemeA.cobalt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(TactilePressStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7.5)
        .background(ThemeA.cobalt.opacity(0.10))
    }

    private func todoHairlineRow(_ item: TodoItem, accent: Color) -> some View {
        let isSelected = vm.selectedTodoKeys.contains(item.todoKey)
        let dispatch = vm.dispatchesByKey[item.todoKey]
        let isRunning = dispatch?.status == .running
        let isExpanded = vm.expandedTodoKey == item.todoKey
        let cleanDisplay = TodoMarkdownParser.stripSourceSuffix(item.text)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Button(action: {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78)) {
                        vm.toggleTodoSelection(item)
                    }
                }) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundColor(isSelected ? ThemeA.cobalt : ThemeA.textMuted)
                        .padding(.top, 2)
                }
                .buttonStyle(TactilePressStyle(scale: 0.90))
                .disabled(isRunning)
                .help(L10n.selectTodoForBatchHelp(lang))
                .accessibilityLabel(L10n.selectTodoForBatchHelp(lang))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.project)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(accent)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(accent.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        if let dispatch {
                            todoDispatchPill(dispatch: dispatch, isExpanded: isExpanded) {
                                if reduceMotion {
                                    vm.toggleConversationDrawer(for: item)
                                } else {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        vm.toggleConversationDrawer(for: item)
                                    }
                                }
                            }
                        } else if let src = item.sources.last {
                            Button(action: {
                                if reduceMotion {
                                    vm.toggleConversationDrawer(for: item)
                                } else {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        vm.toggleConversationDrawer(for: item)
                                    }
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left")
                                        .font(.system(size: 9))
                                    Text("\(src.agent) · \(src.sessionPrefix)")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .foregroundColor(ThemeA.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.white.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ThemeA.hairline, lineWidth: 0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(TactilePressStyle())
                            .help(L10n.viewConversationHelp(lang))
                        }

                        Spacer(minLength: 4)

                        let isStopping = vm.stoppingKeys.contains(item.todoKey)
                        let canStop = vm.canStopDispatchDirectly(dispatch)
                        let actionLabel = isStopping ? L10n.stoppingLabel(lang)
                            : isRunning ? L10n.stopTaskHelp(lang) : L10n.runTodoNowHelp(lang)
                        Button(action: {
                            if isRunning { vm.stopDispatch(forKey: item.todoKey) }
                            else { vm.dispatchTodo(item) }
                        }) {
                            Image(systemName: isStopping ? "hourglass" : isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(isRunning ? ThemeA.coralRed : ThemeA.cobaltText)
                                .frame(width: 24, height: 20)
                                .background((isRunning ? ThemeA.coralRed : ThemeA.cobalt).opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(TactilePressStyle())
                        .disabled(isStopping || (isRunning && !canStop))
                        .help(actionLabel)
                        .accessibilityLabel("\(actionLabel) · \(cleanDisplay)")
                        .accessibilityIdentifier("todo-run-\(item.todoKey)")

                        Button(action: {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.72)) {
                                vm.toggleTodo(item)
                            }
                        }) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(ThemeA.emerald)
                                .frame(width: 20, height: 18)
                                .background(ThemeA.emerald.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ThemeA.emerald.opacity(0.28), lineWidth: 0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(TactilePressStyle())
                        .help(L10n.markTodoDoneHelp(lang))
                        .accessibilityLabel("\(L10n.markTodoDoneHelp(lang)) · \(cleanDisplay)")
                        .disabled(isRunning)
                    }

                    Text(cleanDisplay.isEmpty ? item.text : cleanDisplay)
                        .font(.system(size: 11.5))
                        .foregroundColor(ThemeA.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8.5)
            .padding(.horizontal, 4)

            if isExpanded {
                todoConversationDrawer(item: item, dispatch: dispatch)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isSelected ? ThemeA.cobalt.opacity(0.06) : Color.clear)
    }

    private func dispatchStatusColor(_ status: TodoDispatchStatus) -> Color {
        switch status {
        case .running: return ThemeA.cobalt
        case .completed: return ThemeA.emerald
        case .needsAttention: return ThemeA.amber
        case .failed: return ThemeA.coralRed
        case .stopped: return ThemeA.textSecondary
        }
    }

    private func todoDispatchPill(dispatch: TodoDispatchRecord, isExpanded: Bool, onTap: @escaping () -> Void) -> some View {
        let isStopping = dispatch.status == .running && vm.stoppingKeys.contains(dispatch.todoKey)
        let color = isStopping ? ThemeA.amber : dispatchStatusColor(dispatch.status)
        return Button(action: onTap) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 5.5, height: 5.5)
                Text("\(isStopping ? L10n.stoppingLabel(lang) : L10n.dispatchStatusLabel(dispatch.status, lang)) · \(L10n.speakerAgent(dispatch.agent))")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.32), lineWidth: 0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(TactilePressStyle())
        .help(L10n.viewConversationHelp(lang))
    }

    private func todoConversationDrawer(item: TodoItem, dispatch: TodoDispatchRecord?) -> some View {
        let turns = vm.conversationTurnsByKey[item.todoKey] ?? []
        let agentName = L10n.speakerAgent(dispatch?.agent ?? item.sources.last?.agent ?? "")
        let sidPrefix = String((dispatch?.sessionId ?? item.sources.last?.sessionPrefix ?? "").prefix(8))

        return VStack(alignment: .leading, spacing: 7) {
            if let dispatch, !dispatch.summary.isEmpty, !turns.isEmpty,
               dispatch.status == .failed || dispatch.summary == TodoDispatchRunner.unconfirmedAntigravitySummary
                   || dispatch.summary == TodoDispatchRunner.missingAntigravityReplySummary {
                Text(dispatch.summary)
                    .font(.system(size: 10.5))
                    .foregroundColor(ThemeA.coralRed)
            }
            if turns.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 10))
                    Text(dispatch?.summary.isEmpty == false ? dispatch!.summary : L10n.noConversationYet(lang))
                        .font(.system(size: 10.5))
                        .lineLimit(3)
                }
                .foregroundColor(ThemeA.textMuted)
            } else {
                ForEach(turns) { turn in
                    let isUser = turn.role == "user"
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isUser ? L10n.speakerUser(lang) : agentName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(isUser ? ThemeA.amber : ThemeA.cobaltText)
                        Text(turn.text)
                            .font(.system(size: 10.5))
                            .foregroundColor(ThemeA.textPrimary.opacity(0.90))
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5.5)
                    .background(isUser ? Color.white.opacity(0.03) : ThemeA.cobalt.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack(spacing: 8) {
                if !sidPrefix.isEmpty {
                    Text(sidPrefix)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(ThemeA.textMuted)
                }
                Spacer()
                Button(action: { vm.openConversationFile(for: item) }) {
                    HStack(spacing: 3.5) {
                        Text(L10n.openFullTranscript(lang))
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9.5))
                    }
                    .foregroundColor(ThemeA.cobaltText)
                }
                .buttonStyle(TactilePressStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ThemeA.recessedBg)
        .overlay(alignment: .leading) {
            Rectangle().fill(ThemeA.cobalt.opacity(0.55)).frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 22)
        .padding(.trailing, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Tab 2: Settings (Language i18n + Lmemory + DND/Display + Webhook)

    private var settingsTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    // 1. Language & IP Auto-Detection (REQ-007)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            sectionLabel(icon: "globe", title: L10n.languageSection(lang), count: 0, color: ThemeA.cobaltText)
                            Spacer()
                            Text(L10n.languageHint(mode: vm.config.languageMode, country: vm.config.detectedIPCountry, effective: lang, lang: lang))
                                .font(.system(size: 10))
                                .foregroundColor(ThemeA.textMuted)
                                .lineLimit(1)
                        }

                        DarkDropdown(
                            id: "language",
                            openId: $openDropdownId,
                            selection: Binding(
                                get: { vm.config.languageMode },
                                set: { vm.setLanguageMode($0) }
                            ),
                            options: [
                                (LanguageMode.auto, L10n.languageAuto(lang)),
                                (LanguageMode.zhHans, L10n.languageZh(lang)),
                                (LanguageMode.en, L10n.languageEn(lang))
                            ]
                        )
                    }

                    hairlineDivider

                    // 2. Lmemory Integration
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel(icon: "brain.head.profile", title: L10n.lmemorySection(lang), count: 0, color: ThemeA.cobaltText)

                        if let env = vm.detectedEnv {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                                ForEach(env.agents) { ag in
                                    HStack(spacing: 6) {
                                        Text(ag.displayName)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundColor(ThemeA.textPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        Circle()
                                            .fill(ag.lmemoryConnected ? ThemeA.emerald : (ag.installed ? ThemeA.amber : ThemeA.textMuted))
                                            .frame(width: 6, height: 6)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6.5)
                                    .background(Color.white.opacity(0.03))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(ThemeA.hairline, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }

                        TextField(L10n.vaultPlaceholder(lang), text: $vm.config.vaultPath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(ThemeA.textPrimary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(ThemeA.recessedBg)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ThemeA.hairline, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                        HStack(spacing: 8) {
                            Button(action: { vm.runOneClickDeploy() }) {
                                Label(vm.isDeploying ? L10n.deploying(lang) : L10n.backupAndDeploy(lang), systemImage: "arrow.down.circle")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(ThemeA.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5.5)
                                    .background(Color.white.opacity(0.055))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.11), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .disabled(vm.isDeploying)
                            .buttonStyle(TactilePressStyle())

                            Button(action: { vm.prepareOnboarding() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(ThemeA.textSecondary)
                                    .frame(width: 26, height: 26)
                                    .background(Color.white.opacity(0.045))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(ThemeA.hairline, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(TactilePressStyle())
                            .help(L10n.redetectHelp(lang))
                        }

                        if !vm.deployResults.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(vm.deployResults) { r in
                                    HStack(spacing: 5) {
                                        Image(systemName: r.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(r.status == "ok" ? ThemeA.emerald : ThemeA.amber)
                                        Text("\(r.agent): \(r.message)")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(ThemeA.textSecondary)
                                    }
                                }
                            }
                        }
                    }

                    hairlineDivider

                    // 3. DND & Multi-Screen
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel(icon: "moon.zzz", title: L10n.dndScreenSection(lang), count: 0, color: ThemeA.amber)

                        DarkCheckbox(title: L10n.focusDND(lang), isOn: $vm.config.focusMode)
                        DarkCheckbox(title: L10n.scheduledDND(lang), isOn: $vm.config.dndEnabled)

                        if vm.config.dndEnabled {
                            HStack(spacing: 7) {
                                TextField("22:00", text: $vm.config.dndStart)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(ThemeA.textPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .frame(width: 66)
                                    .background(ThemeA.recessedBg)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.hairline, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(ThemeA.textMuted)

                                TextField("08:30", text: $vm.config.dndEnd)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(ThemeA.textPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .frame(width: 66)
                                    .background(ThemeA.recessedBg)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeA.hairline, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            if !vm.dndErrorMsg.isEmpty {
                                Text(vm.dndErrorMsg)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(ThemeA.coralRed)
                            }
                        }

                        let screenOptions: [(String, String)] = [("all", L10n.allScreens(lang))] + NSScreen.screens.map { s in
                            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                            return ("locked:\(id)", L10n.lockedScreen(s.localizedName, lang))
                        }
                        DarkDropdown(
                            id: "screenMode",
                            openId: $openDropdownId,
                            selection: $vm.config.screenMode,
                            options: screenOptions
                        )
                    }

                    hairlineDivider

                    // 4. External Push (Webhook Only)
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel(icon: "paperplane.fill", title: L10n.pushSection(lang), count: 0, color: ThemeA.emerald)

                        DarkCheckbox(title: "Webhook", isOn: $vm.config.webhookEnabled)

                        if vm.config.webhookEnabled {
                            DarkDropdown(
                                id: "webhookKind",
                                openId: $openDropdownId,
                                selection: $vm.config.webhookKind,
                                options: WebhookKind.allCases.map { ($0, $0.label(for: lang)) }
                            )

                            if !vm.maskedWebhookPreview.isEmpty {
                                Text(vm.maskedWebhookPreview)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(ThemeA.textMuted)
                            }

                            SecureField(L10n.webhookPlaceholder(lang), text: $vm.webhookURLDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(ThemeA.textPrimary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(ThemeA.recessedBg)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ThemeA.hairline, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 7))

                            HStack {
                                Spacer()
                                Button(action: { vm.testWebhookNow() }) {
                                    Label(L10n.testPush(lang), systemImage: "paperplane")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(ThemeA.textPrimary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.05))
                                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ThemeA.hairline, lineWidth: 1))
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(TactilePressStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            hairlineDivider

            // Sticky bottom save bar
            HStack(spacing: 10) {
                if !vm.settingsStatusMsg.isEmpty {
                    Text(vm.settingsStatusMsg)
                        .font(.system(size: 10.5))
                        .foregroundColor(vm.settingsStatusIsError ? ThemeA.coralRed : ThemeA.emerald)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }

                // Morphing Save Button (Idle -> Saved)
                Button(action: { vm.saveSettingsAndSecrets() }) {
                    Label(
                        vm.saveFeedbackActive ? L10n.savedFeedback(lang) : L10n.saveSettings(lang),
                        systemImage: vm.saveFeedbackActive ? "checkmark.circle.fill" : "checkmark"
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: vm.saveFeedbackActive
                                ? [ThemeA.emerald, Color(red: 22/255, green: 163/255, blue: 74/255)]
                                : [ThemeA.cobalt, Color(red: 37/255, green: 99/255, blue: 235/255)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: vm.saveFeedbackActive)
                }
                .buttonStyle(TactilePressStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(ThemeA.recessedBg.opacity(0.6))
        }
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.health.state == .healthy ? ThemeA.emerald : (vm.health.state == .failed ? ThemeA.coralRed : ThemeA.amber))
                .frame(width: 7, height: 7)
            Button(action: {
                if vm.health.state == .missing {
                    switchTab(2)
                } else if !vm.health.logPath.isEmpty {
                    vm.openFileSafely(vm.health.logPath)
                }
            }) {
                Text(L10n.lmemoryHealthLabel(vm.health.state, lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeA.textSecondary)
            }
            .buttonStyle(TactilePressStyle())
            .help(L10n.healthTooltip(vm.health, lang))

            Spacer()

            if !vm.todoMarkdownPath.isEmpty {
                Button(action: { vm.openFileSafely(vm.todoMarkdownPath) }) {
                    HStack(spacing: 4) {
                        Text("每日待办.md")
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundColor(ThemeA.cobaltText)
                }
                .buttonStyle(TactilePressStyle())
                .help(L10n.openTodoMdHelp(lang))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8.5)
        .background(ThemeA.barBg)
    }

    // MARK: - Icon & Color Helpers

    private func sectionLabel(icon: String, title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(count > 0 ? "\(title) \(count)" : title)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundColor(color)
    }

    private func toolIcon(_ source: TaskSource) -> String {
        switch source {
        case .antigravity: return "sparkles"
        case .codex: return "terminal"
        case .claude: return "bubble.left.and.text.bubble.right"
        case .workbuddy: return "briefcase"
        case .zcode: return "chevron.left.forwardslash.chevron.right"
        case .launchd: return "gearshape.2"
        case .custom: return "bolt"
        }
    }

    private func toolColor(_ source: TaskSource) -> Color {
        switch source {
        case .antigravity: return ThemeA.cobaltText
        case .codex: return Color(red: 167/255, green: 139/255, blue: 250/255)
        case .claude: return Color(red: 251/255, green: 146/255, blue: 60/255)
        case .workbuddy: return Color(red: 52/255, green: 211/255, blue: 153/255)
        case .zcode: return Color(red: 251/255, green: 191/255, blue: 36/255)
        case .launchd: return ThemeA.amber
        case .custom: return ThemeA.emerald
        }
    }

    private func statusColor(_ status: RunStatus) -> Color {
        switch status {
        case .error, .missed: return ThemeA.coralRed
        case .attention: return ThemeA.amber
        case .success: return ThemeA.emerald
        case .running: return ThemeA.cobalt
        case .stopped, .unknown: return ThemeA.textMuted
        }
    }

    private func levelIcon(_ lv: NotifyLevel) -> String {
        switch lv {
        case .priority: return "star.fill"
        case .normal: return "bell.fill"
        case .muted: return "bell.slash.fill"
        }
    }

    private func levelColor(_ lv: NotifyLevel) -> Color {
        switch lv {
        case .priority: return ThemeA.amber
        case .normal: return ThemeA.textSecondary
        case .muted: return ThemeA.textMuted
        }
    }
}

// MARK: - Theme-Matched Custom Controls (No Native Aqua Widgets)

private struct DarkCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: {
            if reduceMotion {
                isOn.toggle()
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    isOn.toggle()
                }
            }
        }) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(isOn ? ThemeA.cobalt : ThemeA.recessedBg)
                        .frame(width: 15, height: 15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .stroke(isOn ? ThemeA.cobalt.opacity(0.85) : (hovered ? Color.white.opacity(0.24) : ThemeA.outerBorder), lineWidth: 1)
                        )
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(ThemeA.textPrimary)

                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressStyle(scale: 0.99))
        .onHover { hovered = $0 }
    }
}

private struct DarkDropdown<Value: Hashable>: View {
    let id: String
    @Binding var openId: String?
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredIndex: Int? = nil
    @State private var triggerHovered = false

    private var isOpen: Bool { openId == id }
    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? options.first?.label ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                let toggle = {
                    openId = isOpen ? nil : id
                }
                if reduceMotion {
                    toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        toggle()
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Text(currentLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(ThemeA.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(ThemeA.textSecondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isOpen)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .background(ThemeA.recessedBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isOpen ? ThemeA.cobalt.opacity(0.65) : (triggerHovered ? Color.white.opacity(0.2) : ThemeA.outerBorder), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(TactilePressStyle(scale: 0.99))
            .onHover { triggerHovered = $0 }

            if isOpen {
                VStack(spacing: 1) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        let isSelected = opt.value == selection
                        Button(action: {
                            selection = opt.value
                            if reduceMotion {
                                openId = nil
                            } else {
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    openId = nil
                                }
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text(opt.label)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                    .foregroundColor(isSelected ? ThemeA.cobaltText : ThemeA.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(ThemeA.cobaltText)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? ThemeA.cobaltSoft
                                    : (hoveredIndex == idx ? Color.white.opacity(0.05) : Color.clear)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered in
                            hoveredIndex = hovered ? idx : (hoveredIndex == idx ? nil : hoveredIndex)
                        }
                    }
                }
                .padding(4)
                .background(ThemeA.barBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(ThemeA.outerBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
