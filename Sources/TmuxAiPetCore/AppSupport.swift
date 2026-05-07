import Foundation

public enum AppSupport {
    public static let bundleIdentifier = "com.kazuph.tmux-ai-pet"
    public static let appName = "tmux-ai-pet"

    public static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tmux-ai-pet")
    }

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
