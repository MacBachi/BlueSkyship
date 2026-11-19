import Foundation

/// What a column needs to show an article from a feed, beyond what every post has.
struct ArticleInfo: Decodable, Hashable, Sendable {
    /// The article on the publisher's website.
    var link: String?
    var title: String
    /// The whole text as the feed sent it, read through the same safe reader as Mastodon posts.
    var body: String
    var bodyFacets: [Facet]?
    var imageURL: String?
    var author: String?
    /// The feed's name, for the line above the title.
    var source: String
    /// Where the article came from, so a column with several feeds can open just that one.
    var feedURL: String?
}

/// Feed articles become posts, so filters, searching in a column and keyboard focus work on them unchanged.
/// The text a filter looks at is the title, the summary and the link.
enum ArticleMapper {
    /// How much of the article text a column shows. The whole text opens on click.
    static let summaryLength = 320

    static func post(_ entry: FeedEntry, feedTitle: String, feedURL: String, siteLink: String?) -> PostView {
        let link = entry.link.flatMap { resolve($0, against: feedURL) }
        let parsed = MastodonHTML.parse(entry.html)
        let body = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = Self.summary(of: body)
        let title = entry.title.isEmpty ? Self.summary(of: body, length: 80) : entry.title
        let text = summary.isEmpty ? title : "\(title)\n\n\(summary)"
        let date = entry.published.map(ATDate.string) ?? ""
        let host = URL(string: siteLink ?? feedURL)?.host ?? URL(string: feedURL)?.host ?? feedURL
        let author = Profile(
            did: FeedSourceID.author(feedURL: feedURL),
            handle: host,
            displayName: feedTitle.isEmpty ? host : feedTitle,
            avatar: Self.icon(siteLink: siteLink, feedURL: feedURL)
        )
        var post = PostView(
            uri: FeedSourceID.article(feedURL: feedURL, entryID: entry.id),
            cid: "",
            author: author,
            record: PostRecord(text: text, createdAt: date.isEmpty ? nil : date),
            indexedAt: date
        )
        let image = entry.imageURL.flatMap { resolve($0, against: feedURL) }
            .flatMap(URL.init(string:))
            .flatMap { LinkPolicy.isSecureMedia($0) ? $0.absoluteString : nil }
        post.article = ArticleInfo(
            link: link,
            title: title,
            body: body,
            bodyFacets: parsed.facets.isEmpty ? nil : parsed.facets,
            imageURL: image,
            author: entry.author,
            source: feedTitle.isEmpty ? host : feedTitle,
            feedURL: feedURL
        )
        return post
    }

    /// Up to `length` characters, cut at a word, in one paragraph.
    static func summary(of text: String, length: Int = summaryLength) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > length else { return flat }
        let cut = flat.prefix(length)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + " …"
    }

    /// The site's own icon, from the site itself rather than an icon service that would learn what you read.
    static func icon(siteLink: String?, feedURL: String) -> String? {
        guard let url = URL(string: siteLink ?? feedURL), url.scheme == "https", let host = url.host else { return nil }
        return "https://\(host)/favicon.ico"
    }

    static func resolve(_ raw: String, against base: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed, relativeTo: URL(string: base))?.absoluteURL, LinkPolicy.isWebURL(url) else { return nil }
        return url.absoluteString
    }
}

/// Feed articles and feeds get identifiers that can never be taken for a Bluesky or Mastodon one.
enum FeedSourceID {
    static func article(feedURL: String, entryID: String) -> String { "article:\(feedURL)#\(entryID)" }
    static func author(feedURL: String) -> String { "feedsource:\(feedURL)" }
    static func isArticle(_ uri: String) -> Bool { uri.hasPrefix("article:") }
    static func isSource(_ actor: String) -> Bool { actor.hasPrefix("feedsource:") }
}
