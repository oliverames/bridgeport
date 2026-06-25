import Foundation

public struct MCPServiceConfig: Codable, Sendable {
    public let command: String
    public let args: [String]?
    public let env: [String: String]?
}

public struct Connector: Sendable {
    public let name: String
    public let directoryPath: String
    public let command: String
    public let args: [String]
    public var env: [String: String]
}

public actor ConnectorManager {
    private let connectorsPath: String
    private var configOverrides: [String: String] = [:]
    
    public init(connectorsPath: String = "/Users/oliverames/Developer/Projects/ames-connectors/plugins") {
        self.connectorsPath = connectorsPath
        self.configOverrides = Self.loadConfigOverrides()
    }
    
    private static func loadConfigOverrides() -> [String: String] {
        // Load custom overrides from ~/.config/bridgeport/config.json
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".config/bridgeport/config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envOverrides = json["env"] as? [String: String] else {
            return [:]
        }
        return envOverrides
    }
    
    public func discoverConnectors() async -> [Connector] {
        var discovered: [Connector] = []
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: connectorsPath)
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            return []
        }
        
        while let folderURL = enumerator.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue {
                // Look for .mcp.json or .antigravity-plugin/mcp_config.json
                let mcpJsonURL = folderURL.appendingPathComponent(".mcp.json")
                let antigravityJsonURL = folderURL.appendingPathComponent(".antigravity-plugin/mcp_config.json")
                
                let targetURL: URL
                if fileManager.fileExists(atPath: mcpJsonURL.path) {
                    targetURL = mcpJsonURL
                } else if fileManager.fileExists(atPath: antigravityJsonURL.path) {
                    targetURL = antigravityJsonURL
                } else {
                    continue
                }
                
                do {
                    let data = try Data(contentsOf: targetURL)
                    // The JSON can either be { "mcpServers": { "name": { ... } } } or just { "name": { ... } }
                    if let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        var servers: [String: Any] = [:]
                        if let mcpServers = rawJson["mcpServers"] as? [String: Any] {
                            servers = mcpServers
                        } else {
                            servers = rawJson
                        }
                        
                        for (serverName, serverVal) in servers {
                            if let serverDict = serverVal as? [String: Any],
                               let command = serverDict["command"] as? String {
                                let args = (serverDict["args"] as? [String]) ?? []
                                var env = (serverDict["env"] as? [String: String]) ?? [:]
                                
                                // Expand path placeholder ${ANTIGRAVITY_PLUGIN_ROOT}
                                let absolutePluginPath = folderURL.path
                                for (key, value) in env {
                                    env[key] = value.replacingOccurrences(of: "${ANTIGRAVITY_PLUGIN_ROOT}", with: absolutePluginPath)
                                }
                                let finalCommand = command.replacingOccurrences(of: "${ANTIGRAVITY_PLUGIN_ROOT}", with: absolutePluginPath)
                                let finalArgs = args.map { $0.replacingOccurrences(of: "${ANTIGRAVITY_PLUGIN_ROOT}", with: absolutePluginPath) }
                                
                                discovered.append(Connector(
                                    name: serverName,
                                    directoryPath: folderURL.path,
                                    command: finalCommand,
                                    args: finalArgs,
                                    env: env
                                ))
                            }
                        }
                    }
                } catch {
                    print("Error reading MCP config at \(targetURL.path): \(error)")
                }
            }
        }
        
        return discovered
    }
    
    public func resolveEnvironment(for connector: Connector) async -> [String: String] {
        var resolvedEnv = ProcessInfo.processInfo.environment
        
        // Merge the connector's specified environment
        for (key, val) in connector.env {
            let expandedVal = await expandVariables(val)
            resolvedEnv[key] = expandedVal
        }
        
        return resolvedEnv
    }
    
    private func expandVariables(_ value: String) async -> String {
        var result = value
        let pattern = "\\$\\{([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        
        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, options: [], range: nsRange)
        
        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result) else { continue }
            let varName = String(result[varRange])
            
            let resolvedVal = await resolveVariable(varName)
            if let fullRange = Range(match.range(at: 0), in: result) {
                result.replaceSubrange(fullRange, with: resolvedVal)
            }
        }
        
        return result
    }
    
    private func resolveVariable(_ name: String) async -> String {
        // 1. Check config overrides first
        if let override = configOverrides[name] {
            return await resolveValueSource(override)
        }
        
        // 2. Check current process environment
        if let envVal = ProcessInfo.processInfo.environment[name] {
            return await resolveValueSource(envVal)
        }
        
        return ""
    }
    
    private func resolveValueSource(_ value: String) async -> String {
        if value.hasPrefix("op://") {
            return await read1PasswordSecret(reference: value)
        }
        return value
    }
    
    private func read1PasswordSecret(reference: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/op")
        if !FileManager.default.fileExists(atPath: process.executableURL?.path ?? "") {
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/op")
        }
        
        guard let execURL = process.executableURL, FileManager.default.fileExists(atPath: execURL.path) else {
            print("1Password CLI (op) not found")
            return ""
        }
        
        process.arguments = ["read", reference]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let secret = String(data: data, encoding: .utf8) {
                    return secret.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "unknown error"
                print("1Password CLI read failed: \(errStr)")
            }
        } catch {
            print("Failed to run 1Password CLI: \(error)")
        }
        
        return ""
    }
}
