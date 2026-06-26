import Foundation
import Security

public enum ConnectorSourceKind: String, Codable, Sendable {
    case imported
    case mirrored
}

public struct BridgeportImportedConnector: Codable, Sendable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var directoryPath: String
    public var configPath: String
    public var importedFrom: String

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        directoryPath: String,
        configPath: String,
        importedFrom: String
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.directoryPath = directoryPath
        self.configPath = configPath
        self.importedFrom = importedFrom
    }
}

public struct BridgeportConnectorSettings: Codable, Sendable {
    public var enabled: Bool
    public var exposePublicly: Bool
    public var publicPath: String?

    public init(enabled: Bool = true, exposePublicly: Bool = false, publicPath: String? = nil) {
        self.enabled = enabled
        self.exposePublicly = exposePublicly
        self.publicPath = publicPath
    }
}

public struct OnePasswordEnvironmentSettings: Codable, Sendable {
    public var enabled: Bool
    public var accountId: String
    public var environmentId: String
    public var environmentName: String
    public var localEnvFilePath: String

    public init(
        enabled: Bool = false,
        accountId: String = "",
        environmentId: String = "",
        environmentName: String = "",
        localEnvFilePath: String = ""
    ) {
        self.enabled = enabled
        self.accountId = accountId
        self.environmentId = environmentId
        self.environmentName = environmentName
        self.localEnvFilePath = localEnvFilePath
    }
}

public struct ClaudeCustomConnectorExport: Codable, Sendable {
    public let name: String
    public let remoteMCPServerURL: String
    public let readyForClaudeApp: Bool
    public let authentication: String
    public let note: String
}

public struct AnthropicMessagesAPIMCPServer: Codable, Sendable {
    public let type: String
    public let name: String
    public let url: String
    public let authorizationToken: String

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case url
        case authorizationToken = "authorization_token"
    }

    public init(name: String, url: String, authorizationToken: String) {
        self.type = "url"
        self.name = name
        self.url = url
        self.authorizationToken = authorizationToken
    }
}

public struct MistralCustomConnectorExport: Codable, Sendable {
    public let name: String
    public let serverURL: String
    public let description: String
    public let authenticationMethod: String
    public let authorizationHeader: String
}

public struct VibeCodeMCPServerExport: Codable, Sendable {
    public let name: String
    public let transport: String
    public let url: String
    public let headers: [String: String]
    public let toml: String
}

public struct CloudConnectorExport: Codable, Sendable {
    public let generatedAt: String
    public let publicBaseURL: String
    public let queryTokenFallbackEnabled: Bool
    public let claudeCustomConnectors: [ClaudeCustomConnectorExport]
    public let anthropicMessagesAPIMCPServers: [AnthropicMessagesAPIMCPServer]
    public let mistralCustomConnectors: [MistralCustomConnectorExport]
    public let vibeCodeMCPServers: [VibeCodeMCPServerExport]
    public let notes: [String]
}

public struct BridgeportConfig: Codable, Sendable {
    public var token: String?
    public var port: UInt16?
    public var publicBaseURL: String?
    public var bindHost: String?
    public var allowedOrigins: [String]?
    public var allowQueryTokenAuth: Bool?
    public var connectorsPath: String?
    public var additionalConnectorPaths: [String]?
    public var importedConnectors: [String: BridgeportImportedConnector]?
    public var connectorSettings: [String: BridgeportConnectorSettings]?
    public var onePasswordEnvironment: OnePasswordEnvironmentSettings?
    public var env: [String: String]?
    public var disabledConnectors: [String]?

    public init(
        token: String? = nil,
        port: UInt16? = nil,
        publicBaseURL: String? = nil,
        bindHost: String? = nil,
        allowedOrigins: [String]? = nil,
        allowQueryTokenAuth: Bool? = nil,
        connectorsPath: String? = nil,
        additionalConnectorPaths: [String]? = nil,
        importedConnectors: [String: BridgeportImportedConnector]? = nil,
        connectorSettings: [String: BridgeportConnectorSettings]? = nil,
        onePasswordEnvironment: OnePasswordEnvironmentSettings? = nil,
        env: [String: String]? = nil,
        disabledConnectors: [String]? = nil
    ) {
        self.token = token
        self.port = port
        self.publicBaseURL = publicBaseURL
        self.bindHost = bindHost
        self.allowedOrigins = allowedOrigins
        self.allowQueryTokenAuth = allowQueryTokenAuth
        self.connectorsPath = connectorsPath
        self.additionalConnectorPaths = additionalConnectorPaths
        self.importedConnectors = importedConnectors
        self.connectorSettings = connectorSettings
        self.onePasswordEnvironment = onePasswordEnvironment
        self.env = env
        self.disabledConnectors = disabledConnectors
    }

    public func settings(for connectorName: String) -> BridgeportConnectorSettings {
        if let setting = connectorSettings?[connectorName] {
            return setting
        }
        if disabledConnectors?.contains(connectorName) == true {
            return BridgeportConnectorSettings(enabled: false)
        }
        return BridgeportConnectorSettings()
    }

    public func enabledConnectorNames(from connectors: [Connector]) -> Set<String> {
        Set(connectors.filter { settings(for: $0.name).enabled }.map(\.name))
    }

    public func publicRoutePath(for connector: Connector) -> String {
        let configuredPath = settings(for: connector.name).publicPath ?? connector.name
        return ConfigManager.normalizedRoutePath(configuredPath)
    }
}

public enum BridgeportPaths {
    public static let configHomeEnvironmentKey = "BRIDGEPORT_CONFIG_HOME"

    public static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[configHomeEnvironmentKey], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/bridgeport")
    }

    public static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("config.json")
    }

    public static func clientConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("mcp_config.json")
    }

    public static func cloudConnectorConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("cloud_connectors.json")
    }

    public static func installedBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent("bin/bridgeport")
    }
}

public actor ConfigManager {
    private let configURL: URL
    private let clientConfigURL: URL
    private let cloudConnectorConfigURL: URL

    public init(
        configURL: URL = BridgeportPaths.configURL(),
        clientConfigURL: URL = BridgeportPaths.clientConfigURL(),
        cloudConnectorConfigURL: URL = BridgeportPaths.cloudConnectorConfigURL()
    ) {
        self.configURL = configURL
        self.clientConfigURL = clientConfigURL
        self.cloudConnectorConfigURL = cloudConnectorConfigURL
    }

    public func load() -> BridgeportConfig {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configURL.path) {
            let config = Self.defaultConfig()
            save(config)
            return config
        }

        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            var config = try decoder.decode(BridgeportConfig.self, from: data)
            var shouldSave = false

            if config.token == nil || config.token?.isEmpty == true {
                config.token = Self.generateSecureToken()
                shouldSave = true
            }

            if config.connectorsPath == nil || config.connectorsPath?.isEmpty == true {
                config.connectorsPath = Self.defaultPrimaryConnectorsPath()
                shouldSave = true
            }

            if config.publicBaseURL == nil {
                config.publicBaseURL = ""
                shouldSave = true
            }

            if config.bindHost == nil || config.bindHost?.isEmpty == true {
                config.bindHost = "127.0.0.1"
                shouldSave = true
            }

            if config.allowedOrigins == nil {
                config.allowedOrigins = Self.defaultAllowedOrigins(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)
                shouldSave = true
            }

            if config.allowQueryTokenAuth == nil {
                config.allowQueryTokenAuth = false
                shouldSave = true
            }

            if config.additionalConnectorPaths == nil {
                config.additionalConnectorPaths = Self.defaultAdditionalConnectorPaths(excluding: config.connectorsPath)
                shouldSave = true
            }

            if config.importedConnectors == nil {
                config.importedConnectors = [:]
                shouldSave = true
            }

            if config.connectorSettings == nil {
                config.connectorSettings = Self.settingsFromLegacyDisabled(config.disabledConnectors ?? [])
                shouldSave = true
            }

            if config.onePasswordEnvironment == nil {
                config.onePasswordEnvironment = OnePasswordEnvironmentSettings()
                shouldSave = true
            }

            if config.env == nil {
                config.env = Self.loadDefaultEnvFromClaude()
                shouldSave = true
            }

            if shouldSave {
                save(config)
            }

            return config
        } catch {
            logMessage("ConfigManager.load: Failed to decode config, generating default: \(error)")
            let config = Self.defaultConfig()
            save(config)
            return config
        }
    }

    public func save(_ config: BridgeportConfig) {
        let fileManager = FileManager.default
        let directoryURL = configURL.deletingLastPathComponent()

        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            logMessage("ConfigManager: Config saved successfully to \(configURL.path)")
        } catch {
            logMessage("ConfigManager.save: Failed to save config: \(error)")
        }
    }

    public func rotateToken() -> String {
        var config = load()
        let newToken = Self.generateSecureToken()
        config.token = newToken
        save(config)
        return newToken
    }

    public func writeMcpClientConfig(config: BridgeportConfig, connectors: [Connector]) {
        let token = config.token ?? ""
        let port = config.port ?? 8080
        var mcpServers: [String: [String: Any]] = [:]

        for connector in connectors {
            let setting = config.settings(for: connector.name)
            guard setting.enabled else { continue }

            let baseURL: String
            if setting.exposePublicly, config.publicBaseURL?.isEmpty == false {
                baseURL = Self.clientEndpointBaseURL(port: port, publicBaseURL: config.publicBaseURL)
            } else {
                baseURL = "http://localhost:\(port)"
            }

            let routePath = config.publicRoutePath(for: connector)
            mcpServers[connector.name] = [
                "type": "http",
                "url": Self.mcpEndpointURL(baseURL: baseURL, routePath: routePath),
                "headers": [
                    "Authorization": "Bearer \(token)"
                ]
            ]
        }

        let clientConfig: [String: Any] = [
            "mcpServers": mcpServers
        ]

        do {
            let directoryURL = clientConfigURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            let data = try JSONSerialization.data(withJSONObject: clientConfig, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: clientConfigURL, options: .atomic)
            logMessage("ConfigManager: Wrote client MCP config to \(clientConfigURL.path)")
        } catch {
            logMessage("ConfigManager: Failed to write client MCP config: \(error)")
        }
    }

    public func writeCloudConnectorConfig(config: BridgeportConfig, connectors: [Connector]) {
        let export = Self.cloudConnectorExport(config: config, connectors: connectors)

        do {
            let directoryURL = cloudConnectorConfigURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(export)
            try data.write(to: cloudConnectorConfigURL, options: .atomic)
            logMessage("ConfigManager: Wrote cloud connector export to \(cloudConnectorConfigURL.path)")
        } catch {
            logMessage("ConfigManager: Failed to write cloud connector export: \(error)")
        }
    }

    public static func cloudConnectorExport(config: BridgeportConfig, connectors: [Connector], generatedAt: Date = Date()) -> CloudConnectorExport {
        let publicConnectors = publicConnectors(config: config, connectors: connectors)
        let token = config.token ?? ""
        let queryTokenFallbackEnabled = config.allowQueryTokenAuth == true

        return CloudConnectorExport(
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            publicBaseURL: clientEndpointBaseURL(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL),
            queryTokenFallbackEnabled: queryTokenFallbackEnabled,
            claudeCustomConnectors: publicConnectors.map { connector in
                let baseURL = clientEndpointBaseURL(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)
                let routePath = config.publicRoutePath(for: connector)
                return ClaudeCustomConnectorExport(
                    name: connector.name,
                    remoteMCPServerURL: mcpEndpointURL(
                        baseURL: baseURL,
                        routePath: routePath,
                        queryToken: queryTokenFallbackEnabled ? token : nil
                    ),
                    readyForClaudeApp: queryTokenFallbackEnabled,
                    authentication: queryTokenFallbackEnabled ? "Query token in URL" : "Requires OAuth support or query-token fallback",
                    note: queryTokenFallbackEnabled
                        ? "Paste this URL into Claude's Add custom connector dialog."
                        : "Claude's app connector dialog has no static Authorization header field. Enable query-token fallback or add OAuth support before using this URL in Claude."
                )
            },
            anthropicMessagesAPIMCPServers: publicConnectors.map { connector in
                anthropicMessagesAPIServer(config: config, connector: connector)
            },
            mistralCustomConnectors: publicConnectors.map { connector in
                mistralCustomConnector(config: config, connector: connector)
            },
            vibeCodeMCPServers: publicConnectors.map { connector in
                vibeCodeMCPServer(config: config, connector: connector)
            },
            notes: [
                "Claude app custom connectors are reached from Anthropic's cloud and need a public URL.",
                "Anthropic Messages API MCP connector definitions can use authorization_token, so they do not need query-token fallback.",
                "Mistral Work custom connectors auto-detect Bearer authentication when Bridgeport returns WWW-Authenticate: Bearer.",
                "Vibe Code CLI supports streamable-http MCP servers with Authorization headers in config.toml."
            ]
        )
    }

    public static func publicConnectors(config: BridgeportConfig, connectors: [Connector]) -> [Connector] {
        guard config.publicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return []
        }

        return connectors.filter { connector in
            let settings = config.settings(for: connector.name)
            return settings.enabled && settings.exposePublicly
        }
    }

    public static func anthropicMessagesAPIServer(config: BridgeportConfig, connector: Connector) -> AnthropicMessagesAPIMCPServer {
        let baseURL = clientEndpointBaseURL(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)
        return AnthropicMessagesAPIMCPServer(
            name: connector.name,
            url: mcpEndpointURL(baseURL: baseURL, routePath: config.publicRoutePath(for: connector)),
            authorizationToken: config.token ?? ""
        )
    }

    public static func mistralCustomConnector(config: BridgeportConfig, connector: Connector) -> MistralCustomConnectorExport {
        let baseURL = clientEndpointBaseURL(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)
        return MistralCustomConnectorExport(
            name: connector.name,
            serverURL: mcpEndpointURL(baseURL: baseURL, routePath: config.publicRoutePath(for: connector)),
            description: "Bridgeport-hosted MCP connector for \(connector.name).",
            authenticationMethod: "HTTP Bearer Token",
            authorizationHeader: "Bearer \(config.token ?? "")"
        )
    }

    public static func vibeCodeMCPServer(config: BridgeportConfig, connector: Connector) -> VibeCodeMCPServerExport {
        let baseURL = clientEndpointBaseURL(port: config.port ?? 8080, publicBaseURL: config.publicBaseURL)
        let url = mcpEndpointURL(baseURL: baseURL, routePath: config.publicRoutePath(for: connector))
        let token = config.token ?? ""
        return VibeCodeMCPServerExport(
            name: connector.name,
            transport: "streamable-http",
            url: url,
            headers: ["Authorization": "Bearer \(token)"],
            toml: vibeCodeTOML(name: connector.name, url: url, token: token)
        )
    }

    public static func vibeCodeTOML(name: String, url: String, token: String) -> String {
        """
        [[mcp_servers]]
        name = "\(tomlEscaped(name))"
        transport = "streamable-http"
        url = "\(tomlEscaped(url))"
        headers = { "Authorization" = "Bearer \(tomlEscaped(token))" }
        """
    }

    public static func encodedJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public static func defaultConfig() -> BridgeportConfig {
        let primaryConnectorsPath = defaultPrimaryConnectorsPath()
        return BridgeportConfig(
            token: generateSecureToken(),
            port: 8080,
            publicBaseURL: "",
            bindHost: "127.0.0.1",
            allowedOrigins: defaultAllowedOrigins(port: 8080, publicBaseURL: ""),
            allowQueryTokenAuth: false,
            connectorsPath: primaryConnectorsPath,
            additionalConnectorPaths: defaultAdditionalConnectorPaths(excluding: primaryConnectorsPath),
            importedConnectors: [:],
            connectorSettings: [:],
            onePasswordEnvironment: OnePasswordEnvironmentSettings(),
            env: loadDefaultEnvFromClaude(),
            disabledConnectors: []
        )
    }

    public static func clientEndpointBaseURL(port: UInt16, publicBaseURL: String?) -> String {
        var trimmed = (publicBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "http://localhost:\(port)"
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    public static func mcpEndpointURL(baseURL: String, routePath: String) -> String {
        "\(baseURL)/mcp/\(normalizedRoutePath(routePath))"
    }

    public static func mcpEndpointURL(baseURL: String, routePath: String, queryToken: String?) -> String {
        let endpoint = mcpEndpointURL(baseURL: baseURL, routePath: routePath)
        guard let queryToken, !queryToken.isEmpty else { return endpoint }
        guard var components = URLComponents(string: endpoint) else { return endpoint }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: queryToken))
        components.queryItems = queryItems
        return components.url?.absoluteString ?? "\(endpoint)?token=\(queryToken)"
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func normalizedRoutePath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "mcp" : path
    }

    public static func defaultAllowedOrigins(port: UInt16, publicBaseURL: String?) -> [String] {
        var origins = [
            "http://localhost:\(port)",
            "http://127.0.0.1:\(port)",
            "http://[::1]:\(port)"
        ]

        if let publicBaseURL,
           let url = URL(string: publicBaseURL),
           let scheme = url.scheme,
           let host = url.host {
            var origin = "\(scheme)://\(host)"
            if let port = url.port {
                origin += ":\(port)"
            }
            origins.append(origin)
        }

        return Array(Set(origins)).sorted()
    }

    public static func settingsFromLegacyDisabled(_ disabledConnectors: [String]) -> [String: BridgeportConnectorSettings] {
        var settings: [String: BridgeportConnectorSettings] = [:]
        for connector in disabledConnectors {
            settings[connector] = BridgeportConnectorSettings(enabled: false)
        }
        return settings
    }

    public static func defaultPrimaryConnectorsPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent("Developer/Projects")
        let candidates = [
            projects.appendingPathComponent("ames-plugins/plugins"),
            projects.appendingPathComponent("ames-connectors/plugins")
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
        return candidates[0].path
    }

    public static func defaultAdditionalConnectorPaths(excluding primaryPath: String? = nil) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent("Developer/Projects")
        let primary = primaryPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path }
        let candidates = [
            projects.appendingPathComponent("ames-plugins/plugins"),
            projects.appendingPathComponent("ames-connectors/plugins"),
            projects.appendingPathComponent("ynab-mcp-server"),
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".claude/plugins/cache/apple-notes-mcp/apple-notes/2.5.3"),
            home.appendingPathComponent(".claude/plugins/cache/apple-notes-mcp-ames/apple-notes/1.4.3")
        ]

        var paths: [String] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: standardized) else { continue }
            guard standardized != primary else { continue }
            guard !seen.contains(standardized) else { continue }
            seen.insert(standardized)
            paths.append(standardized)
        }
        return paths
    }

    public static func generateSecureToken() -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var token = "ames_"
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status == errSecSuccess {
            for byte in randomBytes {
                let index = Int(byte) % letters.count
                token.append(letters[letters.index(letters.startIndex, offsetBy: index)])
            }
            return token
        }
        return token + String((0..<32).map { _ in letters.randomElement()! })
    }

    private static func loadDefaultEnvFromClaude() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeSettingsURL = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: String] else {
            return [:]
        }

        var filtered: [String: String] = [:]
        for (key, val) in env {
            if key.contains("TOKEN") || key.contains("KEY") || key.contains("SECRET") || key.contains("ID") || key.contains("PATH") {
                filtered[key] = val
            }
        }
        return filtered
    }
}
