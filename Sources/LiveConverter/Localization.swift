import Foundation

/// Minimal in-code localization: English or Chinese.
/// Language follows an in-app preference ("auto" | "en" | "zh"); "auto" uses the
/// system language. (An SPM-packaged .app can't rely on .lproj bundles, so strings
/// live in code.)
enum L {
    /// UserDefaults key shared with the in-app language picker (@AppStorage).
    static let prefKey = "liveconverter.lang"

    static var isChinese: Bool {
        switch UserDefaults.standard.string(forKey: prefKey) {
        case "zh": return true
        case "en": return false
        default:   return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
        }
    }

    /// Return the Chinese string when Chinese is active, otherwise English.
    static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
