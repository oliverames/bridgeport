import Foundation
import Testing
@testable import bridgeport

@Test func normalizedRoutePathsAreStable() {
    #expect(ConfigManager.normalizedRoutePath("/ynab/") == "ynab")
    #expect(ConfigManager.normalizedRoutePath(" apple-notes ") == "apple-notes")
    #expect(ConfigManager.normalizedRoutePath("/") == "mcp")
    #expect(ConfigManager.normalizedRoutePath("../bad path?token=x") == "bad-path-token-x")
}

@Test func dotenvParserHandlesMountedOnePasswordFileShape() {
    let values = ConnectorManager.parseDotenv("""
    # 1Password mounted env
    export YNAB_API_TOKEN="ynab-secret"
    GOOGLE_CLIENT_ID=plain-id
    EMPTY=
    SINGLE_QUOTED='value'
    """)

    #expect(values["YNAB_API_TOKEN"] == "ynab-secret")
    #expect(values["GOOGLE_CLIENT_ID"] == "plain-id")
    #expect(values["EMPTY"] == "")
    #expect(values["SINGLE_QUOTED"] == "value")
}

@Test func defaultEnvReferencesPreferClaudeEnvOpReferences() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let claudeEnv = root.appendingPathComponent(".env")
    try """
    GITHUB_TOKEN=op://Development/GitHub/credential
    PLAIN_TOKEN=plaintext
    TOOL_PATH=/usr/local/bin/tool
    """.write(to: claudeEnv, atomically: true, encoding: .utf8)

    let settings = root.appendingPathComponent("settings.json")
    try """
    {
      "env": {
        "GITHUB_TOKEN": "plaintext-token",
        "TOOL_PATH": "/usr/local/bin/tool"
      }
    }
    """.write(to: settings, atomically: true, encoding: .utf8)

    let values = ConfigManager.defaultEnvReferences(claudeEnvURL: claudeEnv, claudeSettingsURL: settings)

    #expect(values["GITHUB_TOKEN"] == "op://Development/GitHub/credential")
    #expect(values["PLAIN_TOKEN"] == nil)
    #expect(values["TOOL_PATH"] == nil)
}

@Test func defaultEnvReferencesOnlyFallsBackToSafeClaudeSettingsValues() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let missingEnv = root.appendingPathComponent("missing.env")
    let settings = root.appendingPathComponent("settings.json")
    try """
    {
      "env": {
        "GITHUB_TOKEN": "plaintext-token",
        "GITHUB_TOKEN_REF": "op://Development/GitHub/credential",
        "TOOL_PATH": "/usr/local/bin/tool"
      }
    }
    """.write(to: settings, atomically: true, encoding: .utf8)

    let values = ConfigManager.defaultEnvReferences(claudeEnvURL: missingEnv, claudeSettingsURL: settings)

    #expect(values["GITHUB_TOKEN"] == nil)
    #expect(values["GITHUB_TOKEN_REF"] == "op://Development/GitHub/credential")
    #expect(values["TOOL_PATH"] == "/usr/local/bin/tool")
}

@Test func mountedOnePasswordEnvParticipatesInConnectorResolution() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let envFile = root.appendingPathComponent("bridgeport.env")
    try """
    YNAB_API_TOKEN=from-mounted-env
    SHARED_VALUE=from-mounted-env
    """.write(to: envFile, atomically: true, encoding: .utf8)

    let connector = Connector(
        name: "ynab",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "node",
        args: [],
        env: [
            "CONNECTOR_TOKEN": "${YNAB_API_TOKEN}",
            "SHARED_VALUE": "from-connector"
        ],
        importedFrom: root.path,
        sourceKind: .imported
    )
    let config = BridgeportConfig(
        onePasswordEnvironment: OnePasswordEnvironmentSettings(enabled: true, localEnvFilePath: envFile.path),
        env: [
            "CONFIG_ONLY": "from-config",
            "CONFIG_FROM_MOUNT": "${YNAB_API_TOKEN}"
        ]
    )
    let manager = ConnectorManager(config: config, processEnvironment: ["PATH": "/usr/bin"])

    let resolved = await manager.resolveEnvironment(for: connector)

    #expect(resolved["YNAB_API_TOKEN"] == "from-mounted-env")
    #expect(resolved["CONFIG_ONLY"] == "from-config")
    #expect(resolved["CONFIG_FROM_MOUNT"] == "from-mounted-env")
    #expect(resolved["CONNECTOR_TOKEN"] == "from-mounted-env")
    #expect(resolved["SHARED_VALUE"] == "from-connector")
}

@Test func discoversRelativePluginManifestMCPConfig() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let pluginDir = root.appendingPathComponent("sample-plugin")
    try FileManager.default.createDirectory(at: pluginDir.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
    try """
    {
      "name": "sample-plugin",
      "mcpServers": "./.mcp.json"
    }
    """.write(to: pluginDir.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)

    try """
    {
      "mcpServers": {
        "sample": {
          "command": "node",
          "args": ["${CLAUDE_PROJECT_DIR:-.}/build/index.js", "${PLUGIN_ROOT}/fixtures"],
          "env": {"SAMPLE_TOKEN": "${SAMPLE_TOKEN}"}
        }
      }
    }
    """.write(to: pluginDir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

    let manager = ConnectorManager(connectorPaths: [root.path])
    let connectors = await manager.discoverConnectors()

    #expect(connectors.count == 1)
    #expect(connectors.first?.name == "sample")
    #expect(connectors.first?.args.first == "./build/index.js")
    #expect(connectors.first?.args.last == pluginDir.appendingPathComponent("fixtures").path)
    #expect(connectors.first?.requiredEnvVarNames == ["SAMPLE_TOKEN"])
}

@Test func discoversLocalCodexMCPServersAndSkipsWebOnlyServers() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let codexDir = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let codexConfig = codexDir.appendingPathComponent("config.toml")
    try """
    [mcp_servers.node_repl]
    command = "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"
    args = ["--stdio", "${CODEX_PLUGIN_ROOT}/shim.js"]
    env = { "NODE_PATH" = "/tmp/node", "TOKEN_REF" = "${TOKEN_REF}" }

    [mcp_servers.web_docs]
    url = "https://example.com/mcp"

    [mcp_servers.remote_command]
    command = "wss://example.com/mcp"
    """.write(to: codexConfig, atomically: true, encoding: .utf8)

    let manager = ConnectorManager(connectorPaths: [codexConfig.path])
    let connectors = await manager.discoverConnectors()

    #expect(connectors.count == 1)
    #expect(connectors.first?.name == "node_repl")
    #expect(connectors.first?.command == "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl")
    #expect(connectors.first?.args.last == codexDir.appendingPathComponent("shim.js").path)
    #expect(connectors.first?.env["NODE_PATH"] == "/tmp/node")
    #expect(connectors.first?.requiredEnvVarNames == ["TOKEN_REF"])
}

@Test func parsesCodexQuotedTablesAndEnvSubtables() {
    let servers = ConnectorManager.codexMCPServers(fromTOML: """
    [mcp_servers."quoted.name"]
    command = 'node'
    args = ['server.js', '--name=quoted.name']

    [mcp_servers."quoted.name".env]
    API_TOKEN = "op://Development/Token/credential"
    """)

    #expect(servers["quoted.name"]?.command == "node")
    #expect(servers["quoted.name"]?.args == ["server.js", "--name=quoted.name"])
    #expect(servers["quoted.name"]?.env?["API_TOKEN"] == "op://Development/Token/credential")
}

@Test func parsesCodexMultilineArraysAndInlineEnv() {
    let servers = ConnectorManager.codexMCPServers(fromTOML: """
    [mcp_servers.multiline]
    command = "node"
    args = [
      "server.js",
      "--flag=value",
    ]
    env = {
      "TOKEN_REF" = "${TOKEN_REF}",
      "NODE_PATH" = "/tmp/node",
    }
    """)

    #expect(servers["multiline"]?.command == "node")
    #expect(servers["multiline"]?.args == ["server.js", "--flag=value"])
    #expect(servers["multiline"]?.env?["TOKEN_REF"] == "${TOKEN_REF}")
    #expect(servers["multiline"]?.env?["NODE_PATH"] == "/tmp/node")
}

@Test func staleImportedWebCommandsAreSkipped() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let config = BridgeportConfig(
        connectorsPath: root.appendingPathComponent("missing-source").path,
        additionalConnectorPaths: [],
        importedConnectors: [
            "bad": BridgeportImportedConnector(
                command: "https://example.com/mcp",
                directoryPath: root.path,
                configPath: root.appendingPathComponent(".mcp.json").path,
                importedFrom: root.path
            ),
            "remote": BridgeportImportedConnector(
                command: "ssh://example.com/mcp",
                directoryPath: root.path,
                configPath: root.appendingPathComponent(".mcp.json").path,
                importedFrom: root.path
            ),
            "good": BridgeportImportedConnector(
                command: "node",
                args: ["server.js"],
                directoryPath: root.path,
                configPath: root.appendingPathComponent(".mcp.json").path,
                importedFrom: root.path
            )
        ]
    )
    let manager = ConnectorManager(config: config)
    let connectors = await manager.discoverConnectors()

    #expect(connectors.map(\.name) == ["good"])
}

@Test func clientConfigUsesHeaderAuthAndMcpEndpoint() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = ConfigManager(
        configURL: root.appendingPathComponent("config.json"),
        clientConfigURL: root.appendingPathComponent("mcp_config.json")
    )

    let connector = Connector(
        name: "mock",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "python3",
        args: [],
        env: [:],
        importedFrom: root.path,
        sourceKind: .imported
    )
    let config = BridgeportConfig(
        token: "test-token",
        port: 8080,
        publicBaseURL: "https://mcp.example.com/",
        connectorSettings: [
            "mock": BridgeportConnectorSettings(enabled: true, exposePublicly: true, publicPath: "/mock")
        ]
    )

    await manager.writeMcpClientConfig(config: config, connectors: [connector])

    let data = try Data(contentsOf: root.appendingPathComponent("mcp_config.json"))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let servers = try #require(json["mcpServers"] as? [String: Any])
    let mock = try #require(servers["mock"] as? [String: Any])
    let headers = try #require(mock["headers"] as? [String: String])

    #expect(mock["type"] as? String == "http")
    #expect(mock["url"] as? String == "https://mcp.example.com/mcp/mock")
    #expect(headers["Authorization"] == "Bearer test-token")
    #expect((mock["url"] as? String)?.contains("token=") == false)
}

@Test func generatedConfigFilesArePrivate() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = ConfigManager(
        configURL: root.appendingPathComponent("config.json"),
        clientConfigURL: root.appendingPathComponent("mcp_config.json"),
        cloudConnectorConfigURL: root.appendingPathComponent("cloud_connectors.json")
    )
    let connector = Connector(
        name: "mock",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "python3",
        args: [],
        env: [:],
        importedFrom: root.path,
        sourceKind: .imported
    )
    let config = BridgeportConfig(
        token: "test-token",
        port: 8080,
        publicBaseURL: "https://mcp.example.com/",
        connectorSettings: [
            "mock": BridgeportConnectorSettings(enabled: true, exposePublicly: true)
        ]
    )

    await manager.save(config)
    await manager.writeMcpClientConfig(config: config, connectors: [connector])
    await manager.writeCloudConnectorConfig(config: config, connectors: [connector])

    for url in [
        root.appendingPathComponent("config.json"),
        root.appendingPathComponent("mcp_config.json"),
        root.appendingPathComponent("cloud_connectors.json")
    ] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
        #expect(permissions == 0o600)
    }
}

@Test func cloudConnectorExportCoversClaudeAnthropicMistralAndVibe() {
    let connector = Connector(
        name: "mock",
        directoryPath: "/tmp/mock",
        configPath: "/tmp/mock/.mcp.json",
        command: "python3",
        args: [],
        env: [:],
        importedFrom: "/tmp/mock",
        sourceKind: .imported
    )
    let hiddenConnector = Connector(
        name: "hidden",
        directoryPath: "/tmp/hidden",
        configPath: "/tmp/hidden/.mcp.json",
        command: "python3",
        args: [],
        env: [:],
        importedFrom: "/tmp/hidden",
        sourceKind: .imported
    )
    let config = BridgeportConfig(
        token: "test-token",
        port: 8080,
        publicBaseURL: "https://mcp.example.com/",
        allowQueryTokenAuth: true,
        connectorSettings: [
            "mock": BridgeportConnectorSettings(enabled: true, exposePublicly: true, publicPath: "/mock"),
            "hidden": BridgeportConnectorSettings(enabled: true, exposePublicly: false, publicPath: "/hidden")
        ]
    )

    let export = ConfigManager.cloudConnectorExport(
        config: config,
        connectors: [connector, hiddenConnector],
        generatedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(export.claudeCustomConnectors.count == 1)
    #expect(export.claudeCustomConnectors.first?.remoteMCPServerURL == "https://mcp.example.com/mcp/mock?token=test-token")
    #expect(export.claudeCustomConnectors.first?.readyForClaudeApp == true)
    #expect(export.anthropicMessagesAPIMCPServers.first?.url == "https://mcp.example.com/mcp/mock")
    #expect(export.anthropicMessagesAPIMCPServers.first?.authorizationToken == "test-token")
    #expect(export.mistralCustomConnectors.first?.authenticationMethod == "HTTP Bearer Token")
    #expect(export.mistralCustomConnectors.first?.authorizationHeader == "Bearer test-token")
    #expect(export.vibeCodeMCPServers.first?.transport == "streamable-http")
    #expect(export.vibeCodeMCPServers.first?.toml.contains("headers = { \"Authorization\" = \"Bearer test-token\" }") == true)

    let headerOnlyConfig = BridgeportConfig(
        token: "test-token",
        port: 8080,
        publicBaseURL: "https://mcp.example.com/",
        allowQueryTokenAuth: false,
        connectorSettings: [
            "mock": BridgeportConnectorSettings(enabled: true, exposePublicly: true, publicPath: "/mock")
        ]
    )
    let headerOnlyExport = ConfigManager.cloudConnectorExport(config: headerOnlyConfig, connectors: [connector])

    #expect(headerOnlyExport.claudeCustomConnectors.first?.readyForClaudeApp == false)
    #expect(headerOnlyExport.claudeCustomConnectors.first?.remoteMCPServerURL == "https://mcp.example.com/mcp/mock")
    #expect(headerOnlyExport.anthropicMessagesAPIMCPServers.first?.authorizationToken == "test-token")
}

@Test func constantTimeTokenComparisonMatchesExactStringsOnly() {
    #expect(SSEServer.constantTimeEquals("Bearer test-token", "Bearer test-token"))
    #expect(!SSEServer.constantTimeEquals("Bearer test-token", "Bearer test-token-extra"))
    #expect(!SSEServer.constantTimeEquals("Bearer test-token", "bearer test-token"))
}

@Test func generatedTokensUseURLSafeCharacters() {
    let token = ConfigManager.generateSecureToken()
    #expect(token.hasPrefix("ames_"))
    #expect(token.count >= 48)
    #expect(token.allSatisfy { character in
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    })
}

@Test func processBridgeTerminatesEnvOptionsBeforeConnectorCommand() {
    let connector = Connector(
        name: "option-like",
        directoryPath: "/tmp",
        configPath: "/tmp/.mcp.json",
        command: "-S",
        args: ["node server.js"],
        env: [:],
        importedFrom: "/tmp/.mcp.json",
        sourceKind: .imported
    )

    #expect(ProcessBridge.envLaunchArguments(for: connector) == ["--", "-S", "node server.js"])
}

@Test func launchAgentPlistEscapesSpecialCharacters() throws {
    let data = try LaunchAgentPlist.makeData(
        label: "com.oliverames.bridgeport",
        executablePath: "/tmp/bridgeport & release/bin/bridgeport",
        stdoutPath: "/tmp/bridgeport & release/stdout.log",
        stderrPath: "/tmp/bridgeport & release/stderr.log"
    )
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

    #expect(plist["Label"] as? String == "com.oliverames.bridgeport")
    #expect(plist["ProgramArguments"] as? [String] == ["/tmp/bridgeport & release/bin/bridgeport", "--server"])
    #expect(plist["StandardOutPath"] as? String == "/tmp/bridgeport & release/stdout.log")
    #expect(plist["StandardErrorPath"] as? String == "/tmp/bridgeport & release/stderr.log")
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridgeport-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
