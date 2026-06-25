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
        process.waitUntilExit()
        
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        
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
        let configManager = ConfigManager()
        var config = await configManager.load()
        
        var port: UInt16 = config.port ?? 8080
        var token: String? = config.token
        var connectorsPath: String = config.connectorsPath ?? "/Users/oliverames/Developer/Projects/ames-connectors/plugins"
        
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsURL = home.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentsURL.appendingPathComponent("com.oliverames.bridgeport.plist")
        let binDir = home.appendingPathComponent(".config/bridgeport/bin")
        let destURL = binDir.appendingPathComponent("bridgeport")
        
        #if os(macOS)
        let uid = getuid()
        #else
        let uid: uid_t = 0
        #endif
        
        var daemonAction: String? = nil
        var isServerMode = false
        
        let args = CommandLine.arguments
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
            default:
                print("Unknown argument: \(args[i])")
                print("Usage: bridgeport [--port <port>] [--token <token>] [--connectors-path <path>] [--daemon-install] [--daemon-uninstall] [--daemon-status] [--rotate-token] [--server]")
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
                
                let plistContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>com.oliverames.bridgeport</string>
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
                    <string>\(home.path)/.config/bridgeport/stdout.log</string>
                    <key>StandardErrorPath</key>
                    <string>\(home.path)/.config/bridgeport/stderr.log</string>
                </dict>
                </plist>
                """
                
                do {
                    if !fileManager.fileExists(atPath: launchAgentsURL.path) {
                        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
                    }
                    try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
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
                let newToken = await configManager.rotateToken()
                print("New master API token generated and saved: \(newToken)")
                
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
            #if os(macOS)
            BridgeportApp.main()
            #else
            print("GUI mode is only supported on macOS.")
            exit(1)
            #endif
            return
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
            print("No token provided. Generated temporary secure token for this session:")
            print("\n  \(finalToken)\n")
        }
        
        // Update config with the selected values if we are running in interactive/server mode
        config.port = port
        config.token = finalToken
        config.connectorsPath = connectorsPath
        await configManager.save(config)
        
        logMessage("Initializing Bridgeport with connectors path: \(connectorsPath)")
        
        let manager = ConnectorManager(connectorsPath: connectorsPath)
        
        // Discover connectors
        let connectors = await manager.discoverConnectors()
        if connectors.isEmpty {
            logMessage("Warning: No connectors found at \(connectorsPath)")
        } else {
            logMessage("Discovered \(connectors.count) connector(s):")
            for connector in connectors {
                logMessage("  - \(connector.name) (\(connector.directoryPath))")
                logMessage("    Public URL: http://localhost:\(port)/\(connector.name)/sse?token=\(finalToken)")
            }
        }
        
        let disabledConnectors = config.disabledConnectors ?? []
        
        // Write the client MCP config file for other applications/clients to read
        await configManager.writeMcpClientConfig(port: port, token: finalToken, connectors: connectors, disabledConnectors: disabledConnectors)
        
        let server = SSEServer(port: port, token: finalToken, manager: manager, disabledConnectors: disabledConnectors)
        
        do {
            try await server.start()
        } catch {
            logMessage("Server error: \(error)")
            exit(1)
        }
    }
}
