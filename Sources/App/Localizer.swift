import Foundation
import Observation

enum AppLanguage: String, Sendable {
    case german = "de"
    case english = "en"
}

enum LanguagePreference: String, CaseIterable, Sendable {
    case system, german, english

    /// Each language in its own name, so people can find theirs even in the wrong language.
    var label: String {
        switch self {
        case .system: return tr("Wie System", "Same as system")
        case .german: return "Deutsch"
        case .english: return "English"
        }
    }
}

/// Holds the app's language. It is observable, so every view that shows a `tr` text
/// redraws by itself when the language changes, without a restart and without losing state.
@Observable
final class Localizer: @unchecked Sendable {
    static let shared = Localizer()
    private static let key = "settings.appLanguage"

    private(set) var language: AppLanguage

    var preference: LanguagePreference {
        didSet {
            language = Self.resolve(preference, systemLanguages: Locale.preferredLanguages)
            guard !RuntimeEnvironment.isUnitTestHost else { return }
            UserDefaults.standard.set(preference.rawValue, forKey: Self.key)
        }
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key).flatMap(LanguagePreference.init(rawValue:))
        let preference = stored ?? .system
        self.preference = preference
        language = Self.resolve(preference, systemLanguages: Locale.preferredLanguages)
    }

    /// German when the system prefers it, otherwise English as the common fallback.
    static func resolve(_ preference: LanguagePreference, systemLanguages: [String]) -> AppLanguage {
        switch preference {
        case .german: return .german
        case .english: return .english
        case .system:
            return systemLanguages.first?.lowercased().hasPrefix("de") == true ? .german : .english
        }
    }
}

/// A text in both languages. Keeping the pair together means no text can lack a translation.
func tr(_ german: String, _ english: String) -> String {
    Localizer.shared.language == .german ? german : english
}
