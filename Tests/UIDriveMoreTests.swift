import AppKit
import SwiftUI
import Testing
@testable import BlueSkyship

/// More real flows on the real window, against the simulated server.
@MainActor
@Suite(.serialized) struct UIDriveMoreTests {
    private func rightClick(_ app: DeckHarness) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    // MARK: Menus on text in quotes and notifications

    @Test func aQuoteOffersItsAuthorsMenuAndAClickOpensTheOuterThread() async throws {
        let app = DeckHarness()
        defer { app.close() }
        app.server.includeQuotePost = true
        await app.openHome()
        let quote = try #require(app.textView(containing: "zitierter Text"))
        let titles = try #require(quote.menu(for: rightClick(app))).items.map(\.title)
        #expect(titles.contains { $0.contains("Quentin") }, "the quoted person, not the quoting one")
        quote.onTap?()
        await app.settle()
        #expect(app.server.readNames.contains("app.bsky.feed.getPostThread"))
    }

    @Test func aNotificationTextOffersThePersonsMenu() async throws {
        let app = DeckHarness()
        defer { app.close() }
        app.deck.addColumn(Column(kind: .notifications, accountDID: FakeBluesky.viewerDID))
        await app.settle(0.8)
        let text = try #require(app.textView(containing: "Erster Post"))
        let titles = try #require(text.menu(for: rightClick(app))).items.map(\.title)
        #expect(titles.contains { $0.contains("Nina") }, "the person who reacted")
    }

    // MARK: Direct messages

    @Test func chatsOpenInOrderAndAnswersReachTheServerWithTheProxy() async throws {
        let app = DeckHarness(size: CGSize(width: 800, height: 700))
        defer { app.close() }
        app.deck.addColumn(Column(kind: .messages, accountDID: FakeBluesky.viewerDID))
        await app.settle(1)
        #expect(app.server.readNames.contains("chat.bsky.convo.listConvos"))
        // First row of the list, below the column header.
        await app.click(x: DeckHarness.Layout.columnLeft + 120, y: 80)
        await app.settle(1)
        #expect(app.server.readNames.contains("chat.bsky.convo.getMessages"))
        #expect(app.server.writeNames.contains("chat.bsky.convo.updateRead"), "opening marks it as read")
        app.screenshot("chat-open")

        // Message field at the bottom of the column, then the Return key's action.
        await app.click(x: DeckHarness.Layout.columnLeft + 120, y: 668)
        await app.settle(0.3)
        #expect(app.window.firstResponder is NSTextView, "the message field should take the focus")
        app.type("Antwort https://example.com")
        await app.settle(0.3)
        (app.window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await app.settle(0.6)
        let sent = try #require(app.server.writeBodies(named: "chat.bsky.convo.sendMessage").first)
        let message = try #require(sent["message"] as? [String: Any])
        #expect(message["text"] as? String == "Antwort https://example.com")
        #expect((message["facets"] as? [Any])?.count == 1)
        #expect(app.server.sawChatProxyOnEveryChatCall)
        app.screenshot("chat-sent")
    }

    @Test func aMissingChatPermissionExplainsItself() async throws {
        let app = DeckHarness(size: CGSize(width: 800, height: 700))
        defer { app.close() }
        app.server.refusesChat = true
        app.deck.addColumn(Column(kind: .messages, accountDID: FakeBluesky.viewerDID))
        await app.settle(1)
        app.screenshot("chat-denied")
        #expect(app.server.readNames.contains("chat.bsky.convo.listConvos"))
    }

    // MARK: Notifications

    @Test func unreadCountReachesTheDockAndMarkingAsReadClearsIt() async throws {
        let app = DeckHarness()
        defer {
            app.close()
            NSApp.dockTile.badgeLabel = nil
        }
        await app.deck.pollNotifications()
        #expect(app.deck.totalUnread == 2)
        #expect(NSApp.dockTile.badgeLabel == "2")
        await app.deck.markNotificationsRead(accountDID: FakeBluesky.viewerDID)
        #expect(app.server.writeNames.contains("app.bsky.notification.updateSeen"))
        #expect(app.deck.totalUnread == 0)
        #expect(NSApp.dockTile.badgeLabel == nil)
    }

    // MARK: Composer

    @Test func aPastedPictureTravelsWithThePost() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.click(x: DeckHarness.Layout.railX, y: DeckHarness.Layout.railCompose)
        await app.settle()
        app.type("Mit Bild")

        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        // What ⌘V hands over. The real clipboard stays untouched.
        app.deck.pastedImageData = try #require(image.tiffRepresentation)
        await app.settle(0.8)

        let send = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
        #expect(app.window.performKeyEquivalent(with: send))
        await app.settle(0.6)
        #expect(app.server.writeNames.contains("com.atproto.repo.uploadBlob"))
        let post = try #require(app.server.records(in: "app.bsky.feed.post").first)
        #expect((post["embed"] as? [String: Any])?["$type"] as? String == "app.bsky.embed.images")
    }

    // MARK: Accounts

    @Test func aSecondAccountHasItsOwnColumnsAndSigningOutTakesThemAlong() async throws {
        let app = DeckHarness()
        defer { app.close() }
        let session = Session(
            did: "did:plc:second", handle: "second.test", accessJwt: "a", refreshJwt: "r",
            service: URL(string: "https://\(app.server.host)")!
        )
        app.deck.accounts.installForTesting(
            Account(did: session.did, handle: session.handle),
            client: XRPCClient(service: session.service, session: session, transport: StubProtocol.session())
        )
        let tied = Column(kind: .home, accountDID: session.did)
        let open = Column(kind: .author(actor: "bob.test"), accountDID: session.did)
        let other = Column(kind: .home, accountDID: FakeBluesky.viewerDID)
        app.deck.addColumn(tied)
        app.deck.addColumn(open)
        app.deck.addColumn(other)
        app.deck.addFavorite(kind: .notifications, title: "n", accountDID: session.did)
        await app.settle(0.6)

        app.deck.startCompose(accountDID: session.did)
        #expect(app.deck.compose?.accountDID == session.did)
        await app.deck.logout(did: session.did)
        await app.settle()

        #expect(!app.deck.columns.contains { $0.id == tied.id }, "it only works with that account")
        #expect(app.deck.columns.first { $0.id == open.id }?.accountDID == nil, "public content stays, read publicly")
        #expect(app.deck.columns.contains { $0.id == other.id })
        #expect(app.deck.favorites.isEmpty)
        #expect(app.deck.compose == nil)
    }

    @Test func thePasswordPageOpensOnlyOnceAndOnlyWithoutAnAccount() {
        let empty = DeckStore()
        #expect(empty.claimAutomaticAppPasswordsOpen())
        #expect(!empty.claimAutomaticAppPasswordsOpen())

        let app = DeckHarness()
        defer { app.close() }
        #expect(!app.deck.claimAutomaticAppPasswordsOpen())
    }

    // MARK: Decks

    @Test func renamingAndDeletingADeckStayConsistent() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        let first = app.deck.activeDeckID
        app.deck.addDeck(name: "Arbeit")
        let second = app.deck.activeDeckID
        app.deck.renameDeck(second, to: "Privat")
        #expect(app.deck.activeDeck?.name == "Privat")
        await app.deck.perform(.deleteDeck(try #require(app.deck.activeDeck)))
        await app.settle(0.6)
        #expect(app.deck.activeDeckID == first)
        #expect(app.deck.columns.count == 1)
    }

    // MARK: Records for the official validator

    /// Everything the app sends, written out so the official Bluesky validator can check it.
    @Test func writeAllRecordsForValidation() async throws {
        let app = DeckHarness()
        defer { app.close() }
        let did = FakeBluesky.viewerDID
        let client = try #require(app.deck.accounts.client(for: did))
        let image = DraftImage(
            prepared: PreparedImage(data: Data([1, 2, 3]), mimeType: "image/jpeg", width: 40, height: 20),
            alt: "ein Fuchs"
        )
        let target = StrongRef(uri: "at://did:plc:alice/app.bsky.feed.post/3abc", cid: FakeBluesky.validCID)

        try await client.createPost(PostDraft(text: "Hallo @me.test #tag https://example.com/a äöü 👋", langs: ["de"]), repo: did)
        try await client.createPost(PostDraft(text: "Mit Bild", images: [image]), repo: did)
        try await client.createPost(PostDraft(text: "Zitat", quote: target), repo: did)
        try await client.createPost(PostDraft(text: "Zitat mit Bild", quote: target, images: [image]), repo: did)
        try await client.createPost(PostDraft(text: "Antwort", reply: ReplyRef(root: target, parent: target)), repo: did)
        _ = await client.createThread(texts: ["Thread 1", "Thread 2"], first: PostDraft(text: "Thread 1"), replyRule: .followers, repo: did)
        for rule in [ReplyRule.nobody, .mentioned, .following] {
            try await client.setReplyRule(rule, post: "at://\(did)/app.bsky.feed.post/3rule", repo: did)
        }
        _ = try await client.createInteraction(collection: "app.bsky.feed.like", subject: target, repo: did)
        _ = try await client.createInteraction(collection: "app.bsky.feed.repost", subject: target, repo: did)
        _ = try await client.follow(did: "did:plc:alice", repo: did)
        _ = try await client.block(did: "did:plc:alice", repo: did)

        let blob = BlobRef(ref: .init(link: FakeBluesky.validCID), mimeType: "video/mp4", size: 3)
        let video = NewPostRecord.Embed.Video(video: blob, alt: "Clip", aspectRatio: .init(width: 16, height: 9))
        let embeds = [
            NewPostRecord.Embed.make(quote: nil, images: [], video: video),
            NewPostRecord.Embed.make(quote: target, images: [], video: video),
        ]
        var extra: [[String: Any]] = []
        for embed in embeds {
            let record = NewPostRecord(
                text: "Video", createdAt: ATDate.string(), langs: nil, facets: nil, reply: nil, embed: embed
            )
            let data = try JSONEncoder().encode(record)
            extra.append(try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }

        var all = app.server.writeBodies(named: "com.atproto.repo.createRecord").compactMap { body -> [String: Any]? in
            guard let collection = body["collection"], let record = body["record"] else { return nil }
            return ["collection": collection, "record": record]
        }
        all += extra.map { ["collection": "app.bsky.feed.post", "record": $0] }
        #expect(all.count >= 15)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "records-for-validation.json")
        try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]).write(to: url)
        print("VALIDATION \(all.count) records at \(url.path)")
    }

    // MARK: Pictures of the windows

    /// Holds Settings, Help and the deck open in both languages, so real window captures can be taken from outside.
    @Test func showWindowsForCapture() async throws {
        guard ProcessInfo.processInfo.environment["BLUESKYSHIP_CAPTURE"] != nil
            || FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "capture-windows") else { return }
        let deck = DeckStore()
        var windows: [NSWindow] = []
        var lines: [String] = []
        func show<V: View>(_ view: V, name: String, size: CGSize, at index: Int) {
            let window = ActiveLookingWindow(
                contentRect: CGRect(origin: CGPoint(x: -3000 - CGFloat(index) * 1000, y: -3000), size: size),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = NSHostingView(rootView: view.environment(deck).frame(width: size.width, height: size.height))
            window.orderFrontRegardless()
            windows.append(window)
            lines.append("\(window.windowNumber) \(name)")
        }
        let base = NSTemporaryDirectory()
        defer { windows.forEach { $0.orderOut(nil) } }

        Localizer.shared.preference = .english
        show(SettingsView(), name: "settings-en", size: CGSize(width: 460, height: 640), at: 0)
        show(HelpView(), name: "help-en", size: CGSize(width: 860, height: 640), at: 1)
        try await Task.sleep(for: .seconds(1))
        try lines.joined(separator: "\n").write(toFile: base + "capture-en.txt", atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(5))
        Localizer.shared.preference = .german
        try await Task.sleep(for: .seconds(1))
        try "go".write(toFile: base + "capture-de.txt", atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(5))
    }
}
