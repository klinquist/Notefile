import Foundation

enum AppPreferences {
    static let newEntryThresholdMinutesKey = "Settings.NewEntryThresholdMinutes"
    static let noteFontSizeKey = "Settings.NoteFontSize"

    static let defaultNewEntryThresholdMinutes = 0
    static let defaultNoteFontSize = 17.0
    static let minimumNoteFontSize = 12.0
    static let maximumNoteFontSize = 30.0

    static func newEntryThresholdMinutes() -> Int {
        normalizedNewEntryThresholdMinutes(
            UserDefaults.standard.object(forKey: newEntryThresholdMinutesKey) as? Int
                ?? defaultNewEntryThresholdMinutes
        )
    }

    static func noteFontSize() -> Double {
        normalizedNoteFontSize(
            UserDefaults.standard.object(forKey: noteFontSizeKey) as? Double
                ?? defaultNoteFontSize
        )
    }

    static func normalizedNewEntryThresholdMinutes(_ value: Int) -> Int {
        min(max(value, 0), 60)
    }

    static func normalizedNoteFontSize(_ value: Double) -> Double {
        min(max(value, minimumNoteFontSize), maximumNoteFontSize)
    }
}
