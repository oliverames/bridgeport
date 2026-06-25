import Foundation

public struct BridgeportConfig: Codable, Sendable {
    public var token: String?
    public var port: UInt16?
    public var connectorsPath: String?
    public var env: [String: String]?
    public var disabledConnectors: [String]?
    
    public init(token: String? = nil, port: UInt16? = nil, connectorsPath: String? = nil, env: [String: String]? = nil, disabledConnectors: [String]? = nil) {
        self.token = token
        self.port = port
        self.connectorsPath = connectorsPath
        self.env = env
        self.disabledConnectors = disabledConnectors
    }
}

public actor ConfigManager {
    private let configURL: URL
    
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configURL = home.appendingPathComponent(".config/bridgeport/config.json")
    }
    
    public func load() -> BridgeportConfig {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configURL.path) {
            // Create default config
            let defaultToken = Self.generateSecureToken()
            let defaultEnv = Self.loadDefaultEnvFromClaude()
            let config = BridgeportConfig(
                token: defaultToken,
                port: 8080,
                connectorsPath: "/Users/oliverames/Developer/Projects/ames-connectors/plugins",
                env: defaultEnv
            )
            save(config)
            return config
        }
        
        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            var config = try decoder.decode(BridgeportConfig.self, from: data)
            
            // Ensure token exists
            if config.token == nil || config.token?.isEmpty == true {
                config.token = Self.generateSecureToken()
                save(config)
            }
            
            // Pre-populate env if nil or empty
            if config.env == nil || config.env?.isEmpty == true {
                config.env = Self.loadDefaultEnvFromClaude()
                save(config)
            }
            
            return config
        } catch {
            logMessage("ConfigManager.load: Failed to decode config, generating default: \(error)")
            let defaultToken = Self.generateSecureToken()
            let defaultEnv = Self.loadDefaultEnvFromClaude()
            let config = BridgeportConfig(
                token: defaultToken,
                port: 8080,
                connectorsPath: "/Users/oliverames/Developer/Projects/ames-connectors/plugins",
                env: defaultEnv
            )
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
            encoder.outputFormatting = .prettyPrinted
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
    
    public func writeMcpClientConfig(port: UInt16, token: String, connectors: [Connector], disabledConnectors: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mcpConfigURL = home.appendingPathComponent(".config/bridgeport/mcp_config.json")
        
        var mcpServers: [String: [String: Any]] = [:]
        let disabledSet = Set(disabledConnectors)
        
        for connector in connectors {
            if !disabledSet.contains(connector.name) {
                mcpServers[connector.name] = [
                    "type": "sse",
                    "url": "http://localhost:\(port)/\(connector.name)/sse?token=\(token)"
                ]
            }
        }
        
        let clientConfig: [String: Any] = [
            "mcpServers": mcpServers
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: clientConfig, options: .prettyPrinted)
            try data.write(to: mcpConfigURL, options: .atomic)
            logMessage("ConfigManager: Wrote client MCP config to \(mcpConfigURL.path)")
        } catch {
            logMessage("ConfigManager: Failed to write client MCP config: \(error)")
        }
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
    
    public static func generateSecureToken() -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return "ames_" + String((0..<32).map { _ in letters.randomElement()! })
    }
}
