import Foundation

/// The list of subscriptions that Feedly and every other feed reader can export.
struct OPMLFolder: Equatable, Sendable {
    var name: String
    var feeds: [OPMLFeed]
}

struct OPMLFeed: Equatable, Sendable {
    var title: String
    var url: String
}

final class OPMLParser: NSObject, XMLParserDelegate {
    /// One folder per category, in the file's order. Feeds outside any category go into one folder named `looseName`.
    static func parse(_ data: Data, looseName: String = tr("Feeds", "Feeds")) throws -> [OPMLFolder] {
        let delegate = OPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        guard delegate.sawOPML else { throw FeedParseError.notAFeed }
        var folders = delegate.folders.filter { !$0.feeds.isEmpty }
        if !delegate.loose.isEmpty { folders.append(OPMLFolder(name: looseName, feeds: delegate.loose)) }
        return folders
    }

    private var sawOPML = false
    private var folders: [OPMLFolder] = []
    private var loose: [OPMLFeed] = []
    /// For each open outline: the index of the folder it opened, if it is a folder.
    private var stack: [Int?] = []

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if name.lowercased() == "opml" { sawOPML = true }
        guard name.lowercased() == "outline" else { return }
        let title = attributes["title"] ?? attributes["text"] ?? ""
        if let xmlURL = attributes["xmlUrl"] ?? attributes["xmlurl"], let url = FeedFetcher.normalize(xmlURL) {
            let feed = OPMLFeed(title: title, url: url.absoluteString)
            // A feed belongs to the nearest folder above it; nested folders count as their outermost one.
            if let folder = stack.compactMap({ $0 }).first {
                if !folders[folder].feeds.contains(feed) { folders[folder].feeds.append(feed) }
            } else if !loose.contains(feed) {
                loose.append(feed)
            }
            stack.append(nil)
        } else if stack.compactMap({ $0 }).isEmpty {
            folders.append(OPMLFolder(name: title.isEmpty ? tr("Ordner", "Folder") : title, feeds: []))
            stack.append(folders.count - 1)
        } else {
            stack.append(nil)
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name.lowercased() == "outline", !stack.isEmpty { stack.removeLast() }
    }
}
