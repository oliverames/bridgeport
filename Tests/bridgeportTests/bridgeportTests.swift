import Foundation
import Testing
@testable import bridgeport

@Test func normalizedRoutePathsAreStable() {
    #expect(ConfigManager.normalizedRoutePath("/ynab/") == "ynab")
    #expect(ConfigManager.normalizedRoutePath(" apple-notes ") == "apple-notes")
    #expect(ConfigManager.normalizedRoutePath("/") == "mcp")
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

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridgeport-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
