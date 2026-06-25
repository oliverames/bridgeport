import Foundation

public struct BridgeportConfig: Codable, Sendable {
    public var token: String?
    public var port: UInt16?
    public var connectorsPath: String?
    public var env: [String: String]?
    
    public init(token: String? = nil, port: UInt16? = nil, connectorsPath: String? = nil, env: [String: String]? = nil) {
        self.token = token
        self.port = port
        self.connectorsPath = connectorsPath
        self.env = env
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
            let config = BridgeportConfig(
                token: defaultToken,
                port: 8080,
                connectorsPath: "/Users/oliverames/Developer/Projects/ames-connectors/plugins",
                env: [:]
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
            return config
        } catch {
            logMessage("ConfigManager.load: Failed to decode config, generating default: \(error)")
            let defaultToken = Self.generateSecureToken()
            let config = BridgeportConfig(
                token: defaultToken,
                port: 8080,
                connectorsPath: "/Users/oliverames/Developer/Projects/ames-connectors/plugins",
                env: [:]
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
    
    public static func generateSecureToken() -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return "ames_" + String((0..<32).map { _ in letters.randomElement()! })
    }
}
