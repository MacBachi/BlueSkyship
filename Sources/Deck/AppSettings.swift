import Foundation
import Observation

enum PostTextSize: String, CaseIterable, Sendable {
    case small, standard, large, extraLarge

    var points: CGFloat {
        switch self {
        case .small: return 12
        case .standard: return 13
        case .large: return 15
        case .extraLarge: return 17
        }
    }

    var label: String {
        switch self {
        case .small: return tr("Klein", "Small")
        case .standard: return tr("Standard", "Standard")
        case .large: return tr("Groß", "Large")
        case .extraLarge: return tr("Sehr groß", "Extra large")
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static var refreshChoices: [(seconds: Int, label: String)] {
        [
        (30, tr("30 Sekunden", "30 seconds")), (60, tr("1 Minute", "1 minute")), (120, tr("2 Minuten", "2 minutes")), (300, tr("5 Minuten", "5 minutes")), (0, tr("Nie", "Never")),
        ]
    }
    static var languageChoices: [(code: String, label: String)] {
        [
        ("", tr("Automatisch (Systemsprache)", "Automatic (system language)")), ("de", tr("Deutsch", "German")), ("en", tr("Englisch", "English")),
        ("fr", tr("Französisch", "French")), ("es", tr("Spanisch", "Spanish")), ("it", tr("Italienisch", "Italian")),
        ]
    }

    private enum Key {
        static let refresh = "settings.refreshSeconds"
        static let showMedia = "settings.showMedia"
        static let width = "settings.defaultWidth"
        static let language = "settings.postLanguage"
        static let keyboard = "settings.keyboardShortcuts"
        static let dockBadge = "settings.dockBadge"
        static let systemNotifications = "settings.systemNotifications"
        static let textSize = "settings.textSize"
        static let requireAltText = "settings.requireAltText"
        static let iCloudSync = "settings.iCloudSync"
    }

    private let defaults: UserDefaults

    /// 0 turns automatic updates off.
    var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: Key.refresh) } }
    /// When off, posts show a compact button instead of pictures, for a calmer deck.
    var showMedia: Bool { didSet { defaults.set(showMedia, forKey: Key.showMedia) } }
    var defaultWidth: ColumnWidth { didSet { defaults.set(defaultWidth.rawValue, forKey: Key.width) } }
    /// Language tag on new posts; empty follows the system.
    var postLanguage: String { didSet { defaults.set(postLanguage, forKey: Key.language) } }

    /// Single-key commands such as `j` and `l`. Off for anyone who hits them by accident.
    var keyboardShortcuts: Bool { didSet { defaults.set(keyboardShortcuts, forKey: Key.keyboard) } }
    var showDockBadge: Bool { didSet { defaults.set(showDockBadge, forKey: Key.dockBadge) } }
    /// Off until asked for, because macOS has to request permission first.
    var showSystemNotifications: Bool { didSet { defaults.set(showSystemNotifications, forKey: Key.systemNotifications) } }
    var textSize: PostTextSize { didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) } }

    var requireAltText: Bool { didSet { defaults.set(requireAltText, forKey: Key.requireAltText) } }
    /// Favorites, decks and draft text. Sign-ins and pictures stay on each Mac.
    var iCloudSync: Bool { didSet { defaults.set(iCloudSync, forKey: Key.iCloudSync) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requireAltText = defaults.object(forKey: Key.requireAltText) as? Bool ?? false
        iCloudSync = defaults.object(forKey: Key.iCloudSync) as? Bool ?? true
        keyboardShortcuts = defaults.object(forKey: Key.keyboard) as? Bool ?? true
        showDockBadge = defaults.object(forKey: Key.dockBadge) as? Bool ?? true
        showSystemNotifications = defaults.object(forKey: Key.systemNotifications) as? Bool ?? false
        textSize = defaults.string(forKey: Key.textSize).flatMap(PostTextSize.init(rawValue:)) ?? .standard
        refreshSeconds = defaults.object(forKey: Key.refresh) as? Int ?? 60
        showMedia = defaults.object(forKey: Key.showMedia) as? Bool ?? true
        defaultWidth = defaults.string(forKey: Key.width).flatMap(ColumnWidth.init(rawValue:)) ?? .medium
        postLanguage = defaults.string(forKey: Key.language) ?? ""
    }

    /// The language to tag a new post with, or `nil` when the system does not name one.
    var effectivePostLanguage: String? {
        postLanguage.isEmpty ? Locale.current.language.languageCode?.identifier : postLanguage
    }
}
