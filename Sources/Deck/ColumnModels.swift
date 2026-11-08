import Foundation

enum ProfileTab: String, Codable, CaseIterable, Sendable {
    case posts, replies, media

    var apiFilter: String {
        switch self {
        case .posts: return "posts_no_replies"
        case .replies: return "posts_with_replies"
        case .media: return "posts_with_media"
        }
    }

    var label: String {
        switch self {
        case .posts: return "Posts"
        case .replies: return tr("Antworten", "Replies")
        case .media: return tr("Medien", "Media")
        }
    }
}

enum ColumnKind: Codable, Hashable, Sendable {
    case home
    case notifications
    case mentions
    case author(actor: String)
    /// A person's posts, either as a profile page tab or as an "all posts" column.
    case profileTab(actor: String, tab: ProfileTab)
    /// Everything the signed-in account has posted, with exact dates and reactions.
    case ownPosts(actor: String)
    case likes(actor: String)
    case bookmarks
    case messages
    case feed(uri: String, name: String)
    case list(uri: String, name: String)
    case search(query: String)

    var isOwnPosts: Bool {
        if case .ownPosts = self { return true }
        return false
    }

    var requiresAccount: Bool {
        switch self {
        // The public API answers searchPosts with 403, so search needs an account too.
        case .home, .notifications, .mentions, .search, .ownPosts, .likes, .bookmarks, .messages: return true
        case .author, .profileTab, .feed, .list: return false
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .notifications: return tr("Mitteilungen", "Notifications")
        case .mentions: return tr("Erwähnungen", "Mentions")
        case .ownPosts: return tr("Meine Posts", "My Posts")
        case .likes: return tr("Meine Likes", "My Likes")
        case .bookmarks: return tr("Lesezeichen", "Bookmarks")
        case .messages: return tr("Direktnachrichten", "Direct Messages")
        case .author(let actor), .profileTab(let actor, _): return "@\(actor)"
        case .feed(_, let name), .list(_, let name): return name
        case .search(let query): return query
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .notifications: return "bell"
        case .mentions: return "at"
        case .ownPosts: return "text.bubble"
        case .likes: return "heart"
        case .bookmarks: return "bookmark"
        case .messages: return "envelope"
        case .author, .profileTab: return "person"
        case .feed: return "number"
        case .list: return "list.bullet"
        case .search: return "magnifyingglass"
        }
    }
}

enum ColumnWidth: String, Codable, CaseIterable, Sendable {
    case narrow, medium, wide

    var points: CGFloat {
        switch self {
        case .narrow: return 300
        case .medium: return 360
        case .wide: return 460
        }
    }

    var label: String {
        switch self {
        case .narrow: return tr("Schmal", "Narrow")
        case .medium: return tr("Mittel", "Medium")
        case .wide: return tr("Breit", "Wide")
        }
    }
}

struct Column: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: ColumnKind
    /// `nil` reads through the public API without an account.
    var accountDID: String?
    var width: ColumnWidth = .medium
    /// Optional so decks saved before filters existed still load.
    var filter: ColumnFilter?
}

struct NotificationItem: Hashable, Sendable {
    let raw: RawNotification
    var post: PostView?
}

enum ColumnItem: Identifiable, Hashable, Sendable {
    case post(FeedViewPost)
    case notification(NotificationItem)

    var id: String {
        switch self {
        case .post(let item):
            // The same post can appear once as an original and again per reposter.
            return "\(item.post.uri)|\(item.reason?.by?.did ?? "")"
        case .notification(let item):
            return "\(item.raw.uri)|\(item.raw.reason)|\(item.raw.author.did)"
        }
    }

    func replacingPost(_ post: PostView) -> ColumnItem {
        switch self {
        case .post(var item):
            guard item.post.uri == post.uri else { return self }
            item.post = post
            return .post(item)
        case .notification(var item):
            guard item.post?.uri == post.uri else { return self }
            item.post = post
            return .notification(item)
        }
    }
}

extension Array where Element: Identifiable {
    func removingDuplicateIDs() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
