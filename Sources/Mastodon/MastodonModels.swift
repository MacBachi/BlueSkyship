import Foundation

/// The shapes of Mastodon's REST API, as far as this app reads them. Every field a server
/// might leave out is optional, because Mastodon versions and compatible servers differ.
enum Mastodon {
    struct Account: Decodable, Hashable, Sendable {
        let id: String
        let username: String
        let acct: String
        var display_name: String?
        var note: String?
        var url: String?
        var avatar: String?
        var avatar_static: String?
        var header: String?
        var header_static: String?
        var followers_count: Int?
        var following_count: Int?
        var statuses_count: Int?
        var bot: Bool?
        var locked: Bool?
    }

    struct Mention: Decodable, Hashable, Sendable {
        let id: String
        let username: String
        let acct: String
        let url: String
    }

    struct Tag: Decodable, Hashable, Sendable {
        let name: String
    }

    struct MediaAttachment: Decodable, Hashable, Sendable {
        struct Meta: Decodable, Hashable, Sendable {
            struct Size: Decodable, Hashable, Sendable {
                var width: Double?
                var height: Double?
            }
            var original: Size?
            var small: Size?
        }

        let id: String
        /// image, gifv, video, audio or unknown.
        let type: String
        var url: String?
        var preview_url: String?
        var remote_url: String?
        var description: String?
        var meta: Meta?
    }

    struct Card: Decodable, Hashable, Sendable {
        let url: String
        var title: String?
        var description: String?
        var image: String?
    }

    struct Poll: Decodable, Hashable, Sendable {
        struct Option: Decodable, Hashable, Sendable {
            let title: String
            var votes_count: Int?
        }
        var options: [Option]
        var expired: Bool?
        var votes_count: Int?
    }

    struct FilterResult: Decodable, Hashable, Sendable {
        struct Filter: Decodable, Hashable, Sendable {
            let title: String
            /// warn, hide or blur.
            var filter_action: String?
        }
        let filter: Filter
    }

    /// Quotes exist since Mastodon 4.5. Only an accepted quote shows the quoted post.
    final class Quote: Decodable, Hashable, @unchecked Sendable {
        let state: String?
        let quoted_status: Status?

        static func == (lhs: Quote, rhs: Quote) -> Bool {
            lhs.state == rhs.state && lhs.quoted_status == rhs.quoted_status
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(state)
            hasher.combine(quoted_status?.id)
        }
    }

    final class Status: Decodable, Hashable, @unchecked Sendable {
        let id: String
        let created_at: String
        let account: Account
        let content: String
        let visibility: String?
        let spoiler_text: String?
        let sensitive: Bool?
        let url: String?
        let in_reply_to_id: String?
        let in_reply_to_account_id: String?
        let reblog: Status?
        let media_attachments: LossyList<MediaAttachment>?
        let mentions: LossyList<Mention>?
        let tags: LossyList<Tag>?
        let card: Card?
        let poll: Poll?
        let quote: Quote?
        let replies_count: Int?
        let reblogs_count: Int?
        let favourites_count: Int?
        let quotes_count: Int?
        let favourited: Bool?
        let reblogged: Bool?
        let bookmarked: Bool?
        let language: String?
        let filtered: [FilterResult]?

        private enum CodingKeys: String, CodingKey {
            case id, created_at, account, content, visibility, spoiler_text, sensitive, url
            case in_reply_to_id, in_reply_to_account_id, reblog, media_attachments, mentions, tags
            case card, poll, quote, replies_count, reblogs_count, favourites_count, quotes_count
            case favourited, reblogged, bookmarked, language, filtered
        }

        /// Only what a post cannot do without is required. Anything else that does not fit is left out,
        /// so one odd field from some server cannot hide the whole post.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            created_at = try c.decode(String.self, forKey: .created_at)
            account = try c.decode(Account.self, forKey: .account)
            content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
            visibility = try? c.decodeIfPresent(String.self, forKey: .visibility)
            spoiler_text = try? c.decodeIfPresent(String.self, forKey: .spoiler_text)
            sensitive = try? c.decodeIfPresent(Bool.self, forKey: .sensitive)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            in_reply_to_id = try? c.decodeIfPresent(String.self, forKey: .in_reply_to_id)
            in_reply_to_account_id = try? c.decodeIfPresent(String.self, forKey: .in_reply_to_account_id)
            reblog = try? c.decodeIfPresent(Status.self, forKey: .reblog)
            media_attachments = try? c.decodeIfPresent(LossyList<MediaAttachment>.self, forKey: .media_attachments)
            mentions = try? c.decodeIfPresent(LossyList<Mention>.self, forKey: .mentions)
            tags = try? c.decodeIfPresent(LossyList<Tag>.self, forKey: .tags)
            card = try? c.decodeIfPresent(Card.self, forKey: .card)
            poll = try? c.decodeIfPresent(Poll.self, forKey: .poll)
            quote = try? c.decodeIfPresent(Quote.self, forKey: .quote)
            replies_count = try? c.decodeIfPresent(Int.self, forKey: .replies_count)
            reblogs_count = try? c.decodeIfPresent(Int.self, forKey: .reblogs_count)
            favourites_count = try? c.decodeIfPresent(Int.self, forKey: .favourites_count)
            quotes_count = try? c.decodeIfPresent(Int.self, forKey: .quotes_count)
            favourited = try? c.decodeIfPresent(Bool.self, forKey: .favourited)
            reblogged = try? c.decodeIfPresent(Bool.self, forKey: .reblogged)
            bookmarked = try? c.decodeIfPresent(Bool.self, forKey: .bookmarked)
            language = try? c.decodeIfPresent(String.self, forKey: .language)
            filtered = try? c.decodeIfPresent([FilterResult].self, forKey: .filtered)
        }

        static func == (lhs: Status, rhs: Status) -> Bool { lhs.id == rhs.id && lhs.created_at == rhs.created_at }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    struct Notification: Decodable, Hashable, Sendable {
        let id: String
        /// mention, status, reblog, follow, follow_request, favourite, poll, update, quote, …
        let type: String
        let created_at: String
        let account: Account
        var status: Status?

        private enum CodingKeys: String, CodingKey { case id, type, created_at, account, status }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            type = try c.decode(String.self, forKey: .type)
            created_at = try c.decode(String.self, forKey: .created_at)
            account = try c.decode(Account.self, forKey: .account)
            status = try? c.decodeIfPresent(Status.self, forKey: .status)
        }
    }

    struct Relationship: Decodable, Hashable, Sendable {
        let id: String
        var following: Bool?
        var requested: Bool?
        var followed_by: Bool?
        var muting: Bool?
        var blocking: Bool?
    }

    struct Context: Decodable, Sendable {
        let ancestors: LossyList<Status>
        let descendants: LossyList<Status>
    }

    struct Conversation: Decodable, Sendable {
        let id: String
        var last_status: Status?

        private enum CodingKeys: String, CodingKey { case id, last_status }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            last_status = try? c.decodeIfPresent(Status.self, forKey: .last_status)
        }
    }

    struct List: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let title: String
    }

    struct SearchResults: Decodable, Sendable {
        var accounts: LossyList<Account>?
        var statuses: LossyList<Status>?
    }

    /// The parts of `/api/v2/instance` that shape what the composer allows.
    struct Instance: Decodable, Sendable {
        struct Configuration: Decodable, Sendable {
            struct Statuses: Decodable, Sendable {
                var max_characters: Int?
                var max_media_attachments: Int?
                var characters_reserved_per_url: Int?
            }
            var statuses: Statuses?
        }
        let domain: String
        var configuration: Configuration?
    }

    struct Application: Decodable, Sendable {
        let client_id: String
        let client_secret: String
    }

    struct Token: Decodable, Sendable {
        let access_token: String
    }

    struct MediaUpload: Decodable, Sendable {
        let id: String
        var url: String?
    }

    struct Marker: Decodable, Sendable {
        struct Entry: Decodable, Sendable { let last_read_id: String }
        var notifications: Entry?
    }

    struct UnreadCount: Decodable, Sendable { let count: Int }

    struct ErrorPayload: Decodable, Sendable { let error: String? }
}

/// What a Mastodon post has that a Bluesky post does not. Lives on `PostView`, so the same
/// rows, threads and filters show posts from both networks.
struct MastodonPostInfo: Codable, Hashable, Sendable {
    let statusID: String
    var url: String?
    /// The content warning the author wrote. Text and media stay covered until opened.
    var spoilerText: String?
    var sensitive = false
    var visibility: String?
    /// A server-side filter the account set up, with "warn" as action.
    var filterTitle: String?
    /// The id of the author on the reading server, needed to follow or mute without a lookup.
    var authorID: String?

    var warning: String? {
        if let spoilerText, !spoilerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return spoilerText }
        if let filterTitle { return tr("Gefiltert: \(filterTitle)", "Filtered: \(filterTitle)") }
        return nil
    }
}

/// Who may see a Mastodon post.
enum MastodonVisibility: String, CaseIterable, Codable, Sendable {
    case `public`, unlisted, `private`, direct

    var label: String {
        switch self {
        case .public: return tr("Öffentlich", "Public")
        case .unlisted: return tr("Nicht gelistet", "Quiet public")
        case .private: return tr("Nur Follower", "Followers only")
        case .direct: return tr("Nur Erwähnte", "Mentioned only")
        }
    }

    var systemImage: String {
        switch self {
        case .public: return "globe"
        case .unlisted: return "moon"
        case .private: return "lock"
        case .direct: return "at"
        }
    }

    /// A reply never reaches more people than the post it answers.
    func narrowed(to parent: MastodonVisibility?) -> MastodonVisibility {
        guard let parent else { return self }
        let order: [MastodonVisibility] = [.public, .unlisted, .private, .direct]
        return order.firstIndex(of: parent)! > order.firstIndex(of: self)! ? parent : self
    }
}

/// Settings of a Mastodon post that Bluesky has no place for.
struct MastodonPostOptions: Codable, Hashable, Sendable {
    var visibility: MastodonVisibility = .public
    var spoilerText = ""
}
