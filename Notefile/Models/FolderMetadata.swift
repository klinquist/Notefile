import Foundation

struct FolderMetadata: Codable, Equatable {
    var emoji: String
    var accentStyle: AccentStyle

    static let `default` = FolderMetadata(emoji: "📁", accentStyle: .sky)
}

struct NoteMetadata: Codable, Equatable {
    var emoji: String
    var accentStyle: AccentStyle

    static let `default` = NoteMetadata(emoji: "📝", accentStyle: .mint)
}
