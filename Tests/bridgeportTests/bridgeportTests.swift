import Foundation
import Testing
@testable import bridgeport
#if os(macOS)
import Darwin
#endif

@Test func normalizedRoutePathsAreStable() {
    #expect(ConfigManager.normalizedRoutePath("/ynab/") == "ynab")
    #expect(ConfigManager.normalizedRoutePath(" apple-notes ") == "apple-notes")
    #expect(ConfigManager.normalizedRoutePath("/") == "mcp")
    #expect(ConfigManager.normalizedRoutePath("../bad path?token=x") == "bad-path-token-x")
}

@Test func blankConnectorRouteOverridesUseConnectorName() {
    let connector = Connector(
        name: "ynab",
        directoryPath: "/tmp/ynab",
        configPath: "/tmp/ynab/.mcp.json",
        command: "node",
        args: [],
        env: [:],
        importedFrom: "/tmp/ynab",
        sourceKind: .imported
    )
    let nilOverride = BridgeportConfig(
        connectorSettings: [
            "ynab": BridgeportConnectorSettings(publicPath: nil)
        ]
    )
    let blankOverride = BridgeportConfig(
        connectorSettings: [
            "ynab": BridgeportConnectorSettings(publicPath: "  ")
        ]
    )

    #expect(nilOverride.publicRoutePath(for: connector) == "ynab")
    #expect(blankOverride.publicRoutePath(for: connector) == "ynab")
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

@Test func ynabConnectorWriteCapabilityFromSourceIsPreservedForProduction() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let connector = Connector(
        name: "ynab-mcp-server",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "node",
        args: [],
        env: [
            "YNAB_ALLOW_WRITES": "1"
        ],
        importedFrom: root.path,
        sourceKind: .mirrored
    )
    let manager = ConnectorManager(config: BridgeportConfig(env: [:]), processEnvironment: ["PATH": "/usr/bin"])

    let resolved = await manager.resolveEnvironment(for: connector)

    #expect(resolved["YNAB_ALLOW_WRITES"] == "1")
}

@Test func bridgeportEnvCanTemporarilyForceYNABReadOnlyForValidation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let connector = Connector(
        name: "ynab-mcp-server",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "node",
        args: [],
        env: [
            "YNAB_ALLOW_WRITES": "1"
        ],
        importedFrom: root.path,
        sourceKind: .mirrored
    )
    let manager = ConnectorManager(
        config: BridgeportConfig(env: ["YNAB_ALLOW_WRITES": "0"]),
        processEnvironment: ["PATH": "/usr/bin"]
    )

    let resolved = await manager.resolveEnvironment(for: connector)

    #expect(resolved["YNAB_ALLOW_WRITES"] == "0")
}

@Test func mountedOnePasswordEnvParticipatesInConnectorResolution() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let envFile = root.appendingPathComponent("bridgeport.env")
    try """
    YNAB_API_TOKEN=from-mounted-env
    SHARED_VALUE=from-mounted-env
    YNAB_ALLOW_WRITES=0
    """.write(to: envFile, atomically: true, encoding: .utf8)

    let connector = Connector(
        name: "ynab",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "node",
        args: [],
        env: [
            "CONNECTOR_TOKEN": "${YNAB_API_TOKEN}",
            "SHARED_VALUE": "from-connector",
            "YNAB_ALLOW_WRITES": "1"
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
    #expect(resolved["SHARED_VALUE"] == "from-mounted-env")
    #expect(resolved["YNAB_ALLOW_WRITES"] == "0")
}

#if os(macOS)
@Test func mountedOnePasswordFIFOWithoutWriterDoesNotBlockConnectorResolution() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let fifoURL = root.appendingPathComponent("agent.env")
    #expect(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR) == 0)

    let connector = Connector(
        name: "ynab",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "node",
        args: [],
        env: ["YNAB_ALLOW_WRITES": "1"],
        importedFrom: root.path,
        sourceKind: .imported
    )
    let config = BridgeportConfig(
        onePasswordEnvironment: OnePasswordEnvironmentSettings(enabled: true, localEnvFilePath: fifoURL.path),
        env: [:]
    )
    let manager = ConnectorManager(config: config, processEnvironment: ["PATH": "/usr/bin"])

    let start = Date()
    let resolved = await manager.resolveEnvironment(for: connector)

    #expect(Date().timeIntervalSince(start) < 1)
    #expect(resolved["YNAB_ALLOW_WRITES"] == "1")
}
#endif

@Test func unusedOnePasswordConfigReferencesAreNotInjectedIntoConnectorEnvironment() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let connector = Connector(
        name: "minimal",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "node",
        args: [],
        env: [
            "USED_TOKEN": "${USED_TOKEN}"
        ],
        importedFrom: root.path,
        sourceKind: .imported
    )
    let config = BridgeportConfig(
        env: [
            "SAFE_FLAG": "enabled",
            "UNUSED_SECRET": "op://Development/Unused/credential",
            "USED_TOKEN": "from-config"
        ]
    )
    let manager = ConnectorManager(config: config, processEnvironment: ["PATH": "/usr/bin"])

    let resolved = await manager.resolveEnvironment(for: connector)

    #expect(resolved["SAFE_FLAG"] == "enabled")
    #expect(resolved["USED_TOKEN"] == "from-config")
    #expect(resolved["UNUSED_SECRET"] == nil)
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
            "option": BridgeportImportedConnector(
                command: "-S",
                args: ["node server.js"],
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

@Test func malformedExistingConfigIsNotOverwrittenOnLoad() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let configURL = root.appendingPathComponent("config.json")
    let original = "{not-json"
    try original.write(to: configURL, atomically: true, encoding: .utf8)

    let manager = ConfigManager(
        configURL: configURL,
        clientConfigURL: root.appendingPathComponent("mcp_config.json"),
        cloudConnectorConfigURL: root.appendingPathComponent("cloud_connectors.json")
    )

    _ = await manager.load()

    let afterLoad = try String(contentsOf: configURL, encoding: .utf8)
    #expect(afterLoad == original)
    #expect(await manager.loadedExistingConfigFailedToDecode())
}

@Test func cloudConnectorExportCoversChatGPTClaudeAnthropicMistralAndVibe() {
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
    #expect(export.claudeCustomConnectors.first?.name == "Mock (BridgePort)")
    #expect(export.claudeCustomConnectors.first?.remoteMCPServerURL == "https://mcp.example.com/mcp/mock")
    #expect(export.claudeCustomConnectors.first?.readyForClaudeApp == true)
    #expect(export.claudeCustomConnectors.first?.authentication == "OAuth 2.1 authorization code with PKCE")
    #expect(export.chatGPTCustomApps.count == 1)
    #expect(export.chatGPTCustomApps.first?.mcpServerURL == "https://mcp.example.com/mcp/mock?token=test-token")
    #expect(export.chatGPTCustomApps.first?.readyForChatGPT == true)
    #expect(export.anthropicMessagesAPIMCPServers.first?.url == "https://mcp.example.com/mcp/mock")
    #expect(export.anthropicMessagesAPIMCPServers.first?.authorizationToken == "test-token")
    #expect(export.mistralCustomConnectors.first?.authenticationMethod == "HTTP Bearer Token")
    #expect(export.mistralCustomConnectors.first?.authorizationHeader == "Bearer test-token")
    #expect(export.mistralCustomConnectors.first?.name == "Mock (BridgePort)")
    #expect(export.mistralCustomConnectors.first?.iconURL == "https://mcp.example.com/icons/mock")
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.title == "Mock (BridgePort)")
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.name == "mock_bridgeport")
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.server == "https://mcp.example.com/mcp/mock")
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.iconURL == "https://mcp.example.com/icons/mock")
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.visibility == "private")
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.headers["Authorization"] == "Bearer test-token")
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.mistralIntegration == false)
    #expect(export.mistralCustomConnectors.first?.apiCreatePayload.privateToolExecution == false)
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

    #expect(headerOnlyExport.claudeCustomConnectors.first?.readyForClaudeApp == true)
    #expect(headerOnlyExport.claudeCustomConnectors.first?.remoteMCPServerURL == "https://mcp.example.com/mcp/mock")
    #expect(headerOnlyExport.chatGPTCustomApps.first?.readyForChatGPT == false)
    #expect(headerOnlyExport.chatGPTCustomApps.first?.mcpServerURL == "https://mcp.example.com/mcp/mock")
    #expect(headerOnlyExport.anthropicMessagesAPIMCPServers.first?.authorizationToken == "test-token")
}

@Test func mistralConnectorIconURLIncludesCacheKeyWhenIconAssetExists() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let assets = root.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let icon = assets.appendingPathComponent("icon.png")
    try Data([0, 1, 2, 3]).write(to: icon)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_234)],
        ofItemAtPath: icon.path
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
        publicBaseURL: "https://mcp.example.com",
        connectorSettings: [
            "mock": BridgeportConnectorSettings(enabled: true, exposePublicly: true, publicPath: "/mock")
        ]
    )

    let export = ConfigManager.mistralCustomConnector(config: config, connector: connector)

    #expect(export.iconURL == "https://mcp.example.com/icons/mock?v=4-1234")
    #expect(export.apiCreatePayload.iconURL == "https://mcp.example.com/icons/mock?v=4-1234")
}

@Test func mistralConnectorUsesSourceRepoIconBeforeWrapperIcon() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let wrapperAssets = root.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: wrapperAssets, withIntermediateDirectories: true)
    let wrapperIcon = wrapperAssets.appendingPathComponent("icon.png")
    try Data([0, 1, 2, 3]).write(to: wrapperIcon)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_234)],
        ofItemAtPath: wrapperIcon.path
    )

    let sourceAssets = root.appendingPathComponent("sources/ynab-mcp-server/assets")
    try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
    let sourceIcon = sourceAssets.appendingPathComponent("icon.png")
    try Data([0, 1, 2, 3, 4, 5]).write(to: sourceIcon)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 4_321)],
        ofItemAtPath: sourceIcon.path
    )

    let connector = Connector(
        name: "ynab-mcp-server",
        directoryPath: root.path,
        configPath: root.appendingPathComponent(".mcp.json").path,
        command: "npx",
        args: [],
        env: [:],
        importedFrom: root.path,
        sourceKind: .mirrored
    )
    let config = BridgeportConfig(
        token: "test-token",
        port: 8080,
        publicBaseURL: "https://mcp.example.com",
        connectorSettings: [
            "ynab-mcp-server": BridgeportConnectorSettings(enabled: true, exposePublicly: true, publicPath: "/ynab")
        ]
    )

    let export = ConfigManager.mistralCustomConnector(config: config, connector: connector)

    #expect(ConfigManager.connectorIconCandidateURLs(for: connector).first?.path == sourceIcon.path)
    #expect(export.iconURL == "https://mcp.example.com/icons/ynab?v=6-4321")
    #expect(export.apiCreatePayload.iconURL == "https://mcp.example.com/icons/ynab?v=6-4321")
    #expect(export.name == "YNAB (BridgePort)")
    #expect(export.apiCreatePayload.title == "YNAB (BridgePort)")
    #expect(export.apiCreatePayload.name == "ynab_bridgeport")
    #expect(ConfigManager.providerDisplayName(for: connector, routePath: "ynab") == "YNAB (BridgePort)")
}

@Test func mistralSafeConnectorNamesMatchAPIContract() {
    #expect(ConfigManager.mistralSafeConnectorName("Bridgeport YNAB") == "Bridgeport_YNAB")
    #expect(ConfigManager.mistralSafeConnectorName("ynab-mcp-server") == "ynab-mcp-server")
    #expect(ConfigManager.mistralSafeConnectorName("***") == "bridgeport_connector")
    #expect(ConfigManager.mistralSafeConnectorName(String(repeating: "a", count: 80)).count == 64)
}

@Test func constantTimeTokenComparisonMatchesExactStringsOnly() {
    #expect(SSEServer.constantTimeEquals("Bearer test-token", "Bearer test-token"))
    #expect(!SSEServer.constantTimeEquals("Bearer test-token", "Bearer test-token-extra"))
    #expect(!SSEServer.constantTimeEquals("Bearer test-token", "bearer test-token"))
}

@Test func wwwAuthenticateQuotedValuesEscapeUnsafeCharacters() {
    #expect(SSEServer.wwwAuthenticateQuotedValue("https://example.com/mcp/ynab") == "https://example.com/mcp/ynab")
    #expect(SSEServer.wwwAuthenticateQuotedValue("https://example.com/quote\"slash\\line\nnext\r") == #"https://example.com/quote\"slash\\linenext"#)
}

@Test func initializeResponseGetsConnectorIconMetadataWhenMissing() throws {
    let response = """
    {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"mcp-server-for-ynab","version":"3.0.0"}}}
    """
    let decorated = BridgeSession.messageWithBridgeportIconMetadata(
        response,
        iconURL: "https://bridgeport.example.com/icons/ynab"
    )
    let data = try #require(decorated.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(object["result"] as? [String: Any])
    let serverInfo = try #require(result["serverInfo"] as? [String: Any])
    let icons = try #require(serverInfo["icons"] as? [[String: Any]])
    let firstIcon = try #require(icons.first)

    #expect(firstIcon["src"] as? String == "https://bridgeport.example.com/icons/ynab")
    #expect(firstIcon["mimeType"] as? String == "image/png")
    #expect(result["serverCardIconUrl"] as? String == "https://bridgeport.example.com/icons/ynab")

    let upstreamIconResponse = """
    {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"mock","icons":[{"src":"https://upstream/icon.png","mimeType":"image/png"}]}}}
    """
    let preserved = BridgeSession.messageWithBridgeportIconMetadata(
        upstreamIconResponse,
        iconURL: "https://bridgeport.example.com/icons/mock"
    )
    #expect(preserved == upstreamIconResponse)
}

@Test func oauthAccessTokensAreScopedToAuthorizedResource() async {
    let store = OAuthTokenStore()
    let client = await store.registerClient(clientName: "Probe", redirectURIs: ["http://localhost/callback"])
    let code = await store.issueAuthorizationCode(
        clientID: client.clientID,
        redirectURI: "http://localhost/callback",
        codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
        resource: "https://bridgeport.example.com/mcp/ynab"
    )
    let token = await store.redeemAuthorizationCode(
        code: code ?? "",
        clientID: client.clientID,
        redirectURI: "http://localhost/callback",
        codeVerifier: "verifier"
    )

    #expect(token != nil)
    #expect(await store.isValidAccessToken(token ?? "", resource: "https://bridgeport.example.com/mcp/ynab"))
    #expect(!(await store.isValidAccessToken(token ?? "", resource: "https://bridgeport.example.com/mcp/apple-notes")))
}

@Test func oauthRegisteredClientsPersistAcrossStores() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let registry = root.appendingPathComponent("oauth_clients.json")
    let firstStore = OAuthTokenStore(clientRegistryURL: registry)
    let client = await firstStore.registerClient(
        clientName: "Mistral",
        redirectURIs: ["https://callback.mistral.ai/v1/integrations_auth/oauth2_callback"],
        now: Date(timeIntervalSince1970: 100)
    )

    let reloadedStore = OAuthTokenStore(clientRegistryURL: registry)
    let reloadedClient = await reloadedStore.client(id: client.clientID)

    #expect(reloadedClient?.clientID == client.clientID)
    #expect(reloadedClient?.clientName == "Mistral")
    #expect(reloadedClient?.redirectURIs == client.redirectURIs)
}

@Test func oauthStoreAdoptsBridgeportClientIDsForAllowedRedirects() async {
    let store = OAuthTokenStore()
    let clientID = "ames_" + String(repeating: "A", count: 43)

    let adopted = await store.adoptClientIfNeeded(
        clientID: clientID,
        clientName: "callback.mistral.ai",
        redirectURI: "https://callback.mistral.ai/v1/integrations_auth/oauth2_callback",
        now: Date(timeIntervalSince1970: 100)
    )
    let badID = await store.adoptClientIfNeeded(
        clientID: "not-a-bridgeport-client",
        clientName: "callback.mistral.ai",
        redirectURI: "https://callback.mistral.ai/v1/integrations_auth/oauth2_callback"
    )
    let badRedirect = await store.adoptClientIfNeeded(
        clientID: "ames_" + String(repeating: "B", count: 43),
        clientName: "evil.example.com",
        redirectURI: "http://evil.example.com/callback"
    )

    #expect(adopted?.clientID == clientID)
    #expect(adopted?.redirectURIs == ["https://callback.mistral.ai/v1/integrations_auth/oauth2_callback"])
    #expect(badID == nil)
    #expect(badRedirect == nil)
}

@Test func oauthAccessTokensPersistAcrossStores() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let tokenStoreURL = root.appendingPathComponent("oauth_tokens.json")
    let firstStore = OAuthTokenStore(accessTokenStoreURL: tokenStoreURL)
    let client = await firstStore.registerClient(clientName: "Probe", redirectURIs: ["http://localhost/callback"])
    let code = await firstStore.issueAuthorizationCode(
        clientID: client.clientID,
        redirectURI: "http://localhost/callback",
        codeChallenge: OAuthSupport.pkceS256Challenge(for: "verifier"),
        resource: "https://bridgeport.example.com/mcp/ynab"
    )
    let token = await firstStore.redeemAuthorizationCode(
        code: code ?? "",
        clientID: client.clientID,
        redirectURI: "http://localhost/callback",
        codeVerifier: "verifier"
    )
    #expect(token != nil)

    let reloadedStore = OAuthTokenStore(accessTokenStoreURL: tokenStoreURL)
    #expect(await reloadedStore.isValidAccessToken(token ?? "", resource: "https://bridgeport.example.com/mcp/ynab"))
    #expect(!(await reloadedStore.isValidAccessToken(token ?? "", resource: "https://bridgeport.example.com/mcp/apple-notes")))

    let attrs = try FileManager.default.attributesOfItem(atPath: tokenStoreURL.path)
    let permissions = try #require(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
    #expect(permissions == 0o600)
}

@Test func oauthClientRegistryPrunesOldestClientsBeyondCap() async {
    let store = OAuthTokenStore()
    var firstClientID = ""
    var lastClientID = ""

    for index in 0..<300 {
        let client = await store.registerClient(
            clientName: "Client \(index)",
            redirectURIs: ["http://localhost/callback"],
            now: Date(timeIntervalSince1970: TimeInterval(index))
        )
        if index == 0 {
            firstClientID = client.clientID
        }
        lastClientID = client.clientID
    }

    #expect(await store.client(id: firstClientID) == nil)
    #expect(await store.client(id: lastClientID) != nil)
}

@Test func bridgeSessionIdleDetectionTracksOpenStreams() async {
    let connector = Connector(
        name: "idle",
        directoryPath: "/tmp",
        configPath: "/tmp/.mcp.json",
        command: "python3",
        args: [],
        env: [:],
        importedFrom: "/tmp",
        sourceKind: .imported
    )
    let session = BridgeSession(id: "idle-test", connectorName: "idle", bridge: ProcessBridge(connector: connector, env: [:]))

    #expect(await session.isIdle(olderThan: -1))
    #expect(!(await session.isIdle(olderThan: 3600)))

    let (streamId, stream) = await session.addPersistentStream()
    #expect(!(await session.isIdle(olderThan: -1)))

    await session.removePersistentStream(id: streamId)
    #expect(await session.isIdle(olderThan: -1))
    withExtendedLifetime(stream) {}
}

@Test func streamSequenceDeliversChunkedBytesInOrder() async throws {
    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
    continuation.yield(Array("event: message\n".utf8))
    continuation.yield([])
    continuation.yield(Array("data: {}\n\n".utf8))
    continuation.finish()

    var iterator = StreamSequence(stream: stream).makeAsyncIterator()
    var collected: [UInt8] = []
    if let first = await iterator.next() {
        collected.append(first)
    }
    while let buffer = try await iterator.nextBuffer(suggested: 4096) {
        collected.append(contentsOf: buffer)
    }

    #expect(String(decoding: collected, as: UTF8.self) == "event: message\ndata: {}\n\n")
}

@Test func generatedTokensUseURLSafeCharacters() {
    let token = ConfigManager.generateSecureToken()
    #expect(token.hasPrefix("ames_"))
    #expect(token.count >= 48)
    #expect(token.allSatisfy { character in
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    })
}

@Test func processBridgeUsesPortableEnvLaunchArguments() {
    let connector = Connector(
        name: "node-server",
        directoryPath: "/tmp",
        configPath: "/tmp/.mcp.json",
        command: "node",
        args: ["server.js", "--flag"],
        env: [:],
        importedFrom: "/tmp/.mcp.json",
        sourceKind: .imported
    )

    #expect(ProcessBridge.envLaunchArguments(for: connector) == ["node", "server.js", "--flag"])
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

@Test func newInstallDefaultsDoNotContainMaintainerSpecificPathsOrCloudflareValues() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let settings = ConfigManager.defaultCloudflareSettings()

    #expect(ConfigManager.defaultPrimaryConnectorsPath() == "\(home)/.config/bridgeport/connectors")
    #expect(settings.profileName == "Personal tunnel")
    #expect(settings.domain.isEmpty)
    #expect(settings.hostname.isEmpty)
    #expect(settings.tunnelName == "bridgeport")
    #expect(settings.apiTokenEnvVar == "CLOUDFLARE_API_TOKEN")
    #expect(settings.apiTokenOPReference.isEmpty)
    #expect(settings.createdByBridgeport == false)
}

@Test func cloudflareSettingsNormalizeTildePaths() {
    let settings = ConfigManager.normalizedCloudflareSettings(CloudflareSettings(
        enabled: true,
        credentialsFilePath: "~/.cloudflared/bridgeport.json",
        configFilePath: "~/.config/bridgeport/cloudflared/config.yml",
        cloudflaredPath: "~/bin/cloudflared"
    ))

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(settings.credentialsFilePath == "\(home)/.cloudflared/bridgeport.json")
    #expect(settings.configFilePath == "\(home)/.config/bridgeport/cloudflared/config.yml")
    #expect(settings.cloudflaredPath == "\(home)/bin/cloudflared")
}

@Test func cloudflareNormalizationPreservesExplicitUserIdentity() {
    let settings = ConfigManager.normalizedCloudflareSettings(CloudflareSettings(
        profileName: "Existing deployment",
        domain: "gateway.example.org",
        hostname: "mcp.gateway.example.org"
    ))

    #expect(settings.profileName == "Existing deployment")
    #expect(settings.domain == "gateway.example.org")
    #expect(settings.hostname == "mcp.gateway.example.org")
}

@Test func cloudflaredConfigYAMLUsesNamedTunnelAndLocalhostIngress() {
    let yaml = CloudflareManager.cloudflaredConfigYAML(
        settings: CloudflareSettings(
            enabled: true,
            hostname: "mcp.example.com",
            tunnelName: "bridgeport",
            tunnelId: "11111111-2222-3333-4444-555555555555",
            credentialsFilePath: "/Users/example/.cloudflared/bridgeport.json"
        ),
        port: 8080,
        bindHost: "127.0.0.1"
    )

    #expect(yaml.contains(#"tunnel: "11111111-2222-3333-4444-555555555555""#))
    #expect(yaml.contains(#"credentials-file: "/Users/example/.cloudflared/bridgeport.json""#))
    #expect(yaml.contains(#"hostname: "mcp.example.com""#))
    #expect(yaml.contains(#"service: "http://127.0.0.1:8080""#))
    #expect(yaml.contains("service: http_status:404"))
    #expect(!yaml.lowercased().contains("token"))
}

@Test func cloudflareLaunchAgentRunsCloudflaredWithBridgeportConfig() throws {
    let data = try CloudflareManager.launchAgentPlistData(
        label: "com.oliverames.bridgeport.cloudflared",
        cloudflaredPath: "/opt/homebrew/bin/cloudflared",
        configFilePath: "/Users/example/.config/bridgeport/cloudflared/config.yml",
        stdoutPath: "/Users/example/.config/bridgeport/cloudflared_stdout.log",
        stderrPath: "/Users/example/.config/bridgeport/cloudflared_stderr.log"
    )
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

    #expect(plist["Label"] as? String == "com.oliverames.bridgeport.cloudflared")
    #expect(plist["ProgramArguments"] as? [String] == [
        "/opt/homebrew/bin/cloudflared",
        "tunnel",
        "--config",
        "/Users/example/.config/bridgeport/cloudflared/config.yml",
        "run"
    ])
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect(plist["RunAtLoad"] as? Bool == true)
}

@Test func cloudflareStatusDetectsMissingCloudflared() async {
    let settings = CloudflareSettings(
        enabled: true,
        configFilePath: "/tmp/bridgeport-cloudflare-test/config.yml",
        cloudflaredPath: "/tmp/definitely-not-cloudflared-\(UUID().uuidString)"
    )
    let manager = CloudflareManager(settings: settings, port: 8080, bindHost: "127.0.0.1")

    let status = await manager.status()

    #expect(status.state == CloudflareTunnelState.missingCloudflared)
    #expect(status.cloudflaredInstalled == false)
    #expect(status.hostname.isEmpty)
}

@Test func nonInitializeMessagesSkipIconDecoration() {
    let notification = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"value":1}}"#
    let decorated = BridgeSession.messageWithBridgeportIconMetadata(
        notification,
        iconURL: "https://bridgeport.example.com/icons/mock"
    )
    #expect(decorated == notification)
}

@Test func discoveryResultsAreCachedBriefly() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let firstDir = root.appendingPathComponent("first")
    try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
    try #"{"mcpServers": {"first": {"command": "node"}}}"#
        .write(to: firstDir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

    let manager = ConnectorManager(connectorPaths: [root.path])
    let initial = await manager.discoverConnectors()
    #expect(initial.map(\.name) == ["first"])

    let secondDir = root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
    try #"{"mcpServers": {"second": {"command": "node"}}}"#
        .write(to: secondDir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

    // The serving path caches discovery briefly so per-request lookups do not
    // re-walk the filesystem; a connector added moments ago appears after the
    // TTL, not within it.
    let cached = await manager.discoverConnectors()
    #expect(cached.map(\.name) == ["first"])
}

@Test func connectorIconCandidatesIncludeLogoAndRootFilenames() {
    let connector = Connector(
        name: "mock",
        directoryPath: "/tmp/mock",
        configPath: "/tmp/mock/.mcp.json",
        command: "node",
        args: [],
        env: [:],
        importedFrom: "/tmp/mock",
        sourceKind: .imported
    )
    let candidatePaths = ConfigManager.connectorIconCandidateURLs(for: connector).map(\.path)

    #expect(candidatePaths.contains("/tmp/mock/assets/logo.png"))
    #expect(candidatePaths.contains("/tmp/mock/icon.png"))
    #expect(candidatePaths.contains("/tmp/mock/logo.svg"))
    // Bundled source repo icons must stay ahead of wrapper-level icons.
    #expect(candidatePaths.firstIndex(of: "/tmp/mock/sources/mock/assets/icon.png")! < candidatePaths.firstIndex(of: "/tmp/mock/assets/icon.png")!)
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridgeport-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
