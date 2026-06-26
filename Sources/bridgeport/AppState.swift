import Foundation
import Observation

#if os(macOS)
import Darwin
#endif

@Observable
@MainActor
public final class AppState {
    public var port: String = "8080"
    public var bindHost: String = "127.0.0.1"
    public var connectorsPath: String = ""
    public var additionalConnectorPathsText: String = ""
    public var publicBaseURL: String = ""
    public var allowedOriginsText: String = ""
    public var allowQueryTokenAuth: Bool = false
    public var token: String = ""
    public var env: [String: String] = [:]
    public var onePasswordEnvironment = OnePasswordEnvironmentSettings()
    public var importedConnectors: [String: BridgeportImportedConnector] = [:]
    public var connectorSettings: [String: BridgeportConnectorSettings] = [:]
    public var discoveredConnectors: [Connector] = []

    public var isDaemonInstalled: Bool = false
    public var isDaemonRunning: Bool = false
    public var isShowingToken: Bool = false
    public var activeSessionCount: Int = 0
    public var activeSessionsByConnector: [String: Int] = [:]
    public var lastStatusMessage: String = "Not checked"

    public var enabledConnectorCount: Int {
        discoveredConnectors.filter { connectorSettings(for: $0.name).enabled }.count
    }

    public var publicConnectorCount: Int {
        discoveredConnectors.filter { connectorSettings(for: $0.name).enabled && connectorSettings(for: $0.name).exposePublicly }.count
    }

    public var publicCloudConnectors: [Connector] {
        ConfigManager.publicConnectors(config: currentConfig(), connectors: discoveredConnectors)
    }

    public var localBaseURL: String {
        "http://localhost:\(port)"
    }

    public var clientBaseURL: String {
        ConfigManager.clientEndpointBaseURL(port: UInt16(port) ?? 8080, publicBaseURL: publicBaseURL)
    }

    private let configManager = ConfigManager()

    #if os(macOS)
    private let uid = getuid()
    #else
    private let uid: UInt32 = 0
    #endif

    private let label = "com.oliverames.bridgeport"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private var destURL: URL {
        BridgeportPaths.installedBinaryURL()
    }

    public init() {
        Task {
            await reload()
        }
    }

    public func reload() async {
        let config = await configManager.load()
        apply(config)

        let connectorManager = ConnectorManager(config: config)
        discoveredConnectors = await connectorManager.discoverConnectors()
        normalizeConnectorSettings()

        await configManager.writeMcpClientConfig(config: currentConfig(), connectors: discoveredConnectors)
        await configManager.writeCloudConnectorConfig(config: currentConfig(), connectors: discoveredConnectors)
        checkDaemonStatus()
        await refreshDaemonRuntimeStatus()
    }

    public func save(restartDaemon: Bool = true) async {
        let config = currentConfig()
        await configManager.save(config)
        await configManager.writeMcpClientConfig(config: config, connectors: discoveredConnectors)
        await configManager.writeCloudConnectorConfig(config: config, connectors: discoveredConnectors)

        if restartDaemon && isDaemonRunning {
            await self.restartDaemon()
        }
    }

    public func toggleConnector(_ name: String) async {
        var settings = connectorSettings(for: name)
        settings.enabled.toggle()
        connectorSettings[name] = settings
        await save()
        await reload()
    }

    public func togglePublicExposure(_ name: String) async {
        var settings = connectorSettings(for: name)
        settings.exposePublicly.toggle()
        connectorSettings[name] = settings
        await save()
        await reload()
    }

    public func setPublicPath(_ path: String, for name: String) async {
        var settings = connectorSettings(for: name)
        settings.publicPath = ConfigManager.normalizedRoutePath(path)
        connectorSettings[name] = settings
        await save()
    }

    public func rotateToken() async {
        let newToken = await configManager.rotateToken()
        token = newToken
        if isDaemonRunning {
            await restartDaemon()
        }
        await reload()
    }

    public func importMCPs(from path: String) async -> Int {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let manager = ConnectorManager(config: currentConfig())
        let connectors = await manager.discoverConnectors(at: [trimmed])
        var importedCount = 0

        for connector in connectors {
            importedConnectors[connector.name] = BridgeportImportedConnector(
                command: connector.command,
                args: connector.args,
                env: connector.env,
                directoryPath: connector.directoryPath,
                configPath: connector.configPath,
                importedFrom: connector.importedFrom
            )
            if connectorSettings[connector.name] == nil {
                connectorSettings[connector.name] = BridgeportConnectorSettings()
            }
            importedCount += 1
        }

        await save()
        await reload()
        return importedCount
    }

    public func mirrorMCPs(from path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var paths = additionalConnectorPaths
        let standardized = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL.path
        if !paths.contains(standardized) {
            paths.append(standardized)
            additionalConnectorPathsText = paths.joined(separator: "\n")
        }
        await save()
        await reload()
    }

    public func removeMirroredPath(_ path: String) async {
        additionalConnectorPathsText = additionalConnectorPaths
            .filter { $0 != path }
            .joined(separator: "\n")
        await save()
        await reload()
    }

    public func removeImportedConnector(_ name: String) async {
        importedConnectors.removeValue(forKey: name)
        await save()
        await reload()
    }

    public func refreshDaemonRuntimeStatus() async {
        guard let portUInt = UInt16(port),
              !token.isEmpty,
              let url = URL(string: "http://localhost:\(portUInt)/status") else {
            lastStatusMessage = "Status unavailable"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                activeSessionCount = 0
                activeSessionsByConnector = [:]
                lastStatusMessage = "Daemon not responding"
                return
            }

            let status = try JSONDecoder().decode(RuntimeStatus.self, from: data)
            activeSessionCount = status.activeSessions
            activeSessionsByConnector = status.sessionsByConnector
            lastStatusMessage = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            activeSessionCount = 0
            activeSessionsByConnector = [:]
            lastStatusMessage = "Daemon not responding"
        }
    }

    public func checkDaemonStatus() {
        let fileManager = FileManager.default
        let plistExists = fileManager.fileExists(atPath: plistURL.path)
        let binExists = fileManager.fileExists(atPath: destURL.path)

        isDaemonInstalled = plistExists && binExists

        let result = runShell("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
        isDaemonRunning = (result.status == 0)
    }

    public func installDaemon() async {
        let fileManager = FileManager.default
        let configDirectory = BridgeportPaths.configDirectory()
        let binDir = configDirectory.appendingPathComponent("bin")
        let launchAgentsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")

        if isDaemonRunning {
            _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        }

        do {
            if !fileManager.fileExists(atPath: binDir.path) {
                try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
            }

            guard let currentExecURL = Bundle.main.executableURL else {
                logMessage("AppState.installDaemon: Failed to find Bundle.main.executableURL")
                return
            }

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }

            try fileManager.copyItem(at: currentExecURL, to: destURL)
            logMessage("AppState: Copied binary to \(destURL.path)")
        } catch {
            logMessage("AppState: Failed to copy binary: \(error)")
            return
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(destURL.path)</string>
                <string>--server</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(configDirectory.path)/stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(configDirectory.path)/stderr.log</string>
        </dict>
        </plist>
        """

        do {
            if !fileManager.fileExists(atPath: launchAgentsURL.path) {
                try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
            }
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            logMessage("AppState: Failed to write plist: \(error)")
            return
        }

        let result = runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if result.status != 0 {
            logMessage("AppState: Failed to start daemon launchctl exit code \(result.status): \(result.stderr)")
        }

        checkDaemonStatus()
        await refreshDaemonRuntimeStatus()
    }

    public func uninstallDaemon() async {
        let fileManager = FileManager.default

        if isDaemonRunning {
            let result = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
            if result.status != 0 {
                _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)", plistURL.path])
            }
        }

        if fileManager.fileExists(atPath: plistURL.path) {
            try? fileManager.removeItem(at: plistURL)
        }

        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }

        checkDaemonStatus()
        await refreshDaemonRuntimeStatus()
    }

    public func restartDaemon() async {
        if isDaemonRunning {
            _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        }

        let result = runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if result.status != 0 {
            logMessage("AppState: Failed to restart daemon: \(result.stderr)")
        }

        checkDaemonStatus()
        await refreshDaemonRuntimeStatus()
    }

    public func connectorSettings(for name: String) -> BridgeportConnectorSettings {
        connectorSettings[name] ?? BridgeportConnectorSettings()
    }

    public func activeSessions(for connector: Connector) -> Int {
        activeSessionsByConnector[connector.name] ?? 0
    }

    public func endpointURL(for connector: Connector, publicEndpoint: Bool) -> String {
        let config = currentConfig()
        let portUInt = config.port ?? 8080
        let baseURL = publicEndpoint
            ? ConfigManager.clientEndpointBaseURL(port: portUInt, publicBaseURL: config.publicBaseURL)
            : "http://localhost:\(portUInt)"
        return ConfigManager.mcpEndpointURL(baseURL: baseURL, routePath: config.publicRoutePath(for: connector))
    }

    public func claudeCustomConnectorURL(for connector: Connector) -> String? {
        let config = currentConfig()
        guard ConfigManager.publicConnectors(config: config, connectors: [connector]).isEmpty == false else { return nil }
        guard config.allowQueryTokenAuth == true else { return nil }
        let baseURL = ConfigManager.clientEndpointBaseURL(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)
        return ConfigManager.mcpEndpointURL(baseURL: baseURL, routePath: config.publicRoutePath(for: connector), queryToken: config.token)
    }

    public func anthropicMessagesAPIJSON(for connector: Connector) -> String {
        ConfigManager.encodedJSONString(ConfigManager.anthropicMessagesAPIServer(config: currentConfig(), connector: connector))
    }

    public func mistralCustomConnectorJSON(for connector: Connector) -> String {
        ConfigManager.encodedJSONString(ConfigManager.mistralCustomConnector(config: currentConfig(), connector: connector))
    }

    public func vibeCodeTOML(for connector: Connector) -> String {
        ConfigManager.vibeCodeMCPServer(config: currentConfig(), connector: connector).toml
    }

    public func cloudConnectorExportJSON() -> String {
        ConfigManager.encodedJSONString(ConfigManager.cloudConnectorExport(config: currentConfig(), connectors: discoveredConnectors))
    }

    public func allVibeCodeTOML() -> String {
        publicCloudConnectors
            .map { vibeCodeTOML(for: $0) }
            .joined(separator: "\n\n")
    }

    public func currentConfig() -> BridgeportConfig {
        let portUInt = UInt16(port) ?? 8080
        return BridgeportConfig(
            token: token,
            port: portUInt,
            publicBaseURL: publicBaseURL,
            bindHost: bindHost,
            allowedOrigins: allowedOrigins,
            allowQueryTokenAuth: allowQueryTokenAuth,
            connectorsPath: connectorsPath,
            additionalConnectorPaths: additionalConnectorPaths,
            importedConnectors: importedConnectors,
            connectorSettings: connectorSettings,
            onePasswordEnvironment: onePasswordEnvironment,
            env: env,
            disabledConnectors: connectorSettings.filter { !$0.value.enabled }.map(\.key).sorted()
        )
    }

    private func apply(_ config: BridgeportConfig) {
        port = String(config.port ?? 8080)
        bindHost = config.bindHost ?? "127.0.0.1"
        connectorsPath = config.connectorsPath ?? ConfigManager.defaultPrimaryConnectorsPath()
        additionalConnectorPathsText = (config.additionalConnectorPaths ?? []).joined(separator: "\n")
        publicBaseURL = config.publicBaseURL ?? ""
        allowedOriginsText = (config.allowedOrigins ?? ConfigManager.defaultAllowedOrigins(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)).joined(separator: "\n")
        allowQueryTokenAuth = config.allowQueryTokenAuth ?? false
        token = config.token ?? ""
        env = config.env ?? [:]
        importedConnectors = config.importedConnectors ?? [:]
        connectorSettings = config.connectorSettings ?? ConfigManager.settingsFromLegacyDisabled(config.disabledConnectors ?? [])
        onePasswordEnvironment = config.onePasswordEnvironment ?? OnePasswordEnvironmentSettings()
    }

    private func normalizeConnectorSettings() {
        for connector in discoveredConnectors where connectorSettings[connector.name] == nil {
            connectorSettings[connector.name] = BridgeportConnectorSettings()
        }
    }

    private var additionalConnectorPaths: [String] {
        additionalConnectorPathsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var allowedOrigins: [String] {
        allowedOriginsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
