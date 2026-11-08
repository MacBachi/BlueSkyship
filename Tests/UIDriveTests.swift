import AppKit
import SwiftUI
import Testing
@testable import BlueSkyship

/// Real clicks and key presses on the real window, against a simulated server.
/// Serialized, because the events go through the one shared application.
@MainActor
@Suite(.serialized) struct UIDriveTests {
    private typealias L = DeckHarness.Layout

    /// The text of the first post, its second line and the mention in the second post.
    private let textX = L.columnLeft + 180
    private let firstPostTextY: CGFloat = 89
    private let secondPostTextY: CGFloat = 188
    private let likeX = L.columnLeft + 233
    private let firstPostActionsY: CGFloat = 131

    // MARK: Text in posts (A1 to A4)

    @Test func aClickOnPostTextOpensTheThread() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        #expect(app.textView(x: textX, y: firstPostTextY) != nil, "there should be selectable text here")
        await app.click(x: textX, y: firstPostTextY)
        await app.settle()
        #expect(app.server.readNames.contains("app.bsky.feed.getPostThread"))
    }

    @Test func draggingSelectsTextAndDoesNotOpenTheThread() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        let text = try #require(app.textView(x: textX, y: firstPostTextY))
        app.drag(fromX: L.columnLeft + 60, toX: L.columnLeft + 200, y: firstPostTextY)
        await app.settle()
        #expect(text.selectedRange().length > 0)
        #expect(!app.server.readNames.contains("app.bsky.feed.getPostThread"))

        // With text selected, the next click only clears the selection.
        await app.click(x: textX, y: firstPostTextY)
        await app.settle()
        #expect(text.selectedRange().length == 0)
        #expect(!app.server.readNames.contains("app.bsky.feed.getPostThread"))
    }

    @Test func rightClickOnTextOffersThePostMenuAndCopyWhenSelected() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        let text = try #require(app.textView(x: textX, y: firstPostTextY))
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        let titles = try #require(text.menu(for: event)).items.map(\.title)
        #expect(titles.contains { $0.contains("Alice") })
        #expect(!titles.contains(tr("Kopieren", "Copy")))

        app.drag(fromX: L.columnLeft + 60, toX: L.columnLeft + 200, y: firstPostTextY)
        await app.settle()
        let selected = try #require(text.menu(for: event)).items.map(\.title)
        #expect(selected.first == tr("Kopieren", "Copy"))
    }

    @Test func ownPostsOfferDeletingAndOthersDoNot() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        let other = try #require(app.textView(x: textX, y: firstPostTextY)?.menu(for: event))
        #expect(!other.items.contains { $0.title == tr("Post löschen …", "Delete Post…") })
        // The third post is the viewer's own.
        let own = try #require(app.textView(x: textX, y: 271)?.menu(for: event))
        #expect(own.items.contains { $0.title == tr("Post löschen …", "Delete Post…") })
    }

    @Test func aMentionInTextOpensTheProfileAndAHashtagASearchColumn() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        // "@car" at the start of the second post's text.
        await app.click(x: L.columnLeft + 70, y: secondPostTextY)
        await app.settle()
        #expect(app.server.readNames.contains("app.bsky.actor.getProfile"))
        #expect(!app.server.readNames.contains("app.bsky.feed.getPostThread"), "a link is not a click on the post")
    }

    @Test func aHashtagInTextOpensASearchColumn() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        // "#tag" follows the mention.
        await app.click(x: L.columnLeft + 98, y: secondPostTextY)
        await app.settle(0.8)
        #expect(app.deck.columns.contains { $0.kind == .search(query: "#tagg") })
        #expect(!app.server.readNames.contains("app.bsky.feed.getPostThread"))
    }

    // MARK: Buttons

    @Test func anAvatarOpensTheProfile() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        await app.click(x: L.columnLeft + 30, y: 80)
        await app.settle()
        #expect(app.server.readNames.contains("app.bsky.actor.getProfile"))
    }

    @Test func theHeartLikesThePostAndTheSecondClickTakesItBack() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        await app.click(x: likeX, y: firstPostActionsY)
        await app.settle()
        let likes = app.server.records(in: "app.bsky.feed.like")
        #expect(likes.count == 1)
        #expect((likes.first?["subject"] as? [String: String])?["uri"]?.hasSuffix("/p1") == true)

        await app.click(x: likeX, y: firstPostActionsY)
        await app.settle()
        #expect(app.server.writeNames.contains("com.atproto.repo.deleteRecord"))
    }

    @Test func railButtonsOpenTheirPanels() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.settle()
        await app.click(x: L.railX, y: L.railFavorites)
        await app.settle()
        #expect(app.deck.isShowingFavorites)
        await app.click(x: L.railX, y: L.railFavorites)
        await app.settle()
        #expect(!app.deck.isShowingFavorites)

        await app.click(x: L.railX, y: L.railSearch)
        await app.settle()
        #expect(app.deck.isShowingGlobalSearch)
        await app.click(x: L.railX, y: L.railSearch)
        await app.settle()
        #expect(!app.deck.isShowingGlobalSearch)

        await app.click(x: L.railX, y: L.railCompose)
        await app.settle()
        #expect(app.deck.compose != nil)
    }

    // MARK: Search

    @Test func theColumnMagnifierFiltersWhileTyping() async throws {
        let app = DeckHarness()
        defer { app.close() }
        let column = await app.openHome()
        let feed = app.deck.feed(for: column)
        #expect(feed.visibleItems.count == 3)
        await app.click(x: L.columnLeft + 257, y: 30)
        await app.settle()
        #expect(app.window.firstResponder is NSTextView, "the search field should have the focus")
        app.type("eigen")
        await app.settle()
        #expect(feed.searchTerm == "eigen")
        #expect(feed.visibleItems.count == 1)
        await app.click(x: L.columnLeft + 257, y: 30)
        await app.settle()
        #expect(feed.searchTerm.isEmpty)
        #expect(feed.visibleItems.count == 3)
    }

    @Test func blueskySearchShowsItsResultNextToTheDeck() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        await app.click(x: L.railX, y: L.railSearch)
        await app.settle()
        app.type("hallo")
        await app.settle(0.5)
        app.deck.searchBluesky(for: "hallo")
        await app.settle(0.8)
        #expect(app.server.readNames.contains("app.bsky.feed.searchPosts"))
        #expect(app.deck.previewColumn?.kind == .search(query: "hallo"))
        #expect(app.deck.columns.count == 1)
    }

    // MARK: Posting

    @Test func writingAPostInTheComposerReachesTheServer() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.click(x: L.railX, y: L.railCompose)
        await app.settle()
        #expect(app.window.firstResponder is NSTextView, "the composer should take the focus")
        app.type("Hallo #welt")
        await app.settle()
        #expect(app.deck.drafts.first?.preview == "Hallo #welt", "text is kept as a draft while typing")
        // The key equivalent of the Post button.
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
        #expect(app.window.performKeyEquivalent(with: event))
        await app.settle()
        let posts = app.server.records(in: "app.bsky.feed.post")
        #expect(posts.count == 1)
        #expect(posts.first?["text"] as? String == "Hallo #welt")
        #expect((posts.first?["facets"] as? [Any])?.count == 1)
        #expect(app.deck.compose == nil)
        #expect(app.deck.drafts.isEmpty)
    }

    @Test func aConfirmedDeleteRemovesThePostFromTheScreen() async throws {
        let app = DeckHarness()
        defer { app.close() }
        let column = await app.openHome()
        let feed = app.deck.feed(for: column)
        let own = try #require(feed.visibleItems.compactMap(\.displayedPost).first { app.deck.isOwnPost($0) })
        await app.deck.perform(.deletePost(own))
        await app.settle()
        #expect(app.server.writeNames.contains("com.atproto.repo.deleteRecord"))
        #expect(feed.visibleItems.count == 2)
    }

    // MARK: Keyboard

    @Test func singleKeysWorkInTheDeckAndLikeThePostOnTheScreen() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        #expect(app.press("j", keyCode: 38))
        #expect(app.deck.keyboardFocus != nil)
        #expect(app.press("l", keyCode: 37))
        await app.settle()
        #expect(app.server.records(in: "app.bsky.feed.like").count == 1)
    }

    @Test func typingNeverTriggersSingleKeyCommands() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        _ = app.press("j", keyCode: 38)
        await app.click(x: L.railX, y: L.railCompose)
        await app.settle()
        #expect(app.window.firstResponder is NSTextView)
        #expect(!app.press("l", keyCode: 37), "this letter belongs into the text")
        await app.settle()
        #expect(app.server.records(in: "app.bsky.feed.like").isEmpty)
    }

    @Test func keysKeepWorkingAfterSelectingTextInAPost() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        app.drag(fromX: L.columnLeft + 60, toX: L.columnLeft + 200, y: 89)
        await app.settle()
        #expect(app.press("j", keyCode: 38))
        #expect(app.deck.keyboardFocus != nil)
    }

    // MARK: Scheduled posts

    @Test func aDuePostGoesOutOnceAndAMissedOneWaits() async throws {
        let app = DeckHarness()
        defer { app.close() }
        let now = Date()
        app.deck.scheduledPosts = [
            ScheduledPost(date: now.addingTimeInterval(-60), segments: ["faellig", "zweiter"], accountDID: FakeBluesky.viewerDID),
            ScheduledPost(date: now.addingTimeInterval(-7200), segments: ["verpasst"], accountDID: FakeBluesky.viewerDID),
            ScheduledPost(date: now.addingTimeInterval(3600), segments: ["spaeter"], accountDID: FakeBluesky.viewerDID),
        ]
        await app.deck.sendDueScheduledPosts(now: now)
        await app.deck.sendDueScheduledPosts(now: now)
        await app.settle()
        let texts = app.server.records(in: "app.bsky.feed.post").compactMap { $0["text"] as? String }
        #expect(texts == ["faellig", "zweiter"], "sent exactly once, and nothing else")
        #expect(app.deck.scheduledPosts.map { $0.segments[0] }.sorted() == ["spaeter", "verpasst"])
    }

    // MARK: Decks (A25)

    @Test func anEmptyDeckStillFillsTheWholeWindow() async throws {
        let app = DeckHarness()
        defer { app.close() }
        app.deck.addDeck(name: "Leer")
        await app.settle(0.8)
        #expect(app.deck.columns.isEmpty)
        // The navigation rail has to stay at the left edge, with the window's background everywhere.
        let farRight = try #require(app.color(x: 1080, y: 380))
        let center = try #require(app.color(x: 575, y: 100))
        #expect(farRight.isClose(to: center), "the content must reach the right edge")
        let farLeft = try #require(app.color(x: 3, y: 380))
        #expect(farLeft.alphaComponent > 0.9, "the rail must start at the left edge")
    }

    @Test func eachDeckKeepsItsColumnsOnScreen() async throws {
        let app = DeckHarness()
        defer { app.close() }
        await app.openHome()
        let first = app.deck.activeDeckID
        app.deck.addDeck(name: "Arbeit")
        await app.settle()
        #expect(app.textView(x: 240, y: 89) == nil)
        app.deck.switchDeck(first)
        await app.settle(0.8)
        #expect(app.textView(x: 240, y: 89) != nil)
    }

    // MARK: Moving a column to the favorites (A24)

    @Test func aMovedColumnKeepsItsContentFilterAndWidth() async throws {
        let app = DeckHarness()
        defer { app.close() }
        var column = Column(kind: .author(actor: "bob.test"), accountDID: FakeBluesky.viewerDID)
        column.filter = ColumnFilter(hideReposts: true)
        column.width = .wide
        app.deck.addColumn(column)
        await app.settle(0.5)
        app.deck.moveColumnToFavorites(column)
        await app.settle(0.5)
        #expect(app.deck.columns.isEmpty)
        let favorite = try #require(app.deck.favorites.first)
        #expect(favorite.kind == .author(actor: "bob.test"), "the content must stay what the column showed")
        #expect(favorite.filter == ColumnFilter(hideReposts: true))
        #expect(favorite.title == "Bob Beispiel", "a person is listed by name")
        #expect(favorite.avatar != nil)

        app.deck.togglePreview(favorite)
        #expect(app.deck.previewColumn?.filter == ColumnFilter(hideReposts: true))
        app.deck.pinAsColumn(favorite)
        let restored = try #require(app.deck.columns.first)
        #expect(restored.kind == .author(actor: "bob.test"))
        #expect(restored.filter == ColumnFilter(hideReposts: true))
        #expect(restored.width == .wide)
    }
}

private extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.deviceRGB), let b = other.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.05
            && abs(a.greenComponent - b.greenComponent) < 0.05
            && abs(a.blueComponent - b.blueComponent) < 0.05
            && abs(a.alphaComponent - b.alphaComponent) < 0.05
    }
}
