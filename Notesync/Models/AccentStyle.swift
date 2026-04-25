import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AccentStyle: Codable, Identifiable, Hashable {
    case coral
    case amber
    case lemon
    case mint
    case sky
    case ocean
    case rose
    case slate
    case custom(String)

    static let allCases: [AccentStyle] = [
        .coral,
        .amber,
        .lemon,
        .mint,
        .sky,
        .ocean,
        .rose,
        .slate
    ]

    var id: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "coral": self = .coral
        case "amber": self = .amber
        case "lemon": self = .lemon
        case "mint": self = .mint
        case "sky": self = .sky
        case "ocean": self = .ocean
        case "rose": self = .rose
        case "slate": self = .slate
        default:
            guard let hexValue = Self.normalizedHex(rawValue) else { return nil }
            self = .custom(hexValue)
        }
    }

    var rawValue: String {
        switch self {
        case .coral: "coral"
        case .amber: "amber"
        case .lemon: "lemon"
        case .mint: "mint"
        case .sky: "sky"
        case .ocean: "ocean"
        case .rose: "rose"
        case .slate: "slate"
        case let .custom(hexValue): Self.normalizedHex(hexValue) ?? "#667085"
        }
    }

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
        case .custom: "Custom"
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
        case let .custom(hexValue): Self.color(from: hexValue) ?? Color(red: 0.40, green: 0.48, blue: 0.60)
        }
    }

    static func custom(from color: Color) -> AccentStyle {
        .custom(hexString(from: color) ?? "#667085")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = AccentStyle(rawValue: rawValue) ?? .slate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func normalizedHex(_ value: String) -> String? {
        let raw = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "custom:", with: "")
            .replacingOccurrences(of: "#", with: "")
        guard raw.count == 6,
              raw.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        return "#\(raw.uppercased())"
    }

    private static func color(from hexValue: String) -> Color? {
        guard let normalized = normalizedHex(hexValue) else { return nil }
        let hex = String(normalized.dropFirst())
        guard let value = Int(hex, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }

    private static func hexString(from color: Color) -> String? {
#if os(iOS)
        let resolvedColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
#elseif os(macOS)
        guard let resolvedColor = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = resolvedColor.redComponent
        let green = resolvedColor.greenComponent
        let blue = resolvedColor.blueComponent
#else
        return nil
#endif
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
