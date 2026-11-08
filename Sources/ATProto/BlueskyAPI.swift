import Foundation

struct FeedPage: Sendable {
    var items: [ColumnItem]
    var cursor: String?
}

struct SavedFeed: Identifiable, Hashable, Sendable {
    let uri: String
    let name: String
    var id: String { uri }
}

struct ThreadContent: Decodable, Sendable {
    private(set) var parents: [PostView]
    private(set) var post: PostView
    private(set) var replies: [PostView]

    /// Puts a post with changed like or repost state back in place, wherever it sits in the thread.
    mutating func replace(_ updated: PostView) {
        if post.uri == updated.uri { post = updated }
        parents = parents.map { $0.uri == updated.uri ? updated : $0 }
        replies = replies.map { $0.uri == updated.uri ? updated : $0 }
    }

    private enum CodingKeys: String, CodingKey { case post, parent, replies }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        post = try container.decode(PostView.self, forKey: .post)
        // The parent or a reply may be a blocked or missing stub, which we simply leave out.
        if let parent = try? container.decode(ThreadContent.self, forKey: .parent) {
            parents = parent.parents + [parent.post]
        } else {
            parents = []
        }
        let nodes = try? container.decodeIfPresent(LossyList<ThreadContent>.self, forKey: .replies)
        replies = nodes?.values.map(\.post) ?? []
    }
}

extension XRPCClient {
    // MARK: Reads

    func fetchPage(kind: ColumnKind, cursor: String?, limit: Int = 40) async throws -> FeedPage {
        let limitValue = String(limit)
        switch kind {
        case .home:
            return try await feedPage("app.bsky.feed.getTimeline", [("limit", limitValue), ("cursor", cursor)])
        case .author(let actor):
            return try await feedPage("app.bsky.feed.getAuthorFeed", [
                ("actor", actor), ("limit", limitValue), ("cursor", cursor), ("filter", ProfileTab.posts.apiFilter),
            ])
        case .ownPosts(let actor):
            return try await feedPage("app.bsky.feed.getAuthorFeed", [
                ("actor", actor), ("limit", limitValue), ("cursor", cursor), ("filter", ProfileTab.replies.apiFilter),
            ])
        case .profileTab(let actor, let tab):
            return try await feedPage("app.bsky.feed.getAuthorFeed", [
                ("actor", actor), ("limit", limitValue), ("cursor", cursor), ("filter", tab.apiFilter),
            ])
        case .feed(let uri, _):
            return try await feedPage("app.bsky.feed.getFeed", [("feed", uri), ("limit", limitValue), ("cursor", cursor)])
        case .list(let uri, _):
            return try await feedPage("app.bsky.feed.getListFeed", [("list", uri), ("limit", limitValue), ("cursor", cursor)])
        case .search(let query):
            struct Response: Decodable, Sendable {
                let posts: LossyList<PostView>
                let cursor: String?
            }
            let response: Response = try await get("app.bsky.feed.searchPosts", query: [
                ("q", query), ("sort", "latest"), ("limit", limitValue), ("cursor", cursor),
            ])
            return FeedPage(items: response.posts.values.map { .post(FeedViewPost(post: $0)) }, cursor: response.cursor)
        case .likes(let actor):
            return try await feedPage("app.bsky.feed.getActorLikes", [("actor", actor), ("limit", limitValue), ("cursor", cursor)])
        case .bookmarks:
            return try await bookmarksPage(cursor: cursor, limit: limitValue)
        case .messages:
            // Conversations have their own panel and never come through a timeline.
            return FeedPage(items: [], cursor: nil)
        case .notifications:
            return try await notificationPage(reasons: [], cursor: cursor, limit: limitValue)
        case .mentions:
            return try await notificationPage(reasons: ["mention", "reply", "quote"], cursor: cursor, limit: limitValue)
        }
    }

    private func feedPage(_ nsid: String, _ query: [(String, String?)]) async throws -> FeedPage {
        struct Response: Decodable, Sendable {
            let feed: LossyList<FeedViewPost>
            let cursor: String?
        }
        let response: Response = try await get(nsid, query: query)
        return FeedPage(items: response.feed.values.map(ColumnItem.post), cursor: response.cursor)
    }

    private func notificationPage(reasons: [String], cursor: String?, limit: String) async throws -> FeedPage {
        struct Response: Decodable, Sendable {
            let notifications: LossyList<RawNotification>
            let cursor: String?
        }
        var query: [(String, String?)] = [("limit", limit), ("cursor", cursor)]
        query += reasons.map { ("reasons", $0) }
        let response: Response = try await get("app.bsky.notification.listNotifications", query: query)
        let raw = response.notifications.values
        let posts = try await posts(uris: Set(raw.compactMap(\.subjectURI)))
        let items = raw.map { notification in
            ColumnItem.notification(NotificationItem(
                raw: notification,
                post: notification.subjectURI.flatMap { posts[$0] }
            ))
        }
        return FeedPage(items: items, cursor: response.cursor)
    }

    /// Fetches posts in the API's batches of 25.
    private func posts(uris: Set<String>) async throws -> [String: PostView] {
        struct Response: Decodable, Sendable { let posts: LossyList<PostView> }
        var result: [String: PostView] = [:]
        let all = Array(uris)
        for start in stride(from: 0, to: all.count, by: 25) {
            let batch = all[start..<min(start + 25, all.count)]
            let response: Response = try await get(
                "app.bsky.feed.getPosts", query: batch.map { ("uris", $0) }
            )
            for post in response.posts.values { result[post.uri] = post }
        }
        return result
    }

    func thread(uri: String) async throws -> ThreadContent {
        struct Response: Decodable, Sendable { let thread: ThreadContent }
        let response: Response = try await get("app.bsky.feed.getPostThread", query: [
            ("uri", uri), ("depth", "1"), ("parentHeight", "20"),
        ])
        return response.thread
    }

    func profile(actor: String) async throws -> Profile {
        try await get("app.bsky.actor.getProfile", query: [("actor", actor)])
    }

    func likers(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        struct Like: Decodable, Sendable { let actor: Profile }
        struct Response: Decodable, Sendable {
            let likes: LossyList<Like>
            let cursor: String?
        }
        let response: Response = try await get("app.bsky.feed.getLikes", query: [
            ("uri", uri), ("limit", "50"), ("cursor", cursor),
        ])
        return (response.likes.values.map(\.actor), response.cursor)
    }

    func reposters(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        struct Response: Decodable, Sendable {
            let repostedBy: LossyList<Profile>
            let cursor: String?
        }
        let response: Response = try await get("app.bsky.feed.getRepostedBy", query: [
            ("uri", uri), ("limit", "50"), ("cursor", cursor),
        ])
        return (response.repostedBy.values, response.cursor)
    }

    func quotes(of uri: String, cursor: String?) async throws -> (posts: [PostView], cursor: String?) {
        struct Response: Decodable, Sendable {
            let posts: LossyList<PostView>
            let cursor: String?
        }
        let response: Response = try await get("app.bsky.feed.getQuotes", query: [
            ("uri", uri), ("limit", "50"), ("cursor", cursor),
        ])
        return (response.posts.values, response.cursor)
    }

    func profileDetail(actor: String) async throws -> ProfileDetail {
        try await get("app.bsky.actor.getProfile", query: [("actor", actor)])
    }

    /// Follows an account and returns the follow record's URI. Undo it with `deleteRecord`.
    func follow(did: String, repo: String) async throws -> String {
        struct Record: Encodable, Sendable {
            let type = "app.bsky.graph.follow"
            let subject: String
            let createdAt: String
            private enum CodingKeys: String, CodingKey {
                case type = "$type", subject, createdAt
            }
        }
        let created: CreatedRecord = try await post(
            "com.atproto.repo.createRecord",
            body: CreateRecord(
                repo: repo, collection: "app.bsky.graph.follow",
                record: Record(subject: did, createdAt: ATDate.string())
            )
        )
        return created.uri
    }

    func resolveHandle(_ handle: String) async throws -> String {
        struct Response: Decodable, Sendable { let did: String }
        let response: Response = try await get("com.atproto.identity.resolveHandle", query: [("handle", handle)])
        return response.did
    }

    func feedName(uri: String) async throws -> String {
        struct Response: Decodable, Sendable {
            struct View: Decodable, Sendable { let displayName: String }
            let view: View
        }
        let response: Response = try await get("app.bsky.feed.getFeedGenerator", query: [("feed", uri)])
        return response.view.displayName
    }

    func listName(uri: String) async throws -> String {
        struct Response: Decodable, Sendable {
            struct View: Decodable, Sendable { let name: String }
            let list: View
        }
        let response: Response = try await get("app.bsky.graph.getList", query: [("list", uri), ("limit", "1")])
        return response.list.name
    }

    /// The custom feeds the account has saved in Bluesky.
    func savedFeeds() async throws -> [SavedFeed] {
        struct Item: Decodable, Sendable {
            let type: String
            let value: String
        }
        struct Preference: Decodable, Sendable {
            let items: [Item]?
            private enum CodingKeys: String, CodingKey { case items }
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                items = try? container.decodeIfPresent([Item].self, forKey: .items)
            }
        }
        struct Preferences: Decodable, Sendable { let preferences: LossyList<Preference> }
        struct Generators: Decodable, Sendable {
            struct View: Decodable, Sendable {
                let uri: String
                let displayName: String
            }
            let feeds: LossyList<View>
        }
        let preferences: Preferences = try await get("app.bsky.actor.getPreferences")
        let uris = preferences.preferences.values
            .flatMap { $0.items ?? [] }
            .filter { $0.type == "feed" }
            .map(\.value)
        guard !uris.isEmpty else { return [] }
        let generators: Generators = try await get(
            "app.bsky.feed.getFeedGenerators", query: uris.prefix(25).map { ("feeds", $0) }
        )
        return generators.feeds.values.map { SavedFeed(uri: $0.uri, name: $0.displayName) }
    }

    // MARK: Writes

    struct CreateRecord<Record: Encodable & Sendable>: Encodable, Sendable {
        let repo: String
        let collection: String
        let record: Record
    }

    struct CreatedRecord: Decodable, Sendable {
        let uri: String
        let cid: String
    }

    private struct Subject: Encodable, Sendable {
        let type: String
        let subject: StrongRef
        let createdAt: String
        private enum CodingKeys: String, CodingKey {
            case type = "$type", subject, createdAt
        }
    }

    /// Creates a like (`app.bsky.feed.like`) or repost (`app.bsky.feed.repost`) and returns its record URI.
    func createInteraction(collection: String, subject: StrongRef, repo: String) async throws -> String {
        let record = Subject(type: collection, subject: subject, createdAt: ATDate.string())
        let created: CreatedRecord = try await post(
            "com.atproto.repo.createRecord",
            body: CreateRecord(repo: repo, collection: collection, record: record)
        )
        return created.uri
    }

    /// Deletes a record by its AT-URI (`at://did/collection/rkey`).
    func deleteRecord(uri: String) async throws {
        struct Body: Encodable, Sendable {
            let repo: String
            let collection: String
            let rkey: String
        }
        let parts = uri.replacingOccurrences(of: "at://", with: "").split(separator: "/").map(String.init)
        guard parts.count == 3 else { throw URLError(.badURL) }
        try await postIgnoringResponse(
            "com.atproto.repo.deleteRecord",
            body: Body(repo: parts[0], collection: parts[1], rkey: parts[2])
        )
    }

    @discardableResult
    func createPost(_ draft: PostDraft, repo: String) async throws -> StrongRef {
        let facets = await RichText.resolveMentions(in: RichText.detectFacets(in: draft.text)) { handle in
            try? await self.resolveHandle(handle)
        }
        // Uploads come first: if one fails, no post without its picture goes out.
        var uploaded: [NewPostRecord.Embed.Image] = []
        for image in draft.images {
            let blob = try await uploadBlob(image.prepared)
            uploaded.append(.init(
                image: blob,
                alt: image.alt,
                aspectRatio: .init(width: image.prepared.width, height: image.prepared.height)
            ))
        }
        var uploadedVideo: NewPostRecord.Embed.Video?
        if let video = draft.video {
            uploadedVideo = .init(
                video: try await uploadVideo(video, repo: repo),
                alt: video.alt.isEmpty ? nil : video.alt,
                aspectRatio: .init(width: video.width, height: video.height)
            )
        }
        let record = NewPostRecord(
            text: draft.text,
            createdAt: ATDate.string(),
            langs: draft.langs.isEmpty ? nil : draft.langs,
            facets: facets.isEmpty ? nil : facets,
            reply: draft.reply,
            embed: NewPostRecord.Embed.make(quote: draft.quote, images: uploaded, video: uploadedVideo)
        )
        let created: CreatedRecord = try await post(
            "com.atproto.repo.createRecord",
            body: CreateRecord(repo: repo, collection: "app.bsky.feed.post", record: record)
        )
        return StrongRef(uri: created.uri, cid: created.cid)
    }
}

extension XRPCClient {
    private func uploadBlob(_ image: PreparedImage) async throws -> BlobRef {
        struct Response: Decodable, Sendable { let blob: BlobRef }
        let response: Response = try await upload(
            "com.atproto.repo.uploadBlob", data: image.data, contentType: image.mimeType
        )
        return response.blob
    }
}

/// An uploaded file as the server describes it. Goes back unchanged into the post record.
struct BlobRef: Codable, Hashable, Sendable {
    struct Link: Codable, Hashable, Sendable {
        let link: String
        private enum CodingKeys: String, CodingKey { case link = "$link" }
    }

    var type = "blob"
    let ref: Link
    let mimeType: String
    let size: Int

    private enum CodingKeys: String, CodingKey {
        case type = "$type", ref, mimeType, size
    }
}

struct DraftImage: Codable, Equatable, Sendable {
    var prepared: PreparedImage
    var alt: String
}

struct PostDraft: Sendable {
    var text: String
    var langs: [String] = []
    var reply: ReplyRef?
    var quote: StrongRef?
    var images: [DraftImage] = []
    var video: VideoDraft?
}

struct NewPostRecord: Encodable, Sendable {
    /// Bluesky has one embed per post, so a quote with pictures needs the combined `recordWithMedia` form.
    enum Embed: Encodable, Sendable {
        struct Image: Encodable, Sendable {
            struct Ratio: Encodable, Sendable {
                let width: Int
                let height: Int
            }
            let image: BlobRef
            let alt: String
            let aspectRatio: Ratio
        }

        struct Video: Encodable, Sendable {
            let video: BlobRef
            let alt: String?
            let aspectRatio: Image.Ratio
        }

        case quote(StrongRef)
        case images([Image])
        case quoteWithImages(StrongRef, [Image])
        case video(Video)
        case quoteWithVideo(StrongRef, Video)

        static func make(quote: StrongRef?, images: [Image], video: Video? = nil) -> Embed? {
            if let video {
                return quote.map { .quoteWithVideo($0, video) } ?? .video(video)
            }
            switch (quote, images.isEmpty) {
            case (nil, true): return nil
            case (let quote?, true): return .quote(quote)
            case (nil, false): return .images(images)
            case (let quote?, false): return .quoteWithImages(quote, images)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type = "$type", record, images, media
        }

        private struct QuotePart: Encodable {
            let type = "app.bsky.embed.record"
            let record: StrongRef
            private enum CodingKeys: String, CodingKey {
                case type = "$type", record
            }
        }

        private struct ImagesPart: Encodable {
            let type = "app.bsky.embed.images"
            let images: [Image]
            private enum CodingKeys: String, CodingKey {
                case type = "$type", images
            }
        }

        private struct VideoPart: Encodable {
            let type = "app.bsky.embed.video"
            let video: Video
            private enum CodingKeys: String, CodingKey {
                case type = "$type", video, alt, aspectRatio
            }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(type, forKey: .type)
                try container.encode(video.video, forKey: .video)
                try container.encodeIfPresent(video.alt, forKey: .alt)
                try container.encode(video.aspectRatio, forKey: .aspectRatio)
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .video(let video):
                try VideoPart(video: video).encode(to: encoder)
            case .quoteWithVideo(let quote, let video):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("app.bsky.embed.recordWithMedia", forKey: .type)
                try container.encode(QuotePart(record: quote), forKey: .record)
                try container.encode(VideoPart(video: video), forKey: .media)
            case .quote(let quote):
                try QuotePart(record: quote).encode(to: encoder)
            case .images(let images):
                try ImagesPart(images: images).encode(to: encoder)
            case .quoteWithImages(let quote, let images):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("app.bsky.embed.recordWithMedia", forKey: .type)
                try container.encode(QuotePart(record: quote), forKey: .record)
                try container.encode(ImagesPart(images: images), forKey: .media)
            }
        }
    }

    let type = "app.bsky.feed.post"
    let text: String
    let createdAt: String
    let langs: [String]?
    let facets: [Facet]?
    let reply: ReplyRef?
    let embed: Embed?

    private enum CodingKeys: String, CodingKey {
        case type = "$type", text, createdAt, langs, facets, reply, embed
    }
}

/// Turns a bsky.app URL or AT-URI into the AT-URI of a feed or list.
enum FeedLink: Equatable, Sendable {
    case feed(String)
    case list(String)

    /// Parses without network access. A handle in the URL is returned unresolved in the `at://` authority.
    static func parse(_ input: String) -> FeedLink? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("at://") {
            if text.contains("/app.bsky.feed.generator/") { return .feed(text) }
            if text.contains("/app.bsky.graph.list/") { return .list(text) }
            return nil
        }
        guard let url = URL(string: text), url.host?.hasSuffix("bsky.app") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, parts[0] == "profile" else { return nil }
        switch parts[2] {
        case "feed": return .feed("at://\(parts[1])/app.bsky.feed.generator/\(parts[3])")
        case "lists": return .list("at://\(parts[1])/app.bsky.graph.list/\(parts[3])")
        default: return nil
        }
    }

    var uri: String {
        switch self {
        case .feed(let uri), .list(let uri): return uri
        }
    }

    /// The `at://` authority, which may still be a handle rather than a DID.
    var authority: String? {
        uri.replacingOccurrences(of: "at://", with: "").split(separator: "/").first.map(String.init)
    }

    func replacingAuthority(with did: String) -> FeedLink {
        guard let authority else { return self }
        let updated = uri.replacingOccurrences(of: "at://\(authority)/", with: "at://\(did)/")
        switch self {
        case .feed: return .feed(updated)
        case .list: return .list(updated)
        }
    }
}
