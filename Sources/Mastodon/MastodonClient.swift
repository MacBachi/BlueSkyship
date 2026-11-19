import Foundation

/// A signed-in Mastodon account. The token is the only secret, and it lives in the Keychain.
struct MastodonSession: Codable, Hashable, Sendable {
    /// `https://server`, where the API answers.
    let server: URL
    /// The server's own name in account addresses. Usually the host, but not always.
    let domain: String
    let accountID: String
    let acct: String
    var accessToken: String
    let clientID: String
    let clientSecret: String
}

/// Talks to one Mastodon server. Reads and writes through Mastodon's REST API.
actor MastodonClient: SocialReader {
    let server: URL
    let mapper: MastodonMapper
    let session: MastodonSession?
    private let transport: URLSession
    /// Account ids by address, so a profile does not need a lookup twice.
    private var accountIDs: [String: String] = [:]
    private var instance: Mastodon.Instance?

    init(session: MastodonSession, transport: URLSession = .shared) {
        self.server = session.server
        self.mapper = MastodonMapper(domain: session.domain)
        self.session = session
        self.transport = transport
        accountIDs[session.acct.lowercased()] = session.accountID
    }

    /// For sign-in, before there is a token.
    init(server: URL, transport: URLSession = .shared) {
        self.server = server
        self.mapper = MastodonMapper(domain: server.host ?? "")
        self.session = nil
        self.transport = transport
    }

    // MARK: Transport

    struct Response: Sendable {
        let data: Data
        let status: Int
        let link: String?
    }

    enum Body: Sendable {
        case none
        case form([(String, String)])
        case multipart(Data, boundary: String)
    }

    func send(
        _ method: String, _ path: String, query: [(String, String?)] = [], body: Body = .none, authorized: Bool = true
    ) async throws -> Response {
        var components = URLComponents(url: server.appending(path: path), resolvingAgainstBaseURL: false)
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty {
            components?.queryItems = items
            let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            components?.percentEncodedQuery = encoded
        }
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let token = session?.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        switch body {
        case .none:
            break
        case .form(let fields):
            request.httpBody = Self.formEncoded(fields).data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case .multipart(let data, let boundary):
            request.httpBody = data
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return Response(data: data, status: status, link: http?.value(forHTTPHeaderField: "Link"))
    }

    func get<T: Decodable & Sendable>(_ path: String, query: [(String, String?)] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decode(try await send("GET", path, query: query).data)
    }

    func post<T: Decodable & Sendable>(_ path: String, form: [(String, String)] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decode(try await send("POST", path, body: .form(form)).data)
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    static func error(status: Int, data: Data) -> XRPCError {
        let message = (try? JSONDecoder().decode(Mastodon.ErrorPayload.self, from: data))?.error
        if status == 401 {
            return XRPCError(status: status, code: "AuthenticationRequired", message: message)
        }
        return XRPCError(status: status, code: nil, message: message)
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedName)=\(encodedValue)"
        }.joined(separator: "&")
    }

    /// The `max_id` of the next page. Only that value is taken from the header, never the address,
    /// so a server cannot send the app elsewhere.
    static func nextCursor(fromLink header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end,
                  let components = URLComponents(string: String(part[part.index(after: start)..<end])) else { continue }
            return components.queryItems?.first { $0.name == "max_id" }?.value
        }
        return nil
    }

    // MARK: Accounts

    /// The id of an account on this server. Looks it up, and asks the server to fetch it if it does not know it yet.
    func accountID(for actor: String) async throws -> String {
        let key = actor.lowercased()
        if let id = accountIDs[key] { return id }
        let account: Mastodon.Account
        if let found = try? await get("api/v1/accounts/lookup", query: [("acct", actor)], as: Mastodon.Account.self) {
            account = found
        } else {
            let results: Mastodon.SearchResults = try await get("api/v2/search", query: [
                ("q", "@\(actor)"), ("type", "accounts"), ("resolve", "true"), ("limit", "1"),
            ])
            guard let first = results.accounts?.values.first else {
                throw XRPCError(status: 404, code: nil, message: tr("Profil nicht gefunden.", "Profile not found."))
            }
            account = first
        }
        accountIDs[key] = account.id
        return account.id
    }

    func verifyCredentials() async throws -> Mastodon.Account {
        try await get("api/v1/accounts/verify_credentials")
    }

    func instanceInfo() async throws -> Mastodon.Instance {
        if let instance { return instance }
        let info: Mastodon.Instance = try await get("api/v2/instance")
        instance = info
        return info
    }

    func lists() async throws -> [Mastodon.List] {
        try await get("api/v1/lists")
    }

    // MARK: SocialReader

    func fetchPage(kind: ColumnKind, cursor: String?, limit: Int) async throws -> FeedPage {
        let limitValue = String(min(limit, 40))
        var query: [(String, String?)] = [("limit", limitValue), ("max_id", cursor)]
        switch kind {
        case .rss, .feedly:
            throw Self.unsupported
        case .home:
            return try await statusPage("api/v1/timelines/home", query)
        case .localTimeline:
            return try await statusPage("api/v1/timelines/public", query + [("local", "true")])
        case .federatedTimeline:
            return try await statusPage("api/v1/timelines/public", query)
        case .author(let actor):
            let id = try await accountID(for: actor)
            return try await statusPage("api/v1/accounts/\(id)/statuses", query + [("exclude_replies", "true")])
        case .ownPosts(let actor):
            let id = try await accountID(for: actor)
            return try await statusPage("api/v1/accounts/\(id)/statuses", query)
        case .profileTab(let actor, let tab):
            let id = try await accountID(for: actor)
            switch tab {
            case .posts: query.append(("exclude_replies", "true"))
            case .replies: break
            case .media: query.append(("only_media", "true"))
            }
            return try await statusPage("api/v1/accounts/\(id)/statuses", query)
        case .likes:
            return try await statusPage("api/v1/favourites", query)
        case .bookmarks:
            return try await statusPage("api/v1/bookmarks", query)
        case .list(let id, _):
            guard id.allSatisfy(\.isNumber) else { throw Self.unsupported }
            return try await statusPage("api/v1/timelines/list/\(id)", query)
        case .messages:
            let response = try await send("GET", "api/v1/conversations", query: query)
            let conversations: LossyList<Mastodon.Conversation> = try Self.decode(response.data)
            let items = conversations.values.compactMap(\.last_status).compactMap(mapper.feedItem).map(ColumnItem.post)
            return FeedPage(items: items, cursor: Self.nextCursor(fromLink: response.link))
        case .notifications:
            return try await notificationPage(query)
        case .mentions:
            return try await notificationPage(query + [("types[]", "mention"), ("types[]", "quote")])
        case .search(let term):
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), MastodonTag.isValid(String(trimmed.dropFirst())) {
                return try await statusPage("api/v1/timelines/tag/\(trimmed.dropFirst())", query)
            }
            // Full-text search pages by position rather than by id.
            let offset = Int(cursor ?? "") ?? 0
            let results: Mastodon.SearchResults = try await get("api/v2/search", query: [
                ("q", trimmed), ("type", "statuses"), ("limit", limitValue), ("offset", String(offset)),
            ])
            let statuses = results.statuses?.values ?? []
            return FeedPage(
                items: statuses.compactMap(mapper.feedItem).map(ColumnItem.post),
                cursor: statuses.isEmpty ? nil : String(offset + statuses.count)
            )
        case .feed:
            throw Self.unsupported
        }
    }

    static let unsupported = XRPCError(
        status: 0, code: nil,
        message: tr("Das gibt es bei Mastodon nicht.", "Mastodon does not have this.")
    )

    private func statusPage(_ path: String, _ query: [(String, String?)]) async throws -> FeedPage {
        let response = try await send("GET", path, query: query)
        let statuses: LossyList<Mastodon.Status> = try Self.decode(response.data)
        return FeedPage(
            items: statuses.values.compactMap(mapper.feedItem).map(ColumnItem.post),
            cursor: Self.nextCursor(fromLink: response.link)
        )
    }

    private func notificationPage(_ query: [(String, String?)]) async throws -> FeedPage {
        let response = try await send("GET", "api/v1/notifications", query: query)
        let notifications: LossyList<Mastodon.Notification> = try Self.decode(response.data)
        return FeedPage(
            items: notifications.values.map(mapper.notification).map(ColumnItem.notification),
            cursor: Self.nextCursor(fromLink: response.link)
        )
    }

    func status(id: String) async throws -> Mastodon.Status {
        try await get("api/v1/statuses/\(id)")
    }

    func thread(uri: String) async throws -> ThreadContent {
        guard let id = MastodonID.statusID(fromURI: uri) else { throw URLError(.badURL) }
        async let main = status(id: id)
        async let context: Mastodon.Context = get("api/v1/statuses/\(id)/context")
        guard let post = mapper.post(try await main) else {
            throw XRPCError(status: 0, code: nil, message: tr("Dieser Post ist durch deine Filter ausgeblendet.", "This post is hidden by your filters."))
        }
        let loaded = try await context
        return ThreadContent(
            parents: loaded.ancestors.values.compactMap(mapper.post),
            post: post,
            // Direct answers only, like a Bluesky thread shown one level deep.
            replies: loaded.descendants.values.filter { $0.in_reply_to_id == id }.compactMap(mapper.post)
        )
    }

    func account(actor: String) async throws -> Mastodon.Account {
        try await get("api/v1/accounts/\(try await accountID(for: actor))")
    }

    func profile(actor: String) async throws -> Profile {
        mapper.profile(try await account(actor: actor))
    }

    func profileDetail(actor: String) async throws -> ProfileDetail {
        let account = try await account(actor: actor)
        let relationships: [Mastodon.Relationship]? = session == nil ? nil : try? await get(
            "api/v1/accounts/relationships", query: [("id[]", account.id)]
        )
        return mapper.profileDetail(account, relationship: relationships?.first)
    }

    private func people(_ path: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        let response = try await send("GET", path, query: [("limit", "40"), ("max_id", cursor)])
        let accounts: LossyList<Mastodon.Account> = try Self.decode(response.data)
        return (accounts.values.map(mapper.profile), Self.nextCursor(fromLink: response.link))
    }

    func likers(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        guard let id = MastodonID.statusID(fromURI: uri) else { throw URLError(.badURL) }
        return try await people("api/v1/statuses/\(id)/favourited_by", cursor: cursor)
    }

    func reposters(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        guard let id = MastodonID.statusID(fromURI: uri) else { throw URLError(.badURL) }
        return try await people("api/v1/statuses/\(id)/reblogged_by", cursor: cursor)
    }

    func quotes(of uri: String, cursor: String?) async throws -> (posts: [PostView], cursor: String?) {
        guard let id = MastodonID.statusID(fromURI: uri) else { throw URLError(.badURL) }
        let response = try await send("GET", "api/v1/statuses/\(id)/quotes", query: [("limit", "40"), ("max_id", cursor)])
        let statuses: LossyList<Mastodon.Status> = try Self.decode(response.data)
        return (statuses.values.compactMap(mapper.post), Self.nextCursor(fromLink: response.link))
    }

    func followers(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        try await people("api/v1/accounts/\(try await accountID(for: actor))/followers", cursor: cursor)
    }

    func follows(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        try await people("api/v1/accounts/\(try await accountID(for: actor))/following", cursor: cursor)
    }

    func suggestPeople(matching term: String) async throws -> [Profile] {
        let accounts: LossyList<Mastodon.Account> = try await get("api/v1/accounts/search", query: [
            ("q", term), ("limit", "8"), ("resolve", "false"),
        ])
        return accounts.values.map(mapper.profile)
    }

    // MARK: Interactions

    private func statusAction(_ uri: String, _ action: String) async throws {
        guard let id = MastodonID.statusID(fromURI: uri) else { throw URLError(.badURL) }
        _ = try await send("POST", "api/v1/statuses/\(id)/\(action)", body: .form([]))
    }

    func setFavourite(_ uri: String, _ on: Bool) async throws {
        try await statusAction(uri, on ? "favourite" : "unfavourite")
    }

    func setReblog(_ uri: String, _ on: Bool) async throws {
        try await statusAction(uri, on ? "reblog" : "unreblog")
    }

    func setBookmark(_ uri: String, _ on: Bool) async throws {
        try await statusAction(uri, on ? "bookmark" : "unbookmark")
    }

    func deleteStatus(_ uri: String) async throws {
        guard let id = MastodonID.statusID(fromURI: uri) else { throw URLError(.badURL) }
        _ = try await send("DELETE", "api/v1/statuses/\(id)")
    }

    /// Returns the new relationship, which says whether the follow is pending approval.
    @discardableResult
    func accountAction(_ actor: String, _ action: String) async throws -> Mastodon.Relationship {
        let id = try await accountID(for: actor)
        return try Self.decode(try await send("POST", "api/v1/accounts/\(id)/\(action)", body: .form([])).data)
    }

    // MARK: Notifications

    func unreadNotificationCount() async throws -> Int {
        if let unread = try? await get("api/v1/notifications/unread_count", as: Mastodon.UnreadCount.self) {
            return unread.count
        }
        let markers: Mastodon.Marker = try await get("api/v1/markers", query: [("timeline[]", "notifications")])
        let notifications: LossyList<Mastodon.Notification> = try await get("api/v1/notifications", query: [
            ("limit", "40"), ("since_id", markers.notifications?.last_read_id),
        ])
        return notifications.values.count
    }

    func markNotificationsSeen() async throws {
        let latest: LossyList<Mastodon.Notification> = try await get("api/v1/notifications", query: [("limit", "1")])
        guard let id = latest.values.first?.id else { return }
        _ = try await send("POST", "api/v1/markers", body: .form([("notifications[last_read_id]", id)]))
    }

    func latestNotifications(limit: Int) async throws -> [RawNotification] {
        let notifications: LossyList<Mastodon.Notification> = try await get("api/v1/notifications", query: [
            ("limit", String(limit)),
        ])
        return notifications.values.map { mapper.notification($0).raw }
    }

    // MARK: Posting

    /// Uploads a picture or video and waits until the server has processed it.
    func uploadMedia(data: Data, mimeType: String, filename: String, description: String, pollInterval: Duration = .seconds(2)) async throws -> String {
        let boundary = "BlueSkyship-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        if !description.isEmpty { field("description", description) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let response = try await send("POST", "api/v2/media", body: .multipart(body, boundary: boundary))
        let upload: Mastodon.MediaUpload = try Self.decode(response.data)
        // 202 means the server still converts the file. Posting it before then fails.
        if response.status == 202 || upload.url == nil {
            for _ in 0..<150 {
                try await Task.sleep(for: pollInterval)
                let check = try await send("GET", "api/v1/media/\(upload.id)")
                if check.status == 200, (try? Self.decode(check.data) as Mastodon.MediaUpload)?.url != nil { break }
            }
        }
        return upload.id
    }

    /// Posts one status and returns its URI in the app's form.
    func postStatus(
        text: String, replyTo: String?, quote: String?, mediaIDs: [String], options: MastodonPostOptions, language: String?
    ) async throws -> String {
        var form: [(String, String)] = [("status", text), ("visibility", options.visibility.rawValue)]
        if let replyTo, let id = MastodonID.statusID(fromURI: replyTo) { form.append(("in_reply_to_id", id)) }
        if let quote, let id = MastodonID.statusID(fromURI: quote) { form.append(("quoted_status_id", id)) }
        for id in mediaIDs { form.append(("media_ids[]", id)) }
        let spoiler = options.spoilerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoiler.isEmpty {
            form.append(("spoiler_text", spoiler))
            form.append(("sensitive", "true"))
        }
        if let language { form.append(("language", language)) }
        let status: Mastodon.Status = try await post("api/v1/statuses", form: form)
        return MastodonID.postURI(domain: mapper.domain, statusID: status.id)
    }

    /// Sends the texts as a chain of replies, like a Bluesky thread. Stops at the first error and says how far it got.
    func createThread(
        texts: [String], first: PostDraft, laterImages: [Int: [DraftImage]], options: MastodonPostOptions
    ) async -> ThreadResult {
        var result = ThreadResult(continuation: first.reply)
        for (index, text) in texts.enumerated() {
            do {
                var mediaIDs: [String] = []
                let images = index == 0 ? first.images : (laterImages[index] ?? [])
                for (number, image) in images.enumerated() {
                    mediaIDs.append(try await uploadMedia(
                        data: image.prepared.data, mimeType: image.prepared.mimeType,
                        filename: "image\(number + 1).\(image.prepared.mimeType == "image/png" ? "png" : "jpg")",
                        description: image.alt
                    ))
                }
                if index == 0, let video = first.video {
                    mediaIDs.append(try await uploadMedia(
                        data: video.data, mimeType: "video/mp4", filename: "video.mp4", description: video.alt
                    ))
                }
                let uri = try await postStatus(
                    text: text,
                    replyTo: result.continuation?.parent.uri,
                    quote: index == 0 ? first.quote?.uri : nil,
                    mediaIDs: mediaIDs,
                    options: index == 0 ? options : MastodonPostOptions(visibility: options.visibility, spoilerText: options.spoilerText),
                    language: first.langs.first
                )
                let ref = StrongRef(uri: uri, cid: "")
                result.continuation = ReplyRef(root: result.continuation?.root ?? ref, parent: ref)
                result.sent += 1
            } catch {
                result.error = error
                return result
            }
        }
        return result
    }

    /// Counts like Mastodon does: every link as a fixed length, and a mention only by its name.
    static func characterCount(_ text: String, urlLength: Int = 23) -> Int {
        var counted = text
        if let links = try? NSRegularExpression(pattern: #"https?://\S+"#) {
            counted = links.stringByReplacingMatches(
                in: counted, range: NSRange(counted.startIndex..., in: counted),
                withTemplate: String(repeating: "x", count: urlLength)
            )
        }
        if let mentions = try? NSRegularExpression(pattern: #"(@[\w.-]+)@[\w.-]+\.\w+"#) {
            counted = mentions.stringByReplacingMatches(
                in: counted, range: NSRange(counted.startIndex..., in: counted), withTemplate: "$1"
            )
        }
        return counted.count
    }

    // MARK: Sign-out

    func revokeToken() async {
        guard let session else { return }
        _ = try? await send("POST", "oauth/revoke", body: .form([
            ("client_id", session.clientID), ("client_secret", session.clientSecret), ("token", session.accessToken),
        ]), authorized: false)
    }
}
