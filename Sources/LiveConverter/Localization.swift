import Foundation

/// Minimal in-code localization: picks English or Chinese from the system language.
/// (An SPM-packaged .app can't rely on .lproj bundles, so strings live in code.)
enum L {
    static var isChinese: Bool {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
    }

    /// Return the Chinese string when the system is Chinese, otherwise English.
    static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
