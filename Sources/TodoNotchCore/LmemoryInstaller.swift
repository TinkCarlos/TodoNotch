import Foundation

public struct AgentDetection: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String       // antigravity / codex / cursor / claude-code
    public let displayName: String
    public let installed: Bool
    public let configPath: String
    public let lmemoryConnected: Bool
    public var selected: Bool
}

public struct DeployAgentResult: Identifiable, Equatable, Sendable {
    public var id: String { agent }
    public let agent: String
    public let status: String // ok / manual_needed / failed
    public let message: String
}

public struct LmemoryEnvironment: Sendable {
    public let lmemoryBinary: String?
    public let bootstrapScript: String?
    public let existingVault: String?
    public let agents: [AgentDetection]
}

public final class LmemoryInstallerService: @unchecked Sendable {
    private let homeDir: URL
    private let store: SQLiteStore?

    public init(homeDir: URL = FileManager.default.homeDirectoryForCurrentUser, store: SQLiteStore? = nil) {
        self.homeDir = homeDir
        self.store = store
    }

    public func detectEnvironment(configuredVault: String = "") -> LmemoryEnvironment {
        let fm = FileManager.default
        let lmemCandidates = [
            homeDir.appendingPathComponent(".local/bin/lmemory").path,
            "/opt/homebrew/bin/lmemory",
            "/usr/local/bin/lmemory"
        ]
        let lmemBin = lmemCandidates.first(where: { fm.isExecutableFile(atPath: $0) })

        let bootCandidates = [
            homeDir.appendingPathComponent("projects/Lmemory/scripts/bootstrap.py").path,
            homeDir.appendingPathComponent(".local/share/lmemory/scripts/bootstrap.py").path
        ]
        let bootScript = bootCandidates.first(where: { fm.fileExists(atPath: $0) })

        let discovery = TaskDiscoveryService(homeDir: homeDir)
        let vault = discovery.resolveVaultPath(configuredVault: configuredVault)

        let agyCfg = homeDir.appendingPathComponent(".gemini/config/hooks.json").path
        let codexCfg = homeDir.appendingPathComponent(".codex/config.toml").path
        let cursorCfg = homeDir.appendingPathComponent(".cursor/mcp.json").path
        let claudeCfg = homeDir.appendingPathComponent(".claude.json").path

        let agents: [AgentDetection] = [
            AgentDetection(
                name: "antigravity", displayName: "Antigravity",
                installed: fm.fileExists(atPath: homeDir.appendingPathComponent(".gemini").path),
                configPath: agyCfg,
                lmemoryConnected: fileContains(agyCfg, needle: "lmemory"),
                selected: true
            ),
            AgentDetection(
                name: "codex", displayName: "Codex",
                installed: fm.fileExists(atPath: homeDir.appendingPathComponent(".codex").path),
                configPath: codexCfg,
                lmemoryConnected: fileContains(codexCfg, needle: "lmemory"),
                selected: true
            ),
            AgentDetection(
                name: "cursor", displayName: "Cursor",
                installed: fm.fileExists(atPath: homeDir.appendingPathComponent(".cursor").path),
                configPath: cursorCfg,
                lmemoryConnected: fileContains(cursorCfg, needle: "lmemory"),
                selected: true
            ),
            AgentDetection(
                name: "claude-code", displayName: "Claude Code",
                installed: fm.fileExists(atPath: homeDir.appendingPathComponent(".claude").path) || fm.fileExists(atPath: claudeCfg),
                configPath: claudeCfg,
                lmemoryConnected: fileContains(claudeCfg, needle: "lmemory"),
                selected: true
            )
        ]
        return LmemoryEnvironment(
            lmemoryBinary: lmemBin,
            bootstrapScript: bootScript,
            existingVault: vault.isEmpty ? nil : vault,
            agents: agents
        )
    }

    public func backupConfigs(for agents: [AgentDetection]) -> String {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let backupDir = homeDir
            .appendingPathComponent("Library/Application Support/TodoNotch/backups")
            .appendingPathComponent(fmt.string(from: Date()))
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var count = 0
        for ag in agents where ag.selected && ag.installed && fm.fileExists(atPath: ag.configPath) {
            let dst = backupDir.appendingPathComponent("\(ag.name)-\((ag.configPath as NSString).lastPathComponent)")
            if (try? fm.copyItem(atPath: ag.configPath, toPath: dst.path)) != nil {
                count += 1
            }
        }
        store?.appendAudit(action: "config_backup", target: "agents", result: "ok", detail: "已备份 \(count) 份配置至 \(backupDir.lastPathComponent)")
        return backupDir.path
    }

    public func deploy(env: LmemoryEnvironment, vaultPath: String, lang: AppLanguage = .zhHans) -> [DeployAgentResult] {
        let selected = env.agents.filter { $0.installed && $0.selected }
        _ = backupConfigs(for: selected)

        var results: [DeployAgentResult] = []
        let targetVault = vaultPath.isEmpty ? (env.existingVault ?? homeDir.appendingPathComponent("Documents/LmemoryVault").path) : vaultPath

        // Already connected agents are preserved idempotently
        var needBootstrap: [String] = []
        for ag in selected {
            if ag.lmemoryConnected {
                results.append(DeployAgentResult(agent: ag.displayName, status: "ok", message: L10n.deployConnectedIdempotent(lang)))
            } else {
                needBootstrap.append(ag.name)
            }
        }

        guard !needBootstrap.isEmpty else {
            store?.appendAudit(action: "lmemory_deploy", target: "all", result: "ok", detail: "all connected, idempotent skip")
            return results
        }

        guard let boot = env.bootstrapScript else {
            for ag in needBootstrap {
                results.append(DeployAgentResult(
                    agent: ag, status: "manual_needed",
                    message: L10n.deployMissingBootstrap(lang)
                ))
            }
            store?.appendAudit(action: "lmemory_deploy", target: needBootstrap.joined(separator: ","), result: "partial", detail: "missing bootstrap.py")
            return results
        }

        // Run bootstrap.py safely per-agent so one failure never blocks others
        for ag in needBootstrap {
            if ag == "antigravity" {
                results.append(DeployAgentResult(
                    agent: "Antigravity", status: "manual_needed",
                    message: L10n.deployAgyManual(lang)
                ))
                continue
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [boot, "--vault", targetVault, "--no-open", "--no-timer", "--apps", ag]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    if ag == "codex" {
                        results.append(DeployAgentResult(agent: "Codex", status: "manual_needed", message: L10n.deployCodexTrust(lang)))
                    } else {
                        results.append(DeployAgentResult(agent: ag, status: "ok", message: L10n.deployConnectedVault(lang)))
                    }
                } else {
                    let brief = out.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) ?? "exit \(proc.terminationStatus)"
                    results.append(DeployAgentResult(agent: ag, status: "failed", message: L10n.deploySkipped(String(brief.prefix(80)), lang)))
                }
            } catch {
                results.append(DeployAgentResult(agent: ag, status: "failed", message: L10n.deployLaunchFailed(error.localizedDescription, lang)))
            }
        }
        store?.appendAudit(action: "lmemory_deploy", target: needBootstrap.joined(separator: ","), result: "ok", detail: "completed \(results.count) agent checks")
        return results
    }

    private func fileContains(_ path: String, needle: String) -> Bool {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return txt.localizedCaseInsensitiveContains(needle)
    }
}
