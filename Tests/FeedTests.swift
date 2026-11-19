import Foundation
import Testing
@testable import BlueSkyship

private let rss = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:media="http://search.yahoo.com/mrss/">
<channel>
  <title>Beispiel-Blog</title>
  <link>https://blog.example/</link>
  <item>
    <title>Neues &amp; Altes</title>
    <link>https://blog.example/neu</link>
    <guid isPermaLink="false">post-1</guid>
    <pubDate>Tue, 17 Nov 2026 08:30:00 +0100</pubDate>
    <dc:creator>Anna</dc:creator>
    <description>Kurz.</description>
    <content:encoded><![CDATA[<p>Ein <b>langer</b> Text mit <a href="https://example.org/x">Link</a>.</p><p><img src="https://img.example/a.jpg"></p>]]></content:encoded>
    <source url="https://other.example/rss"><title>Fremder Titel</title></source>
  </item>
  <item>
    <title>Zweiter</title>
    <link>/relativ</link>
    <pubDate>Mon, 16 Nov 2026 10:00:00 GMT</pubDate>
    <enclosure url="https://img.example/b.png" type="image/png" length="1"/>
    <description>Über Fußball und anderes.</description>
  </item>
</channel>
</rss>
"""

private let atom = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title>
  <link rel="alternate" href="https://atom.example/"/>
  <link rel="self" href="https://atom.example/feed.xml"/>
  <entry>
    <title type="html">Hallo &lt;em&gt;Welt&lt;/em&gt;</title>
    <link rel="alternate" href="https://atom.example/hallo"/>
    <id>tag:atom.example,2026:1</id>
    <published>2026-11-18T09:00:00Z</published>
    <updated>2026-11-18T10:00:00Z</updated>
    <author><name>Bert</name></author>
    <summary type="html">&lt;p&gt;Zusammenfassung&lt;/p&gt;</summary>
  </entry>
</feed>
"""

@Suite("Feeds: reading RSS and Atom")
struct FeedParsingTests {
    @Test func readsRSS() throws {
        let feed = try FeedParser.parse(Data(rss.utf8))
        #expect(feed.title == "Beispiel-Blog")
        #expect(feed.siteLink == "https://blog.example/")
        #expect(feed.entries.count == 2)
        let first = feed.entries[0]
        #expect(first.title == "Neues & Altes")
        #expect(first.id == "post-1")
        #expect(first.link == "https://blog.example/neu")
        #expect(first.author == "Anna")
        #expect(first.html.contains("langer"))
        #expect(first.imageURL == "https://img.example/a.jpg")
        #expect(first.published == Date(timeIntervalSince1970: 1_794_900_600))
        #expect(feed.entries[1].imageURL == "https://img.example/b.png")
    }

    @Test func readsAtom() throws {
        let feed = try FeedParser.parse(Data(atom.utf8))
        #expect(feed.title == "Atom Feed")
        #expect(feed.siteLink == "https://atom.example/")
        let entry = try #require(feed.entries.first)
        #expect(entry.title == "Hallo Welt")
        #expect(entry.link == "https://atom.example/hallo")
        #expect(entry.author == "Bert")
        #expect(entry.id == "tag:atom.example,2026:1")
        #expect(entry.published == ATDate.parse("2026-11-18T09:00:00Z"))
    }

    @Test func readsRDF() throws {
        let rdf = """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
          <channel rdf:about="https://rdf.example/"><title>RDF</title><link>https://rdf.example/</link></channel>
          <item rdf:about="https://rdf.example/1"><title>Eins</title><link>https://rdf.example/1</link></item>
        </rdf:RDF>
        """
        let feed = try FeedParser.parse(Data(rdf.utf8))
        #expect(feed.title == "RDF")
        #expect(feed.entries.first?.id == "https://rdf.example/1")
    }

    @Test func refusesWhatIsNoFeed() {
        #expect(throws: FeedParseError.notAFeed) { try FeedParser.parse(Data("<html><body>Hallo</body></html>".utf8)) }
        #expect(throws: FeedParseError.notAFeed) { try FeedParser.parse(Data("kein xml".utf8)) }
    }

    @Test func neverLoadsOutsideEntities() throws {
        let hostile = """
        <?xml version="1.0"?>
        <!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
        <rss><channel><title>T</title><item><title>&secret;</title><link>https://a.example/</link></item></channel></rss>
        """
        let feed = try? FeedParser.parse(Data(hostile.utf8))
        #expect(feed?.entries.first?.title.contains("root") != true)
    }

    @Test func readsDatesInTheirManyForms() {
        #expect(FeedDate.parse("Tue, 17 Nov 2026 08:30:00 +0100") != nil)
        #expect(FeedDate.parse("Tue, 17 Nov 2026 08:30:00 GMT") != nil)
        #expect(FeedDate.parse("17 Nov 2026 08:30:00 +0000") != nil)
        #expect(FeedDate.parse("2026-11-17T08:30:00+01:00") != nil)
        #expect(FeedDate.parse("2026-11-17T08:30:00.123Z") != nil)
        #expect(FeedDate.parse("2026-11-17") != nil)
        #expect(FeedDate.parse("gestern") == nil)
    }
}

@Suite("Feeds: articles in columns")
struct ArticleMappingTests {
    private func posts() throws -> [PostView] {
        let feed = try FeedParser.parse(Data(rss.utf8))
        return feed.entries.map {
            ArticleMapper.post($0, feedTitle: feed.title, feedURL: "https://blog.example/feed", siteLink: feed.siteLink)
        }
    }

    @Test func becomesAnArticlePost() throws {
        let post = try #require(try posts().first)
        #expect(post.isArticle)
        #expect(post.uri == "article:https://blog.example/feed#post-1")
        #expect(FeedSourceID.isArticle(post.uri))
        #expect(post.author.displayName == "Beispiel-Blog")
        #expect(post.author.handle == "blog.example")
        #expect(post.author.avatar == "https://blog.example/favicon.ico")
        #expect(post.record.text.hasPrefix("Neues & Altes\n\n"))
        #expect(post.article?.body == "Ein langer Text mit Link.")
        #expect(post.article?.bodyFacets?.isEmpty == false)
        #expect(post.webURL?.absoluteString == "https://blog.example/neu")
        #expect(post.date != nil)
    }

    @Test func resolvesRelativeLinksAgainstTheFeed() throws {
        let second = try posts()[1]
        #expect(second.article?.link == "https://blog.example/relativ")
    }

    @Test func dropsLinksAndPicturesThatAreNotSafe() {
        let entry = FeedEntry(id: "1", title: "T", link: "javascript:alert(1)", html: "x", imageURL: "http://img.example/a.jpg")
        let post = ArticleMapper.post(entry, feedTitle: "F", feedURL: "https://f.example/rss", siteLink: nil)
        #expect(post.article?.link == nil)
        #expect(post.webURL == nil)
        #expect(post.article?.imageURL == nil)
    }

    @Test func shortensTheSummaryAtAWord() {
        let text = String(repeating: "Wort ", count: 200)
        let summary = ArticleMapper.summary(of: text)
        #expect(summary.count <= ArticleMapper.summaryLength + 2)
        #expect(summary.hasSuffix("Wort …"))
    }

    @Test func filtersSeeTitleTextAndSource() throws {
        let items = try posts().map { ColumnItem.post(FeedViewPost(post: $0)) }
        let hideSport = ColumnFilter(excludeTerms: ["fußball"])
        #expect(hideSport.apply(items).count == 1)
        let onlyBlog = ColumnFilter(includeTerms: ["Beispiel-Blog"])
        #expect(onlyBlog.apply(items).count == 2)
    }
}

@Suite("Feeds: always show, always hide and saved filters")
struct FilterRuleTests {
    private func item(_ text: String, uri: String) -> ColumnItem {
        let entry = FeedEntry(id: uri, title: text, link: nil, html: "")
        return .post(FeedViewPost(post: ArticleMapper.post(entry, feedTitle: "F", feedURL: "https://f.example/rss", siteLink: nil)))
    }

    @Test func alwaysShowBeatsAlwaysHide() {
        let items = [item("Apple und Sport", uri: "1"), item("Nur Sport", uri: "2"), item("Wetter", uri: "3")]
        let filter = ColumnFilter(excludeTerms: ["sport"], alwaysShowTerms: ["apple"])
        #expect(filter.apply(items).map(\.id).count == 2)
        #expect(filter.apply(items).contains { $0.displayedPost?.record.text == "Apple und Sport" })
    }

    @Test func alwaysShowAlsoBeatsOnlyWith() {
        let items = [item("Apple", uri: "1"), item("Swift", uri: "2"), item("Wetter", uri: "3")]
        let filter = ColumnFilter(includeTerms: ["swift"], alwaysShowTerms: ["apple"])
        #expect(filter.apply(items).count == 2)
    }

    @Test func savedFiltersAddUp() {
        let items = [item("Sport", uri: "1"), item("Politik", uri: "2"), item("Wetter", uri: "3"), item("Politik Apple", uri: "4")]
        let own = ColumnFilter(excludeTerms: ["sport"])
        let saved = ColumnFilter(excludeTerms: ["politik"], alwaysShowTerms: ["apple"])
        let shown = ColumnFilter.apply([own, saved], to: items).compactMap { $0.displayedPost?.record.text }
        #expect(shown == ["Wetter", "Politik Apple"])
    }

    @Test func oldFiltersStillLoad() throws {
        let old = #"{"includeTerms":["a"],"excludeTerms":[],"mediaOnly":false,"hideReposts":true,"hideReplies":false}"#
        let filter = try JSONDecoder().decode(ColumnFilter.self, from: Data(old.utf8))
        #expect(filter.includeTerms == ["a"])
        #expect(filter.alwaysShowTerms.isEmpty)
        #expect(filter.hideReposts)
    }

    @Test @MainActor func presetsReachTheColumnAndGoAwayWhenDeleted() {
        let deck = DeckStore()
        let column = Column(kind: .rss(feeds: ["https://f.example/rss"], name: "F"))
        deck.addColumn(column)
        let preset = deck.savePreset(name: "Ohne Sport", filter: ColumnFilter(excludeTerms: ["sport"]))
        deck.setPreset(preset, used: true, in: column.id)
        #expect(deck.feed(for: deck.columns.last!).presets.count == 1)
        #expect(deck.columnCount(using: preset) == 1)

        var changed = preset
        changed.filter.excludeTerms = ["fußball"]
        deck.updatePreset(changed)
        #expect(deck.feed(for: deck.columns.last!).presets.first?.excludeTerms == ["fußball"])

        deck.deletePreset(preset.id)
        #expect(deck.columns.last?.presetIDs == nil)
        #expect(deck.feed(for: deck.columns.last!).presets.isEmpty)
    }

    @Test func widerColumnsExist() {
        #expect(ColumnWidth.huge.points > ColumnWidth.extraWide.points)
        #expect(ColumnWidth.extraWide.points > ColumnWidth.wide.points)
        let old = #"{"id":"6F9F1D2A-8B0C-4C47-9E5B-2B7D1F0C0A11","kind":{"home":{}},"width":"wide"}"#
        #expect((try? JSONDecoder().decode(Column.self, from: Data(old.utf8)))?.presetIDs == nil)
    }
}

@Suite("Feeds: addresses and OPML")
struct FeedAddressTests {
    @Test func normalizesAddresses() {
        #expect(FeedFetcher.normalize("blog.example/feed")?.absoluteString == "https://blog.example/feed")
        #expect(FeedFetcher.normalize("http://blog.example/rss")?.absoluteString == "https://blog.example/rss")
        #expect(FeedFetcher.normalize("feed://blog.example/rss")?.absoluteString == "https://blog.example/rss")
        #expect(FeedFetcher.normalize("javascript:alert(1)") == nil)
        #expect(FeedFetcher.normalize("https://user:pw@blog.example/") == nil)
        #expect(FeedFetcher.normalize("kein host") == nil)
    }

    @Test func findsTheFeedInAWebsitesHead() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/a.css">
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">
        <link rel='alternate' type='application/atom+xml' href='https://other.example/atom'>
        </head></html>
        """
        let links = FeedFetcher.feedLinks(in: html, base: URL(string: "https://site.example/blog/")!)
        #expect(links.map(\.absoluteString) == ["https://site.example/feed.xml", "https://other.example/atom"])
    }

    @Test func readsOPMLFolders() throws {
        let opml = """
        <?xml version="1.0"?>
        <opml version="1.0"><head><title>Feedly</title></head><body>
          <outline text="Tech" title="Tech">
            <outline type="rss" text="A" title="A" xmlUrl="https://a.example/rss" htmlUrl="https://a.example"/>
            <outline type="rss" text="B" xmlUrl="http://b.example/feed"/>
            <outline text="Unterordner"><outline type="rss" text="C" xmlUrl="https://c.example/rss"/></outline>
          </outline>
          <outline text="Leer"></outline>
          <outline type="rss" text="Lose" xmlUrl="https://lose.example/rss"/>
        </body></opml>
        """
        let folders = try OPMLParser.parse(Data(opml.utf8), looseName: "Feeds")
        #expect(folders.map(\.name) == ["Tech", "Feeds"])
        #expect(folders[0].feeds.map(\.url) == ["https://a.example/rss", "https://b.example/feed", "https://c.example/rss"])
        #expect(folders[1].feeds.map(\.title) == ["Lose"])
    }

    @Test @MainActor func importMakesOneDeckWithAColumnPerFolder() {
        let deck = DeckStore()
        let before = deck.decks.count
        deck.importOPML([
            OPMLFolder(name: "Tech", feeds: [OPMLFeed(title: "A", url: "https://a.example/rss")]),
            OPMLFolder(name: "News", feeds: [OPMLFeed(title: "B", url: "https://b.example/rss")]),
        ], deckName: "feedly")
        #expect(deck.decks.count == before + 1)
        #expect(deck.activeDeck?.name == "feedly")
        #expect(deck.columns.map(\.kind.title) == ["Tech", "News"])
        #expect(deck.columns.allSatisfy { $0.accountDID == nil && $0.kind.isFeedSource })
    }
}

@Suite("Feeds: fetching from a simulated server")
struct FeedFetchingTests {
    @Test func readsSeveralFeedsAndSurvivesABrokenOne() async throws {
        StubProtocol.register(host: "good.feeds.test") { _ in (200, Data(rss.utf8)) }
        StubProtocol.register(host: "atom.feeds.test") { _ in (200, Data(atom.utf8)) }
        StubProtocol.register(host: "broken.feeds.test") { _ in (500, Data()) }
        let reader = FeedReader(transport: StubProtocol.session())
        let page = try await reader.fetchPage(
            kind: .rss(feeds: ["https://good.feeds.test/rss", "https://atom.feeds.test/atom", "https://broken.feeds.test/x"], name: "Mix"),
            cursor: nil, limit: 40
        )
        let dates = page.items.compactMap { $0.displayedPost?.date }
        #expect(page.items.count == 3)
        #expect(dates == dates.sorted(by: >))
        #expect(page.cursor == nil)
        // Feeds have no further pages.
        let next = try await reader.fetchPage(kind: .rss(feeds: ["https://good.feeds.test/rss"], name: "x"), cursor: "more", limit: 40)
        #expect(next.items.isEmpty)
    }

    @Test func reportsWhenEveryFeedFails() async {
        StubProtocol.register(host: "down.feeds.test") { _ in (404, Data()) }
        let reader = FeedReader(transport: StubProtocol.session())
        await #expect(throws: (any Error).self) {
            try await reader.fetchPage(kind: .rss(feeds: ["https://down.feeds.test/rss"], name: "x"), cursor: nil, limit: 40)
        }
    }

    @Test func findsTheFeedBehindAWebsite() async throws {
        StubProtocol.register(host: "site.feeds.test") { request in
            if request.url?.path == "/feed.xml" { return (200, Data(rss.utf8)) }
            return (200, Data(#"<html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head></html>"#.utf8))
        }
        let found = try await FeedFetcher.discover("site.feeds.test", transport: StubProtocol.session())
        #expect(found.url == "https://site.feeds.test/feed.xml")
        #expect(found.feed.title == "Beispiel-Blog")
    }

    @Test @MainActor func feedColumnsReadWithoutAnAccount() async throws {
        StubProtocol.register(host: "column.feeds.test") { _ in (200, Data(rss.utf8)) }
        let deck = DeckStore()
        deck.feedTransport = StubProtocol.session()
        let kind = try await deck.rssColumnKind(addresses: "https://column.feeds.test/rss\n", name: "")
        #expect(kind == .rss(feeds: ["https://column.feeds.test/rss"], name: "Beispiel-Blog"))
        deck.openColumn(kind: kind, accountDID: nil)
        let column = try #require(deck.columns.last)
        let reader = try #require(deck.readClient(for: column))
        let feed = deck.feed(for: column)
        await feed.refresh(using: reader, kind: column.kind)
        #expect(feed.items.count == 2)
    }

    @Test @MainActor func keyboardNeverLikesOrAnswersAnArticle() async throws {
        StubProtocol.register(host: "keys.feeds.test") { _ in (200, Data(rss.utf8)) }
        let deck = DeckStore()
        deck.feedTransport = StubProtocol.session()
        let column = Column(kind: .rss(feeds: ["https://keys.feeds.test/rss"], name: "F"))
        deck.addColumn(column)
        let feed = deck.feed(for: column)
        await feed.refresh(using: try #require(deck.readClient(for: column)), kind: column.kind)
        let item = try #require(feed.visibleItems.first)
        let post = try #require(item.displayedPost)
        deck.keyboardFocus = KeyboardFocus(columnID: column.id, itemID: item.id)
        #expect(deck.handle(.reply))
        #expect(deck.compose == nil)
        #expect(deck.handle(.open))
        #expect(deck.columnRequest?.action == .push(.article(post)))
    }
}

@Suite("Feeds: Feedly")
struct FeedlyTests {
    private func server(host: String, token: String = "made-up-token") -> FeedlyClient { // secret-scan:allow (made-up test value)
        FeedlyClient(
            connection: Feedly.Connection(token: token, userID: "u1", name: "Test"),
            transport: StubProtocol.session(), baseURL: URL(string: "https://\(host)/v3/")!
        )
    }

    @Test func readsAStreamPageByPage() async throws {
        let seen = SeenRequests()
        StubProtocol.register(host: "pages.feedly.test") { request in
            seen.add(request)
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer made-up-token" else { return (401, Data()) } // secret-scan:allow (made-up test value)
            let continuation = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "continuation" }?.value
            let body = continuation == nil
                ? #"{"continuation":"page2","items":[{"id":"e1","title":"Erster","published":1795419000000,"canonicalUrl":"https://n.example/1","summary":{"content":"<p>Hallo</p>"},"origin":{"streamId":"feed/https://n.example/rss","title":"News","htmlUrl":"https://n.example/"},"visual":{"url":"https://img.example/v.jpg"}}]}"#
                : #"{"items":[{"id":"e2","title":"Zweiter","crawled":1795400000000,"alternate":[{"href":"https://n.example/2"}],"visual":{"url":"none"}}]}"#
            return (200, Data(body.utf8))
        }
        let client = server(host: "pages.feedly.test")
        let first = try await client.page(streamID: Feedly.allStreamID(userID: "u1"), continuation: nil, count: 40)
        #expect(first.cursor == "page2")
        let post = try #require(first.items.first?.displayedPost)
        #expect(post.article?.title == "Erster")
        #expect(post.article?.source == "News")
        #expect(post.article?.feedURL == "https://n.example/rss")
        #expect(post.article?.imageURL == "https://img.example/v.jpg")
        #expect(post.webURL?.absoluteString == "https://n.example/1")
        let second = try await client.page(streamID: "x", continuation: "page2", count: 40)
        #expect(second.cursor == nil)
        #expect(second.items.first?.displayedPost?.article?.imageURL == nil)
        #expect(second.items.first?.displayedPost?.webURL?.absoluteString == "https://n.example/2")
        #expect(seen.urls.first?.contains("streamId=user/u1/category/global.all") == true)
    }

    @Test func turnsARejectedTokenIntoAClearMessage() async {
        StubProtocol.register(host: "rejects.feedly.test") { _ in (401, Data()) }
        await #expect(throws: FeedlyError.self) {
            try await FeedlyClient.connect(
                token: "expired", transport: StubProtocol.session(), baseURL: URL(string: "https://rejects.feedly.test/v3/")!
            )
        }
    }

    @Test @MainActor func feedlyColumnsSayWhenNotConnected() async {
        let deck = DeckStore()
        let reader = deck.feedReader
        await #expect(throws: FeedlyError.self) {
            try await reader.fetchPage(kind: .feedly(streamID: "x", name: "x"), cursor: nil, limit: 20)
        }
    }
}

final class SeenRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var urls: [String] { lock.withLock { list } }
    func add(_ request: URLRequest) {
        lock.withLock { list.append(request.url?.absoluteString.removingPercentEncoding ?? "") }
    }
}
