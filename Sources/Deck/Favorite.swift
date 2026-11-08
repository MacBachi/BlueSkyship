import Foundation

/// Something to look at now and then, without it taking up a column all the time.
struct Favorite: Codable, Identifiable, Hashable, Sendable {
    enum Category: CaseIterable {
        case people, searches, feeds, other

        var label: String {
            switch self {
            case .people: return tr("Personen", "People")
            case .searches: return tr("Hashtags & Suchen", "Hashtags & Searches")
            case .feeds: return tr("Feeds & Listen", "Feeds & Lists")
            case .other: return tr("Weitere", "More")
            }
        }
    }

    var id = UUID()
    var kind: ColumnKind
    var title: String
    var avatar: String?
    /// Only for views tied to one account, such as its notifications. Others use the first account.
    var accountDID: String?
    /// From a column moved here, so that pinning it again brings back the same column.
    var filter: ColumnFilter?
    var width: ColumnWidth?

    var avatarURL: URL? { avatar.flatMap(URL.init(string:)) }

    var personHandle: String? {
        switch kind {
        case .author(let actor), .profileTab(let actor, _): return actor
        default: return nil
        }
    }

    /// Fixed views follow the app language; names of people, searches and feeds stay as saved.
    var displayTitle: String {
        Favorite.isTiedToAccount(kind) ? kind.title : title
    }

    var category: Category {
        switch kind {
        case .author, .profileTab: return .people
        case .search: return .searches
        case .feed, .list: return .feeds
        case .home, .notifications, .mentions, .ownPosts, .likes, .bookmarks, .messages: return .other
        }
    }

    /// Both ways of showing a person's posts count as the same favorite.
    static func normalized(_ kind: ColumnKind) -> ColumnKind {
        if case .author(let actor) = kind { return .profileTab(actor: actor, tab: .replies) }
        return kind
    }

    /// Whether this kind of view belongs to one account rather than to whoever is signed in.
    static func isTiedToAccount(_ kind: ColumnKind) -> Bool {
        switch kind {
        case .home, .notifications, .mentions, .ownPosts, .likes, .bookmarks, .messages: return true
        case .author, .profileTab, .feed, .list, .search: return false
        }
    }
}

/// What someone typed into the "add favorite" field, before any network lookup.
enum FavoriteInput: Equatable {
    case person(String)
    /// Looks like a handle, but "node.js" looks the same. A failed lookup makes it a search.
    case personOrSearch(String)
    case search(String)
    case feedLink(FeedLink)
    case invalid

    static func parse(_ raw: String) -> FavoriteInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid }
        if let link = FeedLink.parse(text) { return .feedLink(link) }

        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            // A link to a profile works. Any other web address means nothing here.
            guard let url = URL(string: text), url.host?.hasSuffix("bsky.app") == true else { return .invalid }
            let parts = url.pathComponents.filter { $0 != "/" }
            return parts.count == 2 && parts[0] == "profile" ? .person(parts[1]) : .invalid
        }
        if text.hasPrefix("@") {
            let handle = String(text.dropFirst())
            return handle.isEmpty || handle.contains(" ") ? .invalid : .person(handle)
        }
        if text.hasPrefix("did:") { return .person(text) }
        if text.hasPrefix("#") { return text.count > 1 ? .search(text) : .invalid }
        if !text.contains(" "), text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") {
            return .personOrSearch(text)
        }
        return .search(text)
    }
}
