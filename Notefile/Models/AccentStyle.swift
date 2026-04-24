import SwiftUI

enum AccentStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case coral
    case amber
    case lemon
    case mint
    case sky
    case ocean
    case rose
    case slate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coral: "Coral"
        case .amber: "Amber"
        case .lemon: "Lemon"
        case .mint: "Mint"
        case .sky: "Sky"
        case .ocean: "Ocean"
        case .rose: "Rose"
        case .slate: "Slate"
        }
    }

    var color: Color {
        switch self {
        case .coral: Color(red: 0.95, green: 0.43, blue: 0.34)
        case .amber: Color(red: 0.91, green: 0.61, blue: 0.17)
        case .lemon: Color(red: 0.84, green: 0.78, blue: 0.28)
        case .mint: Color(red: 0.28, green: 0.73, blue: 0.55)
        case .sky: Color(red: 0.29, green: 0.64, blue: 0.88)
        case .ocean: Color(red: 0.16, green: 0.43, blue: 0.86)
        case .rose: Color(red: 0.83, green: 0.33, blue: 0.52)
        case .slate: Color(red: 0.40, green: 0.48, blue: 0.60)
        }
    }
}
