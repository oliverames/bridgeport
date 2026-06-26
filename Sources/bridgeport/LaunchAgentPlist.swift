import Foundation

public enum LaunchAgentPlist {
    public static func makeData(
        label: String,
        executablePath: String,
        stdoutPath: String,
        stderrPath: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                executablePath,
                "--server"
            ],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath
        ]

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
