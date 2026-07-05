import Foundation

public actor ProcessBridge {
    private static let stdoutQueue = DispatchQueue(label: "com.oliverames.bridgeport.processbridge.stdout", qos: .utility, attributes: .concurrent)
    private static let stderrQueue = DispatchQueue(label: "com.oliverames.bridgeport.processbridge.stderr", qos: .utility, attributes: .concurrent)
    private static let waitQueue = DispatchQueue(label: "com.oliverames.bridgeport.processbridge.wait", qos: .utility, attributes: .concurrent)

    private let connector: Connector
    private let env: [String: String]
    // Serial per-bridge queue so stdin writes stay ordered without blocking
    // Swift's cooperative executor when the subprocess pipe is full.
    private let stdinQueue = DispatchQueue(label: "com.oliverames.bridgeport.processbridge.stdin", qos: .utility)
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
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = Self.envLaunchArguments(for: connector)
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

        // These loops call blocking POSIX APIs, so keep them off Swift's cooperative executor.
        Self.stdoutQueue.async {
            Self.readStdoutLoop(pipe: stdout, onMessage: onMessage)
        }

        // Drain stderr so subprocesses cannot block on a full pipe. Connector stderr may contain
        // credentials, so Bridgeport intentionally does not persist the contents.
        Self.stderrQueue.async {
            Self.drainStderrLoop(pipe: stderr)
        }

        Self.waitQueue.async { [weak self] in
            proc.waitUntilExit()
            Task {
                await self?.handleExit()
            }
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
        let data = Data(line.utf8)
        let name = connector.name
        stdinQueue.async {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                logMessage("ProcessBridge.write: failed to write to \(name) stdin: \(error)")
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        let proc = process
        let stdin = stdinPipe
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        // Close stdin first so well-behaved MCP servers exit on EOF, then
        // terminate, then escalate to SIGKILL if the process ignores SIGTERM.
        stdinQueue.async {
            try? stdin?.fileHandleForWriting.close()
        }
        if let proc, proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            Self.waitQueue.asyncAfter(deadline: .now() + 5) {
                if proc.isRunning {
                    logMessage("ProcessBridge.stop: process \(pid) ignored SIGTERM, sending SIGKILL")
                    kill(pid, SIGKILL)
                }
            }
        }
        onExit?()
    }

    private func handleExit() {
        guard isRunning else { return }
        isRunning = false
        onExit?()
    }

    // Cap on a single newline-delimited JSON-RPC message. A connector that
    // streams an unterminated line cannot balloon daemon memory.
    private static let maxLineBytes = 32 * 1024 * 1024

    private static func readStdoutLoop(pipe: Pipe, onMessage: @escaping @Sendable (String) -> Void) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var buffer = Data()
        var tempBuffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fd, &tempBuffer, tempBuffer.count)
            if bytesRead <= 0 {
                logMessage("ProcessBridge.readStdoutLoop: POSIX read returned \(bytesRead) (EOF or error)")
                break
            }
            let data = Data(tempBuffer.prefix(bytesRead))
            buffer.append(data)

            if buffer.count > maxLineBytes, !buffer.contains(10) {
                logMessage("ProcessBridge.readStdoutLoop: dropping oversized unterminated output line (\(buffer.count) bytes)")
                buffer.removeAll(keepingCapacity: false)
                continue
            }

            // Parse newline delimited messages
            while let newlineIndex = buffer.firstIndex(of: 10) { // 10 is '\n'
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                if let line = String(data: lineData, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onMessage(trimmed)
                    }
                }
            }
        }
    }

    static func envLaunchArguments(for connector: Connector) -> [String] {
        [connector.command] + connector.args
    }

    private static func drainStderrLoop(pipe: Pipe) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var tempBuffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fd, &tempBuffer, tempBuffer.count)
            if bytesRead <= 0 {
                break
            }
        }
    }
}
