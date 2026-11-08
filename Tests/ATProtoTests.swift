import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import SwiftUI
import UniformTypeIdentifiers
@testable import BlueSkyship

@Suite struct RichTextTests {
    @Test func detectsFacetsAtUTF8ByteOffsetsAfterEmoji() {
        let text = "👋 hi @alice.bsky.social see https://example.com/a. #swift!"
        let detected = RichText.detectFacets(in: text)
        let bytes = Array(text.utf8)
        func slice(_ item: RichText.Detected) -> String {
            String(decoding: bytes[item.byteStart..<item.byteEnd], as: UTF8.self)
        }
        #expect(detected.map(slice) == ["@alice.bsky.social", "https://example.com/a", "#swift"])
        #expect(detected[0].kind == .handle("alice.bsky.social"))
        #expect(detected[1].kind == .link("https://example.com/a"))
        #expect(detected[2].kind == .tag("swift"))
    }

    @Test func ignoresEmailAddressesAndNumericTags() {
        #expect(RichText.detectFacets(in: "mail me: a@b.com #123").isEmpty)
    }

    @Test func unresolvedMentionStaysPlainText() async {
        let detected = RichText.detectFacets(in: "@gone.example hi @ok.example")
        let facets = await RichText.resolveMentions(in: detected) { handle in
            handle == "ok.example" ? "did:plc:ok" : nil
        }
        #expect(facets.count == 1)
        #expect(facets[0].features == [.mention(did: "did:plc:ok")])
    }

    @Test func rendersLinkOverMultibyteTextAndSurvivesBadFacets() {
        let text = "ä→ link"
        let start = "ä→ ".utf8.count
        let facets = [
            Facet(byteStart: start, byteEnd: start + 4, feature: .link("https://example.com")),
            Facet(byteStart: 2, byteEnd: 1, feature: .tag("inverted")),
            Facet(byteStart: 0, byteEnd: 999, feature: .tag("outOfBounds")),
        ]
        let rendered = RichText.attributed(text: text, facets: facets)
        #expect(String(rendered.characters) == text)
        let linked = rendered.runs.compactMap { run in run.link.map { _ in String(rendered[run.range].characters) } }
        #expect(linked == ["link"])
    }
}

@Suite struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private let author = #"{"did":"did:plc:a","handle":"a.test"}"#
    private func post(uri: String, embed: String = "null") -> String {
        """
        {"uri":"\(uri)","cid":"c","author":\(author),"indexedAt":"2026-01-01T00:00:00.000Z",
         "record":{"text":"hi","createdAt":"2026-01-01T00:00:00Z"},"embed":\(embed)}
        """
    }

    @Test func oneBrokenPostDoesNotLoseTheOthers() throws {
        let json = "[\(#"{"post":{"uri":"broken"}}"#),{\"post\":\(post(uri: "at://ok"))}]"
        let list = try decode(LossyList<FeedViewPost>.self, json)
        #expect(list.values.map(\.post.uri) == ["at://ok"])
    }

    @Test func decodesEmbedUnion() throws {
        let images = #"{"$type":"app.bsky.embed.images#view","images":[{"thumb":"t","fullsize":"f","alt":""}]}"#
        guard case .images(let list) = try decode(Embed.self, images) else {
            Issue.record("expected images"); return
        }
        #expect(list.count == 1)

        let unknown = #"{"$type":"app.bsky.embed.future#view","x":1}"#
        #expect(try decode(Embed.self, unknown) == .unknown)

        let blocked = #"{"$type":"app.bsky.embed.record#view","record":{"$type":"app.bsky.embed.record#viewBlocked","uri":"u","blocked":true}}"#
        #expect(try decode(Embed.self, blocked) == .quote(nil))

        let withMedia = """
        {"$type":"app.bsky.embed.recordWithMedia#view",
         "record":{"record":{"$type":"app.bsky.embed.record#viewRecord","uri":"q","cid":"c","author":\(author),
                             "value":{"text":"quoted"},"indexedAt":"2026-01-01T00:00:00Z"}},
         "media":\(images)}
        """
        guard case .quoteWithMedia(let quoted, let media) = try decode(Embed.self, withMedia),
              case .images = media else {
            Issue.record("expected quote with media"); return
        }
        #expect(quoted?.value.text == "quoted")
    }

    @Test func replyContextToleratesBlockedParent() throws {
        let json = #"{"parent":{"$type":"app.bsky.feed.defs#blockedPost","uri":"u","blocked":true,"author":{"did":"did:plc:x"}}}"#
        #expect(try decode(ReplyContext.self, json).parentAuthor == nil)
    }

    @Test func threadSkipsMissingParentAndReplies() throws {
        let json = """
        {"post":\(post(uri: "at://root")),
         "parent":{"$type":"app.bsky.feed.defs#notFoundPost","uri":"gone","notFound":true},
         "replies":[{"$type":"app.bsky.feed.defs#blockedPost","uri":"b"},{"post":\(post(uri: "at://reply"))}]}
        """
        let thread = try decode(ThreadContent.self, json)
        #expect(thread.parents.isEmpty)
        #expect(thread.replies.map(\.uri) == ["at://reply"])
    }

    @Test func feedLinkParsing() {
        #expect(FeedLink.parse("https://bsky.app/profile/a.test/feed/cool") == .feed("at://a.test/app.bsky.feed.generator/cool"))
        #expect(FeedLink.parse("https://bsky.app/profile/did:plc:x/lists/l1") == .list("at://did:plc:x/app.bsky.graph.list/l1"))
        #expect(FeedLink.parse("https://bsky.app/profile/a.test/post/1") == nil)
        #expect(FeedLink.parse("https://evil.example/profile/a/feed/b") == nil)
        #expect(FeedLink.parse("https://bsky.app/profile/a.test/feed/cool")?.replacingAuthority(with: "did:plc:z").uri
            == "at://did:plc:z/app.bsky.feed.generator/cool")
    }

    @Test func queryEscapesPlusSoSearchTermsSurvive() throws {
        let url = try XRPCClient.url(
            service: URL(string: "https://x.test")!, nsid: "a.b.c", query: [("q", "c++ & co"), ("skip", nil)]
        )
        #expect(url.absoluteString.contains("q=c%2B%2B%20%26%20co"))
        #expect(!url.absoluteString.contains("skip"))
    }
}

/// All writes here go to stubbed servers: nothing reaches Bluesky.
@Suite struct SocialAPITests {
    private func client(_ handler: @escaping StubProtocol.Handler) -> XRPCClient {
        let host = "social-\(UUID().uuidString).test"
        StubProtocol.register(host: host, handler: handler)
        let session = Session(did: "did:me", handle: "me", accessJwt: "a", refreshJwt: "r", service: URL(string: "https://\(host)")!)
        return XRPCClient(service: session.service, session: session, transport: StubProtocol.session())
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func threadChainsRepliesAndKeepsPicturesOnTheFirstPost() async throws {
        let bodies = BodyLog()
        let client = client { request in
            if request.url?.path.hasSuffix("uploadBlob") == true {
                return (200, Data(#"{"blob":{"$type":"blob","ref":{"$link":"x"},"mimeType":"image/jpeg","size":1}}"#.utf8))
            }
            let index = bodies.append(StubProtocol.body(of: request))
            return (200, Data(#"{"uri":"at://p\#(index)","cid":"c\#(index)"}"#.utf8))
        }
        let image = DraftImage(prepared: PreparedImage(data: Data([1]), mimeType: "image/jpeg", width: 1, height: 1), alt: "")
        let result = await client.createThread(
            texts: ["a", "b", "c"], first: PostDraft(text: "a", images: [image]), repo: "did:me"
        )
        #expect(result.sent == 3)
        #expect(result.error == nil)
        let records = try bodies.values.map { try #require(try json($0)["record"] as? [String: Any]) }
        #expect(records.map { $0["text"] as? String } == ["a", "b", "c"])
        #expect(records[0]["reply"] == nil)
        #expect(records[0]["embed"] != nil)
        #expect(records[1]["embed"] == nil)
        let second = try #require(records[1]["reply"] as? [String: [String: String]])
        #expect(second["root"]?["uri"] == "at://p0")
        #expect(second["parent"]?["uri"] == "at://p0")
        let third = try #require(records[2]["reply"] as? [String: [String: String]])
        #expect(third["root"]?["uri"] == "at://p0")
        #expect(third["parent"]?["uri"] == "at://p1")
    }

    @Test func threadReplyKeepsTheOriginalRoot() async throws {
        let bodies = BodyLog()
        let client = client { request in
            let index = bodies.append(StubProtocol.body(of: request))
            return (200, Data(#"{"uri":"at://p\#(index)","cid":"c"}"#.utf8))
        }
        let root = StrongRef(uri: "at://root", cid: "r")
        let parent = StrongRef(uri: "at://parent", cid: "p")
        _ = await client.createThread(
            texts: ["a", "b"], first: PostDraft(text: "a", reply: ReplyRef(root: root, parent: parent)), repo: "did:me"
        )
        let record = try #require(try json(bodies.values[1])["record"] as? [String: Any])
        let reply = try #require(record["reply"] as? [String: [String: String]])
        #expect(reply["root"]?["uri"] == "at://root")
        #expect(reply["parent"]?["uri"] == "at://p0")
    }

    @Test func failureMidThreadSaysHowFarItGotAndWhereToContinue() async {
        let bodies = BodyLog()
        let client = client { request in
            let index = bodies.append(StubProtocol.body(of: request))
            return index == 1 ? (500, Data()) : (200, Data(#"{"uri":"at://p\#(index)","cid":"c"}"#.utf8))
        }
        let result = await client.createThread(texts: ["a", "b", "c"], first: PostDraft(text: "a"), repo: "did:me")
        #expect(result.sent == 1)
        #expect(result.error != nil)
        #expect(result.continuation?.parent.uri == "at://p0")
        #expect(bodies.values.count == 2)
    }

    @Test func moderationAndBookmarksSendTheDocumentedFields() async throws {
        let calls = RequestLog()
        let client = client { request in
            calls.append(request.url?.lastPathComponent ?? "", StubProtocol.body(of: request))
            return (200, Data(#"{"uri":"at://b","cid":"c"}"#.utf8))
        }
        try await client.mute(actor: "did:x")
        try await client.unmute(actor: "did:x")
        #expect(try await client.block(did: "did:x", repo: "did:me") == "at://b")
        try await client.addBookmark(StrongRef(uri: "at://p", cid: "c"))
        try await client.removeBookmark(uri: "at://p")
        try await client.deleteRecord(uri: "at://did:me/app.bsky.feed.post/abc")
        try await client.markNotificationsSeen(at: Date(timeIntervalSince1970: 0))

        #expect(calls.names == [
            "app.bsky.graph.muteActor", "app.bsky.graph.unmuteActor", "com.atproto.repo.createRecord",
            "app.bsky.bookmark.createBookmark", "app.bsky.bookmark.deleteBookmark",
            "com.atproto.repo.deleteRecord", "app.bsky.notification.updateSeen",
        ])
        #expect(try json(calls.bodies[0])["actor"] as? String == "did:x")
        let block = try json(calls.bodies[2])
        #expect(block["collection"] as? String == "app.bsky.graph.block")
        let record = try #require(block["record"] as? [String: Any])
        #expect(record["$type"] as? String == "app.bsky.graph.block")
        #expect(record["subject"] as? String == "did:x")
        #expect(try json(calls.bodies[3])["cid"] as? String == "c")
        let delete = try json(calls.bodies[5])
        #expect(delete["repo"] as? String == "did:me")
        #expect(delete["collection"] as? String == "app.bsky.feed.post")
        #expect(delete["rkey"] as? String == "abc")
        #expect(try json(calls.bodies[6])["seenAt"] != nil)
    }

    @Test func chatGoesThroughTheProxyAndOtherCallsDoNot() async throws {
        let headers = RequestLog()
        let client = client { request in
            headers.append(request.url?.lastPathComponent ?? "", Data((request.value(forHTTPHeaderField: "atproto-proxy") ?? "").utf8))
            return (200, Data(#"{"convos":[{"id":"1","rev":"r","muted":false,"unreadCount":2,"members":[{"did":"did:me","handle":"me"},{"did":"did:x","handle":"x"}],"lastMessage":{"$type":"chat.bsky.convo.defs#deletedMessageView","id":"m","rev":"r","sender":{"did":"did:x"},"sentAt":"2026-01-01T00:00:00Z"}}],"count":1}"#.utf8))
        }
        let result = try await client.conversations()
        #expect(result.conversations.first?.unreadCount == 2)
        #expect(result.conversations.first?.others(excluding: "did:me").map(\.handle) == ["x"])
        #expect(result.conversations.first?.lastMessage?.text == nil)
        #expect(String(decoding: headers.bodies[0] ?? Data(), as: UTF8.self) == "did:web:api.bsky.chat#bsky_chat")

        _ = try await client.unreadNotificationCountIgnoringBody()
        #expect(headers.bodies[1]?.isEmpty == true)
    }

    @Test func decodesMessagesIncludingDeletedOnes() async throws {
        let client = client { _ in
            (200, Data(#"{"messages":[{"$type":"chat.bsky.convo.defs#messageView","id":"2","rev":"r","text":"hi","sender":{"did":"did:x"},"sentAt":"2026-01-01T00:00:01Z"},{"$type":"chat.bsky.convo.defs#deletedMessageView","id":"1","rev":"r","sender":{"did":"did:me"},"sentAt":"2026-01-01T00:00:00Z"}]}"#.utf8))
        }
        let messages = try await client.messages(conversation: "1").messages
        #expect(messages.map(\.id) == ["2", "1"])
        #expect(messages[0].text == "hi")
        #expect(messages[1].text == nil)
    }

    @Test func likesAndBookmarksBecomeColumns() async throws {
        let post = #"{"uri":"at://p","cid":"c","author":{"did":"d","handle":"h"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"t"},"viewer":{"bookmarked":true}}"#
        let client = client { request in
            if request.url?.lastPathComponent == "app.bsky.bookmark.getBookmarks" {
                return (200, Data(#"{"bookmarks":[{"subject":{"uri":"at://p","cid":"c"},"item":\#(post)},{"subject":{"uri":"at://gone","cid":"c"},"item":{"$type":"app.bsky.feed.defs#notFoundPost","uri":"at://gone","notFound":true}}]}"#.utf8))
            }
            return (200, Data(#"{"feed":[{"post":\#(post)}]}"#.utf8))
        }
        let bookmarks = try await client.fetchPage(kind: .bookmarks, cursor: nil)
        #expect(bookmarks.items.count == 1)
        #expect(bookmarks.items[0].displayedPost?.viewer?.bookmarked == true)
        let likes = try await client.fetchPage(kind: .likes(actor: "did:me"), cursor: nil)
        #expect(likes.items.count == 1)
    }

    @Test func embeddedFeedsListsAndStarterPacksBecomeCards() throws {
        func card(_ record: String) throws -> Embed {
            try JSONDecoder().decode(Embed.self, from: Data(#"{"$type":"app.bsky.embed.record#view","record":\#(record)}"#.utf8))
        }
        let creator = #""creator":{"did":"d","handle":"h.test"},"cid":"c","indexedAt":"2026-01-01T00:00:00Z""#
        guard case .recordCard(let pack) = try card(#"{"$type":"app.bsky.graph.defs#starterPackViewBasic","uri":"at://d/app.bsky.graph.starterpack/abc","record":{"name":"Pack","description":"D"},\#(creator)}"#) else {
            Issue.record("expected card"); return
        }
        #expect(pack.title == "Pack")
        #expect(pack.webURL?.absoluteString == "https://bsky.app/starter-pack/h.test/abc")

        guard case .recordCard(let feed) = try card(#"{"$type":"app.bsky.feed.defs#generatorView","uri":"at://d/app.bsky.feed.generator/f","did":"x","displayName":"My Feed",\#(creator)}"#) else {
            Issue.record("expected card"); return
        }
        #expect(feed.kind == .feed)
        #expect(feed.webURL?.absoluteString == "https://bsky.app/profile/h.test/feed/f")

        guard case .recordCard(let list) = try card(#"{"$type":"app.bsky.graph.defs#listView","uri":"at://d/app.bsky.graph.list/l","name":"My List","purpose":"p",\#(creator)}"#) else {
            Issue.record("expected card"); return
        }
        #expect(list.webURL?.absoluteString == "https://bsky.app/profile/h.test/lists/l")

        #expect(try card(#"{"$type":"app.bsky.embed.record#viewBlocked","uri":"u","blocked":true}"#) == .quote(nil))
    }
}

@MainActor
@Suite struct DeckFeatureTests {
    private func context() -> ComposeContext { ComposeContext(accountDID: "did:me") }

    @Test func draftsAreKeptWhileTypingAndEmptyOnesVanish() {
        let deck = DeckStore()
        let id = UUID()
        deck.saveDraft(id: id, segments: ["hello"], context: context())
        deck.saveDraft(id: id, segments: ["hello again"], context: context())
        #expect(deck.drafts.count == 1)
        #expect(deck.drafts[0].preview == "hello again")
        deck.saveDraft(id: id, segments: ["  ", "\n"], context: context())
        #expect(deck.drafts.isEmpty)
    }

    @Test func draftsKeepWhatTheyReplyTo() throws {
        let deck = DeckStore()
        let parent = StrongRef(uri: "at://p", cid: "c")
        var context = context()
        context.savedReply = ReplyRef(root: parent, parent: parent)
        context.savedTargetLabel = "Reply to X"
        let id = UUID()
        deck.saveDraft(id: id, segments: ["a", "b"], context: context)
        deck.open(try #require(deck.drafts.first))
        #expect(deck.compose?.initialSegments == ["a", "b"])
        #expect(deck.compose?.effectiveReply?.parent.uri == "at://p")
        #expect(deck.compose?.targetLabel == "Reply to X")
        #expect(deck.compose?.draftID == id)
    }

    @Test func scheduledPostsGoOutOnlyWhenDueAndAskWhenLate() {
        let now = Date()
        func post(_ offset: TimeInterval) -> ScheduledPost {
            ScheduledPost(date: now.addingTimeInterval(offset), segments: ["x"], accountDID: "d")
        }
        #expect(post(60).due(now: now) == .wait)
        #expect(post(-60).due(now: now) == .send)
        #expect(post(-ScheduledPost.graceInterval - 1).due(now: now) == .overdue)
        var failed = post(-60)
        failed.lastError = "nope"
        #expect(failed.due(now: now) == .overdue)
    }

    @Test func scheduledPostSurvivesSavingWithItsPicture() throws {
        let image = DraftImage(prepared: PreparedImage(data: Data([1, 2]), mimeType: "image/jpeg", width: 2, height: 1), alt: "a")
        let post = ScheduledPost(date: Date(), segments: ["x"], images: [image], accountDID: "d")
        let decoded = try JSONDecoder().decode(ScheduledPost.self, from: try JSONEncoder().encode(post))
        #expect(decoded.images.first?.prepared.data == Data([1, 2]))
        #expect(decoded.images.first?.alt == "a")
    }

    @Test func decksKeepTheirOwnColumns() throws {
        let deck = DeckStore()
        deck.addColumn(Column(kind: .search(query: "first")))
        let firstID = deck.activeDeckID
        deck.addDeck(name: "  Arbeit ")
        #expect(deck.activeDeck?.name == "Arbeit")
        #expect(deck.columns.isEmpty)
        deck.addColumn(Column(kind: .search(query: "second")))
        deck.switchDeck(firstID)
        #expect(deck.columns.map(\.kind) == [.search(query: "first")])
    }

    @Test func theLastDeckCannotBeDeleted() {
        let deck = DeckStore()
        deck.deleteDeck(deck.activeDeckID)
        #expect(deck.decks.count == 1)
        deck.addDeck(name: "B")
        let second = deck.activeDeckID
        deck.deleteDeck(second)
        #expect(deck.decks.count == 1)
        #expect(deck.activeDeckID == deck.decks[0].id)
    }

    @Test func emptyDeckNameGetsADefaultAndRenameIgnoresBlank() {
        let deck = DeckStore()
        deck.addDeck(name: "  ")
        #expect(deck.activeDeck?.name == "Deck 2")
        deck.renameDeck(deck.activeDeckID, to: " ")
        #expect(deck.activeDeck?.name == "Deck 2")
    }

    @Test func favoritesMoveWithinTheirGroupOnly() throws {
        let deck = DeckStore()
        deck.addFavorite(kind: .search(query: "a"), title: "a")
        deck.addFavorite(kind: .feed(uri: "u", name: "f"), title: "f")
        deck.addFavorite(kind: .search(query: "b"), title: "b")
        let b = try #require(deck.favorites.last)
        deck.moveFavorite(b, by: -1)
        #expect(deck.favorites.map(\.title) == ["b", "f", "a"])
        deck.moveFavorite(try #require(deck.favorites.first), by: -1)
        #expect(deck.favorites.map(\.title) == ["b", "f", "a"])
    }

    @Test func parsesKeyCommands() {
        #expect(KeyCommand.parse(characters: "j", keyCode: 38, hasModifiers: false) == .next)
        #expect(KeyCommand.parse(characters: "l", keyCode: 37, hasModifiers: false) == .like)
        #expect(KeyCommand.parse(characters: "3", keyCode: 20, hasModifiers: false) == .jumpToColumn(2))
        #expect(KeyCommand.parse(characters: "", keyCode: 124, hasModifiers: false) == .nextColumn)
        #expect(KeyCommand.parse(characters: "", keyCode: 53, hasModifiers: false) == .back)
        #expect(KeyCommand.parse(characters: "l", keyCode: 37, hasModifiers: true) == nil)
        #expect(KeyCommand.parse(characters: "z", keyCode: 6, hasModifiers: false) == nil)
    }

    @Test func keyboardWalksThroughTheItemsOfAColumn() async throws {
        let deck = DeckStore()
        let column = Column(kind: .home)
        deck.addColumn(column)
        let host = "keys-\(UUID().uuidString).test"
        let feedJSON = ["a", "b"].map { #"{"post":{"uri":"at://\#($0)","cid":"c","author":{"did":"d","handle":"h"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"t"}}}"# }
        StubProtocol.register(host: host) { _ in (200, Data(#"{"feed":[\#(feedJSON.joined(separator: ","))]}"#.utf8)) }
        let client = XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
        await deck.feed(for: column).refresh(using: client, kind: .home)

        #expect(deck.handle(.next))
        #expect(deck.keyboardFocus?.itemID.hasPrefix("at://a") == true)
        _ = deck.handle(.next)
        #expect(deck.keyboardFocus?.itemID.hasPrefix("at://b") == true)
        _ = deck.handle(.next)
        #expect(deck.keyboardFocus?.itemID.hasPrefix("at://b") == true)
        _ = deck.handle(.previous)
        #expect(deck.keyboardFocus?.itemID.hasPrefix("at://a") == true)

        _ = deck.handle(.open)
        guard case .push(.thread(let post))? = deck.columnRequest?.action else {
            Issue.record("expected thread"); return
        }
        #expect(post.uri == "at://a")
    }

    @Test func firstNotificationPassOnlySetsTheMark() {
        func item(_ date: String) -> RawNotification {
            RawNotification(uri: date, cid: "c", author: Profile(did: "d", handle: "h"), reason: "like", indexedAt: date)
        }
        let items = [item("2026-01-02T00:00:00Z"), item("2026-01-01T00:00:00Z")]
        let first = NotificationDigest.newItems(items, since: nil)
        #expect(first.new.isEmpty)
        #expect(first.mark == "2026-01-02T00:00:00Z")
        let second = NotificationDigest.newItems([item("2026-01-03T00:00:00Z")] + items, since: first.mark)
        #expect(second.new.map(\.indexedAt) == ["2026-01-03T00:00:00Z"])
        #expect(second.mark == "2026-01-03T00:00:00Z")
        #expect(NotificationDigest.newItems([], since: second.mark).mark == second.mark)
    }

    @Test func removingFromAFeedTakesItOutOfBothLists() async throws {
        let host = "remove-\(UUID().uuidString).test"
        let body = #"{"feed":[{"post":{"uri":"at://a","cid":"c","author":{"did":"d","handle":"h"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"t"}}}]}"#
        StubProtocol.register(host: host) { _ in (200, Data(body.utf8)) }
        let client = XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        feed.remove { $0.displayedPost?.uri == "at://a" }
        #expect(feed.visibleItems.isEmpty)
    }

    @Test func confirmationsAreWorded() {
        let person = Profile(did: "d", handle: "h.test")
        #expect(DeckConfirmation.block(person, accountDID: nil).title.contains("h.test"))
        #expect(!DeckConfirmation.mute(person, accountDID: nil).message.isEmpty)
    }
}

final class FakeCloudStore: CloudStore {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
    func synchronize() -> Bool { true }
}

/// All against a simulated store: nothing reaches iCloud.
@MainActor
@Suite struct CloudSyncTests {
    struct Item: Codable, Identifiable, Equatable {
        let id: Int
        var text = ""
    }

    private func document(_ store: CloudStore) throws -> (CloudDocument<Item>, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "cloud-\(UUID().uuidString)"))
        return (CloudDocument(key: "items", store: store, defaults: defaults), defaults)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)

    @Test func firstMacUploadsWhatItHas() throws {
        let store = FakeCloudStore()
        let (mac, _) = try document(store)
        #expect(mac.reconcile(local: [Item(id: 1)], now: t0) == nil)
        #expect(store.values["items"] != nil)
    }

    @Test func emptyStartDoesNotOverwriteAnything() throws {
        let store = FakeCloudStore()
        let (mac, _) = try document(store)
        #expect(mac.reconcile(local: [], now: t0) == nil)
        #expect(store.values.isEmpty)
    }

    @Test func secondMacCombinesInsteadOfLosingData() throws {
        let store = FakeCloudStore()
        let (first, _) = try document(store)
        first.push([Item(id: 1)], at: t0)
        let (second, _) = try document(store)
        let merged = second.reconcile(local: [Item(id: 2), Item(id: 1, text: "local copy")], now: t1)
        #expect(merged == [Item(id: 1), Item(id: 2)])
        // The combined list is now what the first Mac receives.
        #expect(first.reconcile(local: [Item(id: 1)], now: t2) == [Item(id: 1), Item(id: 2)])
    }

    @Test func laterChangeWinsIncludingDeletions() throws {
        let store = FakeCloudStore()
        let (first, _) = try document(store)
        let (second, _) = try document(store)
        first.push([Item(id: 1), Item(id: 2)], at: t0)
        _ = second.reconcile(local: [], now: t0)
        second.push([Item(id: 2)], at: t1)
        #expect(first.reconcile(local: [Item(id: 1), Item(id: 2)], now: t2) == [Item(id: 2)])
    }

    @Test func nothingChangesWhenBothAreCurrent() throws {
        let store = FakeCloudStore()
        let (mac, _) = try document(store)
        mac.push([Item(id: 1)], at: t0)
        #expect(mac.reconcile(local: [Item(id: 1)], now: t1) == nil)
    }

    @Test func changeMadeOfflineGoesUpLater() throws {
        let store = FakeCloudStore()
        let (mac, _) = try document(store)
        mac.push([Item(id: 1)], at: t0)
        let earlier = store.values["items"]
        mac.push([Item(id: 1), Item(id: 2)], at: t1)
        store.values["items"] = earlier
        #expect(mac.reconcile(local: [Item(id: 1), Item(id: 2)], now: t2) == nil)
        let (other, _) = try document(store)
        #expect(other.reconcile(local: [], now: t2) == [Item(id: 1), Item(id: 2)])
    }

    @Test func tooMuchDataIsRefusedAndNothingIsStored() throws {
        let store = FakeCloudStore()
        let (mac, _) = try document(store)
        let huge = Item(id: 1, text: String(repeating: "x", count: CloudDocument<Item>.maxBytes + 1))
        #expect(mac.push([huge], at: t0) == .tooLarge)
        #expect(store.values.isEmpty)
    }

    @Test func deckTakesOverChangesFromAnotherMacAndKeepsItsOwnChoice() throws {
        let store = FakeCloudStore()
        let defaults = try #require(UserDefaults(suiteName: "deck-\(UUID().uuidString)"))
        let otherDefaults = try #require(UserDefaults(suiteName: "deck-\(UUID().uuidString)"))
        let deck = DeckStore()
        deck.addFavorite(kind: .search(query: "a"), title: "a")
        deck.addDeck(name: "Arbeit")
        deck.saveDraft(id: UUID(), segments: ["Entwurf"], context: ComposeContext(accountDID: "d"))
        let active = deck.activeDeckID
        deck.apply(cloud: CloudDocuments(store: store, defaults: defaults))

        let other = DeckStore()
        other.apply(cloud: CloudDocuments(store: store, defaults: otherDefaults))
        #expect(other.favorites.map(\.title) == ["a"])
        #expect(other.decks.contains { $0.name == "Arbeit" })
        #expect(other.drafts.first?.preview == "Entwurf")
        #expect(deck.activeDeckID == active)
    }
}

@Suite struct ModerationTests {
    private func post(_ text: String = "hello", labels: [String] = [], following: Bool = false, facetTag: String? = nil) throws -> PostView {
        let labelJSON = labels.map { #"{"val":"\#($0)","src":"s","uri":"u","cts":"2026-01-01T00:00:00Z"}"# }.joined(separator: ",")
        let viewer = following ? #","viewer":{"following":"at://f"}"# : ""
        return try JSONDecoder().decode(PostView.self, from: Data("""
        {"uri":"at://p","cid":"c","author":{"did":"d","handle":"h"\(viewer)},"indexedAt":"2026-01-01T00:00:00Z",
         "record":{"text":"\(text)"},"labels":[\(labelJSON)]}
        """.utf8))
    }

    private func prefs(_ json: String) throws -> ModerationPrefs {
        try JSONDecoder().decode(ModerationPrefs.self, from: Data(#"{"preferences":[\#(json)]}"#.utf8))
    }

    @Test func readsTheAccountSettingsAndSkipsWhatItDoesNotKnow() throws {
        let prefs = try prefs("""
        {"$type":"app.bsky.actor.defs#adultContentPref","enabled":true},
        {"$type":"app.bsky.actor.defs#contentLabelPref","label":"porn","visibility":"hide"},
        {"$type":"app.bsky.actor.defs#contentLabelPref","labelerDid":"did:x","label":"nudity","visibility":"hide"},
        {"$type":"app.bsky.actor.defs#mutedWordsPref","items":[{"value":"spoiler","targets":["content"]}]},
        {"$type":"app.bsky.actor.defs#somethingNew","x":1}
        """)
        #expect(prefs.adultContentEnabled)
        #expect(prefs.labelVisibility == ["porn": "hide"])
        #expect(prefs.mutedWords.map(\.value) == ["spoiler"])
    }

    @Test func mutedWordsHidePostsButNeverOwnOnes() throws {
        let prefs = try prefs(#"{"$type":"app.bsky.actor.defs#mutedWordsPref","items":[{"value":"spoiler","targets":["content","tag"]}]}"#)
        #expect(prefs.decision(for: try post("a spoiler here"), isOwn: false) == .hide)
        #expect(prefs.decision(for: try post("a #spoiler here"), isOwn: false) == .hide)
        #expect(prefs.decision(for: try post("no match"), isOwn: false) == .show)
        #expect(prefs.decision(for: try post("a spoiler here"), isOwn: true) == .show)
    }

    @Test func tagOnlyMuteLeavesPlainWordsAlone() throws {
        let prefs = try prefs(#"{"$type":"app.bsky.actor.defs#mutedWordsPref","items":[{"value":"news","targets":["tag"]}]}"#)
        #expect(prefs.decision(for: try post("the news today"), isOwn: false) == .show)
        #expect(prefs.decision(for: try post("the #news today"), isOwn: false) == .hide)
    }

    @Test func mutedWordsRespectFollowingAndExpiry() throws {
        let prefs = try prefs("""
        {"$type":"app.bsky.actor.defs#mutedWordsPref","items":[
          {"value":"one","targets":["content"],"actorTarget":"exclude-following"},
          {"value":"two","targets":["content"],"expiresAt":"2020-01-01T00:00:00Z"}]}
        """)
        #expect(prefs.decision(for: try post("one"), isOwn: false) == .hide)
        #expect(prefs.decision(for: try post("one", following: true), isOwn: false) == .show)
        #expect(prefs.decision(for: try post("two"), isOwn: false) == .show)
    }

    @Test func adultLabelsStayHiddenUntilSomeoneOptsIn() throws {
        let strict = ModerationPrefs()
        #expect(strict.decision(for: try post(labels: ["porn"]), isOwn: false) == .hide)
        #expect(strict.decision(for: try post(labels: ["graphic-media"]), isOwn: false) == .warn("graphic-media"))
        #expect(strict.decision(for: try post(labels: ["!hide"]), isOwn: false) == .hide)
        #expect(strict.decision(for: try post(labels: ["something-else"]), isOwn: false) == .show)

        let adult = try prefs(#"{"$type":"app.bsky.actor.defs#adultContentPref","enabled":true}"#)
        #expect(adult.decision(for: try post(labels: ["porn"]), isOwn: false) == .warn("porn"))
        #expect(adult.decision(for: try post(labels: ["nudity"]), isOwn: false) == .show)
    }

    @Test func aPostWithBrokenLabelsIsNotKeptOutOfAColumnByThem() throws {
        #expect(try post().labels?.isEmpty == true)
    }

    @MainActor @Test func feedLeavesHiddenPostsOutOfWhatItShows() async throws {
        let host = "mod-\(UUID().uuidString).test"
        let item = { (uri: String, text: String) in #"{"post":{"uri":"\#(uri)","cid":"c","author":{"did":"d","handle":"h"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"\#(text)"}}}"# }
        let body = #"{"feed":[\#(item("at://a", "fine")),\#(item("at://b", "spoiler"))]}"#
        StubProtocol.register(host: host) { _ in (200, Data(body.utf8)) }
        let client = XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        #expect(feed.visibleItems.count == 2)
        feed.moderation = try prefs(#"{"$type":"app.bsky.actor.defs#mutedWordsPref","items":[{"value":"spoiler","targets":["content"]}]}"#)
        #expect(feed.visibleItems.count == 1)
        feed.isOwnPost = { _ in true }
        feed.moderation = ModerationPrefs()
        #expect(feed.visibleItems.count == 2)
    }
}

/// Against stubbed servers: nothing reaches Bluesky.
@Suite struct GapFeatureTests {
    private func client(host: String, _ handler: @escaping StubProtocol.Handler) -> XRPCClient {
        StubProtocol.register(host: host, handler: handler)
        let session = Session(did: "did:me", handle: "me", accessJwt: "a", refreshJwt: "r", service: URL(string: "https://\(host)")!)
        return XRPCClient(service: session.service, session: session, transport: StubProtocol.session())
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func replyRuleIsSavedUnderThePostsOwnKey() async throws {
        let log = RequestLog()
        let client = client(host: "gate-\(UUID().uuidString).test") { request in
            log.append(request.url?.lastPathComponent ?? "", StubProtocol.body(of: request))
            return (200, Data(#"{"uri":"at://did:me/app.bsky.feed.post/abc","cid":"c"}"#.utf8))
        }
        let result = await client.createThread(texts: ["a", "b"], first: PostDraft(text: "a"), replyRule: .followers, repo: "did:me")
        #expect(result.sent == 2)
        #expect(!result.replyRuleFailed)
        #expect(log.names.count == 3)
        let gate = try object(log.bodies[1])
        #expect(gate["collection"] as? String == "app.bsky.feed.threadgate")
        #expect(gate["rkey"] as? String == "abc")
        let record = try #require(gate["record"] as? [String: Any])
        #expect(record["post"] as? String == "at://did:me/app.bsky.feed.post/abc")
        let allow = try #require(record["allow"] as? [[String: String]])
        #expect(allow == [["$type": "app.bsky.feed.threadgate#followerRule"]])
    }

    @Test func nobodyMeansAnEmptyListAndEveryoneMeansNoRecord() async throws {
        #expect(ReplyRule.nobody.allowTypes?.isEmpty == true)
        #expect(ReplyRule.everyone.allowTypes == nil)
        let log = RequestLog()
        let client = client(host: "open-\(UUID().uuidString).test") { request in
            log.append(request.url?.lastPathComponent ?? "", nil)
            return (200, Data(#"{"uri":"at://did:me/app.bsky.feed.post/x","cid":"c"}"#.utf8))
        }
        _ = await client.createThread(texts: ["a"], first: PostDraft(text: "a"), repo: "did:me")
        #expect(log.names.count == 1)
    }

    @Test func aReplyGetsNoRuleBecauseOnlyThreadsCanHaveOne() async {
        let log = RequestLog()
        let client = client(host: "reply-\(UUID().uuidString).test") { request in
            log.append(request.url?.lastPathComponent ?? "", nil)
            return (200, Data(#"{"uri":"at://did:me/app.bsky.feed.post/x","cid":"c"}"#.utf8))
        }
        let parent = StrongRef(uri: "at://p", cid: "c")
        _ = await client.createThread(
            texts: ["a"], first: PostDraft(text: "a", reply: ReplyRef(root: parent, parent: parent)),
            replyRule: .nobody, repo: "did:me"
        )
        #expect(log.names.count == 1)
    }

    @Test func failedRuleStillCountsTheOutgoingPostAndSaysSo() async {
        let log = BodyLog()
        let client = client(host: "fail-\(UUID().uuidString).test") { request in
            let index = log.append(nil)
            return index == 1 ? (500, Data()) : (200, Data(#"{"uri":"at://did:me/app.bsky.feed.post/x","cid":"c"}"#.utf8))
        }
        let result = await client.createThread(texts: ["a"], first: PostDraft(text: "a"), replyRule: .nobody, repo: "did:me")
        #expect(result.sent == 1)
        #expect(result.error == nil)
        #expect(result.replyRuleFailed)
    }

    @Test func picturesGoToTheirOwnPostInAThread() async throws {
        let log = RequestLog()
        let client = client(host: "pics-\(UUID().uuidString).test") { request in
            if request.url?.path.hasSuffix("uploadBlob") == true {
                return (200, Data(#"{"blob":{"$type":"blob","ref":{"$link":"x"},"mimeType":"image/jpeg","size":1}}"#.utf8))
            }
            log.append("post", StubProtocol.body(of: request))
            return (200, Data(#"{"uri":"at://did:me/app.bsky.feed.post/x","cid":"c"}"#.utf8))
        }
        let image = DraftImage(prepared: PreparedImage(data: Data([1]), mimeType: "image/jpeg", width: 1, height: 1), alt: "")
        _ = await client.createThread(
            texts: ["a", "b", "c"], first: PostDraft(text: "a"), laterImages: [2: [image]], repo: "did:me"
        )
        let records = try log.bodies.map { try #require(try object($0)["record"] as? [String: Any]) }
        #expect(records[0]["embed"] == nil)
        #expect(records[1]["embed"] == nil)
        #expect((records[2]["embed"] as? [String: Any])?["$type"] as? String == "app.bsky.embed.images")
    }

    @MainActor @Test func laterImagesLeaveOutTheFirstPostAndEmptyOnes() {
        let image = DraftImage(prepared: PreparedImage(data: Data([1]), mimeType: "m", width: 1, height: 1), alt: "")
        #expect(Array(DeckStore.laterImages([[image], [], [image]]).keys) == [2])
    }

    @Test func peopleListsAndSuggestionsReadTheDocumentedFields() async throws {
        let person = #"{"did":"d","handle":"p.test"}"#
        let client = client(host: "people-\(UUID().uuidString).test") { request in
            switch request.url?.lastPathComponent {
            case "app.bsky.graph.getFollowers": return (200, Data(#"{"subject":\#(person),"followers":[\#(person)],"cursor":"n"}"#.utf8))
            case "app.bsky.graph.getFollows": return (200, Data(#"{"subject":\#(person),"follows":[\#(person)]}"#.utf8))
            default: return (200, Data(#"{"actors":[\#(person)]}"#.utf8))
            }
        }
        let followers = try await client.followers(of: "d", cursor: nil)
        #expect(followers.people.map(\.handle) == ["p.test"])
        #expect(followers.cursor == "n")
        #expect(try await client.follows(of: "d", cursor: nil).people.count == 1)
        #expect(try await client.suggestPeople(matching: "p").count == 1)
    }

    @Test func startingAChatUsesTheProxyAndSendsFacets() async throws {
        let log = RequestLog()
        let client = client(host: "chat-\(UUID().uuidString).test") { request in
            let proxy = request.value(forHTTPHeaderField: "atproto-proxy") ?? ""
            log.append("\(request.url?.lastPathComponent ?? "")|\(proxy)", StubProtocol.body(of: request))
            if request.url?.lastPathComponent == "chat.bsky.convo.getConvoForMembers" {
                return (200, Data(#"{"convo":{"id":"1","rev":"r","muted":false,"unreadCount":0,"members":[{"did":"did:me","handle":"me"},{"did":"did:x","handle":"x"}]}}"#.utf8))
            }
            return (200, Data(#"{"id":"m","rev":"r","text":"hi","sender":{"did":"did:me"},"sentAt":"2026-01-01T00:00:00Z"}"#.utf8))
        }
        #expect(try await client.conversation(with: "did:x").id == "1")
        let link = Facet(byteStart: 0, byteEnd: 2, feature: .link("https://x.test"))
        _ = try await client.send(message: "hi", facets: [link], conversation: "1")
        #expect(log.names.allSatisfy { $0.hasSuffix("did:web:api.bsky.chat#bsky_chat") })
        let message = try #require(try object(log.bodies[1])["message"] as? [String: Any])
        #expect((message["facets"] as? [Any])?.count == 1)
    }

    @Test func videoFollowsTheOfficialUploadFlow() async throws {
        let log = RequestLog()
        let polls = BodyLog()
        let host = "video-\(UUID().uuidString).test"
        let videoHost = "videoservice-\(UUID().uuidString).test"
        let blob = #"{"$type":"blob","ref":{"$link":"vid"},"mimeType":"video/mp4","size":3}"#
        StubProtocol.register(host: videoHost) { request in
            let name = request.url?.lastPathComponent ?? ""
            log.append("\(name)|\(request.value(forHTTPHeaderField: "Authorization") ?? "")|\(request.url?.query ?? "")", nil)
            if name == "app.bsky.video.uploadVideo" {
                return (200, Data(#"{"jobStatus":{"jobId":"j1","did":"did:me","state":"JOB_STATE_CREATED"}}"#.utf8))
            }
            return polls.append(nil) == 0
                ? (200, Data(#"{"jobStatus":{"jobId":"j1","did":"did:me","state":"JOB_STATE_ENCODING"}}"#.utf8))
                : (200, Data(#"{"jobStatus":{"jobId":"j1","did":"did:me","state":"JOB_STATE_COMPLETED","blob":\#(blob)}}"#.utf8))
        }
        let client = client(host: host) { request in
            switch request.url?.lastPathComponent {
            case "com.atproto.repo.describeRepo":
                return (200, Data(##"{"didDoc":{"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example"}]}}"##.utf8))
            case "com.atproto.server.getServiceAuth":
                #expect(request.url?.query?.contains("aud=did:web:pds.example") == true)
                #expect(request.url?.query?.contains("lxm=com.atproto.repo.uploadBlob") == true)
                return (200, Data(#"{"token":"svc"}"#.utf8))
            default:
                return (500, Data())
            }
        }
        let video = VideoDraft(data: Data([1, 2, 3]), width: 16, height: 9, alt: "")
        let result = try await client.uploadVideo(
            video, repo: "did:me", videoService: URL(string: "https://\(videoHost)")!, pollInterval: .milliseconds(1)
        )
        #expect(result.ref.link == "vid")
        #expect(log.names[0].hasPrefix("app.bsky.video.uploadVideo|Bearer svc|did=did:me"))
        #expect(log.names.dropFirst().allSatisfy { $0.hasPrefix("app.bsky.video.getJobStatus||jobId=j1") })
    }

    @Test func failedVideoJobReportsTheReason() async throws {
        let videoHost = "vf-\(UUID().uuidString).test"
        StubProtocol.register(host: videoHost) { _ in
            (200, Data(#"{"jobStatus":{"jobId":"j","did":"d","state":"JOB_STATE_FAILED","message":"too long"}}"#.utf8))
        }
        let client = client(host: "vfmain-\(UUID().uuidString).test") { request in
            request.url?.lastPathComponent == "com.atproto.repo.describeRepo"
                ? (200, Data(##"{"didDoc":{"service":[{"id":"#atproto_pds","serviceEndpoint":"https://p.example"}]}}"##.utf8))
                : (200, Data(#"{"token":"t"}"#.utf8))
        }
        do {
            _ = try await client.uploadVideo(
                VideoDraft(data: Data([1]), width: 1, height: 1, alt: ""), repo: "d",
                videoService: URL(string: "https://\(videoHost)")!, pollInterval: .milliseconds(1)
            )
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription.contains("too long"))
        }
    }

    @Test func videoEmbedHasTheDocumentedShape() throws {
        let blob = BlobRef(ref: .init(link: "v"), mimeType: "video/mp4", size: 1)
        let video = NewPostRecord.Embed.Video(video: blob, alt: nil, aspectRatio: .init(width: 16, height: 9))
        let plain = try object(try JSONEncoder().encode(NewPostRecord.Embed.make(quote: nil, images: [], video: video)))
        #expect(plain["$type"] as? String == "app.bsky.embed.video")
        #expect((plain["aspectRatio"] as? [String: Int]) == ["width": 16, "height": 9])
        let quoted = try object(try JSONEncoder().encode(NewPostRecord.Embed.make(quote: StrongRef(uri: "q", cid: "c"), images: [], video: video)))
        #expect(quoted["$type"] as? String == "app.bsky.embed.recordWithMedia")
        #expect((quoted["media"] as? [String: Any])?["$type"] as? String == "app.bsky.embed.video")
    }

    @MainActor @Test func draggingAFavoriteStaysInsideItsGroup() throws {
        let deck = DeckStore()
        deck.addFavorite(kind: .search(query: "a"), title: "a")
        deck.addFavorite(kind: .search(query: "b"), title: "b")
        deck.addFavorite(kind: .feed(uri: "u", name: "f"), title: "f")
        let a = deck.favorites[0].id, b = deck.favorites[1].id, f = deck.favorites[2].id
        deck.moveFavorite(b, onto: a)
        #expect(deck.favorites.map(\.title) == ["b", "a", "f"])
        deck.moveFavorite(a, onto: f)
        #expect(deck.favorites.map(\.title) == ["b", "a", "f"])
    }
}

@MainActor
@Suite struct SelectablePostTextTests {
    @Test func onlyAClickThatDidNothingElseOpensTheThread() {
        #expect(PostTextView.isPlainClick(clickCount: 1, selectionLength: 0, hadSelection: false, clickedLink: false))
        // Dragging or double-clicking selected text.
        #expect(!PostTextView.isPlainClick(clickCount: 1, selectionLength: 5, hadSelection: false, clickedLink: false))
        #expect(!PostTextView.isPlainClick(clickCount: 2, selectionLength: 5, hadSelection: false, clickedLink: false))
        // The click only cleared an earlier selection.
        #expect(!PostTextView.isPlainClick(clickCount: 1, selectionLength: 0, hadSelection: true, clickedLink: false))
        // A link has its own destination.
        #expect(!PostTextView.isPlainClick(clickCount: 1, selectionLength: 0, hadSelection: false, clickedLink: true))
    }

    @Test func menuOffersCopyOnlyWithASelectionAndRunsItsEntries() throws {
        var didRun = false
        let entries = [
            PostMenuEntry(title: "A") { didRun = true },
            .separator,
            PostMenuEntry(title: "B"),
        ]
        let plain = PostTextView.makeMenu(entries: entries, offersCopy: false)
        #expect(plain.items.map(\.title) == ["A", "", "B"])
        #expect(plain.items[1].isSeparatorItem)

        let withCopy = PostTextView.makeMenu(entries: entries, offersCopy: true)
        #expect(withCopy.items.count == 5)
        #expect(withCopy.items[1].isSeparatorItem)
        #expect(withCopy.items[0].action == #selector(NSText.copy(_:)))

        let item = try #require(plain.items.first)
        let target = try #require(item.target as? NSObject)
        target.perform(item.action)
        #expect(didRun)
    }

    @Test func textKeepsItsLinksAndHeightGrowsWithNarrowerWidth() throws {
        let link = Facet(byteStart: 0, byteEnd: 4, feature: .link("https://example.com"))
        let text = RichText.attributed(text: "link und noch sehr viel mehr Text, der irgendwann umbrechen muss", facets: [link])
        let result = SelectablePostText.attributed(text, fontSize: 13, color: .labelColor)
        let value = result.attribute(.link, at: 0, effectiveRange: nil)
        #expect((value as? URL)?.absoluteString == "https://example.com")
        #expect(result.attribute(.link, at: 6, effectiveRange: nil) == nil)
        #expect(result.attribute(.font, at: 6, effectiveRange: nil) != nil)

        let view = SelectablePostText(text: text, fontSize: 13, onOpenLink: { _ in })
        let hosting = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "de")))
        hosting.frame = CGRect(x: 0, y: 0, width: 120, height: 400)
        let narrow = hosting.fittingSize
        #expect(narrow.height > 0)
        let wide = NSHostingView(rootView: view.frame(width: 600).fixedSize(horizontal: false, vertical: true))
        wide.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        #expect(wide.fittingSize.height > 0)
    }
}

@MainActor
@Suite struct SearchTests {
    private func item(_ text: String, handle: String = "a.test", name: String = "Anna") throws -> ColumnItem {
        let json = """
        {"post":{"uri":"at://\(UUID().uuidString)","cid":"c","author":{"did":"d","handle":"\(handle)","displayName":"\(name)"},
         "indexedAt":"2026-01-01T00:00:00Z","record":{"text":"\(text)"}}}
        """
        return .post(try JSONDecoder().decode(FeedViewPost.self, from: Data(json.utf8)))
    }

    @Test func matchesPartsOfWordsAuthorsAndAccents() throws {
        let post = try item("Heute in Köln am Rhein", handle: "bert.example", name: "Bärbel")
        #expect(post.matchesSearch("köl"))
        #expect(post.matchesSearch("KOLN"))
        #expect(post.matchesSearch("barb"))
        #expect(post.matchesSearch("bert.exa"))
        #expect(post.matchesSearch("rhein heute"))
        #expect(!post.matchesSearch("rhein berlin"))
        #expect(post.matchesSearch("   "))
    }

    private func client(pages: [[String]]) -> XRPCClient {
        let bodies = pages.map { texts -> Data in
            let feed = texts.map { #"{"post":{"uri":"at://\#($0)","cid":"c","author":{"did":"d","handle":"h"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"\#($0)"}}}"# }
            return Data(#"{"cursor":"next","feed":[\#(feed.joined(separator: ","))]}"#.utf8)
        }
        let responses = StubResponses(bodies.map { (200, $0) })
        let host = "search-\(UUID().uuidString).test"
        StubProtocol.register(host: host) { _ in responses.next() }
        return XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
    }

    @Test func searchNarrowsTheColumnAndEndingItRestoresEverything() async throws {
        let client = client(pages: [["apple", "banana"]])
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        feed.searchTerm = "app"
        #expect(feed.isSearching)
        #expect(feed.visibleItems.count == 1)
        #expect(feed.items.count == 2)
        feed.searchTerm = ""
        #expect(feed.visibleItems.count == 2)
    }

    @Test func searchFetchesOlderPagesWhenTooLittleIsLoaded() async throws {
        let client = client(pages: [["apple"], ["needle one"], ["needle two"]])
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        feed.searchTerm = "needle"
        #expect(feed.visibleItems.isEmpty)
        await feed.loadMore(using: client, kind: .home)
        #expect(feed.visibleItems.count == 1)
    }

    @Test func resultStaysTemporaryUntilSavedOrPinned() throws {
        let deck = DeckStore()
        deck.showResult(kind: .search(query: "x"), title: "x")
        #expect(deck.previewColumn?.kind == .search(query: "x"))
        #expect(deck.favorites.isEmpty)
        #expect(deck.columns.isEmpty)
        deck.showResult(kind: .search(query: "y"), title: "y")
        #expect(deck.previewColumn?.kind == .search(query: "y"))
        deck.closeGlobalSearch()
        #expect(deck.previewColumn == nil)
        #expect(!deck.isShowingGlobalSearch)
    }

    @Test func atNameOpensAProfileWithoutNeedingAnAccount() {
        let deck = DeckStore()
        deck.searchBluesky(for: "@bsky.app")
        #expect(deck.previewColumn?.kind == .profileTab(actor: "bsky.app", tab: .replies))
        deck.closeFavoritePreview()
        deck.searchBluesky(for: "")
        #expect(deck.previewColumn == nil)
    }

    @Test func wordSearchWithoutAccountAsksToSignIn() {
        let deck = DeckStore()
        deck.searchBluesky(for: "swift")
        #expect(deck.previewColumn == nil)
        #expect(deck.isLoggingIn)
    }

    @Test func columnSearchGoesToTheFocusedColumnOrTheFirst() {
        let deck = DeckStore()
        let first = Column(kind: .search(query: "a"))
        let second = Column(kind: .search(query: "b"))
        deck.addColumn(first)
        deck.addColumn(second)
        deck.startColumnSearch()
        #expect(deck.columnSearchRequest?.columnID == first.id)
        deck.keyboardFocus = KeyboardFocus(columnID: second.id, itemID: "x")
        deck.startColumnSearch()
        #expect(deck.columnSearchRequest?.columnID == second.id)
    }
}

@Suite struct LanguageTests {
    @Test func followsTheSystemAndFallsBackToEnglish() {
        #expect(Localizer.resolve(.system, systemLanguages: ["de-AT", "en-US"]) == .german)
        #expect(Localizer.resolve(.system, systemLanguages: ["de"]) == .german)
        #expect(Localizer.resolve(.system, systemLanguages: ["en-GB", "de-DE"]) == .english)
        #expect(Localizer.resolve(.system, systemLanguages: ["fr-FR"]) == .english)
        #expect(Localizer.resolve(.system, systemLanguages: []) == .english)
    }

    @Test func manualChoiceBeatsTheSystem() {
        #expect(Localizer.resolve(.english, systemLanguages: ["de-AT"]) == .english)
        #expect(Localizer.resolve(.german, systemLanguages: ["en-US"]) == .german)
    }

    @Test func helpTextsAreValidMarkdownAndTheTLDRStaysShort() throws {
        let everything = HelpContent.tldr + HelpContent.tour.map(\.text) + HelpContent.topics.flatMap(\.bullets)
        for text in everything {
            _ = try AttributedString(markdown: text)
        }
        #expect(HelpContent.tldr.count <= 12)
        #expect(HelpContent.tldr.allSatisfy { $0.count <= 110 })
        #expect(Set(HelpContent.topics.map(\.id)).count == HelpContent.topics.count)
    }
}

@MainActor
@Suite struct FavoritesTests {
    @Test func parsesWhatPeopleType() {
        #expect(FavoriteInput.parse("  @alice.bsky.social ") == .person("alice.bsky.social"))
        #expect(FavoriteInput.parse("#swift") == .search("#swift"))
        #expect(FavoriteInput.parse("open source") == .search("open source"))
        #expect(FavoriteInput.parse("swift") == .search("swift"))
        #expect(FavoriteInput.parse("alice.bsky.social") == .personOrSearch("alice.bsky.social"))
        #expect(FavoriteInput.parse("did:plc:abc") == .person("did:plc:abc"))
        #expect(FavoriteInput.parse("https://bsky.app/profile/alice.test") == .person("alice.test"))
        #expect(FavoriteInput.parse("https://bsky.app/profile/a.test/feed/cool") == .feedLink(.feed("at://a.test/app.bsky.feed.generator/cool")))
        #expect(FavoriteInput.parse("https://bsky.app/profile/a.test/lists/l") == .feedLink(.list("at://a.test/app.bsky.graph.list/l")))
    }

    @Test func rejectsWhatMeansNothing() {
        for input in ["", "   ", "@", "#", "@two words", "https://example.com/x", "https://bsky.app/profile/a/post/1"] {
            #expect(FavoriteInput.parse(input) == .invalid, "\(input)")
        }
    }

    @Test func sortsIntoCategories() {
        #expect(Favorite(kind: .author(actor: "a"), title: "").category == .people)
        #expect(Favorite(kind: .profileTab(actor: "a", tab: .replies), title: "").category == .people)
        #expect(Favorite(kind: .search(query: "#x"), title: "").category == .searches)
        #expect(Favorite(kind: .feed(uri: "u", name: "n"), title: "").category == .feeds)
        #expect(Favorite(kind: .list(uri: "u", name: "n"), title: "").category == .feeds)
        #expect(Favorite(kind: .notifications, title: "").category == .other)
    }

    @Test func addingTwiceKeepsOneAndBothPersonViewsCountAsTheSame() {
        let deck = DeckStore()
        deck.addFavorite(kind: .author(actor: "a.test"), title: "A")
        deck.addFavorite(kind: .profileTab(actor: "a.test", tab: .replies), title: "A again")
        #expect(deck.favorites.count == 1)
        #expect(deck.isFavorite(.author(actor: "a.test")))
        #expect(deck.isFavorite(.profileTab(actor: "a.test", tab: .replies)))
    }

    @Test func movingAColumnFreesTheDeckAndKeepsTheFavorite() {
        let deck = DeckStore()
        let column = Column(kind: .search(query: "#swift"))
        deck.addColumn(column)
        deck.moveColumnToFavorites(column)
        #expect(deck.columns.isEmpty)
        #expect(deck.favorites.map(\.kind) == [.search(query: "#swift")])
        #expect(deck.isShowingFavorites)
    }

    @Test func previewIsTemporaryAndNeverEntersTheDeck() throws {
        let deck = DeckStore()
        deck.addFavorite(kind: .search(query: "x"), title: "x")
        let favorite = try #require(deck.favorites.first)

        deck.togglePreview(favorite)
        #expect(deck.previewColumn?.kind == .search(query: "x"))
        #expect(deck.columns.isEmpty)

        deck.togglePreview(favorite)
        #expect(deck.previewColumn == nil)

        deck.togglePreview(favorite)
        deck.isShowingFavorites = false
        #expect(deck.previewColumn == nil)
        #expect(deck.favorites.count == 1)
    }

    @Test func pinningMakesItAColumnAndKeepsItAsFavorite() throws {
        let deck = DeckStore()
        deck.addFavorite(kind: .search(query: "x"), title: "x")
        let favorite = try #require(deck.favorites.first)
        deck.togglePreview(favorite)
        deck.pinAsColumn(favorite)
        #expect(deck.columns.map(\.kind) == [.search(query: "x")])
        #expect(deck.previewColumn == nil)
        #expect(deck.favorites.count == 1)
    }

    @Test func removingThePreviewedFavoriteClosesThePreview() throws {
        let deck = DeckStore()
        deck.addFavorite(kind: .search(query: "x"), title: "x")
        let favorite = try #require(deck.favorites.first)
        deck.togglePreview(favorite)
        deck.removeFavorite(favorite)
        #expect(deck.favorites.isEmpty)
        #expect(deck.previewColumn == nil)
    }

    @Test func accountTiedViewsRememberTheirAccountOthersDoNot() {
        let deck = DeckStore()
        deck.addFavorite(kind: .notifications, title: "n", accountDID: "did:me")
        deck.addFavorite(kind: .search(query: "x"), title: "x", accountDID: "did:me")
        #expect(deck.favorites[0].accountDID == "did:me")
        #expect(deck.favorites[1].accountDID == nil)
    }

    @Test func savedFavoritesSurviveEncoding() throws {
        let favorite = Favorite(kind: .feed(uri: "u", name: "n"), title: "n", avatar: "a")
        let data = try JSONEncoder().encode([favorite])
        #expect(try JSONDecoder().decode([Favorite].self, from: data) == [favorite])
    }
}

@Suite struct ImagePreparerTests {
    /// Random pixels barely compress, so this is the hard case for the size limit.
    private func noisePNG(width: Int, height: Int) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var value: UInt32 = 12345
        for index in 0..<bytes.count where index % 4 != 3 {
            value = value &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: value >> 24)
        }
        let context = try #require(bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        })
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func largeImageEndsUpWithinServerLimits() throws {
        let prepared = try ImagePreparer.prepare(try noisePNG(width: 3000, height: 1500))
        #expect(prepared.data.count <= ImagePreparer.maxBytes)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(max(prepared.width, prepared.height) <= 2000)
        #expect(abs(Double(prepared.width) / Double(prepared.height) - 2) < 0.01)
    }

    @Test func locationMetadataIsRemoved() throws {
        let plain = try noisePNG(width: 64, height: 64)
        let source = try #require(CGImageSourceCreateWithData(plain as CFData, nil))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 47.2, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 11.4, kCGImagePropertyGPSLongitudeRef: "E",
        ] as [CFString: Any]]
        CGImageDestinationAddImageFromSource(destination, source, 0, gps as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let withGPS = output as Data
        let check = try #require(CGImageSourceCreateWithData(withGPS as CFData, nil))
        let before = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any]
        #expect(before?[kCGImagePropertyGPSDictionary] != nil)

        let prepared = try ImagePreparer.prepare(withGPS)
        let result = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let after = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any]
        #expect(after?[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func notAnImageIsRejected() {
        #expect(throws: (any Error).self) {
            try ImagePreparer.prepare(Data("not an image".utf8))
        }
    }
}

/// All against stubbed servers: nothing here reaches Bluesky.
@Suite struct PostingWithImagesTests {
    private let image = DraftImage(
        prepared: PreparedImage(data: Data([1, 2, 3]), mimeType: "image/jpeg", width: 40, height: 20),
        alt: "ein Fuchs"
    )
    private let blobJSON = #"{"blob":{"$type":"blob","ref":{"$link":"bafkrei"},"mimeType":"image/jpeg","size":3}}"#

    private func client(
        failUpload: Bool = false,
        capture: CapturedBody,
        calls: CallLog
    ) -> XRPCClient {
        let host = "images-\(UUID().uuidString).test"
        let blobJSON = blobJSON
        StubProtocol.register(host: host) { request in
            let path = request.url?.path ?? ""
            calls.append("\(path.split(separator: "/").last ?? "")|\(request.value(forHTTPHeaderField: "Content-Type") ?? "")")
            if path.hasSuffix("uploadBlob") {
                return failUpload ? (500, Data()) : (200, Data(blobJSON.utf8))
            }
            capture.set(StubProtocol.body(of: request))
            return (200, Data(#"{"uri":"u","cid":"c"}"#.utf8))
        }
        let session = Session(
            did: "did:plc:me", handle: "me", accessJwt: "a", refreshJwt: "r",
            service: URL(string: "https://\(host)")!
        )
        return XRPCClient(service: session.service, session: session, transport: StubProtocol.session())
    }

    private func record(_ capture: CapturedBody) throws -> [String: Any] {
        let body = try #require(capture.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(json["record"] as? [String: Any])
    }

    @Test func uploadsFirstThenPostsWithImageEmbed() async throws {
        let capture = CapturedBody(), calls = CallLog()
        let client = client(capture: capture, calls: calls)
        try await client.createPost(PostDraft(text: "", images: [image]), repo: "did:plc:me")

        #expect(calls.values == ["com.atproto.repo.uploadBlob|image/jpeg", "com.atproto.repo.createRecord|application/json"])
        let embed = try #require(try record(capture)["embed"] as? [String: Any])
        #expect(embed["$type"] as? String == "app.bsky.embed.images")
        let first = try #require((embed["images"] as? [[String: Any]])?.first)
        #expect(first["alt"] as? String == "ein Fuchs")
        #expect((first["aspectRatio"] as? [String: Int]) == ["width": 40, "height": 20])
        let blob = try #require(first["image"] as? [String: Any])
        #expect(blob["$type"] as? String == "blob")
        #expect((blob["ref"] as? [String: String])?["$link"] == "bafkrei")
    }

    @Test func quoteWithImageUsesCombinedEmbed() async throws {
        let capture = CapturedBody(), calls = CallLog()
        let client = client(capture: capture, calls: calls)
        let quote = StrongRef(uri: "at://q", cid: "qc")
        try await client.createPost(PostDraft(text: "x", quote: quote, images: [image]), repo: "did:plc:me")

        let embed = try #require(try record(capture)["embed"] as? [String: Any])
        #expect(embed["$type"] as? String == "app.bsky.embed.recordWithMedia")
        let quotePart = try #require(embed["record"] as? [String: Any])
        #expect(quotePart["$type"] as? String == "app.bsky.embed.record")
        #expect((quotePart["record"] as? [String: String])?["uri"] == "at://q")
        #expect((embed["media"] as? [String: Any])?["$type"] as? String == "app.bsky.embed.images")
    }

    @Test func quoteAloneKeepsPlainRecordEmbed() async throws {
        let capture = CapturedBody(), calls = CallLog()
        let client = client(capture: capture, calls: calls)
        try await client.createPost(PostDraft(text: "x", quote: StrongRef(uri: "at://q", cid: "c")), repo: "did:plc:me")
        let embed = try #require(try record(capture)["embed"] as? [String: Any])
        #expect(embed["$type"] as? String == "app.bsky.embed.record")
    }

    @Test func failedUploadMeansNoPostGoesOut() async throws {
        let capture = CapturedBody(), calls = CallLog()
        let client = client(failUpload: true, capture: capture, calls: calls)
        await #expect(throws: (any Error).self) {
            try await client.createPost(PostDraft(text: "x", images: [image]), repo: "did:plc:me")
        }
        #expect(capture.value == nil)
    }

    @Test func followCreatesGraphRecordForTheSubject() async throws {
        let capture = CapturedBody(), calls = CallLog()
        let client = client(capture: capture, calls: calls)
        let uri = try await client.follow(did: "did:plc:bob", repo: "did:plc:me")
        #expect(uri == "u")
        let body = try #require(capture.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["collection"] as? String == "app.bsky.graph.follow")
        let record = try #require(json["record"] as? [String: Any])
        #expect(record["$type"] as? String == "app.bsky.graph.follow")
        #expect(record["subject"] as? String == "did:plc:bob")
    }
}

@Suite struct ProfileAndNavigationTests {
    @Test func decodesProfileDetail() throws {
        let json = #"{"did":"d","handle":"h.test","description":"Bio","followersCount":3,"viewer":{"following":"at://f"}}"#
        let profile = try JSONDecoder().decode(ProfileDetail.self, from: Data(json.utf8))
        #expect(profile.bestName == "h.test")
        #expect(profile.viewer?.following == "at://f")
        #expect(profile.viewer?.followedBy == nil)
    }

    @Test func allPostsColumnAsksServerForEverythingIncludingReplies() async throws {
        let query = CapturedBody()
        let host = "tab-\(UUID().uuidString).test"
        StubProtocol.register(host: host) { request in
            query.set(Data((request.url?.query ?? "").utf8))
            return (200, Data(#"{"feed":[]}"#.utf8))
        }
        let client = XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
        _ = try await client.fetchPage(kind: .profileTab(actor: "h.test", tab: .replies), cursor: nil)
        let sent = String(decoding: try #require(query.value), as: UTF8.self)
        #expect(sent.contains("actor=h.test"))
        #expect(sent.contains("filter=posts_with_replies"))
    }

    @Test func ownPostsColumnIncludesRepliesAndNeedsAnAccount() async throws {
        let query = CapturedBody()
        let host = "own-\(UUID().uuidString).test"
        StubProtocol.register(host: host) { request in
            query.set(Data((request.url?.query ?? "").utf8))
            return (200, Data(#"{"feed":[]}"#.utf8))
        }
        let client = XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
        let kind = ColumnKind.ownPosts(actor: "did:plc:me")
        _ = try await client.fetchPage(kind: kind, cursor: nil)
        let sent = String(decoding: try #require(query.value), as: UTF8.self)
        #expect(sent.contains("filter=posts_with_replies"))
        #expect(kind.requiresAccount)
        #expect(kind.isOwnPosts)
        #expect(!ColumnKind.home.isOwnPosts)
    }

    @Test func decodesWhoReacted() async throws {
        let host = "reactions-\(UUID().uuidString).test"
        let person = #"{"did":"d","handle":"p.test"}"#
        let post = #"{"uri":"at://q","cid":"c","author":{"did":"d","handle":"p.test"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"t"}}"#
        StubProtocol.register(host: host) { request in
            switch request.url?.lastPathComponent {
            case "app.bsky.feed.getLikes":
                return (200, Data(#"{"uri":"u","likes":[{"actor":\#(person),"createdAt":"x","indexedAt":"x"}],"cursor":"next"}"#.utf8))
            case "app.bsky.feed.getRepostedBy":
                return (200, Data(#"{"uri":"u","repostedBy":[\#(person)]}"#.utf8))
            default:
                return (200, Data(#"{"uri":"u","posts":[\#(post)]}"#.utf8))
            }
        }
        let client = XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
        let likes = try await client.likers(of: "u", cursor: nil)
        #expect(likes.people.map(\.handle) == ["p.test"])
        #expect(likes.cursor == "next")
        let reposts = try await client.reposters(of: "u", cursor: nil)
        #expect(reposts.people.count == 1)
        #expect(reposts.cursor == nil)
        let quotes = try await client.quotes(of: "u", cursor: nil)
        #expect(quotes.posts.map(\.uri) == ["at://q"])
    }

    @Test func mentionLinksYieldTheirDID() throws {
        let rendered = RichText.attributed(
            text: "@bob", facets: [Facet(byteStart: 0, byteEnd: 4, feature: .mention(did: "did:plc:bob"))]
        )
        let url = try #require(rendered.runs.compactMap(\.link).first)
        #expect(RichText.mentionedDID(in: url) == "did:plc:bob")
        #expect(RichText.mentionedDID(in: URL(string: "https://example.com")!) == nil)
    }

    @Test func profileBioLinksOnlyWebAddresses() {
        let rendered = RichText.linkifiedPlainText("Hi @bob, siehe https://example.com #tag")
        let links = rendered.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://example.com"])
    }

    @Test func threadReplacesPostWhereverItSits() throws {
        func post(_ uri: String, likes: Int = 0) -> String {
            """
            {"uri":"\(uri)","cid":"c","author":{"did":"d","handle":"h"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"t"},"likeCount":\(likes)}
            """
        }
        let json = """
        {"post":\(post("at://main")),"parent":{"post":\(post("at://parent"))},"replies":[{"post":\(post("at://reply"))}]}
        """
        var thread = try JSONDecoder().decode(ThreadContent.self, from: Data(json.utf8))
        for uri in ["at://main", "at://parent", "at://reply"] {
            thread.replace(try JSONDecoder().decode(PostView.self, from: Data(post(uri, likes: 7).utf8)))
        }
        #expect(thread.post.likeCount == 7)
        #expect(thread.parents[0].likeCount == 7)
        #expect(thread.replies[0].likeCount == 7)
    }

    @MainActor @Test func settingsFallBackToDefaultsAndPersist() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.refreshSeconds == 60)
        #expect(fresh.showMedia)
        #expect(fresh.defaultWidth == .medium)

        fresh.refreshSeconds = 0
        fresh.showMedia = false
        fresh.defaultWidth = .wide
        fresh.postLanguage = "fr"

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.refreshSeconds == 0)
        #expect(!reloaded.showMedia)
        #expect(reloaded.defaultWidth == .wide)
        #expect(reloaded.effectivePostLanguage == "fr")
    }
}

@Suite struct ColumnFilterTests {
    private func item(
        _ text: String = "text",
        handle: String = "a.test",
        extra: String = "",
        embed: String = "null",
        reason: String = "null"
    ) throws -> ColumnItem {
        let json = """
        {"post":{"uri":"at://\(UUID().uuidString)","cid":"c","author":{"did":"d","handle":"\(handle)"},
         "indexedAt":"2026-01-01T00:00:00Z","record":{"text":"\(text)"\(extra)},"embed":\(embed)},"reason":\(reason)}
        """
        return .post(try JSONDecoder().decode(FeedViewPost.self, from: Data(json.utf8)))
    }

    private func shows(_ filter: ColumnFilter, _ item: ColumnItem) -> Bool {
        filter.apply([item]).count == 1
    }

    @Test func emptyFilterShowsEverything() throws {
        #expect(!ColumnFilter().isActive)
        #expect(shows(ColumnFilter(), try item()))
    }

    @Test func matchesWholeWordsOnly() throws {
        let filter = ColumnFilter(excludeTerms: ["art"])
        #expect(shows(filter, try item("what a party")))
        #expect(!shows(filter, try item("modern art, today")))
    }

    @Test func ignoresCaseAndAccents() throws {
        #expect(!shows(ColumnFilter(excludeTerms: ["koln"]), try item("Heute in KÖLN")))
        #expect(!shows(ColumnFilter(excludeTerms: ["Köln"]), try item("heute in koln")))
    }

    @Test func excludeBeatsInclude() throws {
        let filter = ColumnFilter(includeTerms: ["swift"], excludeTerms: ["spoiler"])
        #expect(shows(filter, try item("swift news")))
        #expect(!shows(filter, try item("swift spoiler")))
        #expect(!shows(filter, try item("kotlin news")))
    }

    @Test func anyIncludeTermIsEnough() throws {
        let filter = ColumnFilter(includeTerms: ["swift", "apple"])
        #expect(shows(filter, try item("apple event")))
    }

    @Test func phrasesHashtagsAndNonLatinTextMatch() throws {
        #expect(!shows(ColumnFilter(excludeTerms: ["open source"]), try item("I love open source a lot")))
        #expect(!shows(ColumnFilter(excludeTerms: ["#swift"]), try item("hello #swift!")))
        #expect(shows(ColumnFilter(excludeTerms: ["#swift"]), try item("hello #swiftui")))
        #expect(!shows(ColumnFilter(excludeTerms: ["東京"]), try item("今日は東京です")))
    }

    @Test func handleTermsTargetTheAuthorAndPlainWordsDoNot() throws {
        let author = try item("hi", handle: "spam.bsky.social")
        #expect(!shows(ColumnFilter(excludeTerms: ["@spam.bsky.social"]), author))
        #expect(shows(ColumnFilter(excludeTerms: ["@other.bsky.social"]), author))
        #expect(shows(ColumnFilter(excludeTerms: ["bsky"]), author))
    }

    @Test func searchesLinkTargetsCardsQuotesAndImageDescriptions() throws {
        let facet = #","facets":[{"index":{"byteStart":0,"byteEnd":4},"features":[{"$type":"app.bsky.richtext.facet#link","uri":"https://hidden.example/x"}]}]"#
        #expect(!shows(ColumnFilter(excludeTerms: ["hidden.example"]), try item("link", extra: facet)))

        let card = #"{"$type":"app.bsky.embed.external#view","external":{"uri":"https://x.test","title":"Secret title"}}"#
        #expect(!shows(ColumnFilter(excludeTerms: ["secret"]), try item(embed: card)))

        let image = #"{"$type":"app.bsky.embed.images#view","images":[{"thumb":"t","fullsize":"f","alt":"a red fox"}]}"#
        #expect(!shows(ColumnFilter(excludeTerms: ["fox"]), try item(embed: image)))

        let quote = #"{"$type":"app.bsky.embed.record#view","record":{"uri":"q","cid":"c","author":{"did":"d","handle":"q.test"},"value":{"text":"quoted word"},"indexedAt":"2026-01-01T00:00:00Z"}}"#
        #expect(!shows(ColumnFilter(excludeTerms: ["quoted"]), try item(embed: quote)))
    }

    @Test func mediaOnlyAcceptsImagesAndVideoButNotLinkCards() throws {
        let filter = ColumnFilter(mediaOnly: true)
        let image = #"{"$type":"app.bsky.embed.images#view","images":[{"thumb":"t","fullsize":"f"}]}"#
        let video = #"{"$type":"app.bsky.embed.video#view","playlist":"p"}"#
        let card = #"{"$type":"app.bsky.embed.external#view","external":{"uri":"https://x.test","thumb":"t"}}"#
        #expect(shows(filter, try item(embed: image)))
        #expect(shows(filter, try item(embed: video)))
        #expect(!shows(filter, try item(embed: card)))
        #expect(!shows(filter, try item()))
    }

    @Test func hidesRepostsAndRepliesButNotPinnedPosts() throws {
        let repost = #"{"$type":"app.bsky.feed.defs#reasonRepost","by":{"did":"r","handle":"r.test"},"indexedAt":"2026-01-01T00:00:00Z"}"#
        let pin = #"{"$type":"app.bsky.feed.defs#reasonPin"}"#
        let filter = ColumnFilter(hideReposts: true)
        #expect(!shows(filter, try item(reason: repost)))
        #expect(shows(filter, try item(reason: pin)))

        let reply = #","reply":{"root":{"uri":"r","cid":"c"},"parent":{"uri":"p","cid":"c"}}"#
        #expect(!shows(ColumnFilter(hideReplies: true), try item(extra: reply)))
        #expect(shows(ColumnFilter(hideReplies: true), try item()))
    }

    @Test func notificationsWithoutAPostFailTextAndMediaFilters() {
        let raw = RawNotification(
            uri: "u", cid: "c", author: Profile(did: "d", handle: "f.test"),
            reason: "follow", indexedAt: "2026-01-01T00:00:00Z"
        )
        let follow = ColumnItem.notification(NotificationItem(raw: raw))
        #expect(!shows(ColumnFilter(includeTerms: ["word"]), follow))
        #expect(!shows(ColumnFilter(mediaOnly: true), follow))
        #expect(shows(ColumnFilter(excludeTerms: ["word"]), follow))
    }

    @Test func parsesCommaSeparatedTerms() {
        #expect(ColumnFilter.parseTerms(" swift, open source ,,\nSWIFT, ä ") == ["swift", "open source", "ä"])
        #expect(ColumnFilter.parseTerms("  ,  ").isEmpty)
    }

    @Test func decksSavedBeforeFiltersExistedStillLoad() throws {
        let saved = #"[{"id":"7B2C0C4E-7F39-4B0E-9C39-1C2D3E4F5A6B","kind":{"home":{}},"width":"medium"}]"#
        let columns = try JSONDecoder().decode([Column].self, from: Data(saved.utf8))
        #expect(columns.count == 1)
        #expect(columns[0].filter == nil)
    }
}

@Suite struct DeckOverflowTests {
    private let columns = (0..<4).map { Column(kind: .search(query: "c\($0)")) }

    /// Four 300-wide columns side by side, shifted by the scroll offset.
    private func frames(scrolledBy offset: CGFloat) -> [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: columns.enumerated().map { index, column in
            (column.id, CGRect(x: CGFloat(index) * 300 - offset, y: 0, width: 300, height: 500))
        })
    }

    @Test func columnsBeyondTheRightEdgeAreListedInOrder() {
        let result = DeckOverflow.compute(columns: columns, frames: frames(scrolledBy: 0), viewportWidth: 600)
        #expect(result.left.isEmpty)
        #expect(result.right == [columns[2], columns[3]])
    }

    @Test func scrollingMovesColumnsToTheLeftSide() {
        let result = DeckOverflow.compute(columns: columns, frames: frames(scrolledBy: 300), viewportWidth: 600)
        #expect(result.left == [columns[0]])
        #expect(result.right == [columns[3]])
    }

    @Test func columnStaysVisibleWhileHalfOfItShows() {
        let half = DeckOverflow.compute(columns: columns, frames: frames(scrolledBy: 0), viewportWidth: 750)
        #expect(!half.right.contains(columns[2]))
        let less = DeckOverflow.compute(columns: columns, frames: frames(scrolledBy: 0), viewportWidth: 749)
        #expect(less.right.contains(columns[2]))
    }

    @Test func everythingVisibleMeansNoBar() {
        #expect(DeckOverflow.compute(columns: columns, frames: frames(scrolledBy: 0), viewportWidth: 1200).isEmpty)
        #expect(DeckOverflow.compute(columns: columns, frames: [:], viewportWidth: 0).isEmpty)
    }
}

@MainActor
@Suite struct ColumnFeedTests {
    private func client(pages: [[String]]) -> XRPCClient {
        let bodies = pages.map { uris -> Data in
            let feed = uris.map { #"{"post":{"uri":"\#($0)","cid":"c","author":{"did":"d","handle":"h"},"indexedAt":"2026-01-01T00:00:00Z","record":{"text":"\#($0)"}}}"# }
            return Data(#"{"cursor":"next","feed":[\#(feed.joined(separator: ","))]}"#.utf8)
        }
        let responses = StubResponses(bodies.map { (200, $0) })
        let host = "feed-\(UUID().uuidString).test"
        StubProtocol.register(host: host) { _ in responses.next() }
        return XRPCClient(service: URL(string: "https://\(host)")!, transport: StubProtocol.session())
    }

    @Test func newPostsWaitWhileReadingAndArriveOnRequest() async throws {
        let client = client(pages: [["at://1", "at://2"], ["at://0", "at://1", "at://2"]])
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        #expect(feed.items.count == 2)

        feed.anchorID = feed.items[1].id // scrolled down
        await feed.refresh(using: client, kind: .home)
        #expect(feed.items.count == 2)
        #expect(feed.pending.count == 1)

        feed.showPending()
        #expect(feed.items.count == 3)
        #expect(feed.pending.isEmpty)
        #expect(feed.isAtTop)
    }

    @Test func loadMoreKeepsFetchingUntilSomethingMatches() async throws {
        let client = client(pages: [["at://a"], ["at://b"], ["at://needle"], ["at://later"]])
        let feed = ColumnFeed()
        feed.filter = ColumnFilter(includeTerms: ["needle"])
        await feed.refresh(using: client, kind: .home)
        #expect(feed.visibleItems.isEmpty)
        #expect(feed.hiddenCount == 1)

        await feed.loadMore(using: client, kind: .home)
        #expect(feed.visibleItems.count == 1)
        #expect(feed.items.count == 3) // stopped at the match, "later" was not fetched
    }

    @Test func loadMoreGivesUpAfterThePageLimit() async throws {
        let client = client(pages: (0..<9).map { ["at://none\($0)"] })
        let feed = ColumnFeed()
        feed.filter = ColumnFilter(includeTerms: ["needle"])
        await feed.refresh(using: client, kind: .home)
        await feed.loadMore(using: client, kind: .home)
        #expect(feed.items.count == 6) // first page plus five more
        #expect(feed.hasMore)
    }

    @Test func fillStopsOnceEnoughItemsAreVisible() async throws {
        let matches = (0..<10).map { "at://needle/\($0)" }
        let client = client(pages: [["at://none"], matches, ["at://needle/later"]])
        let feed = ColumnFeed()
        feed.filter = ColumnFilter(includeTerms: ["needle"])
        await feed.refresh(using: client, kind: .home)
        await feed.fillIfNeeded(using: client, kind: .home)
        #expect(feed.visibleItems.count == 10)
        #expect(feed.items.count == 11)
    }

    @Test func filterWithoutMatchesStopsFetchingOnItsOwn() async throws {
        let client = client(pages: (0..<20).map { ["at://none\($0)"] })
        let feed = ColumnFeed()
        feed.filter = ColumnFilter(includeTerms: ["needle"])
        await feed.refresh(using: client, kind: .home)
        await feed.fillIfNeeded(using: client, kind: .home)
        await feed.fillIfNeeded(using: client, kind: .home)
        #expect(feed.items.count == 6) // first page plus the budget of five, not ten

        // Asking explicitly still works, and a new filter gets a new budget.
        await feed.loadMore(using: client, kind: .home)
        #expect(feed.items.count == 11)
        feed.filter = ColumnFilter(includeTerms: ["other"])
        await feed.fillIfNeeded(using: client, kind: .home)
        #expect(feed.items.count == 16)
    }

    @Test func noFilterMeansNoExtraFetching() async throws {
        let client = client(pages: [["at://1"], ["at://2"]])
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        await feed.fillIfNeeded(using: client, kind: .home)
        #expect(feed.items.count == 1)
    }

    @Test func changingFilterKeepsLoadedItemsAndHiddenPendingShowsNoBadge() async throws {
        let client = client(pages: [["at://1", "at://needle"], ["at://8", "at://9"]])
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        feed.filter = ColumnFilter(includeTerms: ["needle"])
        #expect(feed.visibleItems.count == 1)
        #expect(feed.items.count == 2)

        await feed.refresh(using: client, kind: .home)
        #expect(feed.pending.count == 2)
        #expect(feed.visiblePending.isEmpty)

        feed.filter = ColumnFilter()
        #expect(feed.visibleItems.count == 2)
        #expect(feed.visiblePending.count == 2)
    }

    @Test func rerankedFeedDoesNotReplaceWhatIsBeingRead() async throws {
        let client = client(pages: [["at://1", "at://2"], ["at://8", "at://9"]])
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        let before = feed.items.map(\.id)

        await feed.refresh(using: client, kind: .home)
        #expect(feed.items.map(\.id) == before)
        #expect(feed.pending.count == 2)
    }

    @Test func newPostsAppearDirectlyAtTop() async throws {
        let client = client(pages: [["at://1"], ["at://0", "at://1"]])
        let feed = ColumnFeed()
        await feed.refresh(using: client, kind: .home)
        await feed.refresh(using: client, kind: .home)
        #expect(feed.items.count == 2)
        #expect(feed.pending.isEmpty)
    }
}

@Suite struct SessionRefreshTests {
    /// Refresh tokens are single-use, so a burst of expired requests must trigger only one refresh.
    @Test func concurrentExpiryRefreshesExactlyOnce() async throws {
        let counter = RefreshCounter()
        let host = "refresh-\(UUID().uuidString).test"
        StubProtocol.register(host: host) { request in
            let token = request.value(forHTTPHeaderField: "Authorization")
            if request.url?.path.hasSuffix("refreshSession") == true {
                counter.increment()
                #expect(token == "Bearer refresh-old")
                return (200, Data(#"{"did":"d","handle":"h","accessJwt":"new","refreshJwt":"refresh-new"}"#.utf8))
            }
            if token == "Bearer new" {
                return (200, Data(#"{"did":"ok"}"#.utf8))
            }
            return (400, Data(#"{"error":"ExpiredToken"}"#.utf8))
        }
        let saved = SavedSessions()
        let session = Session(
            did: "d", handle: "h", accessJwt: "old", refreshJwt: "refresh-old",
            service: URL(string: "https://\(host)")!
        )
        let client = XRPCClient(
            service: session.service, session: session,
            transport: StubProtocol.session(), onSessionChange: { saved.append($0) }
        )
        struct Reply: Decodable, Sendable { let did: String }

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let reply: Reply = try await client.get("x.y.z")
                    return reply.did
                }
            }
            for try await did in group { #expect(did == "ok") }
        }
        #expect(counter.value == 1)
        #expect(saved.values.map(\.refreshJwt) == ["refresh-new"])
    }

    @Test func failedRefreshReportsExpiredSession() async {
        let host = "expired-\(UUID().uuidString).test"
        StubProtocol.register(host: host) { _ in (400, Data(#"{"error":"ExpiredToken"}"#.utf8)) }
        let session = Session(
            did: "d", handle: "h", accessJwt: "old", refreshJwt: "r",
            service: URL(string: "https://\(host)")!
        )
        let client = XRPCClient(service: session.service, session: session, transport: StubProtocol.session())
        struct Reply: Decodable, Sendable { let did: String }
        do {
            let _: Reply = try await client.get("x.y.z")
            Issue.record("expected failure")
        } catch let error as XRPCError {
            #expect(error.code == "SessionExpired")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func createPostSendsRecordWithFacetsAndReply() async throws {
        let host = "post-\(UUID().uuidString).test"
        let captured = CapturedBody()
        StubProtocol.register(host: host) { request in
            if request.url?.path.hasSuffix("resolveHandle") == true {
                return (200, Data(#"{"did":"did:plc:bob"}"#.utf8))
            }
            captured.set(StubProtocol.body(of: request))
            return (200, Data(#"{"uri":"u","cid":"c"}"#.utf8))
        }
        let session = Session(
            did: "did:plc:me", handle: "me", accessJwt: "a", refreshJwt: "r",
            service: URL(string: "https://\(host)")!
        )
        let client = XRPCClient(service: session.service, session: session, transport: StubProtocol.session())
        let parent = StrongRef(uri: "at://p", cid: "pc")
        try await client.createPost(
            PostDraft(text: "hi @bob.test", langs: ["de"], reply: ReplyRef(root: parent, parent: parent)),
            repo: "did:plc:me"
        )

        let body = try #require(captured.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["repo"] as? String == "did:plc:me")
        #expect(json["collection"] as? String == "app.bsky.feed.post")
        let record = try #require(json["record"] as? [String: Any])
        #expect(record["$type"] as? String == "app.bsky.feed.post")
        #expect(record["text"] as? String == "hi @bob.test")
        #expect(record["langs"] as? [String] == ["de"])
        #expect((record["reply"] as? [String: Any])?["parent"] != nil)
        let facet = try #require((record["facets"] as? [[String: Any]])?.first)
        let index = try #require(facet["index"] as? [String: Int])
        #expect(index == ["byteStart": 3, "byteEnd": 12])
        let feature = try #require((facet["features"] as? [[String: Any]])?.first)
        #expect(feature["$type"] as? String == "app.bsky.richtext.facet#mention")
        #expect(feature["did"] as? String == "did:plc:bob")
    }
}
