import Foundation
#if os(macOS)
import Darwin
#endif

@discardableResult
func runShell(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines), stderrStr.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        return (-1, "", error.localizedDescription)
    }
}

func isServiceLoaded(label: String, uid: uid_t) -> Bool {
    let result = runShell("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
    return result.status == 0
}

@main
struct bridgeport {
    static func main() async {
        let args = CommandLine.arguments
        func isAppLaunchArgument(_ argument: String) -> Bool {
            argument == "--open-settings" || argument.hasPrefix("--open-settings=")
        }

        let requestedSettingsWindow = args.dropFirst().contains(where: isAppLaunchArgument)
        let isBridgeportCLIInvocation = args.dropFirst().contains {
            $0.hasPrefix("--") && !isAppLaunchArgument($0)
        }

        if requestedSettingsWindow {
            setenv("BRIDGEPORT_OPEN_SETTINGS", "1", 1)
            if let pane = args.dropFirst().first(where: { $0.hasPrefix("--open-settings=") })?.split(separator: "=", maxSplits: 1).last {
                setenv("BRIDGEPORT_SETTINGS_PANE", String(pane), 1)
            }
        }

        if !isBridgeportCLIInvocation {
            #if os(macOS)
            BridgeportApp.main()
            #else
            print("GUI mode is only supported on macOS.")
            exit(1)
            #endif
            return
        }

        let configManager = ConfigManager()
        var config = await configManager.load()
        let loadedExistingConfigFailedToDecode = await configManager.loadedExistingConfigFailedToDecode()

        var port: UInt16 = config.port ?? 8080
        var token: String? = config.token
        var connectorsPath: String = config.connectorsPath ?? ConfigManager.defaultPrimaryConnectorsPath()
        var publicBaseURL = config.publicBaseURL ?? ""
        var bindHost = config.bindHost ?? "127.0.0.1"

        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsURL = home.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentsURL.appendingPathComponent("com.oliverames.bridgeport.plist")
        let configDirectory = BridgeportPaths.configDirectory()
        let binDir = configDirectory.appendingPathComponent("bin")
        let destURL = binDir.appendingPathComponent("bridgeport")

        #if os(macOS)
        let uid = getuid()
        #else
        let uid: uid_t = 0
        #endif

        var daemonAction: String? = nil
        var isServerMode = false
        var shouldRegenerateAllowedOrigins = false

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--server":
                isServerMode = true
                i += 1
            case "--daemon-install":
                daemonAction = "install"
                i += 1
            case "--daemon-uninstall":
                daemonAction = "uninstall"
                i += 1
            case "--daemon-status":
                daemonAction = "status"
                i += 1
            case "--rotate-token":
                daemonAction = "rotate-token"
                i += 1
            case "--port":
                if i + 1 < args.count, let p = UInt16(args[i+1]) {
                    port = p
                    shouldRegenerateAllowedOrigins = true
                    i += 2
                } else {
                    print("Error: Invalid port argument")
                    exit(1)
                }
            case "--token":
                if i + 1 < args.count {
                    token = args[i+1]
                    i += 2
                } else {
                    print("Error: Invalid token argument")
                    exit(1)
                }
            case "--connectors-path":
                if i + 1 < args.count {
                    connectorsPath = args[i+1]
                    i += 2
                } else {
                    print("Error: Invalid connectors-path argument")
                    exit(1)
                }
            case "--public-base-url":
                if i + 1 < args.count {
                    publicBaseURL = args[i+1]
                    shouldRegenerateAllowedOrigins = true
                    i += 2
                } else {
                    print("Error: Invalid public-base-url argument")
                    exit(1)
                }
            case "--bind-host":
                if i + 1 < args.count {
                    bindHost = args[i+1]
                    i += 2
                } else {
                    print("Error: Invalid bind-host argument")
                    exit(1)
                }
            case "--allow-query-token-auth":
                config.allowQueryTokenAuth = true
                i += 1
            default:
                print("Unknown argument: \(args[i])")
                print("Usage: bridgeport [--server] [--port <port>] [--token <token>] [--connectors-path <path>] [--public-base-url <url>] [--bind-host <host>] [--allow-query-token-auth] [--daemon-install] [--daemon-uninstall] [--daemon-status] [--rotate-token]")
                exit(1)
            }
        }

        // Handle daemon actions
        if let action = daemonAction {
            switch action {
            case "status":
                let fileManager = FileManager.default
                let plistExists = fileManager.fileExists(atPath: plistURL.path)
                let binExists = fileManager.fileExists(atPath: destURL.path)
                let isLoaded = isServiceLoaded(label: "com.oliverames.bridgeport", uid: uid)

                print("Bridgeport Daemon Status:")
                print("  - Binary installed: \(binExists ? "Yes (\(destURL.path))" : "No")")
                print("  - Plist registered: \(plistExists ? "Yes (\(plistURL.path))" : "No")")
                print("  - Service loaded:    \(isLoaded ? "Yes (Running)" : "No")")
                exit(0)

            case "install":
                let fileManager = FileManager.default
                print("Installing Bridgeport daemon...")

                if isServiceLoaded(label: "com.oliverames.bridgeport", uid: uid) {
                    print("  Stopping existing daemon...")
                    _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/com.oliverames.bridgeport"])
                }

                do {
                    if !fileManager.fileExists(atPath: binDir.path) {
                        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
                    }

                    let currentExecPath = CommandLine.arguments[0]
                    let currentExecURL = URL(fileURLWithPath: currentExecPath)

                    if fileManager.fileExists(atPath: destURL.path) {
                        try fileManager.removeItem(at: destURL)
                    }

                    try fileManager.copyItem(at: currentExecURL, to: destURL)
                    print("  Copied binary to \(destURL.path)")
                } catch {
                    print("Error: Failed to copy binary: \(error)")
                    exit(1)
                }

                do {
                    if !fileManager.fileExists(atPath: launchAgentsURL.path) {
                        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
                    }
                    let plistData = try LaunchAgentPlist.makeData(
                        label: "com.oliverames.bridgeport",
                        executablePath: destURL.path,
                        stdoutPath: configDirectory.appendingPathComponent("stdout.log").path,
                        stderrPath: configDirectory.appendingPathComponent("stderr.log").path
                    )
                    try plistData.write(to: plistURL, options: .atomic)
                    print("  Wrote plist to \(plistURL.path)")
                } catch {
                    print("Error: Failed to write plist: \(error)")
                    exit(1)
                }

                let result = runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
                if result.status == 0 {
                    print("Successfully installed and started Bridgeport daemon!")
                } else {
                    print("Error: Failed to start daemon (launchctl exit code \(result.status)): \(result.stderr)")
                    exit(1)
                }
                exit(0)

            case "uninstall":
                let fileManager = FileManager.default
                print("Uninstalling Bridgeport daemon...")

                if isServiceLoaded(label: "com.oliverames.bridgeport", uid: uid) {
                    print("  Stopping daemon...")
                    let result = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/com.oliverames.bridgeport"])
                    if result.status != 0 {
                        _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)", plistURL.path])
                    }
                }

                if fileManager.fileExists(atPath: plistURL.path) {
                    do {
                        try fileManager.removeItem(at: plistURL)
                        print("  Removed plist \(plistURL.path)")
                    } catch {
                        print("  Warning: Failed to remove plist: \(error)")
                    }
                }

                if fileManager.fileExists(atPath: destURL.path) {
                    do {
                        try fileManager.removeItem(at: destURL)
                        print("  Removed binary \(destURL.path)")
                    } catch {
                        print("  Warning: Failed to remove binary: \(error)")
                    }
                }

                print("Successfully uninstalled Bridgeport daemon!")
                exit(0)

            case "rotate-token":
                print("Rotating Bridgeport master API token...")
                _ = await configManager.rotateToken()
                print("New master API token generated and saved.")

                if isServiceLoaded(label: "com.oliverames.bridgeport", uid: uid) {
                    print("Restarting daemon to apply changes...")
                    _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/com.oliverames.bridgeport"])
                    let result = runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
                    if result.status == 0 {
                        print("Daemon restarted successfully.")
                    } else {
                        print("Warning: Failed to restart daemon: \(result.stderr)")
                    }
                }
                exit(0)

            default:
                break
            }
        }

        if !isServerMode {
            print("Error: --server is required for command-line server mode.")
            print("Usage: bridgeport [--server] [--port <port>] [--token <token>] [--connectors-path <path>] [--public-base-url <url>] [--bind-host <host>] [--allow-query-token-auth] [--daemon-install] [--daemon-uninstall] [--daemon-status] [--rotate-token]")
            exit(1)
        }

        // Resolve token from env if not set in config/args
        if token == nil {
            token = ProcessInfo.processInfo.environment["BRIDGEPORT_TOKEN"]
        }

        // Generate random token if still nil
        let finalToken: String
        if let t = token {
            finalToken = t
        } else {
            finalToken = ConfigManager.generateSecureToken()
            print("No token provided. Generated and saved a new master API token.")
        }

        config.port = port
        config.token = finalToken
        config.publicBaseURL = publicBaseURL
        config.bindHost = bindHost
        if shouldRegenerateAllowedOrigins || config.allowedOrigins?.isEmpty != false {
            config.allowedOrigins = ConfigManager.defaultAllowedOrigins(port: port, publicBaseURL: publicBaseURL)
        }
        config.connectorsPath = connectorsPath
        config.connectorSettings = config.connectorSettings ?? ConfigManager.settingsFromLegacyDisabled(config.disabledConnectors ?? [])
        config.importedConnectors = config.importedConnectors ?? [:]
        config.onePasswordEnvironment = config.onePasswordEnvironment ?? OnePasswordEnvironmentSettings()
        if loadedExistingConfigFailedToDecode {
            logMessage("Skipping implicit config save because the existing config file could not be decoded.")
        } else {
            await configManager.save(config)
        }

        logMessage("Initializing Bridgeport with connectors path: \(connectorsPath)")
        if let additionalConnectorPaths = config.additionalConnectorPaths, !additionalConnectorPaths.isEmpty {
            logMessage("Additional connector sources: \(additionalConnectorPaths.joined(separator: ", "))")
        }

        let manager = ConnectorManager(config: config)

        let connectors = await manager.discoverConnectors()
        if connectors.isEmpty {
            logMessage("Warning: No connectors found at \(connectorsPath)")
        } else {
            logMessage("Discovered \(connectors.count) connector(s):")
            for connector in connectors {
                logMessage("  - \(connector.name) (\(connector.directoryPath))")
                let routePath = config.publicRoutePath(for: connector)
                let localURL = ConfigManager.mcpEndpointURL(baseURL: "http://localhost:\(port)", routePath: routePath)
                let settings = config.settings(for: connector.name)
                if !settings.enabled {
                    logMessage("    Disabled")
                } else if settings.exposePublicly && !publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let publicBase = ConfigManager.clientEndpointBaseURL(port: port, publicBaseURL: publicBaseURL)
                    logMessage("    Public MCP endpoint: \(ConfigManager.mcpEndpointURL(baseURL: publicBase, routePath: routePath))")
                } else {
                    logMessage("    Local MCP endpoint: \(localURL)")
                }
            }
        }

        await configManager.writeMcpClientConfig(config: config, connectors: connectors)
        await configManager.writeCloudConnectorConfig(config: config, connectors: connectors)

        let server = SSEServer(config: config, manager: manager)

        do {
            try await server.start()
        } catch {
            logMessage("Server error: \(error)")
            exit(1)
        }
    }
}
