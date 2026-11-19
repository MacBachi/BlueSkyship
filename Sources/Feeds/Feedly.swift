import Foundation

enum FeedlyError: LocalizedError {
    case notConnected
    case rejected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return tr("Feedly ist nicht verbunden. Unter Einstellungen → Feeds einen Zugangsschlüssel eintragen.",
                      "Feedly is not connected. Enter an access token under Settings → Feeds.")
        case .rejected:
            return tr("Feedly hat den Zugangsschlüssel abgelehnt. Er ist vielleicht abgelaufen.",
                      "Feedly rejected the access token. It may have expired.")
        }
    }
}

enum Feedly {
    struct Profile: Decodable, Sendable {
        let id: String
        var fullName: String?
        var email: String?
    }

    struct Collection: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        var label: String?
        var feeds: [Feed]?
    }

    struct Feed: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        var title: String?
        var website: String?
        var visualUrl: String?
    }

    struct Stream: Decodable, Sendable {
        var continuation: String?
        var items: [Entry]
    }

    struct Entry: Decodable, Sendable {
        struct Content: Decodable, Sendable { var content: String? }
        struct Origin: Decodable, Sendable {
            var streamId: String?
            var title: String?
            var htmlUrl: String?
        }
        struct Link: Decodable, Sendable { var href: String? }
        struct Visual: Decodable, Sendable { var url: String? }

        let id: String
        var title: String?
        var author: String?
        var published: Double?
        var crawled: Double?
        var canonicalUrl: String?
        var alternate: [Link]?
        var summary: Content?
        var content: Content?
        var origin: Origin?
        var visual: Visual?
    }

    /// What the app keeps after connecting: the token goes to the Keychain, the rest is not secret.
    struct Connection: Codable, Equatable, Sendable {
        var token: String
        var userID: String
        var name: String
    }

    static let baseURL = URL(string: "https://cloud.feedly.com/v3/")!
    /// Where Feedly hands out access tokens.
    static let tokenPageURL = URL(string: "https://feedly.com/i/team/api")!
    /// Where Feedly offers its subscriptions as an OPML file.
    static let opmlExportURL = URL(string: "https://feedly.com/i/opml")!

    /// Feedly's own name for "everything I subscribe to".
    static func allStreamID(userID: String) -> String { "user/\(userID)/category/global.all" }

    static func entryPost(_ entry: Entry) -> PostView {
        let feedURL = entry.origin?.streamId.map { $0.hasPrefix("feed/") ? String($0.dropFirst(5)) : $0 } ?? "feedly"
        let link = entry.canonicalUrl ?? entry.alternate?.first?.href
        let summary = entry.summary?.content ?? ""
        let content = entry.content?.content ?? ""
        let published = (entry.published ?? entry.crawled).map { Date(timeIntervalSince1970: $0 / 1000) }
        let visual = entry.visual?.url.flatMap { $0 == "none" ? nil : $0 }
        let feedEntry = FeedEntry(
            id: entry.id,
            title: FeedParser.clean(entry.title ?? ""),
            link: link,
            html: content.count > summary.count ? content : summary,
            author: entry.author,
            published: published,
            imageURL: visual ?? FeedParser.firstImage(in: content.isEmpty ? summary : content)
        )
        return ArticleMapper.post(
            feedEntry, feedTitle: entry.origin?.title ?? "", feedURL: feedURL, siteLink: entry.origin?.htmlUrl
        )
    }
}

/// Reads a Feedly account. Feedly gives the sign-in that other apps use only to partners it chose,
/// so this works with an access token that the person creates at Feedly and pastes in.
actor FeedlyClient {
    let connection: Feedly.Connection
    private let transport: URLSession
    private let baseURL: URL

    init(connection: Feedly.Connection, transport: URLSession = .shared, baseURL: URL = Feedly.baseURL) {
        self.connection = connection
        self.transport = transport
        self.baseURL = baseURL
    }

    /// Checks a token and learns whose it is.
    static func connect(token: String, transport: URLSession = .shared, baseURL: URL = Feedly.baseURL) async throws -> Feedly.Connection {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeedlyError.rejected }
        let profile: Feedly.Profile = try await get("profile", token: trimmed, transport: transport, baseURL: baseURL)
        return Feedly.Connection(token: trimmed, userID: profile.id, name: profile.fullName ?? profile.email ?? "Feedly")
    }

    func collections() async throws -> [Feedly.Collection] {
        try await Self.get("collections", token: connection.token, transport: transport, baseURL: baseURL)
    }

    func page(streamID: String, continuation: String?, count: Int) async throws -> FeedPage {
        var query = [URLQueryItem(name: "streamId", value: streamID), URLQueryItem(name: "count", value: String(min(max(count, 1), 100)))]
        if let continuation { query.append(URLQueryItem(name: "continuation", value: continuation)) }
        let stream: Feedly.Stream = try await Self.get("streams/contents", query: query, token: connection.token, transport: transport, baseURL: baseURL)
        let items = stream.items.map { ColumnItem.post(FeedViewPost(post: Feedly.entryPost($0))) }
        return FeedPage(items: items.removingDuplicateIDs(), cursor: stream.continuation)
    }

    private static func get<T: Decodable>(
        _ path: String, query: [URLQueryItem] = [], token: String, transport: URLSession, baseURL: URL
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw FeedlyError.rejected }
            if http.statusCode == 429 {
                throw XRPCError(status: 429, code: nil, message: tr("Feedly lässt gerade keine weiteren Abfragen zu. Später erneut versuchen.", "Feedly allows no more requests right now. Try again later."))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw XRPCError(status: http.statusCode, code: nil, message: tr("Feedly antwortet mit Fehler \(http.statusCode).", "Feedly answered with error \(http.statusCode)."))
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// The Feedly token is a password in all but name, so it lives in the Keychain.
enum FeedlyKeychain {
    private static let service = "dev.blueskyship.feedly"
    private static let account = "feedly"

    static func save(_ connection: Feedly.Connection) {
        guard !RuntimeEnvironment.isUnitTestHost, let data = try? JSONEncoder().encode(connection) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Feedly.Connection? {
        guard !RuntimeEnvironment.isUnitTestHost else { return nil }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Feedly.Connection.self, from: data)
    }

    static func delete() {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
