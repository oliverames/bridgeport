import Foundation

public struct LaunchAgentCommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool {
        status == 0
    }
}

public enum LaunchAgentManager {
    public static func isLoaded(label: String, uid: UInt32) -> Bool {
        let result = runShell("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
        return result.status == 0
    }

    @discardableResult
    public static func bootout(label: String, uid: UInt32, plistURL: URL? = nil) -> LaunchAgentCommandResult {
        let labelResult = commandResult(runShell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]))
        if labelResult.succeeded {
            waitUntilUnloaded(label: label, uid: uid)
            return labelResult
        }

        guard let plistURL else {
            return labelResult
        }

        let plistResult = commandResult(runShell("/bin/launchctl", ["bootout", "gui/\(uid)", plistURL.path]))
        if plistResult.succeeded {
            waitUntilUnloaded(label: label, uid: uid)
            return plistResult
        }

        return labelResult
    }

    @discardableResult
    public static func bootstrap(label: String, uid: UInt32, plistURL: URL, attempts: Int = 5) -> LaunchAgentCommandResult {
        let clampedAttempts = max(1, attempts)
        var lastResult = LaunchAgentCommandResult(status: -1, stdout: "", stderr: "launchctl bootstrap was not attempted")

        for attempt in 0..<clampedAttempts {
            let result = commandResult(runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path]))
            lastResult = result

            if result.succeeded || isLoaded(label: label, uid: uid) || result.stderr.localizedCaseInsensitiveContains("service is already loaded") {
                return LaunchAgentCommandResult(status: 0, stdout: result.stdout, stderr: result.stderr)
            }

            if attempt < clampedAttempts - 1 {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        return lastResult
    }

    @discardableResult
    public static func restart(label: String, uid: UInt32, plistURL: URL) -> LaunchAgentCommandResult {
        if isLoaded(label: label, uid: uid) {
            bootout(label: label, uid: uid, plistURL: plistURL)
        }
        return bootstrap(label: label, uid: uid, plistURL: plistURL)
    }

    private static func commandResult(_ result: (status: Int32, stdout: String, stderr: String)) -> LaunchAgentCommandResult {
        LaunchAgentCommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }

    private static func waitUntilUnloaded(label: String, uid: UInt32) {
        for attempt in 0..<5 {
            if !isLoaded(label: label, uid: uid) {
                return
            }

            if attempt < 4 {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}
