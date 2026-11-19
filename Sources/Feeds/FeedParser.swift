import Foundation

/// One article as a feed describes it, before it becomes something a column can show.
struct FeedEntry: Equatable, Sendable {
    var id: String
    var title: String
    var link: String?
    /// HTML or plain text, whichever the feed sent. The longer one of summary and content.
    var html: String
    var author: String?
    var published: Date?
    var imageURL: String?
}

struct ParsedFeed: Equatable, Sendable {
    var title: String
    /// The website the feed belongs to.
    var siteLink: String?
    var entries: [FeedEntry]
}

enum FeedParseError: LocalizedError, Equatable {
    case notAFeed

    var errorDescription: String? {
        tr("Unter dieser Adresse liegt kein RSS- oder Atom-Feed.", "There is no RSS or Atom feed at this address.")
    }
}

/// Reads RSS 2.0, RSS 1.0 (RDF) and Atom. Feeds in the wild bend every rule, so this reads what it
/// can and skips the rest rather than failing on the first odd element.
final class FeedParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Feeds never need outside entities, and loading them would let a feed reach other files.
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        guard delegate.sawFeedRoot, ok || !delegate.entries.isEmpty else { throw FeedParseError.notAFeed }
        return ParsedFeed(
            title: Self.clean(delegate.feedTitle),
            siteLink: delegate.siteLink,
            entries: delegate.entries
        )
    }

    private var sawFeedRoot = false
    private var isAtom = false
    private var path: [String] = []
    private var buffer = ""
    private var feedTitle = ""
    private var siteLink: String?
    private var entries: [FeedEntry] = []
    private var current: Draft?

    private struct Draft {
        var id = ""
        var title = ""
        var link: String?
        var summary = ""
        var content = ""
        var author: String?
        var date: String?
        var imageURL: String?
    }

    private static let itemNames: Set<String> = ["item", "entry"]

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        let element = name.lowercased()
        if path.isEmpty {
            sawFeedRoot = ["rss", "feed", "rdf:rdf"].contains(element)
            isAtom = element == "feed"
        }
        path.append(element)
        buffer = ""

        if Self.itemNames.contains(element) {
            current = Draft()
            if let about = attributes["rdf:about"] { current?.id = about }
            return
        }
        if element == "link", isAtom || attributes["href"] != nil {
            // Atom: <link rel="alternate" href="…"/>. The first alternate or rel-less link wins.
            let rel = attributes["rel"] ?? "alternate"
            guard let href = attributes["href"] else { return }
            if current != nil {
                if rel == "alternate", current?.link == nil { current?.link = href }
                if rel == "enclosure", attributes["type"]?.hasPrefix("image/") == true, current?.imageURL == nil {
                    current?.imageURL = href
                }
            } else if rel == "alternate", siteLink == nil {
                siteLink = href
            }
            return
        }
        guard current != nil else { return }
        switch element {
        case "enclosure":
            if attributes["type"]?.hasPrefix("image/") == true, current?.imageURL == nil {
                current?.imageURL = attributes["url"]
            }
        case "media:thumbnail":
            if current?.imageURL == nil { current?.imageURL = attributes["url"] }
        case "media:content":
            let isImage = attributes["medium"] == "image" || attributes["type"]?.hasPrefix("image/") == true
            if isImage, current?.imageURL == nil { current?.imageURL = attributes["url"] }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        buffer += String(decoding: block, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = name.lowercased()
        defer {
            if !path.isEmpty { path.removeLast() }
            buffer = ""
        }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.itemNames.contains(element), let draft = current {
            current = nil
            entries.append(Self.entry(from: draft))
            return
        }
        guard current != nil else {
            // The channel's own title sits directly under <channel> or <feed>.
            let parent = path.dropLast().last
            if element == "title", feedTitle.isEmpty, parent == "channel" || parent == "feed" { feedTitle = text }
            if element == "link", siteLink == nil, parent == "channel", !text.isEmpty { siteLink = text }
            return
        }
        // Atom puts the author's name one level deeper: <author><name>…</name></author>.
        if element == "name", path.count >= 3, path[path.count - 2] == "author",
           Self.itemNames.contains(path[path.count - 3]), current?.author == nil, !text.isEmpty {
            current?.author = text
            return
        }
        // Only direct children of the item count; a <title> inside <source> or <media:group> does not.
        guard let parent = path.dropLast().last, Self.itemNames.contains(parent) else { return }
        switch element {
        case "title": current?.title = text
        case "link" where !text.isEmpty: if current?.link == nil { current?.link = text }
        case "guid", "id": if current?.id.isEmpty == true { current?.id = text }
        case "description", "summary": current?.summary = text
        case "content:encoded", "content": current?.content = text
        case "author", "dc:creator": if current?.author == nil, !text.isEmpty { current?.author = text }
        case "pubdate", "published", "dc:date", "updated":
            if current?.date == nil || element == "published" { current?.date = text }
        default: break
        }
    }

    private static func entry(from draft: Draft) -> FeedEntry {
        let html = draft.content.count > draft.summary.count ? draft.content : draft.summary
        let title = clean(draft.title)
        let link = draft.link?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = draft.id.isEmpty ? (link ?? title) : draft.id
        return FeedEntry(
            id: id,
            title: title,
            link: link,
            html: html,
            author: draft.author.map(clean),
            published: draft.date.flatMap(FeedDate.parse),
            imageURL: draft.imageURL ?? firstImage(in: html)
        )
    }

    /// Titles often carry HTML entities or tags of their own.
    static func clean(_ text: String) -> String {
        guard text.contains("<") || text.contains("&") else { return text }
        return MastodonHTML.plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first picture in the article, for feeds that name no picture of their own.
    static func firstImage(in html: String) -> String? {
        guard let tag = html.range(of: "<img", options: .caseInsensitive) else { return nil }
        let rest = html[tag.upperBound...]
        guard let end = rest.firstIndex(of: ">") else { return nil }
        let attributes = rest[..<end]
        guard let src = attributes.range(of: "src=", options: .caseInsensitive) else { return nil }
        var value = attributes[src.upperBound...]
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        value = value.dropFirst()
        guard let close = value.firstIndex(of: quote) else { return nil }
        let url = String(value[..<close]).replacingOccurrences(of: "&amp;", with: "&")
        return url.lowercased().hasPrefix("https://") ? url : nil
    }
}

/// Feeds write dates in RFC 822 (RSS) or ISO 8601 (Atom), and both with every variation.
enum FeedDate {
    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "EEE, dd MMM yyyy HH:mm Z",
    ]

    static func parse(_ string: String) -> Date? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = ATDate.parse(text) { return date }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in rfc822Formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
