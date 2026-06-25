import Foundation
import Observation

#if os(macOS)
import Darwin
#endif

@Observable
@MainActor
public final class AppState {
    public var port: String = "8080"
    public var connectorsPath: String = ""
    public var token: String = ""
    public var env: [String: String] = [:]
    public var discoveredConnectors: [Connector] = []
    public var disabledConnectors: Set<String> = []
    
    public var isDaemonInstalled: Bool = false
    public var isDaemonRunning: Bool = false
    public var isShowingToken: Bool = false
    
    private let configManager = ConfigManager()
    
    #if os(macOS)
    private let uid = getuid()
    #else
    private let uid: UInt32 = 0
    #endif
    
    private let label = "com.oliverames.bridgeport"
    
    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    
    private var destURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/bridgeport/bin/bridgeport")
    }
    
    public init() {
        Task {
            await reload()
        }
    }
    
    @MainActor
    public func reload() async {
        logMessage("AppState.reload: Loading configuration...")
        let config = await configManager.load()
        self.port = String(config.port ?? 8080)
        self.connectorsPath = config.connectorsPath ?? "/Users/oliverames/Developer/Projects/ames-connectors/plugins"
        self.token = config.token ?? ""
        self.env = config.env ?? [:]
        self.disabledConnectors = Set(config.disabledConnectors ?? [])
        logMessage("AppState.reload: Loaded port=\(self.port), path=\(self.connectorsPath)")
        
        logMessage("AppState.reload: Discovering connectors...")
        let connectorManager = ConnectorManager(connectorsPath: self.connectorsPath)
        self.discoveredConnectors = await connectorManager.discoverConnectors()
        logMessage("AppState.reload: Discovered \(self.discoveredConnectors.count) connectors")
        
        // Write standard client MCP config file
        await configManager.writeMcpClientConfig(
            port: UInt16(self.port) ?? 8080,
            token: self.token,
            connectors: self.discoveredConnectors,
            disabledConnectors: Array(self.disabledConnectors)
        )
        
        logMessage("AppState.reload: Checking daemon status...")
        checkDaemonStatus()
        logMessage("AppState.reload: Daemon status - installed: \(self.isDaemonInstalled), running: \(self.isDaemonRunning)")
    }
    
    @MainActor
    public func save() async {
        let portUInt = UInt16(self.port) ?? 8080
        let config = BridgeportConfig(
            token: self.token,
            port: portUInt,
            connectorsPath: self.connectorsPath,
            env: self.env,
            disabledConnectors: Array(self.disabledConnectors)
        )
        await configManager.save(config)
        
        // Regenerate the client MCP config file locally
        await configManager.writeMcpClientConfig(
            port: portUInt,
            token: self.token,
            connectors: self.discoveredConnectors,
            disabledConnectors: Array(self.disabledConnectors)
        )
        
        // If daemon is running, restart it to apply the new port/path/env
        if isDaemonRunning {
            await restartDaemon()
        }
    }
    
    @MainActor
    public func toggleConnector(_ name: String) async {
        if disabledConnectors.contains(name) {
            disabledConnectors.remove(name)
        } else {
            disabledConnectors.insert(name)
        }
        await save()
    }
    
    @MainActor
    public func rotateToken() async {
        let newToken = await configManager.rotateToken()
        self.token = newToken
        if isDaemonRunning {
            await restartDaemon()
        }
    }
    
    @MainActor
    public func checkDaemonStatus() {
        let fileManager = FileManager.default
        let plistExists = fileManager.fileExists(atPath: plistURL.path)
        let binExists = fileManager.fileExists(atPath: destURL.path)
        
        self.isDaemonInstalled = plistExists && binExists
        
        let result = runShell("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
        self.isDaemonRunning = (result.status == 0)
    }
    
    @MainActor
    public func installDaemon() async {
        let fileManager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binDir = home.appendingPathComponent(".config/bridgeport/bin")
        let launchAgentsURL = home.appendingPathComponent("Library/LaunchAgents")
        
        if isDaemonRunning {
            _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        }
        
        do {
            if !fileManager.fileExists(atPath: binDir.path) {
                try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
            }
            
            // Get currently running executable (either main binary or inside bundle Contents/MacOS/)
            guard let currentExecURL = Bundle.main.executableURL else {
                logMessage("AppState.installDaemon: Failed to find Bundle.main.executableURL")
                return
            }
            
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            
            try fileManager.copyItem(at: currentExecURL, to: destURL)
            logMessage("AppState: Copied binary to \(destURL.path)")
        } catch {
            logMessage("AppState: Failed to copy binary: \(error)")
            return
        }
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
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
        } catch {
            logMessage("AppState: Failed to write plist: \(error)")
            return
        }
        
        let result = runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if result.status != 0 {
            logMessage("AppState: Failed to start daemon launchctl exit code \(result.status): \(result.stderr)")
        }
        
        checkDaemonStatus()
    }
    
    @MainActor
    public func uninstallDaemon() async {
        let fileManager = FileManager.default
        
        if isDaemonRunning {
            let result = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
            if result.status != 0 {
                _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)", plistURL.path])
            }
        }
        
        if fileManager.fileExists(atPath: plistURL.path) {
            try? fileManager.removeItem(at: plistURL)
        }
        
        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }
        
        checkDaemonStatus()
    }
    
    @MainActor
    public func restartDaemon() async {
        if isDaemonRunning {
            _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        }
        
        let result = runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if result.status != 0 {
            logMessage("AppState: Failed to restart daemon: \(result.stderr)")
        }
        
        checkDaemonStatus()
    }
}
