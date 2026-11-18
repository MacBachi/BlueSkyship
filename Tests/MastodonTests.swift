import AuthenticationServices
import CryptoKit
import Foundation
import Testing
@testable import BlueSkyship

/// A simulated Mastodon server with one signed-in account. Nothing here reaches the network.
final class FakeMastodon: @unchecked Sendable {
    let host = "masto-\(UUID().uuidString.prefix(8).lowercased()).test"
    static let domain = "social.test"
    static let me = "me@social.test"
    private let lock = NSLock()
    private var log: [(method: String, path: String, query: [String: [String]], form: [String: [String]])] = []
    private var nextStatusID = 900
    /// Answers by "METHOD path". Anything missing answers 404.
    var routes: [String: (Int, String)] = [:]
    var linkHeader: [String: String] = [:]

    var server: URL { URL(string: "https://\(host)")! }

    var session: MastodonSession {
        MastodonSession(
            server: server, domain: Self.domain, accountID: "1", acct: Self.me,
            accessToken: "token-123", clientID: "cid", clientSecret: "secret" // secret-scan:allow (made-up test value)
        )
    }

    var requests: [(method: String, path: String, query: [String: [String]], form: [String: [String]])] {
        lock.withLock { log }
    }

    func calls(_ method: String, _ path: String) -> [[String: [String]]] {
        requests.filter { $0.method == method && $0.path == path }.map(\.form)
    }

    func client() -> MastodonClient {
        MastodonClient(session: session, transport: StubProtocol.session())
    }

    static func account(_ id: String, _ acct: String, name: String = "Anna") -> String {
        """
        {"id":"\(id)","username":"\(acct.split(separator: "@").first!)","acct":"\(acct)","display_name":"\(name)",
         "note":"<p>Hallo &amp; willkommen</p>","url":"https://social.test/@\(acct)","avatar":"https://files.test/a.png",
         "avatar_static":"https://files.test/a.png","header":"https://files.test/h.png","followers_count":3,
         "following_count":4,"statuses_count":5}
        """
    }

    static func status(
        _ id: String, content: String = "<p>Hallo</p>", account: String = account("2", "anna"),
        extra: String = ""
    ) -> String {
        """
        {"id":"\(id)","created_at":"2026-11-01T10:00:00.000Z","account":\(account),"content":\(json(content)),
         "visibility":"public","spoiler_text":"","sensitive":false,"url":"https://social.test/@anna/\(id)",
         "in_reply_to_id":null,"in_reply_to_account_id":null,"reblog":null,"media_attachments":[],"mentions":[],
         "tags":[],"card":null,"poll":null,"replies_count":1,"reblogs_count":2,"favourites_count":3,
         "favourited":false,"reblogged":false,"bookmarked":false\(extra)}
        """
    }

    static func json(_ string: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed), encoding: .utf8)!
    }

    private static func parse(_ string: String?) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for pair in (string ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            result[parts[0], default: []].append(parts.count > 1 ? parts[1] : "")
        }
        return result
    }

    func start() {
        StubProtocol.registerHeaders(host: host) { [self] request in
            let path = request.url?.path ?? ""
            return lock.withLock { linkHeader[path].map { ["Link": $0] } ?? [:] }
        }
        StubProtocol.register(host: host) { [self] request in
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            let body = StubProtocol.body(of: request)
            let isForm = request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true
            let form = isForm ? Self.parse(body.flatMap { String(data: $0, encoding: .utf8) }) : [:]
            lock.withLock {
                log.append((method, path, Self.parse(request.url?.query), form))
            }
            let isPublic = path.hasPrefix("/oauth/") || path == "/api/v1/apps"
            guard isPublic || request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123" else {
                return (401, Data(#"{"error":"The access token is invalid"}"#.utf8))
            }
            if method == "POST", path == "/api/v1/statuses" {
                let id = lock.withLock { () -> Int in
                    nextStatusID += 1
                    return nextStatusID
                }
                return (200, Data(Self.status(String(id), account: Self.account("1", "me")).utf8))
            }
            if method == "POST", path == "/api/v2/media" {
                return (200, Data(#"{"id":"m1","url":"https://files.test/m1.jpg"}"#.utf8))
            }
            if let (status, text) = lock.withLock({ routes["\(method) \(path)"] }) {
                return (status, Data(text.utf8))
            }
            if method == "POST" { return (200, Data(#"{"id":"2","following":true}"#.utf8)) }
            return (404, Data(#"{"error":"Record not found"}"#.utf8))
        }
    }
}

@MainActor
private func signedInDeck(_ server: FakeMastodon) -> DeckStore {
    let deck = DeckStore()
    deck.accounts.installForTesting(
        Account(did: FakeMastodon.me, handle: FakeMastodon.me, displayName: "Ich", network: .mastodon),
        mastodon: server.client()
    )
    return deck
}

@Suite("Mastodon: reading posts safely")
struct MastodonHTMLTests {
    @Test func paragraphsAndBreaksBecomeLines() {
        let result = MastodonHTML.parse("<p>Eins<br>zwei</p><p>drei &amp; vier</p>")
        #expect(result.text == "Eins\nzwei\n\ndrei & vier")
        #expect(result.facets.isEmpty)
    }

    @Test func hiddenPartsOfLongLinksStayHiddenButTheLinkIsWhole() {
        let html = #"<p>Lies <a href="https://example.com/a/very/long/path" rel="nofollow"><span class="invisible">https://</span><span class="ellipsis">example.com/a/very</span><span class="invisible">/long/path</span></a></p>"#
        let result = MastodonHTML.parse(html)
        #expect(result.text == "Lies example.com/a/very…")
        let shown = RichText.attributed(text: result.text, facets: result.facets)
        let link = shown.runs.compactMap(\.link).first
        #expect(link == URL(string: "https://example.com/a/very/long/path"))
        #expect(!LinkPolicy.isMisleading(shown: "example.com/a/very…", target: link!))
    }

    @Test func hashtagsAndMentionsBecomeInAppLinks() {
        let html = #"<p><span class="h-card"><a href="https://social.test/@bob" class="u-url mention">@<span>bob</span></a></span> <a href="https://social.test/tags/Swift" class="mention hashtag" rel="tag">#<span>Swift</span></a></p>"#
        let mention = Mastodon.Mention(id: "7", username: "bob", acct: "bob", url: "https://social.test/@bob")
        let result = MastodonHTML.parse(html, mentions: [mention], domain: "social.test")
        #expect(result.text == "@bob #Swift")
        let features = result.facets.flatMap(\.features)
        #expect(features.contains(.mention(did: "bob@social.test")))
        #expect(features.contains(.tag("Swift")))
        let links = RichText.attributed(text: result.text, facets: result.facets).runs.compactMap(\.link)
        #expect(links.allSatisfy { $0.scheme == RichText.internalScheme })
        #expect(RichText.mentionedDID(in: links[0]) == "bob@social.test")
    }

    @Test func aMentionTheServerDidNotNameIsJustAWebLink() {
        let html = #"<a href="https://evil.test/@bob" class="u-url mention">@bob</a>"#
        let result = MastodonHTML.parse(html, mentions: [], domain: "social.test")
        #expect(result.facets.flatMap(\.features) == [.link("https://evil.test/@bob")])
    }

    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/passwd", "x-apple.systempreferences:", "shortcuts://run-shortcut?name=x",
        "https://bank.example@evil.test/", "data:text/html,hi", "bskyship://tag?v=x", "vnc://host",
    ])
    func onlyPlainWebLinksAreClickable(_ href: String) {
        let result = MastodonHTML.parse(#"<p><a href="\#(href)">klick</a></p>"#)
        #expect(result.text == "klick")
        #expect(result.facets.isEmpty)
    }

    @Test func scriptsStylesAndPicturesLeaveNothingBehind() {
        let html = #"<p>A<script>steal()</script><style>p{}</style><img src="https://tracker.test/x.png">B<iframe src="x">C</iframe></p>"#
        #expect(MastodonHTML.parse(html).text == "AB")
    }

    @Test func entitiesThatCouldDisguiseTextAreDropped() {
        // Right-to-left override, a control character and a zero code point.
        let result = MastodonHTML.parse("<p>a&#x202E;b&#7;c&#0;d &lt;x&gt; &#x1F600;</p>")
        #expect(result.text == "a&#x202E;b&#7;c&#0;d <x> 😀")
    }

    @Test func brokenMarkupDoesNotCrashOrLoseText() {
        #expect(MastodonHTML.parse("a < b and <p>c").text == "a < b and\n\nc")
        #expect(MastodonHTML.parse("<a href='https://ok.test'>x").facets.count == 1)
        #expect(MastodonHTML.parse("").text == "")
    }

    @Test func theQuoteFallbackLineGoesWhenTheQuoteIsShown() {
        let html = #"<p class="quote-inline">RE: <a href="https://x.test/@a/1">x.test/@a/1</a></p><p>Mein Text</p>"#
        #expect(MastodonHTML.parse(html, hidesQuoteFallback: true).text == "Mein Text")
        #expect(MastodonHTML.parse(html).text.hasPrefix("RE:"))
    }

    @Test func tagsAreCheckedBeforeTheyGoIntoAnAddress() {
        #expect(MastodonTag.isValid("Swift_6"))
        #expect(!MastodonTag.isValid("a/b"))
        #expect(!MastodonTag.isValid("x?y"))
        #expect(!MastodonTag.isValid(""))
    }
}

@Suite("Mastodon: mapping into the deck")
struct MastodonMapperTests {
    let mapper = MastodonMapper(domain: "social.test")

    private func decode(_ json: String) throws -> Mastodon.Status {
        try JSONDecoder().decode(Mastodon.Status.self, from: Data(json.utf8))
    }

    @Test func aBoostShowsTheOriginalWithWhoBoostedIt() throws {
        let inner = FakeMastodon.status("10", account: FakeMastodon.account("3", "carl@other.test", name: "Carl"))
        let outer = FakeMastodon.status("11", account: FakeMastodon.account("2", "anna"), extra: #","reblog":\#(inner)"#)
            .replacingOccurrences(of: #""reblog":null,"#, with: "")
        let item = try #require(mapper.feedItem(try decode(outer)))
        #expect(item.post.author.handle == "carl@other.test")
        #expect(item.reason?.by?.did == "anna@social.test")
        #expect(item.post.uri == "mastodon://social.test/statuses/10")
        #expect(item.post.webURL == URL(string: "https://social.test/@anna/10"))
    }

    @Test func countsAndOwnStateCarryOver() throws {
        let post = try #require(mapper.post(try decode(FakeMastodon.status("5").replacingOccurrences(of: #""favourited":false"#, with: #""favourited":true"#))))
        #expect(post.likeCount == 3)
        #expect(post.repostCount == 2)
        #expect(post.replyCount == 1)
        #expect(post.viewer?.like != nil)
        #expect(post.viewer?.repost == nil)
    }

    @Test func aContentWarningCoversThePost() throws {
        let json = FakeMastodon.status("5").replacingOccurrences(of: #""spoiler_text":"""#, with: #""spoiler_text":"Spoiler zum Film""#)
        let post = try #require(mapper.post(try decode(json)))
        #expect(post.mastodon?.warning == "Spoiler zum Film")
    }

    @Test func filtersFromTheServerHideOrWarn() throws {
        let hide = FakeMastodon.status("5", extra: #","filtered":[{"filter":{"title":"Politik","filter_action":"hide"}}]"#)
        #expect(mapper.post(try decode(hide)) == nil)
        let warn = FakeMastodon.status("6", extra: #","filtered":[{"filter":{"title":"Politik","filter_action":"warn"}}]"#)
        #expect(mapper.post(try decode(warn))?.mastodon?.warning?.contains("Politik") == true)
    }

    @Test func picturesVideosAndOtherFilesBecomeEmbeds() throws {
        let images = FakeMastodon.status("5").replacingOccurrences(of: #""media_attachments":[]"#, with: #"""
            "media_attachments":[{"id":"1","type":"image","url":"https://files.test/1.jpg","preview_url":"https://files.test/1s.jpg","description":"Ein Hund","meta":{"small":{"width":400,"height":300}}}]
            """#)
        guard case .images(let pictures) = mapper.post(try decode(images))?.embed else {
            Issue.record("expected pictures")
            return
        }
        #expect(pictures.first?.alt == "Ein Hund")
        #expect(pictures.first?.thumb == "https://files.test/1s.jpg")

        let gif = FakeMastodon.status("6").replacingOccurrences(of: #""media_attachments":[]"#, with: #"""
            "media_attachments":[{"id":"2","type":"gifv","url":"https://files.test/2.mp4","preview_url":"https://files.test/2.png"}]
            """#)
        guard case .video(let video) = mapper.post(try decode(gif))?.embed else {
            Issue.record("expected a video")
            return
        }
        #expect(video.isGIF)

        let audio = FakeMastodon.status("7").replacingOccurrences(of: #""media_attachments":[]"#, with: #"""
            "media_attachments":[{"id":"3","type":"audio","url":"https://files.test/3.mp3"}]
            """#)
        guard case .external(let link) = mapper.post(try decode(audio))?.embed else {
            Issue.record("expected a link")
            return
        }
        #expect(link.uri == "https://files.test/3.mp3")
    }

    @Test func onlyAcceptedQuotesShowTheQuotedPost() throws {
        let inner = FakeMastodon.status("20")
        let accepted = FakeMastodon.status("21", extra: #","quote":{"state":"accepted","quoted_status":\#(inner)}"#)
        guard case .quote(let quoted?) = mapper.post(try decode(accepted))?.embed else {
            Issue.record("expected a quote")
            return
        }
        #expect(quoted.uri == "mastodon://social.test/statuses/20")
        let pending = FakeMastodon.status("22", extra: #","quote":{"state":"pending","quoted_status":\#(inner)}"#)
        guard case .quote(nil) = mapper.post(try decode(pending))?.embed else {
            Issue.record("a pending quote must not show the post")
            return
        }
    }

    @Test func pollsShowTheirOptions() throws {
        let json = FakeMastodon.status("5").replacingOccurrences(of: #""poll":null"#, with: #""poll":{"options":[{"title":"Ja","votes_count":4},{"title":"Nein","votes_count":1}]}"#)
        let post = try #require(mapper.post(try decode(json)))
        #expect(post.record.text.hasSuffix("◦ Ja (4)\n◦ Nein (1)"))
    }

    @Test func notificationsUseTheAppsWords() throws {
        let json = #"[{"id":"1","type":"favourite","created_at":"2026-11-01T10:00:00.000Z","account":\#(FakeMastodon.account("2", "anna")),"status":\#(FakeMastodon.status("5"))},{"id":"2","type":"reblog","created_at":"2026-11-01T10:00:00.000Z","account":\#(FakeMastodon.account("2", "anna"))},{"id":"3","type":"mention","created_at":"2026-11-01T10:00:00.000Z","account":\#(FakeMastodon.account("2", "anna")),"status":\#(FakeMastodon.status("6").replacingOccurrences(of: #""in_reply_to_id":null"#, with: #""in_reply_to_id":"5""#))}]"#
        let list = try JSONDecoder().decode(LossyList<Mastodon.Notification>.self, from: Data(json.utf8))
        let reasons = list.values.map { mapper.notification($0).raw.reason }
        #expect(reasons == ["like", "repost", "reply"])
        #expect(mapper.notification(list.values[0]).post?.uri == "mastodon://social.test/statuses/5")
    }

    @Test func aBrokenStatusDoesNotBlankTheColumn() throws {
        let json = "[\(FakeMastodon.status("1")),{\"id\":2},\(FakeMastodon.status("3"))]"
        let list = try JSONDecoder().decode(LossyList<Mastodon.Status>.self, from: Data(json.utf8))
        #expect(list.values.map(\.id) == ["1", "3"])
    }

    @Test func profilesUseFullAddressesAndPlainText() throws {
        let account = try JSONDecoder().decode(Mastodon.Account.self, from: Data(FakeMastodon.account("2", "anna").utf8))
        let detail = mapper.profileDetail(account, relationship: Mastodon.Relationship(id: "2", following: true, followed_by: true, muting: false, blocking: false))
        #expect(detail.did == "anna@social.test")
        #expect(detail.description == "Hallo & willkommen")
        #expect(detail.viewer?.following != nil)
        #expect(detail.viewer?.followedBy != nil)
        #expect(detail.webURL == URL(string: "https://social.test/@anna"))
    }
}

@Suite("Mastodon: talking to the server")
struct MastodonClientTests {
    @Test func homeSendsTheTokenAndFindsTheNextPage() async throws {
        let server = FakeMastodon()
        server.routes["GET /api/v1/timelines/home"] = (200, "[\(FakeMastodon.status("5"))]")
        server.linkHeader["/api/v1/timelines/home"] = "<https://elsewhere.test/api/v1/timelines/home?max_id=4>; rel=\"next\", <https://x.test/?min_id=5>; rel=\"prev\""
        server.start()
        let page = try await server.client().fetchPage(kind: .home, cursor: nil)
        #expect(page.items.count == 1)
        #expect(page.cursor == "4")
        _ = try await server.client().fetchPage(kind: .home, cursor: "4")
        #expect(server.requests.last?.query["max_id"] == ["4"])
        // Only the value is used: every request still goes to the account's own server.
        #expect(server.requests.allSatisfy { $0.path.hasPrefix("/api/") })
    }

    @Test func hashtagSearchUsesTheTagTimeline() async throws {
        let server = FakeMastodon()
        server.routes["GET /api/v1/timelines/tag/Swift"] = (200, "[\(FakeMastodon.status("5"))]")
        server.start()
        let page = try await server.client().fetchPage(kind: .search(query: "#Swift"), cursor: nil)
        #expect(page.items.count == 1)
    }

    @Test func profilesAreFoundByAddressAndRemembered() async throws {
        let server = FakeMastodon()
        server.routes["GET /api/v1/accounts/lookup"] = (404, #"{"error":"not found"}"#)
        server.routes["GET /api/v2/search"] = (200, #"{"accounts":[\#(FakeMastodon.account("77", "carl@other.test"))],"statuses":[]}"#)
        server.routes["GET /api/v1/accounts/77/statuses"] = (200, "[\(FakeMastodon.status("5"))]")
        server.start()
        let client = server.client()
        _ = try await client.fetchPage(kind: .profileTab(actor: "carl@other.test", tab: .media), cursor: nil)
        _ = try await client.fetchPage(kind: .profileTab(actor: "carl@other.test", tab: .posts), cursor: nil)
        #expect(server.requests.filter { $0.path == "/api/v2/search" }.count == 1)
        let statusCalls = server.requests.filter { $0.path == "/api/v1/accounts/77/statuses" }
        #expect(statusCalls.first?.query["only_media"] == ["true"])
        #expect(statusCalls.last?.query["exclude_replies"] == ["true"])
    }

    @Test func aThreadShowsParentsAndDirectReplies() async throws {
        let server = FakeMastodon()
        server.routes["GET /api/v1/statuses/5"] = (200, FakeMastodon.status("5"))
        let reply = FakeMastodon.status("6").replacingOccurrences(of: #""in_reply_to_id":null"#, with: #""in_reply_to_id":"5""#)
        let deeper = FakeMastodon.status("7").replacingOccurrences(of: #""in_reply_to_id":null"#, with: #""in_reply_to_id":"6""#)
        server.routes["GET /api/v1/statuses/5/context"] = (200, #"{"ancestors":[\#(FakeMastodon.status("4"))],"descendants":[\#(reply),\#(deeper)]}"#)
        server.start()
        let thread = try await server.client().thread(uri: "mastodon://social.test/statuses/5")
        #expect(thread.parents.map(\.uri) == ["mastodon://social.test/statuses/4"])
        #expect(thread.replies.map(\.uri) == ["mastodon://social.test/statuses/6"])
    }

    @Test func anExpiredTokenSaysToSignInAgain() async {
        let server = FakeMastodon()
        server.start()
        var session = server.session
        session.accessToken = "old"
        let client = MastodonClient(session: session, transport: StubProtocol.session())
        await #expect(throws: XRPCError.self) { try await client.fetchPage(kind: .home, cursor: nil) }
        do {
            _ = try await client.fetchPage(kind: .home, cursor: nil)
        } catch let error as XRPCError {
            #expect(error.code == "AuthenticationRequired")
        } catch {
            Issue.record("unexpected error")
        }
    }

    @Test func bskyFeedsAreRefusedClearly() async {
        let server = FakeMastodon()
        server.start()
        await #expect(throws: XRPCError.self) {
            try await server.client().fetchPage(kind: .feed(uri: "at://x/app.bsky.feed.generator/y", name: "y"), cursor: nil)
        }
    }

    @Test func charactersAreCountedLikeMastodonDoes() {
        #expect(MastodonClient.characterCount("https://example.com/\(String(repeating: "x", count: 200))") == 23)
        #expect(MastodonClient.characterCount("Hi @anna@very.long.server.example") == "Hi @anna".count)
    }

    @Test func aReplyIsNeverMoreVisibleThanItsPost() {
        #expect(MastodonVisibility.public.narrowed(to: .private) == .private)
        #expect(MastodonVisibility.direct.narrowed(to: .public) == .direct)
        #expect(MastodonVisibility.unlisted.narrowed(to: nil) == .unlisted)
    }
}

@Suite("Mastodon: sign-in")
struct MastodonAuthTests {
    @Test(arguments: [
        ("mastodon.social", "https://mastodon.social"),
        ("@anna@chaos.social", "https://chaos.social"),
        ("https://Mastodon.Social/@anna", "https://mastodon.social"),
        (" norden.social ", "https://norden.social"),
    ])
    func theServerIsFoundInWhatPeopleType(_ input: String, _ expected: String) {
        #expect(MastodonAuth.serverURL(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "localhost", "http://mastodon.social", "https://user:pw@mastodon.social", "ftp://x.y"])
    func nonsenseIsNoServer(_ input: String) {
        #expect(MastodonAuth.serverURL(from: input) == nil)
    }

    @Test func pkceMatchesTheStandard() {
        let pkce = MastodonAuth.PKCE()
        let expected = MastodonAuth.PKCE.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8))))
        #expect(pkce.challenge == expected)
        #expect(!pkce.verifier.contains("="))
        #expect(pkce.verifier.count >= 43)
    }

    @Test func onlyTheAnswerToThisSignInIsAccepted() throws {
        let good = URL(string: "blueskyship://oauth?code=abc&state=S1")!
        #expect(try MastodonAuth.code(from: good, state: "S1") == "abc")
        #expect(throws: XRPCError.self) { try MastodonAuth.code(from: good, state: "other") }
        #expect(throws: XRPCError.self) { try MastodonAuth.code(from: URL(string: "evil://oauth?code=abc&state=S1")!, state: "S1") }
        #expect(throws: XRPCError.self) { try MastodonAuth.code(from: URL(string: "blueskyship://oauth?error=access_denied&state=S1")!, state: "S1") }
    }

    @Test func theAuthorizePageAsksOnlyForWhatTheAppNeeds() throws {
        let url = try #require(MastodonAuth.authorizeURL(
            server: URL(string: "https://social.test")!, clientID: "cid", pkce: MastodonAuth.PKCE(), state: "S"
        ))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "social.test")
        #expect(items.first { $0.name == "scope" }?.value == "read write follow")
        #expect(items.first { $0.name == "redirect_uri" }?.value == "blueskyship://oauth")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    }

    @Test func theTokenExchangeSendsTheVerifierAndTheSessionNamesTheAccount() async throws {
        let server = FakeMastodon()
        server.routes["POST /oauth/token"] = (200, #"{"access_token":"token-123"}"#) // secret-scan:allow (made-up test value)
        server.routes["GET /api/v1/accounts/verify_credentials"] = (200, FakeMastodon.account("1", "me"))
        server.routes["GET /api/v2/instance"] = (200, #"{"domain":"social.test"}"#)
        server.start()
        let pkce = MastodonAuth.PKCE()
        let anonymous = MastodonClient(server: server.server, transport: StubProtocol.session())
        let application = try JSONDecoder().decode(Mastodon.Application.self, from: Data(#"{"client_id":"cid","client_secret":"secret"}"#.utf8))
        let token = try await MastodonAuth.token(at: anonymous, code: "abc", application: application, pkce: pkce)
        #expect(server.calls("POST", "/oauth/token").first?["code_verifier"] == [pkce.verifier])
        let session = try await MastodonAuth.completeSession(
            server: server.server, accessToken: token, application: application, transport: StubProtocol.session()
        )
        #expect(session.acct == "me@social.test")
        #expect(session.accountID == "1")
    }

    @Test func theBrowserCanFinishOnABackgroundThread() async throws {
        let url = try await withCheckedThrowingContinuation { continuation in
            let handler = WebSignIn.completion(for: continuation)
            DispatchQueue.global().async {
                handler(URL(string: "blueskyship://oauth?code=c&state=s"), nil)
            }
        }
        #expect(url.scheme == "blueskyship")
    }

    @Test func cancellingTheBrowserIsNoError() async {
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { continuation in
                let handler = WebSignIn.completion(for: continuation)
                DispatchQueue.global().async {
                    handler(nil, ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
        }
    }

    @Test func oldAccountsAreStillBluesky() throws {
        let account = try JSONDecoder().decode(Account.self, from: Data(#"{"did":"did:plc:x","handle":"x.test"}"#.utf8))
        #expect(account.resolvedNetwork == .bluesky)
        #expect(!MastodonID.isActor(account.did))
        #expect(MastodonID.isActor("anna@social.test"))
        #expect(!MastodonID.isActor("anna.bsky.social"))
    }
}

@MainActor
@Suite("Mastodon: actions from the deck")
struct MastodonDeckTests {
    private func post(in deck: DeckStore, _ server: FakeMastodon) async throws -> PostView {
        server.routes["GET /api/v1/timelines/home"] = (200, "[\(FakeMastodon.status("5"))]")
        let page = try await server.client().fetchPage(kind: .home, cursor: nil)
        guard case .post(let item) = page.items.first else { throw URLError(.badServerResponse) }
        return item.post
    }

    @Test func favouriteBoostAndBookmarkReachTheServer() async throws {
        let server = FakeMastodon()
        server.start()
        let deck = signedInDeck(server)
        let post = try await post(in: deck, server)
        var shown = post
        await deck.toggleLike(post, accountDID: FakeMastodon.me) { shown = $0 }
        #expect(shown.viewer?.like != nil)
        #expect(shown.likeCount == 4)
        await deck.toggleRepost(post, accountDID: FakeMastodon.me) { _ in }
        await deck.toggleBookmark(post, accountDID: FakeMastodon.me) { _ in }
        let paths = server.requests.filter { $0.method == "POST" }.map(\.path)
        #expect(paths == ["/api/v1/statuses/5/favourite", "/api/v1/statuses/5/reblog", "/api/v1/statuses/5/bookmark"])
    }

    @Test func aFailedFavouriteIsPutBack() async throws {
        let server = FakeMastodon()
        server.routes["POST /api/v1/statuses/5/favourite"] = (422, #"{"error":"Nope"}"#)
        server.start()
        let deck = signedInDeck(server)
        let post = try await post(in: deck, server)
        var shown = post
        await deck.toggleLike(post, accountDID: FakeMastodon.me) { shown = $0 }
        #expect(shown == post)
        #expect(deck.toast == "Nope")
    }

    @Test func aThreadIsPostedAsAChainWithVisibilityAndWarning() async throws {
        let server = FakeMastodon()
        server.start()
        let deck = signedInDeck(server)
        var context = ComposeContext(accountDID: FakeMastodon.me)
        context.mastodonOptions = MastodonPostOptions(visibility: .private, spoilerText: "Achtung")
        let image = DraftImage(prepared: PreparedImage(data: Data([1, 2, 3]), mimeType: "image/jpeg", width: 1, height: 1), alt: "Bild")
        let result = await deck.publish(
            segments: ["eins", "zwei"], images: [[image], []], video: nil, replyRule: .everyone, context: context
        )
        #expect(result.error == nil)
        #expect(result.sent == 2)
        let posts = server.calls("POST", "/api/v1/statuses")
        #expect(posts.count == 2)
        #expect(posts[0]["status"] == ["eins"])
        #expect(posts[0]["visibility"] == ["private"])
        #expect(posts[0]["spoiler_text"] == ["Achtung"])
        #expect(posts[0]["media_ids[]"] == ["m1"])
        #expect(posts[0]["in_reply_to_id"] == nil)
        #expect(posts[1]["in_reply_to_id"] == ["901"])
        #expect(posts[1]["media_ids[]"] == nil)
    }

    @Test func repliesStayOnTheNetworkAndKeepTheWarning() async throws {
        let server = FakeMastodon()
        server.start()
        let deck = signedInDeck(server)
        deck.accounts.installForTesting(Account(did: "did:plc:b", handle: "b.test"), client: XRPCClient(service: URL(string: "https://nowhere.invalid")!))
        var post = try await post(in: deck, server)
        post.mastodon?.spoilerText = "CW"
        post.mastodon?.visibility = "private"
        deck.settings.mastodonVisibility = .public
        deck.startCompose(replyTo: post)
        #expect(deck.compose?.accountDID == FakeMastodon.me)
        #expect(deck.compose?.mastodonOptions.visibility == .private)
        #expect(deck.compose?.mastodonOptions.spoilerText == "CW")
    }

    @Test func aDirectMessageStartsAPostToThatPerson() async {
        let server = FakeMastodon()
        server.start()
        let deck = signedInDeck(server)
        let result = await deck.openConversation(with: "anna@social.test", accountDID: FakeMastodon.me)
        #expect(result == nil)
        #expect(deck.compose?.initialSegments == ["@anna@social.test "])
        #expect(deck.compose?.mastodonOptions.visibility == .direct)
    }

    @Test func followMuteAndDeleteUseTheAccountID() async throws {
        let server = FakeMastodon()
        server.routes["GET /api/v1/accounts/lookup"] = (200, FakeMastodon.account("2", "anna"))
        server.routes["DELETE /api/v1/statuses/5"] = (200, "{}")
        server.start()
        let deck = signedInDeck(server)
        let profile = ProfileDetail(did: "anna@social.test", handle: "anna@social.test")
        var shown = profile
        await deck.toggleFollow(profile, accountDID: FakeMastodon.me) { shown = $0 }
        #expect(shown.viewer?.following == "following")
        await deck.perform(.mute(Profile(did: "anna@social.test", handle: "anna@social.test"), accountDID: FakeMastodon.me))
        #expect(deck.hiddenAuthorDIDs.contains("anna@social.test"))
        var own = try await post(in: deck, server)
        own = PostView(uri: own.uri, cid: "", author: Profile(did: FakeMastodon.me, handle: FakeMastodon.me), record: own.record, indexedAt: own.indexedAt, mastodon: own.mastodon)
        await deck.perform(.deletePost(own))
        let paths = server.requests.filter { $0.method != "GET" }.map(\.path)
        #expect(paths == ["/api/v1/accounts/2/follow", "/api/v1/accounts/2/mute", "/api/v1/statuses/5"])
    }

    @Test func columnsReadThroughTheMastodonAccount() async throws {
        let server = FakeMastodon()
        server.routes["GET /api/v1/timelines/public"] = (200, "[\(FakeMastodon.status("5"))]")
        server.start()
        let deck = signedInDeck(server)
        let column = Column(kind: .localTimeline, accountDID: FakeMastodon.me)
        let client = try #require(deck.readClient(for: column))
        await deck.feed(for: column).refresh(using: client, kind: column.kind)
        #expect(deck.feed(for: column).items.count == 1)
        #expect(server.requests.last?.query["local"] == ["true"])
        // A Mastodon person never falls back to Bluesky's public service.
        #expect(deck.readClient(for: Column(kind: .author(actor: "anna@social.test"))) == nil)
        #expect(deck.defaultAccountDID(for: .author(actor: "anna@social.test")) == FakeMastodon.me)
    }

    @Test func signingOutRemovesMastodonColumnsInsteadOfReadingThemPublicly() async {
        let server = FakeMastodon()
        server.routes["POST /oauth/revoke"] = (200, "{}")
        server.start()
        let deck = signedInDeck(server)
        deck.addColumn(Column(kind: .author(actor: "anna@social.test"), accountDID: FakeMastodon.me))
        await deck.logout(did: FakeMastodon.me)
        #expect(deck.columns.allSatisfy { $0.accountDID != FakeMastodon.me })
        #expect(!deck.columns.contains { $0.kind == .author(actor: "anna@social.test") })
        #expect(server.requests.contains { $0.path == "/oauth/revoke" })
    }

    @Test func unreadCountsComeFromTheServer() async {
        let server = FakeMastodon()
        server.routes["GET /api/v1/notifications/unread_count"] = (200, #"{"count":7}"#)
        server.start()
        let deck = signedInDeck(server)
        await deck.pollNotifications()
        #expect(deck.unreadCounts[FakeMastodon.me] == 7)
    }
}

@MainActor
@Suite("Mixed searches and account colours")
struct MixedSearchTests {
    /// A Bluesky server that answers searches with one post at a fixed time.
    private func blueskyServer(failing: Bool = false) -> (host: String, client: XRPCClient) {
        let host = "bsky-\(UUID().uuidString.prefix(8).lowercased()).test"
        StubProtocol.register(host: host) { request in
            if failing { return (502, Data(#"{"error":"Down"}"#.utf8)) }
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            let post = FakeBluesky.post(cursor == nil ? "b1" : "b2", text: "#swift von Bluesky")
                .replacingOccurrences(of: "2026-01-01T00:00:00.000Z", with: cursor == nil ? "2026-11-01T12:00:00.000Z" : "2026-10-01T12:00:00.000Z")
            return (200, Data(#"{"posts":[\#(post)]\#(cursor == nil ? #","cursor":"next-b""# : "")}"#.utf8))
        }
        let session = Session(did: "did:plc:me", handle: "me.test", accessJwt: "a", refreshJwt: "r", service: URL(string: "https://\(host)")!)
        return (host, XRPCClient(service: session.service, session: session, transport: StubProtocol.session()))
    }

    private func deckWithBoth(blueskyFails: Bool = false) -> (DeckStore, FakeMastodon) {
        let mastodon = FakeMastodon()
        mastodon.routes["GET /api/v1/timelines/tag/swift"] = (200, "[\(FakeMastodon.status("5"))]")
        mastodon.linkHeader["/api/v1/timelines/tag/swift"] = "<https://x.test/?max_id=4>; rel=\"next\""
        mastodon.start()
        let deck = DeckStore()
        deck.accounts.installForTesting(Account(did: "did:plc:me", handle: "me.test"), client: blueskyServer(failing: blueskyFails).client)
        deck.accounts.installForTesting(
            Account(did: FakeMastodon.me, handle: FakeMastodon.me, network: .mastodon), mastodon: mastodon.client()
        )
        return (deck, mastodon)
    }

    @Test func aSearchWithoutAccountShowsBothNetworksNewestFirst() async throws {
        let (deck, _) = deckWithBoth()
        let column = Column(kind: .search(query: "#swift"))
        #expect(deck.isMixed(column))
        let reader = try #require(deck.readClient(for: column))
        let page = try await reader.fetchPage(kind: column.kind, cursor: nil)
        let posts = page.items.compactMap(\.displayedPost)
        // Bluesky's post is from 1 November 12:00, Mastodon's from 1 November 10:00.
        #expect(posts.map(\.uri) == ["at://did:plc:alice/app.bsky.feed.post/b1", "mastodon://social.test/statuses/5"])
        #expect(posts.map(\.sourceAccountDID) == ["did:plc:me", FakeMastodon.me])

        let next = try #require(MixedReader.decode(page.cursor))
        #expect(next.next == ["did:plc:me": "next-b", FakeMastodon.me: "4"])
    }

    @Test func laterPagesOnlyAskWhoHasMore() async throws {
        let (deck, mastodon) = deckWithBoth()
        let reader = try #require(deck.readClient(for: Column(kind: .search(query: "#swift"))))
        let cursor = MixedReader.encode(MixedReader.Cursor(next: ["did:plc:me": "next-b"]))
        let page = try await reader.fetchPage(kind: .search(query: "#swift"), cursor: cursor)
        #expect(page.items.compactMap(\.displayedPost).map(\.uri) == ["at://did:plc:alice/app.bsky.feed.post/b2"])
        #expect(page.cursor == nil)
        #expect(mastodon.requests.isEmpty)
    }

    @Test func oneNetworkDownStillShowsTheOther() async throws {
        let (deck, _) = deckWithBoth(blueskyFails: true)
        let reader = try #require(deck.readClient(for: Column(kind: .search(query: "#swift"))))
        let page = try await reader.fetchPage(kind: .search(query: "#swift"), cursor: nil)
        #expect(page.items.count == 1)
    }

    @Test func actingOnAMixedPostUsesItsOwnAccount() async throws {
        let (deck, mastodon) = deckWithBoth()
        let reader = try #require(deck.readClient(for: Column(kind: .search(query: "#swift"))))
        let page = try await reader.fetchPage(kind: .search(query: "#swift"), cursor: nil)
        let post = try #require(page.items.compactMap(\.displayedPost).first { $0.isMastodon })
        await deck.toggleLike(post, accountDID: post.sourceAccountDID) { _ in }
        #expect(mastodon.requests.contains { $0.method == "POST" && $0.path == "/api/v1/statuses/5/favourite" })
        deck.startCompose(replyTo: post, accountDID: post.sourceAccountDID)
        #expect(deck.compose?.accountDID == FakeMastodon.me)
    }

    @Test func searchesAndTheirFavoritesMixButPeopleDoNot() {
        let (deck, _) = deckWithBoth()
        #expect(deck.defaultAccountDID(for: .search(query: "#swift")) == nil)
        #expect(deck.defaultAccountDID(for: .profileTab(actor: "anna@social.test", tab: .posts)) == FakeMastodon.me)
        #expect(deck.defaultAccountDID(for: .likes(actor: "did:plc:me")) == "did:plc:me")
        deck.addFavorite(kind: .search(query: "#swift"), title: "#swift", accountDID: FakeMastodon.me)
        #expect(deck.favorites.last?.accountDID == nil)
        #expect(deck.previewColumn == nil)
        deck.togglePreview(deck.favorites.last!)
        #expect(deck.previewColumn?.accountDID == nil)
        #expect(deck.previewColumn.map(deck.isMixed) == true)
    }

    @Test func aHashtagInAMixedColumnOpensAMixedColumn() {
        let (deck, _) = deckWithBoth()
        let handled = deck.handleInternalLink(URL(string: "bskyship://tag?v=swift")!, accountDID: nil)
        #expect(handled)
        #expect(deck.columns.last?.kind == .search(query: "#swift"))
        #expect(deck.columns.last?.accountDID == nil)
    }

    @Test func everyAccountGetsItsOwnColourUntilOneIsChosen() {
        let (deck, _) = deckWithBoth()
        let first = deck.accounts.color(for: "did:plc:me")
        let second = deck.accounts.color(for: FakeMastodon.me)
        #expect(first != nil && second != nil && first != second)
        deck.accounts.setColor(.orange, for: FakeMastodon.me)
        #expect(deck.accounts.color(for: FakeMastodon.me) == .orange)
        #expect(deck.accounts.color(for: "did:plc:me") != .orange)
        #expect(deck.accounts.color(for: "did:plc:unknown") == nil)
    }
}
