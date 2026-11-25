import SwiftUI
import TodoNotchCore

// MARK: - Notch / Top-Bar Pill

struct NotchPillView: View {
    @ObservedObject var vm: AppViewModel
    let physicalNotchWidth: CGFloat
    let earWidth: CGFloat
    let onTap: () -> Void

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
                                .foregroundColor(vm.unreadAlertEvents.isEmpty ? .white : Color(red: 1.0, green: 0.45, blue: 0.45))
                                .lineLimit(1)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(.green)
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
                            .foregroundColor(vm.unreadAlertEvents.isEmpty ? .white : Color(red: 1.0, green: 0.45, blue: 0.45))
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.green)
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
    }
}

// MARK: - 5s Non-Activating Light Toast

struct LightToastView: View {
    @ObservedObject var vm: AppViewModel
    let onOpenMain: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RobotFaceView(presentation: vm.robotPresentation, size: 20)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(vm.toastTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if vm.toastCoalescedCount > 0 {
                        Text("+\(vm.toastCoalescedCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
                Text(vm.toastSummary)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.74))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(white: 0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 340, height: 48)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.green.opacity(0.45), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            vm.dismissToastNow()
            onOpenMain()
        }
        .onHover { vm.setToastHovered($0) }
    }
}

// MARK: - Main Overlay Panel (Icon-First, Minimal Text)

struct MainOverlayView: View {
    @ObservedObject var vm: AppViewModel
    let onClose: () -> Void

    @State private var activeTab = 0
    @State private var expandedTaskKey: String? = nil
    @State private var selectedSourceFilter: TaskSource? = nil

    private static let shortDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(Color.white.opacity(0.09))
            iconTabBar

            if !vm.inlineNotice.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(vm.inlineNotice).font(.system(size: 11))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
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

            Divider().background(Color.white.opacity(0.09))
            footerBar
        }
        .frame(width: 460, height: 540)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Compact Icon-First Header (No moon button, no "收起到刘海" text)

    private var headerBar: some View {
        HStack(spacing: 10) {
            RobotFaceView(presentation: vm.robotPresentation, size: 22)
            Text("TodoNotch")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            HStack(spacing: 8) {
                statChip(icon: "exclamationmark.triangle.fill", count: vm.unreadAlertEvents.count, color: Color(red: 1.0, green: 0.35, blue: 0.35))
                statChip(icon: "person.fill", count: vm.personalTodosOpen.count, color: .orange)
                statChip(icon: "hammer.fill", count: vm.projectTodosOpen.count, color: Color(red: 0.35, green: 0.68, blue: 1.0))
            }

            Spacer()

            Button(action: { vm.refreshAllNow() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(white: 0.82))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("刷新")

            Button(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(Color(white: 0.88))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("收起 (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.black.opacity(0.32))
    }

    private func statChip(icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9.5))
            Text("\(count)").font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundColor(count > 0 ? color : Color(white: 0.42))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(count > 0 ? color.opacity(0.14) : Color.white.opacity(0.05))
        .clipShape(Capsule())
    }

    // MARK: Icon-First 3-Tab Bar

    private var iconTabBar: some View {
        HStack(spacing: 6) {
            tabButton(icon: "clock.arrow.circlepath", title: "定时任务", idx: 0, badge: vm.tasks.filter { $0.sourceStatus == "active" }.count)
            tabButton(icon: "checklist", title: "未完成", idx: 1, badge: vm.personalTodosOpen.count + vm.projectTodosOpen.count)
            tabButton(icon: "gearshape", title: "设置", idx: 2, badge: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.18))
    }

    private func tabButton(icon: String, title: String, idx: Int, badge: Int) -> some View {
        let selected = activeTab == idx
        return Button(action: { activeTab = idx }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 0.5)
                        .background(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(selected ? .white : Color(white: 0.68))
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 6)
            .background(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.001))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: Tab 0 (Default) - Scheduled Tasks Grouped by Tool + 7-Day Dropdown History

    private var scheduledTasksTab: some View {
        let orderedSources: [TaskSource] = [.antigravity, .codex, .claude, .workbuddy, .zcode, .launchd, .custom]
        let presentSources = orderedSources.filter { src in vm.tasks.contains(where: { $0.source == src }) }
        let visibleSources = selectedSourceFilter.map { [$0] } ?? presentSources

        return VStack(spacing: 0) {
            if presentSources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        sourceFilterChip(title: "全部", icon: "square.grid.2x2", count: vm.tasks.count, color: .white, source: nil)
                        ForEach(presentSources, id: \.self) { src in
                            let cnt = vm.tasks.filter { $0.source == src }.count
                            sourceFilterChip(title: toolName(src), icon: toolIcon(src), count: cnt, color: toolColor(src), source: src)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .background(Color.black.opacity(0.14))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if vm.tasks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.badge.questionmark").font(.system(size: 26)).foregroundColor(Color(white: 0.45))
                            Text("未发现定时任务").font(.system(size: 12)).foregroundColor(Color(white: 0.55))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        ForEach(visibleSources, id: \.self) { src in
                            let groupTasks = vm.tasks.filter { $0.source == src }
                            if !groupTasks.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Image(systemName: toolIcon(src))
                                            .font(.system(size: 10.5, weight: .bold))
                                        Text(toolName(src))
                                            .font(.system(size: 11, weight: .bold))
                                        Text("\(groupTasks.filter { $0.sourceStatus == "active" }.count)/\(groupTasks.count)")
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundColor(Color(white: 0.58))
                                    }
                                    .foregroundColor(toolColor(src))
                                    .padding(.leading, 2)

                                    ForEach(groupTasks) { task in
                                        taskExpandableCard(task)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func sourceFilterChip(title: String, icon: String, count: Int, color: Color, source: TaskSource?) -> some View {
        let selected = selectedSourceFilter == source
        return Button(action: { selectedSourceFilter = source }) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                Text("\(count)").font(.system(size: 9.5, weight: .bold, design: .rounded)).opacity(0.75)
            }
            .foregroundColor(selected ? .white : color.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? color.opacity(0.28) : Color.white.opacity(0.06))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toolName(_ source: TaskSource) -> String {
        switch source {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .workbuddy: return "WorkBuddy"
        case .zcode: return "ZCode"
        case .launchd: return "系统 / Lmemory"
        case .custom: return "自定义"
        }
    }

    private func taskExpandableCard(_ task: MonitoredTask) -> some View {
        let isExpanded = expandedTaskKey == task.taskKey
        let isActive = task.sourceStatus == "active"
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Tool icon badge
                Image(systemName: toolIcon(task.source))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(toolColor(task.source))
                    .frame(width: 24, height: 24)
                    .background(toolColor(task.source).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isActive ? statusColor(task.lastRunStatus) : Color(white: 0.38))
                            .frame(width: 6, height: 6)
                        Text(task.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isActive ? .white : Color(white: 0.58))
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: isActive ? "play.fill" : "pause.fill")
                            .font(.system(size: 8))
                            .foregroundColor(isActive ? .green : Color(white: 0.45))
                        if !task.scheduleExpr.isEmpty {
                            Text(task.scheduleExpr)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(white: 0.55))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Priority / Mute icon cycle button
                Button(action: { vm.cycleTaskLevel(task) }) {
                    Image(systemName: levelIcon(task.notifyLevel))
                        .font(.system(size: 11.5))
                        .foregroundColor(levelColor(task.notifyLevel))
                        .frame(width: 24, height: 24)
                        .background(levelColor(task.notifyLevel).opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("通知级别：\(task.notifyLevel.zhLabel)（点击切换）")

                // Expand chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(white: 0.55))
                    .frame(width: 18)
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expandedTaskKey = isExpanded ? nil : task.taskKey
                }
            }

            if isExpanded {
                let weekRuns = vm.recentWeekEvents(for: task.taskKey)
                Divider().background(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    if weekRuns.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "tray").font(.system(size: 10))
                            Text("近 7 天暂无执行记录").font(.system(size: 10.5))
                        }
                        .foregroundColor(Color(white: 0.48))
                        .padding(.vertical, 4)
                    } else {
                        ForEach(weekRuns) { ev in
                            HStack(spacing: 7) {
                                Image(systemName: runStatusIcon(ev.status))
                                    .font(.system(size: 10.5))
                                    .foregroundColor(statusColor(ev.status))
                                Text(Self.shortDateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ev.occurredAt))))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(white: 0.58))
                                Text(ev.summary)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.86))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if !ev.artifactPath.isEmpty {
                                    Button(action: { vm.openFileSafely(ev.artifactPath) }) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(Color(red: 0.45, green: 0.78, blue: 1.0))
                                    }
                                    .buttonStyle(.plain)
                                    .help("打开产出文件")
                                }
                                if !ev.logPath.isEmpty {
                                    Button(action: { vm.openFileSafely(ev.logPath) }) {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(Color(white: 0.68))
                                    }
                                    .buttonStyle(.plain)
                                    .help("打开日志")
                                }
                                if ev.pushStatus == "failed" {
                                    Button(action: { vm.retryPush(for: ev) }) {
                                        Image(systemName: "arrow.clockwise.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.orange)
                                    }
                                    .buttonStyle(.plain)
                                    .help("重试外部推送")
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.22))
            }
        }
        .background(Color.white.opacity(isActive ? 0.055 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isExpanded ? 0.16 : 0.06), lineWidth: 0.8)
        )
    }

    // MARK: Tab 1 - Lmemory Unfinished Tasks & Alerts

    private var unfinishedTodosTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !vm.unreadAlertEvents.isEmpty {
                    sectionChip(icon: "exclamationmark.triangle.fill", title: "告警", count: vm.unreadAlertEvents.count, color: Color(red: 1.0, green: 0.35, blue: 0.35))
                    ForEach(vm.unreadAlertEvents) { ev in
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.octagon.fill").font(.system(size: 12)).foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.taskName).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white)
                                Text(ev.summary).font(.system(size: 11)).foregroundColor(Color(white: 0.8))
                            }
                            Spacer()
                            if !ev.logPath.isEmpty {
                                Button(action: { vm.openFileSafely(ev.logPath) }) {
                                    Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(Color(white: 0.72))
                                }.buttonStyle(.plain)
                            }
                            Button(action: { vm.markEventRead(ev) }) {
                                Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundColor(.green)
                            }.buttonStyle(.plain).help("标为已阅")
                        }
                        .padding(9)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }

                if !vm.personalTodosOpen.isEmpty {
                    sectionChip(icon: "person.fill", title: "待处理", count: vm.personalTodosOpen.count, color: .orange)
                    ForEach(vm.personalTodosOpen) { item in
                        todoRowCard(item, accent: .orange)
                    }
                }

                if !vm.projectTodosOpen.isEmpty {
                    sectionChip(icon: "hammer.fill", title: "进行中", count: vm.projectTodosOpen.count, color: Color(red: 0.35, green: 0.68, blue: 1.0))
                    ForEach(vm.projectTodosOpen) { item in
                        todoRowCard(item, accent: Color(red: 0.35, green: 0.68, blue: 1.0))
                    }
                }

                if vm.unreadAlertEvents.isEmpty && vm.personalTodosOpen.isEmpty && vm.projectTodosOpen.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 28)).foregroundColor(.green)
                        Text("已清空").font(.system(size: 12, weight: .medium)).foregroundColor(Color(white: 0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
            .padding(12)
        }
    }

    private func todoRowCard(_ item: TodoItem, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: { vm.toggleTodo(item) }) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(item.done ? .green : Color(white: 0.62))
                    .padding(.top, 1.5)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.project)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(item.text)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(white: 0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Tab 2 - Settings (Includes Lmemory One-Click Init + DND + Multi-Screen + Push)

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Lmemory Init & Agents (Moved here from default screen)
                sectionChip(icon: "brain.head.profile", title: "Lmemory 接入", count: 0, color: Color(red: 0.45, green: 0.78, blue: 1.0))
                if let env = vm.detectedEnv {
                    VStack(spacing: 5) {
                        ForEach(env.agents) { ag in
                            HStack(spacing: 8) {
                                Image(systemName: ag.installed ? (ag.lmemoryConnected ? "checkmark.circle.fill" : "circle.dotted") : "minus.circle")
                                    .font(.system(size: 12))
                                    .foregroundColor(ag.lmemoryConnected ? .green : (ag.installed ? .orange : Color(white: 0.4)))
                                Text(ag.displayName).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white)
                                Spacer()
                                Image(systemName: ag.lmemoryConnected ? "link" : "link.badge.plus")
                                    .font(.system(size: 11))
                                    .foregroundColor(ag.lmemoryConnected ? .green : Color(white: 0.55))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                TextField("Vault 路径", text: $vm.config.vaultPath).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button(action: { vm.runOneClickDeploy() }) {
                        Label(vm.isDeploying ? "部署中…" : "备份并部署", systemImage: "arrow.down.circle")
                    }
                    .disabled(vm.isDeploying)
                    .buttonStyle(.borderedProminent).controlSize(.small)

                    Button(action: { vm.prepareOnboarding() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("重新探测本机 Agent")
                }
                if !vm.deployResults.isEmpty {
                    ForEach(vm.deployResults) { r in
                        HStack(spacing: 5) {
                            Image(systemName: r.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(r.status == "ok" ? .green : .orange)
                            Text("\(r.agent)：\(r.message)").font(.system(size: 10.5)).foregroundColor(Color(white: 0.85))
                        }
                    }
                }

                Divider().background(Color.white.opacity(0.09))

                // 2. DND & Multi-Screen
                sectionChip(icon: "moon.zzz", title: "勿扰与双屏", count: 0, color: .orange)
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("专注勿扰", isOn: $vm.config.focusMode).font(.system(size: 11.5)).foregroundColor(.white)
                    Toggle("定时勿扰", isOn: $vm.config.dndEnabled).font(.system(size: 11.5)).foregroundColor(.white)
                    if vm.config.dndEnabled {
                        HStack(spacing: 6) {
                            TextField("22:00", text: $vm.config.dndStart).textFieldStyle(.roundedBorder).frame(width: 68)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(Color(white: 0.55))
                            TextField("08:30", text: $vm.config.dndEnd).textFieldStyle(.roundedBorder).frame(width: 68)
                        }
                        if !vm.dndErrorMsg.isEmpty {
                            Text(vm.dndErrorMsg).font(.system(size: 10)).foregroundColor(.red)
                        }
                    }
                    Picker("", selection: $vm.config.screenMode) {
                        Text("双屏常驻").tag("all")
                        ForEach(NSScreen.screens, id: \.self) { s in
                            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                            Text("锁定：\(s.localizedName)").tag("locked:\(id)")
                        }
                    }
                    .labelsHidden()
                    .font(.system(size: 11.5))
                }

                Divider().background(Color.white.opacity(0.09))

                // 3. External Push (Webhook)
                sectionChip(icon: "paperplane.fill", title: "离席推送", count: 0, color: .green)
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Webhook", isOn: $vm.config.webhookEnabled).font(.system(size: 11.5)).foregroundColor(.white)
                    if vm.config.webhookEnabled {
                        Picker("", selection: $vm.config.webhookKind) {
                            ForEach(WebhookKind.allCases, id: \.self) { k in Text(k.zhLabel).tag(k) }
                        }.labelsHidden()
                        if !vm.maskedWebhookPreview.isEmpty {
                            Text(vm.maskedWebhookPreview).font(.system(size: 10, design: .monospaced)).foregroundColor(Color(white: 0.6))
                        }
                        SecureField("https:// Webhook URL", text: $vm.webhookURLDraft).textFieldStyle(.roundedBorder)
                        Button(action: { vm.testWebhookNow() }) { Label("测试推送", systemImage: "paperplane") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }

                    Button(action: { vm.saveSettingsAndSecrets() }) { Label("保存设置", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    if !vm.settingsStatusMsg.isEmpty {
                        Text(vm.settingsStatusMsg).font(.system(size: 10.5)).foregroundColor(.green)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: Compact Footer

    private var footerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.health.state == .healthy ? Color.green : (vm.health.state == .failed ? Color.red : Color.orange))
                .frame(width: 7, height: 7)
            Button(action: {
                if vm.health.state == .missing { activeTab = 2 }
                else if !vm.health.logPath.isEmpty { vm.openFileSafely(vm.health.logPath) }
            }) {
                Text(vm.health.state == .healthy ? "Lmemory 正常" : (vm.health.state == .failed ? "Lmemory 维护异常" : "Lmemory 未配置"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(white: 0.78))
            }
            .buttonStyle(.plain)
            .help(vm.health.detail)

            Spacer()

            if !vm.todoMarkdownPath.isEmpty {
                Button(action: { vm.openFileSafely(vm.todoMarkdownPath) }) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(red: 0.45, green: 0.78, blue: 1.0))
                }
                .buttonStyle(.plain)
                .help("打开每日待办.md")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.28))
    }

    // MARK: Icon & Color Helpers

    private func sectionChip(icon: String, title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(count > 0 ? "\(title) \(count)" : title).font(.system(size: 11, weight: .bold))
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
        case .antigravity: return Color(red: 0.35, green: 0.72, blue: 1.0)
        case .codex: return Color(red: 0.65, green: 0.55, blue: 1.0)
        case .claude: return Color(red: 0.90, green: 0.56, blue: 0.36)
        case .workbuddy: return Color(red: 0.24, green: 0.80, blue: 0.65)
        case .zcode: return Color(red: 0.96, green: 0.76, blue: 0.25)
        case .launchd: return .orange
        case .custom: return .green
        }
    }

    private func statusColor(_ status: RunStatus) -> Color {
        switch status {
        case .error, .missed: return Color(red: 1.0, green: 0.35, blue: 0.35)
        case .attention: return .orange
        case .success: return .green
        case .running: return Color(red: 0.22, green: 0.74, blue: 0.97)
        case .unknown: return Color(white: 0.55)
        }
    }

    private func runStatusIcon(_ status: RunStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .error, .missed: return "xmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .running: return "clock.fill"
        case .unknown: return "circle"
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
        case .priority: return .orange
        case .normal: return Color(white: 0.72)
        case .muted: return Color(white: 0.42)
        }
    }
}
