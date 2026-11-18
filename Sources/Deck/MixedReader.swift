import Foundation

/// Reads one search from several accounts at once, usually one on Bluesky and one on Mastodon,
/// and shows the results as one list, newest first. Every post remembers which account found it,
/// so liking, replying and opening it go through that account.
struct MixedReader: SocialReader {
    struct Source: Sendable {
        let accountDID: String
        let reader: any SocialReader
        var isMastodon: Bool
    }

    let sources: [Source]

    /// The next page of every source, by account. A source without an entry is done.
    struct Cursor: Codable, Equatable {
        var next: [String: String]
    }

    static func encode(_ cursor: Cursor) -> String? {
        guard !cursor.next.isEmpty, let data = try? JSONEncoder().encode(cursor) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String?) -> Cursor? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Cursor.self, from: data)
    }

    func fetchPage(kind: ColumnKind, cursor: String?, limit: Int) async throws -> FeedPage {
        let previous = Self.decode(cursor)
        // On later pages only the sources that still have more are asked.
        let active = sources.filter { previous == nil || previous?.next[$0.accountDID] != nil }
        let results = await withTaskGroup(of: (Int, Result<FeedPage, any Error>).self) { group in
            for (index, source) in active.enumerated() {
                let sourceCursor = previous?.next[source.accountDID]
                group.addTask {
                    do {
                        return (index, .success(try await source.reader.fetchPage(kind: kind, cursor: sourceCursor, limit: limit)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<FeedPage, any Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }

        var items: [ColumnItem] = []
        var next = Cursor(next: [:])
        var firstError: (any Error)?
        for (index, result) in results {
            let source = active[index]
            switch result {
            case .success(let page):
                items += page.items.map { Self.tag($0, with: source.accountDID) }
                if let more = page.cursor { next.next[source.accountDID] = more }
            case .failure(let error):
                // One network being down must not empty the column; the other still shows.
                firstError = firstError ?? error
            }
        }
        if items.isEmpty, let firstError, results.allSatisfy({ if case .failure = $0.1 { return true } else { return false } }) {
            throw firstError
        }
        items.sort { (Self.date($0) ?? .distantPast) > (Self.date($1) ?? .distantPast) }
        return FeedPage(items: items.removingDuplicateIDs(), cursor: Self.encode(next))
    }

    static func tag(_ item: ColumnItem, with accountDID: String) -> ColumnItem {
        switch item {
        case .post(var entry):
            entry.post.sourceAccountDID = accountDID
            return .post(entry)
        case .notification:
            return item
        }
    }

    private static func date(_ item: ColumnItem) -> Date? {
        switch item {
        case .post(let entry): return entry.post.date
        case .notification(let entry): return ATDate.parse(entry.raw.indexedAt)
        }
    }

    // Everything else goes to the network the post or person belongs to.

    private func source(forURI uri: String) throws -> any SocialReader {
        let mastodon = MastodonID.isPostURI(uri)
        guard let source = sources.first(where: { $0.isMastodon == mastodon }) else { throw URLError(.unsupportedURL) }
        return source.reader
    }

    private func source(forActor actor: String) throws -> any SocialReader {
        let mastodon = MastodonID.isActor(actor)
        guard let source = sources.first(where: { $0.isMastodon == mastodon }) else { throw URLError(.unsupportedURL) }
        return source.reader
    }

    func thread(uri: String) async throws -> ThreadContent { try await source(forURI: uri).thread(uri: uri) }
    func profile(actor: String) async throws -> Profile { try await source(forActor: actor).profile(actor: actor) }
    func profileDetail(actor: String) async throws -> ProfileDetail { try await source(forActor: actor).profileDetail(actor: actor) }
    func likers(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        try await source(forURI: uri).likers(of: uri, cursor: cursor)
    }
    func reposters(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        try await source(forURI: uri).reposters(of: uri, cursor: cursor)
    }
    func quotes(of uri: String, cursor: String?) async throws -> (posts: [PostView], cursor: String?) {
        try await source(forURI: uri).quotes(of: uri, cursor: cursor)
    }
    func followers(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        try await source(forActor: actor).followers(of: actor, cursor: cursor)
    }
    func follows(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) {
        try await source(forActor: actor).follows(of: actor, cursor: cursor)
    }
    func suggestPeople(matching term: String) async throws -> [Profile] {
        guard let first = sources.first else { return [] }
        return try await first.reader.suggestPeople(matching: term)
    }
}
