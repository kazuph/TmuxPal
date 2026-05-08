import Foundation

public enum AppSupport {
    public static let bundleIdentifier = "dev.tmuxpal"
    public static let appName = "tmuxpal"

    public static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tmuxpal")
    }

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
