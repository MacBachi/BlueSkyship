import Foundation

/// Decodes an array and drops elements that fail, so one unexpected post cannot blank a whole column.
struct LossyList<Element: Decodable>: Decodable {
    var values: [Element] = []

    private struct Skip: Decodable {}

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                values.append(value)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
    }
}

extension LossyList: Sendable where Element: Sendable {}

struct StrongRef: Codable, Hashable, Sendable {
    let uri: String
    let cid: String
}

struct Profile: Decodable, Hashable, Sendable, Identifiable {
    struct Viewer: Decodable, Hashable, Sendable {
        var following: String?
    }

    let did: String
    let handle: String
    var displayName: String?
    var avatar: String?
    var viewer: Viewer?

    var id: String { did }
    var avatarURL: URL? { avatar.flatMap(URL.init(string:)) }
    var bestName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return handle
    }
}

struct ProfileViewerState: Decodable, Hashable, Sendable {
    /// Record URI of the viewer's follow, needed to undo it.
    var following: String?
    var followedBy: String?
    var muted: Bool?
    /// Record URI of the viewer's block, needed to undo it.
    var blocking: String?
}

struct ProfileDetail: Decodable, Hashable, Sendable {
    let did: String
    let handle: String
    var displayName: String?
    var description: String?
    var avatar: String?
    var banner: String?
    var followersCount: Int?
    var followsCount: Int?
    var postsCount: Int?
    var viewer: ProfileViewerState?

    var avatarURL: URL? { avatar.flatMap(URL.init(string:)) }
    var bannerURL: URL? { banner.flatMap(URL.init(string:)) }
    var webURL: URL? { URL(string: "https://bsky.app/profile/\(handle)") }
    var bestName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return handle
    }
}

struct Facet: Codable, Hashable, Sendable {
    enum Feature: Hashable, Sendable {
        case link(String)
        case mention(did: String)
        case tag(String)
        case unknown
    }

    struct ByteSlice: Codable, Hashable, Sendable {
        let byteStart: Int
        let byteEnd: Int
    }

    let index: ByteSlice
    let features: [Feature]

    init(byteStart: Int, byteEnd: Int, feature: Feature) {
        index = ByteSlice(byteStart: byteStart, byteEnd: byteEnd)
        features = [feature]
    }
}

extension Facet.Feature: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "$type", uri, did, tag
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "app.bsky.richtext.facet#link":
            self = .link(try container.decode(String.self, forKey: .uri))
        case "app.bsky.richtext.facet#mention":
            self = .mention(did: try container.decode(String.self, forKey: .did))
        case "app.bsky.richtext.facet#tag":
            self = .tag(try container.decode(String.self, forKey: .tag))
        default:
            self = .unknown
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .link(let uri):
            try container.encode("app.bsky.richtext.facet#link", forKey: .type)
            try container.encode(uri, forKey: .uri)
        case .mention(let did):
            try container.encode("app.bsky.richtext.facet#mention", forKey: .type)
            try container.encode(did, forKey: .did)
        case .tag(let tag):
            try container.encode("app.bsky.richtext.facet#tag", forKey: .type)
            try container.encode(tag, forKey: .tag)
        case .unknown:
            break
        }
    }
}

struct ReplyRef: Codable, Hashable, Sendable {
    let root: StrongRef
    let parent: StrongRef
}

struct PostRecord: Decodable, Hashable, Sendable {
    var text: String
    var createdAt: String?
    var facets: [Facet]?
    var reply: ReplyRef?

    private enum CodingKeys: String, CodingKey { case text, createdAt, facets, reply }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        facets = try? container.decodeIfPresent([Facet].self, forKey: .facets)
        reply = try? container.decodeIfPresent(ReplyRef.self, forKey: .reply)
    }
}

struct EmbedImage: Decodable, Hashable, Sendable {
    let thumb: String
    let fullsize: String
    var alt: String?
    var aspectRatio: AspectRatio?
}

struct AspectRatio: Decodable, Hashable, Sendable {
    let width: Double
    let height: Double
    var value: CGFloat { height > 0 ? CGFloat(width / height) : 16.0 / 9.0 }
}

struct ExternalLink: Decodable, Hashable, Sendable {
    let uri: String
    var title: String?
    var description: String?
    var thumb: String?
}

struct VideoEmbed: Decodable, Hashable, Sendable {
    let playlist: String
    var thumbnail: String?
    var alt: String?
    var aspectRatio: AspectRatio?
    /// "gif" marks a short clip that loops silently.
    var presentation: String?

    var isGIF: Bool { presentation == "gif" }
}

struct QuotedPost: Decodable, Hashable, Sendable {
    let uri: String
    let cid: String
    let author: Profile
    let value: PostRecord
    let indexedAt: String
    var embeds: [Embed]?

    private enum CodingKeys: String, CodingKey { case uri, cid, author, value, indexedAt, embeds }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        cid = try container.decode(String.self, forKey: .cid)
        author = try container.decode(Profile.self, forKey: .author)
        value = try container.decode(PostRecord.self, forKey: .value)
        indexedAt = try container.decode(String.self, forKey: .indexedAt)
        embeds = try? container.decodeIfPresent([Embed].self, forKey: .embeds)
    }
}

indirect enum Embed: Decodable, Hashable, Sendable {
    case images([EmbedImage])
    case external(ExternalLink)
    case video(VideoEmbed)
    /// `nil` means the quoted post is blocked, deleted or not a post.
    case quote(QuotedPost?)
    case quoteWithMedia(QuotedPost?, media: Embed)
    /// An embedded feed, list or starter pack.
    case recordCard(RecordCard)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type = "$type", images, external, record, media
    }

    /// Shape of `app.bsky.embed.record#view`: `{ record: <union> }`.
    private struct RecordView: Decodable {
        let quoted: QuotedPost?
        let card: RecordCard?
        private enum CodingKeys: String, CodingKey { case record }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            quoted = try? container.decode(QuotedPost.self, forKey: .record)
            card = try? container.decode(RecordCard.self, forKey: .record)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "app.bsky.embed.images#view":
            self = .images(try container.decode([EmbedImage].self, forKey: .images))
        case "app.bsky.embed.external#view":
            self = .external(try container.decode(ExternalLink.self, forKey: .external))
        case "app.bsky.embed.video#view":
            self = .video(try VideoEmbed(from: decoder))
        case "app.bsky.embed.record#view":
            let view = try RecordView(from: decoder)
            if view.quoted == nil, let card = view.card {
                self = .recordCard(card)
            } else {
                self = .quote(view.quoted)
            }
        case "app.bsky.embed.recordWithMedia#view":
            let view = try container.decode(RecordView.self, forKey: .record)
            self = .quoteWithMedia(view.quoted, media: try container.decode(Embed.self, forKey: .media))
        default:
            self = .unknown
        }
    }
}

/// An embedded feed, list or starter pack: enough to name it and link to it.
struct RecordCard: Decodable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case feed, list, starterPack
    }

    let kind: Kind
    let title: String
    let creatorHandle: String
    var description: String?
    let uri: String

    private enum CodingKeys: String, CodingKey {
        case type = "$type", uri, creator, displayName, name, description, record
    }
    private struct Creator: Decodable { let handle: String }
    private struct PackRecord: Decodable {
        let name: String
        var description: String?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        creatorHandle = try container.decode(Creator.self, forKey: .creator).handle
        switch try container.decode(String.self, forKey: .type) {
        case "app.bsky.feed.defs#generatorView":
            kind = .feed
            title = try container.decode(String.self, forKey: .displayName)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
        case "app.bsky.graph.defs#listView":
            kind = .list
            title = try container.decode(String.self, forKey: .name)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
        case "app.bsky.graph.defs#starterPackViewBasic":
            kind = .starterPack
            let record = try container.decode(PackRecord.self, forKey: .record)
            title = record.name
            description = record.description
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Not a card")
        }
    }

    var webURL: URL? {
        guard let rkey = uri.split(separator: "/").last else { return nil }
        switch kind {
        case .feed: return URL(string: "https://bsky.app/profile/\(creatorHandle)/feed/\(rkey)")
        case .list: return URL(string: "https://bsky.app/profile/\(creatorHandle)/lists/\(rkey)")
        case .starterPack: return URL(string: "https://bsky.app/starter-pack/\(creatorHandle)/\(rkey)")
        }
    }
}

struct PostViewer: Decodable, Hashable, Sendable {
    var like: String?
    var repost: String?
    var bookmarked: Bool?
}

struct PostView: Decodable, Hashable, Sendable, Identifiable {
    let uri: String
    let cid: String
    let author: Profile
    let record: PostRecord
    let indexedAt: String
    var embed: Embed?
    var replyCount: Int?
    var repostCount: Int?
    var likeCount: Int?
    var quoteCount: Int?
    var viewer: PostViewer?
    var labels: [ContentLabel]?

    var id: String { uri }
    var ref: StrongRef { StrongRef(uri: uri, cid: cid) }
    var date: Date? { ATDate.parse(record.createdAt ?? indexedAt) }

    /// The bsky.app URL for this post, for "open in browser" and "copy link".
    var webURL: URL? {
        guard let rkey = uri.split(separator: "/").last else { return nil }
        return URL(string: "https://bsky.app/profile/\(author.handle)/post/\(rkey)")
    }
}

struct FeedReason: Decodable, Hashable, Sendable {
    let by: Profile?
    private enum CodingKeys: String, CodingKey { case by }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        by = try? container.decodeIfPresent(Profile.self, forKey: .by)
    }
}

struct ReplyContext: Decodable, Hashable, Sendable {
    let parentAuthor: Profile?

    private enum CodingKeys: String, CodingKey { case parent }
    private enum ParentKeys: String, CodingKey { case author }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let parent = try? container.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent)
        // The parent may be a blocked or missing stub whose author has no handle.
        parentAuthor = try? parent?.decodeIfPresent(Profile.self, forKey: .author)
    }
}

struct FeedViewPost: Decodable, Hashable, Sendable {
    var post: PostView
    var reply: ReplyContext?
    var reason: FeedReason?

    private enum CodingKeys: String, CodingKey { case post, reply, reason }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        post = try container.decode(PostView.self, forKey: .post)
        reply = try? container.decodeIfPresent(ReplyContext.self, forKey: .reply)
        reason = try? container.decodeIfPresent(FeedReason.self, forKey: .reason)
    }

    init(post: PostView) {
        self.post = post
    }
}

struct RawNotification: Decodable, Hashable, Sendable {
    let uri: String
    let cid: String
    let author: Profile
    let reason: String
    var reasonSubject: String?
    let indexedAt: String
    var isRead: Bool?

    /// The post to show beneath the notification, if there is one.
    var subjectURI: String? {
        switch reason {
        case "like", "repost": return reasonSubject
        case "reply", "mention", "quote": return uri
        default: return nil
        }
    }
}

enum ATDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    static func string(_ date: Date = Date()) -> String {
        fractional.string(from: date)
    }

    /// Compact age such as "5m", "3h", "2d", as column layouts have little room.
    static func age(of date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        default: return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Localizer.shared.locale))
        }
    }
}
