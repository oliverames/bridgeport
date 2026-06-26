import Foundation

public struct MCPServiceConfig: Codable, Sendable {
    public let command: String
    public let args: [String]?
    public let env: [String: String]?
    public let url: String?

    public init(command: String, args: [String]? = nil, env: [String: String]? = nil, url: String? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
    }
}

public struct Connector: Sendable {
    public let name: String
    public let directoryPath: String
    public let configPath: String
    public let command: String
    public let args: [String]
    public var env: [String: String]
    public let importedFrom: String
    public let sourceKind: ConnectorSourceKind

    public var requiredEnvVarNames: [String] {
        var names: [String] = []
        let searchableValues = Array(env.values) + [command] + args
        let pattern = "\\$\\{([^}:]+)(?::-([^}]*))?\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ignoredNames = Self.pluginRootNames.union(["CLAUDE_PROJECT_DIR"])

        for val in searchableValues {
            let nsRange = NSRange(val.startIndex..<val.endIndex, in: val)
            let matches = regex.matches(in: val, options: [], range: nsRange)
            for match in matches {
                if match.range(at: 2).location != NSNotFound {
                    continue
                }
                if let varRange = Range(match.range(at: 1), in: val) {
                    let varName = String(val[varRange])
                    if !ignoredNames.contains(varName) {
                        names.append(varName)
                    }
                }
            }
        }
        return Array(Set(names)).sorted()
    }

    public static let pluginRootNames: Set<String> = [
        "ANTIGRAVITY_PLUGIN_ROOT",
        "CLAUDE_PLUGIN_ROOT",
        "CODEX_PLUGIN_ROOT",
        "HERMES_PLUGIN_ROOT",
        "MCP_PLUGIN_ROOT",
        "PLUGIN_ROOT"
    ]
}

public actor ConnectorManager {
    private let config: BridgeportConfig
    private let connectorPaths: [String]
    private let configOverrides: [String: String]
    private let processEnvironment: [String: String]

    public init(config: BridgeportConfig, processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.config = config
        self.connectorPaths = Self.normalizedUniquePaths([config.connectorsPath ?? ConfigManager.defaultPrimaryConnectorsPath()] + (config.additionalConnectorPaths ?? []))
        self.configOverrides = config.env ?? [:]
        self.processEnvironment = processEnvironment
    }

    public init(connectorsPath: String = ConfigManager.defaultPrimaryConnectorsPath(), additionalConnectorPaths: [String] = []) {
        let config = BridgeportConfig(connectorsPath: connectorsPath, additionalConnectorPaths: additionalConnectorPaths, env: [:])
        self.config = config
        self.connectorPaths = Self.normalizedUniquePaths([connectorsPath] + additionalConnectorPaths)
        self.configOverrides = [:]
        self.processEnvironment = ProcessInfo.processInfo.environment
    }

    public init(connectorPaths: [String]) {
        self.config = BridgeportConfig(additionalConnectorPaths: connectorPaths, env: [:])
        self.connectorPaths = Self.normalizedUniquePaths(connectorPaths)
        self.configOverrides = [:]
        self.processEnvironment = ProcessInfo.processInfo.environment
    }

    public static func normalizedUniquePaths(_ paths: [String]) -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = NSString(string: trimmed).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard !seen.contains(standardized) else { continue }
            seen.insert(standardized)
            normalized.append(standardized)
        }
        return normalized
    }

    public func discoverConnectors() async -> [Connector] {
        await discoverConnectors(includeImported: true)
    }

    public func discoverConnectors(at paths: [String]) async -> [Connector] {
        await discoverConnectors(paths: Self.normalizedUniquePaths(paths), includeImported: false)
    }

    private func discoverConnectors(includeImported: Bool) async -> [Connector] {
        await discoverConnectors(paths: connectorPaths, includeImported: includeImported)
    }

    private func discoverConnectors(paths: [String], includeImported: Bool) async -> [Connector] {
        var discovered: [Connector] = []
        var seenNames: Set<String> = []
        let fileManager = FileManager.default

        if includeImported {
            for (name, imported) in (config.importedConnectors ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard !seenNames.contains(name) else { continue }
                let command = imported.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, Self.isLocalCommand(command) else {
                    logMessage("ConnectorManager: Skipping imported MCP '\(name)' with non-local command")
                    continue
                }
                seenNames.insert(name)
                discovered.append(Connector(
                    name: name,
                    directoryPath: imported.directoryPath,
                    configPath: imported.configPath,
                    command: command,
                    args: imported.args,
                    env: imported.env,
                    importedFrom: imported.importedFrom,
                    sourceKind: .imported
                ))
            }
        }

        for path in paths {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
                logMessage("ConnectorManager: Skipping missing connector source \(path)")
                continue
            }

            let url = URL(fileURLWithPath: path)
            if isClaudeSettingsFile(url) {
                discoverConnectors(inClaudeSettingsFile: url, discovered: &discovered, seenNames: &seenNames)
            } else if isCodexConfigFile(url) {
                discoverConnectors(inCodexConfigFile: url, discovered: &discovered, seenNames: &seenNames)
            } else if isDir.boolValue {
                discoverConnectors(inDirectory: url, discovered: &discovered, seenNames: &seenNames)
            } else {
                discoverConnectors(inConfigFile: url, pluginDirectory: inferredPluginDirectory(for: url), discovered: &discovered, seenNames: &seenNames)
            }
        }

        return discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func discoverConnectors(inDirectory rootURL: URL, discovered: inout [Connector], seenNames: inout Set<String>) {
        let configRelativePaths = [
            ".mcp.json",
            ".antigravity-plugin/mcp_config.json",
            ".claude-plugin/plugin.json",
            ".codex-plugin/plugin.json",
            ".hermes-plugin/plugin.json"
        ]

        for directoryURL in candidatePluginDirectories(from: rootURL) {
            for relativePath in configRelativePaths {
                let configURL = directoryURL.appendingPathComponent(relativePath)
                guard FileManager.default.fileExists(atPath: configURL.path) else { continue }
                discoverConnectors(inConfigFile: configURL, pluginDirectory: directoryURL, discovered: &discovered, seenNames: &seenNames)
            }
        }
    }

    private func candidatePluginDirectories(from rootURL: URL) -> [URL] {
        var directories: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL.path
            guard !seen.contains(standardized) else { return }
            seen.insert(standardized)
            directories.append(URL(fileURLWithPath: standardized))
        }

        func appendImmediateChildren(of url: URL) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for childURL in contents {
                let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    append(childURL)
                }
            }
        }

        append(rootURL)
        appendImmediateChildren(of: rootURL)

        let nestedPluginsURL = rootURL.appendingPathComponent("plugins")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: nestedPluginsURL.path, isDirectory: &isDir), isDir.boolValue {
            append(nestedPluginsURL)
            appendImmediateChildren(of: nestedPluginsURL)
        }

        return directories
    }

    private func discoverConnectors(inConfigFile configURL: URL, pluginDirectory: URL, discovered: inout [Connector], seenNames: inout Set<String>) {
        do {
            let data = try Data(contentsOf: configURL)
            guard let rawJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let relativeConfigPath = rawJson["mcpServers"] as? String {
                let nestedConfigURL = resolvePluginRelativePath(relativeConfigPath, pluginDirectory: pluginDirectory, configURL: configURL)
                discoverConnectors(inConfigFile: nestedConfigURL, pluginDirectory: pluginDirectory, discovered: &discovered, seenNames: &seenNames)
                return
            }

            let servers = serverConfigurations(from: rawJson)

            for (serverName, serverDict) in servers {
                if serverDict["url"] != nil && serverDict["command"] == nil {
                    logMessage("ConnectorManager: Skipping web-hosted MCP '\(serverName)' (has URL, no command)")
                    continue
                }

                guard let rawCommand = serverDict["command"] as? String else { continue }
                let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, Self.isLocalCommand(command) else {
                    logMessage("ConnectorManager: Skipping MCP '\(serverName)' with non-local command")
                    continue
                }

                guard !seenNames.contains(serverName) else {
                    logMessage("ConnectorManager: Skipping duplicate connector '\(serverName)' from \(configURL.path)")
                    continue
                }
                seenNames.insert(serverName)

                let args = (serverDict["args"] as? [String]) ?? []
                var env = (serverDict["env"] as? [String: String]) ?? [:]
                let pluginPath = pluginDirectory.standardizedFileURL.path

                for (key, value) in env {
                    env[key] = expandConnectorPlaceholders(value, pluginPath: pluginPath, environment: env)
                }

                discovered.append(Connector(
                    name: serverName,
                    directoryPath: pluginPath,
                    configPath: configURL.standardizedFileURL.path,
                    command: expandConnectorPlaceholders(command, pluginPath: pluginPath, environment: env),
                    args: args.map { expandConnectorPlaceholders($0, pluginPath: pluginPath, environment: env) },
                    env: env,
                    importedFrom: configURL.standardizedFileURL.path,
                    sourceKind: .mirrored
                ))
            }
        } catch {
            logMessage("ConnectorManager: Error reading MCP config at \(configURL.path): \(error)")
        }
    }

    private func discoverConnectors(inCodexConfigFile configURL: URL, discovered: inout [Connector], seenNames: inout Set<String>) {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            logMessage("ConnectorManager: Codex config not readable at \(configURL.path)")
            return
        }

        let servers = Self.codexMCPServers(fromTOML: text)
        let pluginPath = configURL.deletingLastPathComponent().standardizedFileURL.path

        for (serverName, serviceConfig) in servers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            if serviceConfig.url != nil && serviceConfig.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logMessage("ConnectorManager: Skipping web-hosted Codex MCP '\(serverName)'")
                continue
            }

            let command = serviceConfig.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, Self.isLocalCommand(command) else {
                logMessage("ConnectorManager: Skipping Codex MCP '\(serverName)' with non-local command")
                continue
            }

            guard !seenNames.contains(serverName) else {
                logMessage("ConnectorManager: Skipping duplicate connector '\(serverName)' from \(configURL.path)")
                continue
            }
            seenNames.insert(serverName)

            var env = serviceConfig.env ?? [:]
            for (key, value) in env {
                env[key] = expandConnectorPlaceholders(value, pluginPath: pluginPath, environment: env)
            }

            discovered.append(Connector(
                name: serverName,
                directoryPath: pluginPath,
                configPath: configURL.standardizedFileURL.path,
                command: expandConnectorPlaceholders(command, pluginPath: pluginPath, environment: env),
                args: (serviceConfig.args ?? []).map { expandConnectorPlaceholders($0, pluginPath: pluginPath, environment: env) },
                env: env,
                importedFrom: configURL.standardizedFileURL.path,
                sourceKind: .mirrored
            ))
        }
    }

    private func discoverConnectors(inClaudeSettingsFile settingsURL: URL, discovered: inout [Connector], seenNames: inout Set<String>) {
        guard let data = try? Data(contentsOf: settingsURL),
              let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabledPlugins = rawJson["enabledPlugins"] as? [String: Bool] else {
            discoverConnectors(inConfigFile: settingsURL, pluginDirectory: settingsURL.deletingLastPathComponent(), discovered: &discovered, seenNames: &seenNames)
            return
        }

        for pluginID in enabledPlugins.keys.sorted() where enabledPlugins[pluginID] == true {
            let parts = pluginID.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let pluginName = parts[0]
            let marketplaceName = parts[1]

            for pluginURL in candidatePluginLocations(pluginName: pluginName, marketplaceName: marketplaceName) {
                discoverConnectors(inDirectory: pluginURL, discovered: &discovered, seenNames: &seenNames)
            }
        }
    }

    private func candidatePluginLocations(pluginName: String, marketplaceName: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsURL = home.appendingPathComponent("Developer/Projects")
        let cacheURL = home.appendingPathComponent(".claude/plugins/cache")
        var candidates: [URL] = []

        candidates.append(contentsOf: versionedPluginDirectories(cacheURL.appendingPathComponent(marketplaceName).appendingPathComponent(pluginName)))

        if marketplaceName == "ames-plugins" {
            candidates.append(projectsURL.appendingPathComponent("ames-plugins/plugins/\(pluginName)"))
        }

        if marketplaceName == pluginName {
            candidates.append(projectsURL.appendingPathComponent(pluginName))
        }

        candidates.append(projectsURL.appendingPathComponent(marketplaceName).appendingPathComponent(pluginName))
        candidates.append(projectsURL.appendingPathComponent(pluginName))

        var unique: [URL] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: standardized) else { continue }
            guard !seen.contains(standardized) else { continue }
            seen.insert(standardized)
            unique.append(URL(fileURLWithPath: standardized))
        }
        return unique
    }

    private func versionedPluginDirectories(_ rootURL: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }

    private func serverConfigurations(from rawJson: [String: Any]) -> [(String, [String: Any])] {
        let rawServers: [String: Any]
        if let mcpServers = rawJson["mcpServers"] as? [String: Any] {
            rawServers = mcpServers
        } else {
            rawServers = rawJson
        }

        var servers: [(String, [String: Any])] = []
        for (serverName, serverVal) in rawServers {
            guard let serverDict = serverVal as? [String: Any] else { continue }
            guard serverDict["command"] != nil || serverDict["url"] != nil else { continue }
            servers.append((serverName, serverDict))
        }
        return servers.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private func resolvePluginRelativePath(_ path: String, pluginDirectory: URL, configURL: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        let pluginRelativeURL = pluginDirectory.appendingPathComponent(expanded).standardizedFileURL
        if FileManager.default.fileExists(atPath: pluginRelativeURL.path) {
            return pluginRelativeURL
        }

        return configURL.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
    }

    private func inferredPluginDirectory(for configURL: URL) -> URL {
        let parent = configURL.deletingLastPathComponent()
        let hiddenPluginDirs: Set<String> = [
            ".antigravity-plugin",
            ".claude-plugin",
            ".codex-plugin",
            ".hermes-plugin"
        ]
        if hiddenPluginDirs.contains(parent.lastPathComponent) {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    private func isClaudeSettingsFile(_ url: URL) -> Bool {
        url.lastPathComponent == "settings.json" && url.path.contains("/.claude/")
    }

    private func isCodexConfigFile(_ url: URL) -> Bool {
        url.lastPathComponent == "config.toml" && url.path.contains("/.codex/")
    }

    private func expandConnectorPlaceholders(_ value: String, pluginPath: String, environment: [String: String]) -> String {
        var expanded = value
        for placeholder in Connector.pluginRootNames {
            expanded = expanded.replacingOccurrences(of: "${\(placeholder)}", with: pluginPath)
        }
        expanded = expanded.replacingOccurrences(of: "${CLAUDE_PROJECT_DIR:-.}", with: ".")
        expanded = expanded.replacingOccurrences(of: "${CLAUDE_PROJECT_DIR}", with: pluginPath)
        return expandShellStyleVariables(in: expanded, environment: environment, preserveMissing: true)
    }

    public static func codexMCPServers(fromTOML text: String) -> [String: MCPServiceConfig] {
        struct MutableServer {
            var command: String = ""
            var args: [String] = []
            var env: [String: String] = [:]
            var url: String?
        }

        var servers: [String: MutableServer] = [:]
        var currentServer: String?
        var currentIsEnvTable = false

        for rawLine in logicalTOMLLines(text) {
            let line = stripTOMLComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let tableName = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = splitTOMLTableName(tableName)
                if parts.count == 2, parts[0] == "mcp_servers" {
                    currentServer = parts[1]
                    currentIsEnvTable = false
                    if servers[currentServer!] == nil {
                        servers[currentServer!] = MutableServer()
                    }
                } else if parts.count == 3, parts[0] == "mcp_servers", parts[2] == "env" {
                    currentServer = parts[1]
                    currentIsEnvTable = true
                    if servers[currentServer!] == nil {
                        servers[currentServer!] = MutableServer()
                    }
                } else {
                    currentServer = nil
                    currentIsEnvTable = false
                }
                continue
            }

            guard let currentServer,
                  let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = parseTOMLKey(String(line[..<equalsIndex]))
            let value = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if currentIsEnvTable {
                if let parsed = parseTOMLString(value) {
                    servers[currentServer, default: MutableServer()].env[key] = parsed
                }
                continue
            }

            switch key {
            case "command":
                if let parsed = parseTOMLString(value) {
                    servers[currentServer, default: MutableServer()].command = parsed
                }
            case "args":
                servers[currentServer, default: MutableServer()].args = parseTOMLStringArray(value)
            case "env":
                let parsedEnv = parseTOMLInlineStringTable(value)
                servers[currentServer, default: MutableServer()].env.merge(parsedEnv, uniquingKeysWith: { _, new in new })
            case "url":
                servers[currentServer, default: MutableServer()].url = parseTOMLString(value)
            default:
                continue
            }
        }

        return servers.reduce(into: [:]) { result, item in
            result[item.key] = MCPServiceConfig(
                command: item.value.command,
                args: item.value.args,
                env: item.value.env,
                url: item.value.url
            )
        }
    }

    private static func isLocalCommand(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !hasURLScheme(trimmed)
    }

    private static func hasURLScheme(_ value: String) -> Bool {
        guard let schemeEnd = value.range(of: "://")?.lowerBound else { return false }
        let scheme = value[..<schemeEnd]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { character in
            character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
        }
    }

    private static func logicalTOMLLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var squareDepth = 0
        var braceDepth = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripTOMLComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if current.isEmpty {
                current = line
            } else {
                current += " " + line
            }

            let delta = containerDepthDelta(in: line)
            squareDepth += delta.square
            braceDepth += delta.brace

            if squareDepth <= 0, braceDepth <= 0 {
                lines.append(current)
                current.removeAll()
                squareDepth = 0
                braceDepth = 0
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func containerDepthDelta(in line: String) -> (square: Int, brace: Int) {
        var square = 0
        var brace = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for character in line {
            if inDoubleQuote && isEscaped {
                isEscaped = false
                continue
            }
            if inDoubleQuote && character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            guard !inSingleQuote, !inDoubleQuote else { continue }
            switch character {
            case "[":
                square += 1
            case "]":
                square -= 1
            case "{":
                brace += 1
            case "}":
                brace -= 1
            default:
                continue
            }
        }
        return (square, brace)
    }

    private static func stripTOMLComment(_ line: String) -> String {
        var result = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for character in line {
            if inDoubleQuote && isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if inDoubleQuote && character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                result.append(character)
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                result.append(character)
                continue
            }
            if character == "#", !inSingleQuote, !inDoubleQuote {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func splitTOMLTableName(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for character in value {
            if inDoubleQuote && isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if inDoubleQuote && character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(character)
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(character)
                continue
            }
            if character == ".", !inSingleQuote, !inDoubleQuote {
                parts.append(parseTOMLKey(current))
                current.removeAll()
                continue
            }
            current.append(character)
        }
        parts.append(parseTOMLKey(current))
        return parts
    }

    private static func parseTOMLKey(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return parseTOMLString(value) ?? value
    }

    private static func parseTOMLString(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return nil }
        let first = value.first
        let last = value.last
        guard (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return nil
        }

        var inner = String(value.dropFirst().dropLast())
        if first == "\"" {
            inner = inner
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
        }
        return inner
    }

    private static func parseTOMLStringArray(_ rawValue: String) -> [String] {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        return splitTOMLList(String(value.dropFirst().dropLast())).compactMap(parseTOMLString)
    }

    private static func parseTOMLInlineStringTable(_ rawValue: String) -> [String: String] {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return [:] }

        var result: [String: String] = [:]
        for item in splitTOMLList(String(value.dropFirst().dropLast())) {
            guard let equalsIndex = item.firstIndex(of: "=") else { continue }
            let key = parseTOMLKey(String(item[..<equalsIndex]))
            let raw = String(item[item.index(after: equalsIndex)...])
            if let parsed = parseTOMLString(raw) {
                result[key] = parsed
            }
        }
        return result
    }

    private static func splitTOMLList(_ value: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for character in value {
            if inDoubleQuote && isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if inDoubleQuote && character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(character)
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(character)
                continue
            }
            if character == ",", !inSingleQuote, !inDoubleQuote {
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty {
                    items.append(item)
                }
                current.removeAll()
                continue
            }
            current.append(character)
        }

        let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !item.isEmpty {
            items.append(item)
        }
        return items
    }

    public func resolveEnvironment(for connector: Connector) async -> [String: String] {
        var sourceEnv = processEnvironment
        sourceEnv.merge(loadOnePasswordLocalEnv(), uniquingKeysWith: { _, new in new })

        for (key, val) in configOverrides {
            sourceEnv[key] = await resolveValueSource(expandShellStyleVariables(in: val, environment: sourceEnv, preserveMissing: false))
        }

        var resolvedEnv = sourceEnv
        resolvedEnv["PATH"] = enrichedPath(from: sourceEnv["PATH"])

        for (key, val) in connector.env {
            let expandedVal = expandShellStyleVariables(in: val, environment: sourceEnv, preserveMissing: false)
            resolvedEnv[key] = await resolveValueSource(expandedVal)
        }

        return resolvedEnv
    }

    private func expandShellStyleVariables(in value: String, environment: [String: String], preserveMissing: Bool) -> String {
        let pattern = "\\$\\{([^}:]+)(?::-([^}]*))?\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }

        var result = value
        let matches = regex.matches(in: value, options: [], range: NSRange(value.startIndex..<value.endIndex, in: value))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }

            let name = String(result[nameRange])
            let defaultValue: String? = {
                guard match.range(at: 2).location != NSNotFound,
                      let defaultRange = Range(match.range(at: 2), in: result) else { return nil }
                return String(result[defaultRange])
            }()

            let replacement = environment[name] ?? defaultValue ?? (preserveMissing ? String(result[fullRange]) : "")
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private func resolveValueSource(_ value: String) async -> String {
        if value.hasPrefix("op://") {
            return await read1PasswordSecret(reference: value)
        }
        return value
    }

    private func loadOnePasswordLocalEnv() -> [String: String] {
        guard config.onePasswordEnvironment?.enabled == true,
              let path = config.onePasswordEnvironment?.localEnvFilePath,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }

        let expanded = NSString(string: path).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            logMessage("ConnectorManager: 1Password local env file not readable at \(expanded)")
            return [:]
        }
        return Self.parseDotenv(text)
    }

    public static func parseDotenv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
            }
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            if value.count >= 2 {
                let first = value.first
                let last = value.last
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value.removeFirst()
                    value.removeLast()
                }
            }

            values[key] = value
        }

        return values
    }

    private func enrichedPath(from currentPath: String?) -> String {
        let defaults = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var parts = (currentPath ?? "").split(separator: ":").map(String.init)
        for item in defaults where !parts.contains(item) {
            parts.append(item)
        }
        return parts.joined(separator: ":")
    }

    private func read1PasswordSecret(reference: String) async -> String {
        let process = Process()
        let candidatePaths = [
            "/opt/homebrew/bin/op",
            "/usr/local/bin/op",
            "/usr/bin/op"
        ]
        guard let opPath = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            logMessage("ConnectorManager: 1Password CLI (op) not found")
            return ""
        }

        process.executableURL = URL(fileURLWithPath: opPath)
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
                logMessage("ConnectorManager: 1Password CLI read failed: \(errStr)")
            }
        } catch {
            logMessage("ConnectorManager: Failed to run 1Password CLI: \(error)")
        }

        return ""
    }
}
