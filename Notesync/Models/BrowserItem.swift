import Foundation

struct BrowserItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case folder
        case note
    }

    let kind: Kind
    let relativePath: String
    let name: String
    let emoji: String
    let accentStyle: AccentStyle
    let isFavorite: Bool
    let modifiedAt: Date
    let children: [BrowserItem]

    var id: String { "\(kind.rawValue):\(relativePath)" }
    var isFolder: Bool { kind == .folder }
    var childItems: [BrowserItem]? { children.isEmpty ? nil : children }
}
