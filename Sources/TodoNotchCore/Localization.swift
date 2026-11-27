import Foundation

// MARK: - Language Mode & Effective Language

public enum LanguageMode: String, Codable, CaseIterable, Sendable {
    case auto
    case zhHans = "zh-Hans"
    case en
}

public enum AppLanguage: String, Codable, Equatable, Sendable {
    case zhHans = "zh-Hans"
    case en
}

// MARK: - IP-based Default Language Resolver

public enum IPLanguageResolver {
    /// Parses a 2-letter uppercase ISO country code from JSON (`{"country":"CN"}`) or plain text (`"US\n"`).
    public static func parseCountryCode(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["country", "country_code", "countryCode"] {
                if let val = obj[key] as? String, let normalized = normalizeCountryCode(val) {
                    return normalized
                }
            }
        }
        if let text = String(data: data, encoding: .utf8),
           let normalized = normalizeCountryCode(text) {
            return normalized
        }
        return nil
    }

    private static func normalizeCountryCode(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 2,
              cleaned.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else {
            return nil
        }
        return cleaned
    }

    /// Mainland China IP defaults to Simplified Chinese; all other valid countries default to English.
    public static func resolveFromCountry(_ countryCode: String?) -> AppLanguage? {
        guard let code = countryCode.flatMap(normalizeCountryCode) else { return nil }
        return code == "CN" ? .zhHans : .en
    }

    public static func systemFallback(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let first = preferredLanguages.first?.lowercased(), first.hasPrefix("zh") {
            return .zhHans
        }
        return .en
    }

    /// Manual selection (.zhHans / .en) always overrides IP detection.
    public static func resolveEffective(
        mode: LanguageMode,
        detectedCountry: String?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch mode {
        case .zhHans:
            return .zhHans
        case .en:
            return .en
        case .auto:
            return resolveFromCountry(detectedCountry) ?? systemFallback(preferredLanguages: preferredLanguages)
        }
    }

    /// Queries lightweight IP-to-country endpoints concurrently within a strict total timeout budget.
    public static func fetchIPCountryCode(timeout: TimeInterval = 3.0) async -> String? {
        let endpoints = [
            "https://api.country.is",
            "https://ipapi.co/country/"
        ]
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        enum RaceOutcome: Sendable {
            case fetched(String?)
            case timedOut
        }

        return await withTaskGroup(of: RaceOutcome.self) { group in
            for urlString in endpoints {
                guard let url = URL(string: urlString) else { continue }
                group.addTask {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = timeout
                    req.cachePolicy = .reloadIgnoringLocalCacheData
                    do {
                        let (data, resp) = try await session.data(for: req)
                        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            return .fetched(nil)
                        }
                        return .fetched(parseCountryCode(from: data))
                    } catch {
                        return .fetched(nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                return .timedOut
            }
            while let outcome = await group.next() {
                switch outcome {
                case .fetched(let code?):
                    group.cancelAll()
                    return code
                case .fetched(nil):
                    continue
                case .timedOut:
                    group.cancelAll()
                    return nil
                }
            }
            return nil
        }
    }
}

// MARK: - Localized Strings (Chinese & English)

public enum L10n {
    public static func tabTasks(_ lang: AppLanguage) -> String { lang == .zhHans ? "定时任务" : "Tasks" }
    public static func tabTodos(_ lang: AppLanguage) -> String { lang == .zhHans ? "未完成" : "Todos" }
    public static func tabSettings(_ lang: AppLanguage) -> String { lang == .zhHans ? "设置" : "Settings" }

    public static func allFilter(_ lang: AppLanguage) -> String { lang == .zhHans ? "全部" : "All" }
    public static func refreshHelp(_ lang: AppLanguage) -> String { lang == .zhHans ? "刷新" : "Refresh" }
    public static func collapseHelp(_ lang: AppLanguage) -> String { lang == .zhHans ? "收起 (Esc)" : "Collapse (Esc)" }
    public static func noTasksFound(_ lang: AppLanguage) -> String { lang == .zhHans ? "未发现定时任务" : "No scheduled tasks found" }
    public static func noWeekRuns(_ lang: AppLanguage) -> String { lang == .zhHans ? "近 7 天暂无执行记录" : "No runs in the past 7 days" }
    public static func openDesktopTaskHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "在桌面应用打开定时任务" : "Open automation in desktop app"
    }
    public static func taskNavigationInProgress(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "正在定位定时任务…" : "Locating automation…"
    }

    public static func taskNavigationTitle(_ outcome: DesktopNavigationRules.Outcome, _ lang: AppLanguage) -> String {
        if outcome == .needsAccessibility {
            return lang == .zhHans ? "需要辅助功能权限" : "Accessibility permission required"
        }
        return lang == .zhHans ? "打开定时任务" : "Open automation"
    }

    public static func taskNavigationMessage(
        _ outcome: DesktopNavigationRules.Outcome, source: TaskSource, lang: AppLanguage
    ) -> String? {
        let zh = lang == .zhHans
        let app = sourceName(source, lang)
        switch outcome {
        case .opened, .accepted, .cancelled:
            return nil
        case .needsAccessibility:
            return zh ? "允许 TodoNotch 使用辅助功能后重试。重新构建后可能需要重新勾选。"
                : "Allow TodoNotch in Accessibility, then retry. You may need to re-enable access after rebuilding."
        case .appNotInstalled:
            return zh ? "未找到已安装的 \(app) 桌面应用。" : "The \(app) desktop app is not installed."
        case .launchFailed:
            return zh ? "系统未能打开 \(app) 桌面应用。" : "macOS could not open the \(app) desktop app."
        case .deepLinkRejected:
            return zh ? "系统无法将定时任务链接交给 \(app)。" : "macOS could not hand the automation link to \(app)."
        case .invalidTaskId:
            return zh ? "定时任务 ID 无效，无法打开详情。" : "The automation ID is invalid."
        case .unsupportedSource:
            return zh ? "\(app) 暂不支持从这里打开定时任务。" : "\(app) does not support opening automations from here."
        case .ambiguousMatches:
            return zh ? "发现同名或多条匹配的定时任务，已停留在筛选列表，请手动选择。"
                : "Multiple automations matched. The filtered list is open so you can select one."
        case .notFound:
            return zh ? "筛选列表中没有找到指定的定时任务。" : "The requested automation was not found in the filtered list."
        case .timedOut:
            return zh ? "等待 \(app) 显示定时任务超时，请重试。" : "Timed out waiting for \(app) to show the automation. Try again."
        case .wrongTask:
            return zh ? "打开的详情与所选定时任务不一致，请在 \(app) 中手动选择。"
                : "A different automation opened. Select the requested one in \(app)."
        }
    }

    public static func taskNavigationOpenSettings(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "打开辅助功能设置" : "Open Accessibility Settings"
    }

    public static func taskNavigationDismiss(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "关闭提示" : "Dismiss notice"
    }
    public static func openArtifactHelp(_ lang: AppLanguage) -> String { lang == .zhHans ? "打开产出文件" : "Open artifact" }
    public static func openLogHelp(_ lang: AppLanguage) -> String { lang == .zhHans ? "打开日志" : "Open log" }
    public static func retryPushHelp(_ lang: AppLanguage) -> String { lang == .zhHans ? "重试外部推送" : "Retry webhook push" }
    public static func taskLevelHelp(_ level: NotifyLevel, _ lang: AppLanguage) -> String {
        lang == .zhHans
            ? "通知级别：\(level.label(for: lang))（点击切换）"
            : "Notify level: \(level.label(for: lang)) (click to cycle)"
    }

    public static func sourceName(_ source: TaskSource, _ lang: AppLanguage) -> String {
        switch source {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .workbuddy: return "WorkBuddy"
        case .zcode: return "ZCode"
        case .launchd: return lang == .zhHans ? "系统 / Lmemory" : "System / Lmemory"
        case .custom: return lang == .zhHans ? "自定义" : "Custom"
        }
    }

    public static func alertsSection(_ lang: AppLanguage) -> String { lang == .zhHans ? "告警" : "Alerts" }
    public static func personalSection(_ lang: AppLanguage) -> String { lang == .zhHans ? "待处理" : "Action Needed" }
    public static func projectSection(_ lang: AppLanguage) -> String { lang == .zhHans ? "进行中" : "In Progress" }
    public static func markReadHelp(_ lang: AppLanguage) -> String { lang == .zhHans ? "标为已阅" : "Mark as read" }
    public static func allClear(_ lang: AppLanguage) -> String { lang == .zhHans ? "已清空" : "All clear" }

    // Todo Dispatch & Conversation Tracking
    public static func selectedCount(_ count: Int, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "已选 \(count) 项" : "\(count) selected"
    }
    public static func executeSelected(_ count: Int, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "执行 (\(count))" : "Run (\(count))"
    }
    public static func markDoneSelected(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "标为完成" : "Mark Done"
    }
    public static func clearSelection(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "取消" : "Cancel"
    }
    public static func selectTodoForBatchHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "选择用于批量操作" : "Select for batch action"
    }
    public static func markTodoDoneHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "标为已完成（写回每日待办.md）" : "Mark as done (updates 每日待办.md)"
    }
    public static func viewConversationHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "查看/收起对话记录" : "Toggle conversation"
    }
    public static func openFullTranscript(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "打开完整记录" : "Open full log"
    }
    public static func noConversationYet(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "暂无可读取的对话记录" : "No conversation turns yet"
    }
    public static func speakerUser(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "你" : "You"
    }
    public static func speakerAgent(_ agent: String) -> String {
        switch agent.lowercased() {
        case "antigravity": return "Antigravity"
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "cursor": return "Cursor"
        case "pi": return "Pi"
        case "opencode": return "OpenCode"
        case "grok": return "Grok"
        case "qoder": return "Qoder"
        case "workbuddy": return "WorkBuddy"
        case "zcode": return "ZCode"
        default: return agent.isEmpty ? "Agent" : agent
        }
    }
    public static func dispatchStatusLabel(_ status: TodoDispatchStatus, _ lang: AppLanguage) -> String {
        switch (status, lang) {
        case (.running, .zhHans): return "执行中"
        case (.running, .en): return "Running"
        case (.completed, .zhHans): return "已完成"
        case (.completed, .en): return "Done"
        case (.needsAttention, .zhHans): return "待确认"
        case (.needsAttention, .en): return "Needs Input"
        case (.failed, .zhHans): return "失败"
        case (.failed, .en): return "Failed"
        case (.stopped, .zhHans): return "已停止"
        case (.stopped, .en): return "Stopped"
        }
    }
    public static func dispatchDoneSummary(_ status: TodoDispatchStatus, summary: String, lang: AppLanguage) -> String {
        let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return dispatchStatusLabel(status, lang)
    }
    public static func runTaskNowHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "立即执行此定时任务" : "Run scheduled task now"
    }
    public static func runTodoNowHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "执行此待办" : "Run this to-do"
    }
    public static func stopTaskHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "停止当前执行的任务" : "Stop running task"
    }
    public static func stoppingLabel(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "停止中…" : "Stopping…"
    }
    public static func dispatchHistorySaveFailed(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "无法保存上一轮待确认的记录，请刷新后重试" : "Could not save the previous run. Refresh and try again"
    }
    public static func stopFailedNotice(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "未能确认停止进程，请检查终端或对应工具" : "Could not confirm process stopped"
    }
    public static func taskStoppedSummary(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "已手动停止" : "Stopped by user"
    }
    public static func pausedTasksToggle(_ count: Int, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "已暂停 \(count) 项" : "Paused (\(count))"
    }
    public static func taskAlreadyRunningHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "任务正在后台执行中" : "Task is running in background"
    }
    public static func rerunAlertHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "立即重新执行" : "Run task now"
    }
    public static func latestManualRunLabel(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "最近手动执行" : "Latest Manual Run"
    }
    public static func openWorkBuddyHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "在 WorkBuddy 中打开（无后台 CLI）" : "Open in WorkBuddy (GUI only)"
    }
    public static func openInAntigravityToStopHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "在 Antigravity 桌面端查看对话或停止" : "Open in Antigravity Desktop to view or stop"
    }
    public static func antigravityStopInDesktopNotice(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "已切到 Antigravity 桌面端，请在侧边栏查看对话或点击停止" : "Switched to Antigravity Desktop — view or stop the conversation there"
    }

    // Settings
    public static func languageSection(_ lang: AppLanguage) -> String { lang == .zhHans ? "语言与地区" : "Language" }
    public static func languageAuto(_ lang: AppLanguage) -> String { lang == .zhHans ? "自动 (IP)" : "Auto (IP)" }
    public static func languageZh(_ lang: AppLanguage) -> String { "简体中文" }
    public static func languageEn(_ lang: AppLanguage) -> String { "English" }
    public static func languageHint(mode: LanguageMode, country: String, effective: AppLanguage, lang: AppLanguage) -> String {
        if mode != .auto {
            return lang == .zhHans ? "已手动锁定语种（不随 IP 变化覆盖）" : "Manually locked (won't be overridden by IP)"
        }
        if !country.isEmpty {
            let target = effective == .zhHans ? (lang == .zhHans ? "中文" : "Chinese") : "English"
            return lang == .zhHans ? "出口 IP：\(country) → \(target)" : "IP Country: \(country) → \(target)"
        }
        return lang == .zhHans ? "离线/等待检测 → 跟随系统语言" : "Offline/pending → System language"
    }

    public static func lmemorySection(_ lang: AppLanguage) -> String { lang == .zhHans ? "Lmemory 接入" : "Lmemory Integration" }
    public static func vaultPlaceholder(_ lang: AppLanguage) -> String { lang == .zhHans ? "Vault 路径" : "Vault Path" }
    public static func deploying(_ lang: AppLanguage) -> String { lang == .zhHans ? "部署中…" : "Deploying…" }
    public static func backupAndDeploy(_ lang: AppLanguage) -> String { lang == .zhHans ? "备份并部署" : "Backup & Deploy" }
    public static func redetectHelp(_ lang: AppLanguage) -> String { lang == .zhHans ? "重新探测本机 Agent" : "Re-detect local Agents" }

    public static func dndScreenSection(_ lang: AppLanguage) -> String { lang == .zhHans ? "勿扰与双屏" : "DND & Displays" }
    public static func focusDND(_ lang: AppLanguage) -> String { lang == .zhHans ? "专注勿扰" : "Focus DND" }
    public static func scheduledDND(_ lang: AppLanguage) -> String { lang == .zhHans ? "定时勿扰" : "Scheduled DND" }
    public static func allScreens(_ lang: AppLanguage) -> String { lang == .zhHans ? "双屏常驻" : "All Displays" }
    public static func lockedScreen(_ name: String, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "锁定：\(name)" : "Lock: \(name)"
    }

    public static func pushSection(_ lang: AppLanguage) -> String { lang == .zhHans ? "离席推送" : "Away Push" }
    public static func webhookPlaceholder(_ lang: AppLanguage) -> String { "https:// Webhook URL" }
    public static func testPush(_ lang: AppLanguage) -> String { lang == .zhHans ? "测试推送" : "Test Push" }
    public static func saveSettings(_ lang: AppLanguage) -> String { lang == .zhHans ? "保存设置" : "Save Settings" }
    public static func savedFeedback(_ lang: AppLanguage) -> String { lang == .zhHans ? "已保存" : "Saved" }

    public static func lmemoryHealthLabel(_ state: LmemoryHealth.State, _ lang: AppLanguage) -> String {
        switch state {
        case .healthy: return lang == .zhHans ? "Lmemory 正常" : "Lmemory Healthy"
        case .failed: return lang == .zhHans ? "Lmemory 维护异常" : "Lmemory Failed"
        case .missing, .unknown: return lang == .zhHans ? "Lmemory 未配置" : "Lmemory Missing"
        }
    }
    public static func openTodoMdHelp(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "打开每日待办.md" : "Open 每日待办.md"
    }

    // ViewModel Feedback & Messages
    public static func detectingHealth(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "正在检测 Lmemory 状态…" : "Checking Lmemory status…"
    }
    public static func missedSummary(_ lang: AppLanguage) -> String {
        lang == .zhHans
            ? "任务已超过计划时间 15 分钟仍未观测到执行记录（疑似漏跑）"
            : "Task is >15m past schedule with no recorded run (possibly missed)"
    }
    public static func noVaultConfigured(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "未配置 Lmemory 知识库" : "Lmemory Vault not configured"
    }
    public static func noTodoFile(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "暂无每日待办.md" : "No 每日待办.md found"
    }
    public static func syncedLabel(_ lang: AppLanguage) -> String { lang == .zhHans ? "已同步" : "Synced" }
    public static func updatedAt(_ ts: String, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "更新于 \(ts)" : "Updated \(ts)"
    }
    public static func todoWritebackFailed(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "无法写回每日待办.md，请检查文件是否存在" : "Failed to update 每日待办.md; check file path"
    }
    public static func fileMissingNotice(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "原文件已移动或删除" : "File has been moved or deleted"
    }
    public static func invalidWebhookNotice(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "Webhook URL 不合法（仅允许 https:// 或 localhost）" : "Invalid Webhook URL (https:// or localhost only)"
    }
    public static func settingsSavedNotice(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "设置已保存（敏感凭据已加密存入 macOS 钥匙串）" : "Settings saved (secrets stored in macOS Keychain)"
    }
    public static func testingWebhookNotice(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "正在发送测试 Webhook…" : "Sending test Webhook…"
    }
    public static func testFailedPrefix(_ err: String, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "测试失败：\(err)" : "Test failed: \(err)"
    }

    // Status Bar Menu
    public static func menuOpenHub(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "打开待办与定时任务中枢" : "Open TodoNotch Hub"
    }
    public static func menuToggleFocus(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "切换专注勿扰" : "Toggle Focus DND"
    }
    public static func menuOnboarding(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "Lmemory 一键引导 / 修复" : "Lmemory Setup / Repair"
    }
    public static func menuRefresh(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "立即刷新" : "Refresh Now"
    }
    public static func menuQuit(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "退出 TodoNotch" : "Quit TodoNotch"
    }

    // Core Errors, Deploy, Health Tooltip & Fallbacks
    public static func webhookInvalidURL(_ lang: AppLanguage) -> String { invalidWebhookNotice(lang) }
    public static func webhookPayloadTooLarge(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "Webhook 载荷超过 16 KB 上限" : "Webhook payload exceeds 16 KB limit"
    }
    public static func webhookInvalidResponse(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "Webhook 未收到有效 HTTP 响应" : "Webhook received invalid HTTP response"
    }
    public static func webhookHTTPStatus(_ code: Int, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "Webhook 返回 HTTP \(code)" : "Webhook returned HTTP \(code)"
    }
    public static func webhookNetworkUnreachable(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "Webhook 网络不可达或超时" : "Webhook network unreachable or timed out"
    }
    public static func webhookMissingInKeychain(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "未在钥匙串配置 Webhook URL" : "Webhook URL not found in Keychain"
    }
    public static func webhookEnterURLFirst(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "请先输入并保存 Webhook URL" : "Please enter and save a Webhook URL first"
    }
    public static func webhookTestTitle(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "TodoNotch 测试通知" : "TodoNotch Test Notification"
    }
    public static func webhookTestBody(_ lang: AppLanguage) -> String {
        lang == .zhHans
            ? "Webhook 通道连接正常，定时任务异常与重点通知将推送至此。"
            : "Webhook channel is connected. Task alerts and priority notifications will be sent here."
    }
    public static func webhookTestSent(_ kind: WebhookKind, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "测试消息已推送至 \(kind.label(for: lang))" : "Test message sent to \(kind.label(for: lang))"
    }
    public static func keychainWriteFailed(_ status: Int32, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "Keychain 写入失败（OSStatus=\(status)）" : "Keychain write failed (OSStatus=\(status))"
    }
    public static func maskedConfiguredFallback(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "已配置（已脱敏）" : "Configured (masked)"
    }
    public static func deployConnectedIdempotent(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "已接入（幂等保留原有配置与 Vault）" : "Connected (preserved existing config & Vault)"
    }
    public static func deployMissingBootstrap(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "未找到 Lmemory bootstrap.py，请先安装 Lmemory 后点击重新检测" : "Lmemory bootstrap.py not found; install Lmemory and re-detect"
    }
    public static func deployAgyManual(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "请在 Antigravity Hooks 配置中引用 lmemory-agy.py（已备份原配置）" : "Reference lmemory-agy.py in Antigravity Hooks config (original backed up)"
    }
    public static func deployCodexTrust(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "已写入配置；请在 Codex 中执行一次 /hooks 信任确认" : "Config written; run /hooks trust confirmation once in Codex"
    }
    public static func deployConnectedVault(_ lang: AppLanguage) -> String {
        lang == .zhHans ? "已接入并复用 Vault" : "Connected and reusing existing Vault"
    }
    public static func deploySkipped(_ reason: String, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "跳过（\(reason)），原配置已备份" : "Skipped (\(reason)); original config backed up"
    }
    public static func deployLaunchFailed(_ err: String, _ lang: AppLanguage) -> String {
        lang == .zhHans ? "启动部署脚本失败：\(err)" : "Failed to run deploy script: \(err)"
    }
    public static func healthTooltip(_ health: LmemoryHealth, _ lang: AppLanguage) -> String {
        if lang == .zhHans {
            return health.detail.isEmpty ? detectingHealth(lang) : health.detail
        }
        switch health.state {
        case .healthy: return "Lmemory synced normally (nightly maintenance succeeded)"
        case .failed: return "Lmemory nightly maintenance failed — click to view log"
        case .missing: return "Lmemory not installed or Vault not configured — click to deploy"
        case .unknown: return "Lmemory connected (no maintenance log yet)"
        }
    }
    public static func displayTaskName(_ raw: String, source: TaskSource, lang: AppLanguage) -> String {
        if lang == .en && source == .launchd && raw == "Lmemory 每日维护" {
            return "Lmemory Daily Maintenance"
        }
        return raw
    }
    public static func displayScheduleExpr(_ raw: String, source: TaskSource, lang: AppLanguage) -> String {
        if lang == .en && source == .launchd && raw.hasPrefix("每日 ") {
            return raw.replacingOccurrences(of: "每日 ", with: "Daily ")
        }
        return raw
    }
    public static func displayEventSummary(_ raw: String, status: RunStatus, lang: AppLanguage) -> String {
        guard lang == .en else { return raw }
        switch raw {
        case "执行完成": return "Run completed"
        case "执行失败": return "Run failed"
        case "Codex 定时任务已更新": return "Codex scheduled task updated"
        default:
            if raw.hasPrefix("失败：") {
                return "Failed: " + raw.dropFirst(3)
            }
            return raw
        }
    }

}

public extension NotifyLevel {
    func label(for lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.priority, .zhHans): return "重点"
        case (.priority, .en): return "Priority"
        case (.normal, .zhHans): return "普通"
        case (.normal, .en): return "Normal"
        case (.muted, .zhHans): return "静音"
        case (.muted, .en): return "Muted"
        }
    }
}

public extension WebhookKind {
    func label(for lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.feishu, .zhHans): return "飞书"
        case (.feishu, .en): return "Feishu / Lark"
        case (.wecom, .zhHans): return "企业微信"
        case (.wecom, .en): return "WeCom"
        case (.dingtalk, .zhHans): return "钉钉"
        case (.dingtalk, .en): return "DingTalk"
        case (.bark, _): return "Bark"
        case (.generic, .zhHans): return "通用 JSON"
        case (.generic, .en): return "Generic JSON"
        }
    }
}
