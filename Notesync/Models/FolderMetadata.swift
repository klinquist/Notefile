import Foundation

struct FolderMetadata: Codable, Equatable {
    var emoji: String
    var accentStyle: AccentStyle
    var isFavorite: Bool

    static let `default` = FolderMetadata(emoji: "📁", accentStyle: .sky, isFavorite: false)

    init(emoji: String, accentStyle: AccentStyle, isFavorite: Bool = false) {
        self.emoji = emoji
        self.accentStyle = accentStyle
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case emoji
        case accentStyle
        case isFavorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decode(String.self, forKey: .emoji)
        accentStyle = try container.decode(AccentStyle.self, forKey: .accentStyle)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

struct NoteMetadata: Codable, Equatable {
    var emoji: String
    var accentStyle: AccentStyle
    var isFavorite: Bool

    static let `default` = NoteMetadata(emoji: "📝", accentStyle: .mint, isFavorite: false)

    init(emoji: String, accentStyle: AccentStyle, isFavorite: Bool = false) {
        self.emoji = emoji
        self.accentStyle = accentStyle
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case emoji
        case accentStyle
        case isFavorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decode(String.self, forKey: .emoji)
        accentStyle = try container.decode(AccentStyle.self, forKey: .accentStyle)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}
