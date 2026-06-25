import Foundation

public actor ProcessBridge {
    private let connector: Connector
    private let env: [String: String]
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    
    private var isRunning = false
    private var onMessage: (@Sendable (String) -> Void)?
    private var onExit: (@Sendable () -> Void)?
    
    public init(connector: Connector, env: [String: String]) {
        self.connector = connector
        self.env = env
    }
    
    public func start(onMessage: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable () -> Void) throws {
        logMessage("ProcessBridge.start called for \(connector.name)")
        guard !isRunning else { return }
        
        self.onMessage = onMessage
        self.onExit = onExit
        
        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: connector.directoryPath)
        
        // Spawn through bash login shell to ensure path and environment variables (NVM, node, npm) are resolved correctly.
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        
        let cmdStr = "'\(connector.command)' " + connector.args.map { "'\($0)'" }.joined(separator: " ")
        proc.arguments = ["-l", "-c", cmdStr]
        proc.environment = env
        
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc
        self.isRunning = true
        
        try proc.run()
        logMessage("ProcessBridge.start: process spawned successfully (pid: \(proc.processIdentifier))")
        
        // Start reading stdout line-by-line (runs in static/nonisolated context in detached tasks to prevent deadlocks)
        let connectorName = connector.name
        Task.detached {
            await Self.readStdoutLoop(pipe: stdout, onMessage: onMessage)
        }
        
        // Start reading stderr for logs
        Task.detached {
            await Self.readStderrLoop(pipe: stderr, connectorName: connectorName)
        }
        
        // Wait for exit (runs in a detached task off the actor context to prevent blocking)
        Task.detached { [weak self] in
            proc.waitUntilExit()
            await self?.handleExit()
        }
    }
    
    public func write(_ message: String) {
        logMessage("ProcessBridge.write called with length \(message.count)")
        guard isRunning, let stdinPipe = stdinPipe else {
            logMessage("ProcessBridge.write failed: isRunning=\(isRunning), stdinPipe=\(stdinPipe != nil)")
            return
        }
        var line = message
        if !line.hasSuffix("\n") {
            line.append("\n")
        }
        if let data = line.data(using: .utf8) {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                logMessage("ProcessBridge.write: successfully wrote bytes to stdin")
            } catch {
                logMessage("ProcessBridge.write: failed to write: \(error)")
                print("[\(connector.name)] Failed to write to stdin: \(error)")
            }
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        onExit?()
    }
    
    private func handleExit() {
        guard isRunning else { return }
        isRunning = false
        onExit?()
    }
    
    private static func readStdoutLoop(pipe: Pipe, onMessage: @escaping @Sendable (String) -> Void) async {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var buffer = Data()
        var tempBuffer = [UInt8](repeating: 0, count: 4096)
        
        while true {
            logMessage("ProcessBridge.readStdoutLoop: calling POSIX read")
            let bytesRead = read(fd, &tempBuffer, tempBuffer.count)
            if bytesRead <= 0 {
                logMessage("ProcessBridge.readStdoutLoop: POSIX read returned \(bytesRead) (EOF or error)")
                break
            }
            let data = Data(tempBuffer.prefix(bytesRead))
            buffer.append(data)
            
            // Parse newline delimited messages
            while let newlineIndex = buffer.firstIndex(of: 10) { // 10 is '\n'
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(0...newlineIndex)
                
                if let line = String(data: lineData, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        logMessage("ProcessBridge.readStdoutLoop: read line: \(trimmed)")
                        onMessage(trimmed)
                    }
                }
            }
        }
    }
    
    private static func readStderrLoop(pipe: Pipe, connectorName: String) async {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var buffer = Data()
        var tempBuffer = [UInt8](repeating: 0, count: 4096)
        
        while true {
            logMessage("ProcessBridge.readStderrLoop: calling POSIX read")
            let bytesRead = read(fd, &tempBuffer, tempBuffer.count)
            if bytesRead <= 0 {
                logMessage("ProcessBridge.readStderrLoop: POSIX read returned \(bytesRead) (EOF or error)")
                break
            }
            let data = Data(tempBuffer.prefix(bytesRead))
            buffer.append(data)
            
            while let newlineIndex = buffer.firstIndex(of: 10) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(0...newlineIndex)
                
                if let line = String(data: lineData, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        logMessage("ProcessBridge.readStderrLoop: [\(connectorName) stderr] \(trimmed)")
                        print("[\(connectorName) stderr] \(trimmed)")
                    }
                }
            }
        }
    }
}
