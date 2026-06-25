import Foundation

struct StderrStream: TextOutputStream {
    mutating func write(_ string: String) {
        fputs(string, stderr)
        fflush(stderr)
    }
}

public func logMessage(_ message: String) {
    var stderrStream = StderrStream()
    print("[\(Date())] \(message)", to: &stderrStream)
}
