import Foundation

/// Resolves the app language independently from the system localization bundle.
enum InterfaceLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    nonisolated static let storageKey = "interface.language"

    var id: Self { self }

    nonisolated var locale: Locale {
        Locale(identifier: rawValue)
    }

    nonisolated var displayName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        case .japanese:
            return "日本語"
        }
    }

    /// Language name used in AI instructions so responses follow the
    /// interface language.
    nonisolated var aiLanguageName: String {
        switch self {
        case .simplifiedChinese:
            return "Simplified Chinese"
        case .english:
            return "English"
        case .japanese:
            return "Japanese"
        }
    }

    nonisolated static var preferredForSystem: InterfaceLanguage {
        guard let preferredLanguage = Locale.preferredLanguages.first else {
            return .english
        }

        if preferredLanguage.hasPrefix("zh") {
            return .simplifiedChinese
        }
        if preferredLanguage.hasPrefix("ja") {
            return .japanese
        }
        return .english
    }

    nonisolated static var current: InterfaceLanguage {
        let storedValue = UserDefaults.standard.string(forKey: storageKey)
        return storedValue.flatMap(InterfaceLanguage.init(rawValue:)) ?? preferredForSystem
    }

    nonisolated func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return key
        }

        return languageBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    nonisolated func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(key),
            locale: locale,
            arguments: arguments
        )
    }
}
