import Foundation

/// Reads RSS, Atom and Feedly columns. Articles cannot be answered or liked, so everything
/// besides reading pages is unsupported here.
struct FeedReader: SocialReader {
    var transport: URLSession = .shared
    var feedly: FeedlyClient?

    func fetchPage(kind: ColumnKind, cursor: String?, limit: Int) async throws -> FeedPage {
        switch kind {
        case .rss(let feeds, _):
            // Feeds have no pages: everything they offer arrives at once.
            guard cursor == nil else { return FeedPage(items: [], cursor: nil) }
            return try await Self.read(feeds: feeds, transport: transport)
        case .feedly(let streamID, _):
            guard let feedly else { throw FeedlyError.notConnected }
            return try await feedly.page(streamID: streamID, continuation: cursor, count: limit)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    /// All feeds at once, newest first. One broken feed does not empty a column of several.
    static func read(feeds: [String], transport: URLSession) async throws -> FeedPage {
        let results = await withTaskGroup(of: Result<[PostView], any Error>.self) { group in
            for feed in feeds {
                group.addTask {
                    do {
                        let parsed = try await FeedFetcher.fetch(feed, transport: transport)
                        return .success(parsed.entries.map {
                            ArticleMapper.post($0, feedTitle: parsed.title, feedURL: feed, siteLink: parsed.siteLink)
                        })
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var all: [Result<[PostView], any Error>] = []
            for await result in group { all.append(result) }
            return all
        }
        var posts: [PostView] = []
        var firstError: (any Error)?
        for result in results {
            switch result {
            case .success(let found): posts += found
            case .failure(let error): firstError = firstError ?? error
            }
        }
        if posts.isEmpty, let firstError { throw firstError }
        posts.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let items = posts.map { ColumnItem.post(FeedViewPost(post: $0)) }
        return FeedPage(items: items.removingDuplicateIDs(), cursor: nil)
    }

    func thread(uri: String) async throws -> ThreadContent { throw URLError(.unsupportedURL) }
    func profile(actor: String) async throws -> Profile { throw URLError(.unsupportedURL) }
    func profileDetail(actor: String) async throws -> ProfileDetail { throw URLError(.unsupportedURL) }
    func likers(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) { ([], nil) }
    func reposters(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) { ([], nil) }
    func quotes(of uri: String, cursor: String?) async throws -> (posts: [PostView], cursor: String?) { ([], nil) }
    func followers(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) { ([], nil) }
    func follows(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?) { ([], nil) }
    func suggestPeople(matching term: String) async throws -> [Profile] { [] }
}

/// Fetches one feed, and finds the feed behind a website address.
enum FeedFetcher {
    /// Feeds can be large, but nothing a reader shows needs more than this.
    static let maxBytes = 5_000_000

    /// Accepts `example.com`, `https://example.com/feed` and `feed://…`. Plain http becomes https,
    /// because the app only talks to encrypted addresses.
    static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        for prefix in ["feed://", "feed:", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = "https://" + text.dropFirst(prefix.count)
        }
        if !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard let url = URL(string: text), LinkPolicy.isWebURL(url), url.host?.contains(".") == true else { return nil }
        return url
    }

    static func fetch(_ address: String, transport: URLSession) async throws -> ParsedFeed {
        guard let url = normalize(address) else { throw URLError(.badURL) }
        let data = try await download(url, transport: transport)
        return try FeedParser.parse(data)
    }

    /// For a new column: the feed itself, or the first feed a website names in its header.
    static func discover(_ address: String, transport: URLSession = .shared) async throws -> (url: String, feed: ParsedFeed) {
        guard let url = normalize(address) else { throw URLError(.badURL) }
        let data = try await download(url, transport: transport)
        if let feed = try? FeedParser.parse(data) { return (url.absoluteString, feed) }
        let html = String(decoding: data.prefix(500_000), as: UTF8.self)
        // Sites that name no feed in their header often still have one at a usual place.
        let guesses = ["feed", "rss", "feed.xml", "rss.xml", "atom.xml", "index.xml"].compactMap { path in
            url.host.flatMap { URL(string: "https://\($0)/\(path)") }
        }
        var seen = Set<URL>()
        let candidates = (feedLinks(in: html, base: url) + guesses).filter { $0 != url && seen.insert($0).inserted }
        for candidate in candidates {
            if let feedData = try? await download(candidate, transport: transport),
               let feed = try? FeedParser.parse(feedData) {
                return (candidate.absoluteString, feed)
            }
        }
        throw FeedParseError.notAFeed
    }

    static func download(_ url: URL, transport: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("BlueSkyship (RSS reader)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XRPCError(status: http.statusCode, code: nil, message: tr(
                "Der Feed antwortet mit Fehler \(http.statusCode).", "The feed answered with error \(http.statusCode)."
            ))
        }
        guard data.count <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    /// `<link rel="alternate" type="application/rss+xml" href="…">` in a page's head.
    static func feedLinks(in html: String, base: URL) -> [URL] {
        var found: [URL] = []
        var rest = html[...]
        while let start = rest.range(of: "<link", options: .caseInsensitive) {
            guard let end = rest[start.upperBound...].firstIndex(of: ">") else { break }
            let tag = String(rest[start.upperBound..<end])
            rest = rest[end...]
            let lower = tag.lowercased()
            guard lower.contains("alternate"),
                  lower.contains("application/rss+xml") || lower.contains("application/atom+xml") || lower.contains("application/feed+xml"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  let normalized = normalize(url.absoluteString) else { continue }
            found.append(normalized)
        }
        return found
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let value = tag[range.upperBound...]
        guard let quote = value.first, quote == "\"" || quote == "'" else {
            return value.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).first.map(String.init)
        }
        let inner = value.dropFirst()
        return inner.firstIndex(of: quote).map { String(inner[..<$0]) }
    }
}
