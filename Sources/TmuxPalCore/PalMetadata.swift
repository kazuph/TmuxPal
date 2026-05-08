import Foundation

public struct PalRequest: Decodable, Sendable {
    public let palId: String?
    public let displayName: String
    public let rows: [AnimationRow]?
    public let spritesheetPath: String?

    enum CodingKeys: String, CodingKey {
        case palId = "pal_id"
        case id
        case displayName = "display_name"
        case manifestDisplayName = "displayName"
        case rows
        case spritesheetPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        palId = try container.decodeIfPresent(String.self, forKey: .palId)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .manifestDisplayName)
            ?? palId
            ?? "Pal"
        rows = try container.decodeIfPresent([AnimationRow].self, forKey: .rows)
        spritesheetPath = try container.decodeIfPresent(String.self, forKey: .spritesheetPath)
    }
}

public struct AnimationRow: Decodable, Equatable, Sendable {
    public let state: String
    public let row: Int
    public let frames: Int
}

public struct PalAssetConfig: Sendable {
    public let spritesheetURL: URL
    public let metadataURL: URL

    public init(
        spritesheetURL: URL? = nil,
        metadataURL: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/tmuxpal/characters/dokochan/pal.json")
    ) {
        self.metadataURL = metadataURL
        self.spritesheetURL = spritesheetURL ?? Self.defaultSpritesheetURL(metadataURL: metadataURL)
    }

    private static func defaultSpritesheetURL(metadataURL: URL) -> URL {
        if let data = try? Data(contentsOf: metadataURL),
           let request = try? JSONDecoder().decode(PalRequest.self, from: data),
           let spritesheetPath = request.spritesheetPath,
           !spritesheetPath.isEmpty {
            let url = URL(
                fileURLWithPath: spritesheetPath,
                relativeTo: metadataURL.deletingLastPathComponent()
            ).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let png = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/tmuxpal/characters/dokochan/spritesheet.png")
        if FileManager.default.fileExists(atPath: png.path) {
            return png
        }
        return URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/tmuxpal/characters/dokochan/spritesheet.webp")
    }

    public func loadRows() -> [AnimationRow] {
        guard let data = try? Data(contentsOf: metadataURL),
              let request = try? JSONDecoder().decode(PalRequest.self, from: data) else {
            return Self.defaultRows
        }
        return request.rows ?? Self.defaultRows
    }

    public static let defaultRows: [AnimationRow] = [
        AnimationRow(state: "idle", row: 0, frames: 6),
        AnimationRow(state: "running-right", row: 1, frames: 8),
        AnimationRow(state: "running-left", row: 2, frames: 8),
        AnimationRow(state: "waving", row: 3, frames: 4),
        AnimationRow(state: "jumping", row: 4, frames: 5),
        AnimationRow(state: "failed", row: 5, frames: 8),
        AnimationRow(state: "waiting", row: 6, frames: 6),
        AnimationRow(state: "running", row: 7, frames: 6),
        AnimationRow(state: "review", row: 8, frames: 6)
    ]
}
