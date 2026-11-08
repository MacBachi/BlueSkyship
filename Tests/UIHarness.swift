import AppKit
import SwiftUI
import Testing
@testable import BlueSkyship

/// A simulated Bluesky server with one signed-in account. Nothing here reaches the network.
final class FakeBluesky: @unchecked Sendable {
    let host = "fake-\(UUID().uuidString).test"
    static let viewerDID = "did:plc:viewer"
    /// A real content identifier, because the official validator checks their format.
    static let validCID = "bafkreihybpskotkosezr4yzvkj5et62qpf32efvz4wulirfieqii7p2axy"
    var includeQuotePost = false
    var refusesChat = false
    private var chatCallsWithoutProxy = 0
    var sawChatProxyOnEveryChatCall: Bool { lock.withLock { chatCallsWithoutProxy == 0 } }
    private let lock = NSLock()
    private var writes: [(name: String, body: [String: Any])] = []
    private var reads: [String] = []

    var writeNames: [String] { lock.withLock { writes.map(\.name) } }
    var readNames: [String] { lock.withLock { reads } }

    func writeBodies(named name: String) -> [[String: Any]] {
        lock.withLock { writes.filter { $0.name == name }.map(\.body) }
    }

    /// Records written with createRecord, for one collection.
    func records(in collection: String) -> [[String: Any]] {
        writeBodies(named: "com.atproto.repo.createRecord")
            .filter { $0["collection"] as? String == collection }
            .compactMap { $0["record"] as? [String: Any] }
    }

    static func post(_ id: String, text: String, author: String = "alice.test", name: String = "Alice", authorDID: String = "did:plc:alice", facets: String = "") -> String {
        """
        {"uri":"at://\(authorDID)/app.bsky.feed.post/\(id)","cid":"c\(id)",
         "author":{"did":"\(authorDID)","handle":"\(author)","displayName":"\(name)"},
         "indexedAt":"2026-01-01T00:00:00.000Z","likeCount":1,"repostCount":0,"replyCount":0,
         "record":{"text":"\(text)"\(facets)}}
        """
    }

    func start() {
        StubProtocol.register(host: host) { [self] request in
            let name = request.url?.lastPathComponent ?? ""
            if name.hasPrefix("chat.bsky."), request.value(forHTTPHeaderField: "atproto-proxy") != "did:web:api.bsky.chat#bsky_chat" {
                lock.withLock { chatCallsWithoutProxy += 1 }
            }
            if refusesChat, name.hasPrefix("chat.bsky.") {
                lock.withLock { reads.append(name) }
                return (400, Data(#"{"error":"InvalidToken","message":"Bad token scope"}"#.utf8))
            }
            if request.httpMethod == "POST" {
                let body = StubProtocol.body(of: request)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                lock.withLock { writes.append((name, body)) }
                let count = lock.withLock { writes.count }
                if name == "com.atproto.repo.uploadBlob" {
                    return (200, Data(#"{"blob":{"$type":"blob","ref":{"$link":"\#(Self.validCID)"},"mimeType":"image/jpeg","size":3}}"#.utf8))
                }
                if name == "chat.bsky.convo.sendMessage" {
                    return (200, Data(#"{"id":"m9","rev":"r","text":"gesendet","sender":{"did":"\#(Self.viewerDID)"},"sentAt":"2026-01-01T00:02:00Z"}"#.utf8))
                }
                return (200, Data(#"{"uri":"at://\#(Self.viewerDID)/app.bsky.feed.post/3new\#(count)","cid":"\#(Self.validCID)"}"#.utf8))
            }
            lock.withLock { reads.append(name) }
            return answer(name)
        }
    }

    private func answer(_ name: String) -> (Int, Data) {
        // Bytes 0-4 of the second post are a mention, 5-9 a hashtag: clicks on them stay inside the app.
        let facets = #","facets":[{"index":{"byteStart":0,"byteEnd":4},"features":[{"$type":"app.bsky.richtext.facet#mention","did":"did:plc:carol"}]},{"index":{"byteStart":5,"byteEnd":9},"features":[{"$type":"app.bsky.richtext.facet#tag","tag":"tagg"}]}]"#
        let posts = [
            Self.post("p1", text: "Erster Post mit langem Text zum Anklicken und Markieren"),
            Self.post("p2", text: "@car #tag und noch mehr Text", author: "bob.test", name: "Bob", authorDID: "did:plc:bob", facets: facets),
            Self.post("own", text: "Mein eigener Post", author: "me.test", name: "Ich", authorDID: Self.viewerDID),
        ]
        switch name {
        case "app.bsky.feed.getTimeline", "app.bsky.feed.getAuthorFeed", "app.bsky.feed.getFeed", "app.bsky.feed.getActorLikes":
            var entries = posts
            if includeQuotePost {
                let embed = #"{"$type":"app.bsky.embed.record#view","record":{"$type":"app.bsky.embed.record#viewRecord","uri":"at://did:plc:q/app.bsky.feed.post/q1","cid":"c","author":{"did":"did:plc:q","handle":"q.test","displayName":"Quentin"},"value":{"text":"zitierter Text"},"indexedAt":"2026-01-01T00:00:00Z"}}"#
                entries.insert(#"{"uri":"at://did:plc:alice/app.bsky.feed.post/qp","cid":"c","author":{"did":"did:plc:alice","handle":"alice.test","displayName":"Alice"},"indexedAt":"2026-01-01T00:00:00.000Z","record":{"text":"Zitiert"},"embed":\#(embed)}"#, at: 0)
            }
            let feed = entries.map { #"{"post":\#($0)}"# }.joined(separator: ",")
            return (200, Data(#"{"feed":[\#(feed)]}"#.utf8))
        case "app.bsky.feed.getPosts":
            return (200, Data(#"{"posts":[\#(posts[0])]}"#.utf8))
        case "chat.bsky.convo.listConvos":
            return (200, Data(#"{"convos":[{"id":"c1","rev":"r","muted":false,"unreadCount":1,"members":[{"did":"\#(Self.viewerDID)","handle":"me.test"},{"did":"did:plc:bob","handle":"bob.test","displayName":"Bob"}],"lastMessage":{"$type":"chat.bsky.convo.defs#messageView","id":"m2","rev":"r","text":"Zweite Nachricht","sender":{"did":"did:plc:bob"},"sentAt":"2026-01-01T00:01:00Z"}}]}"#.utf8))
        case "chat.bsky.convo.getMessages":
            return (200, Data(#"{"messages":[{"$type":"chat.bsky.convo.defs#messageView","id":"m2","rev":"r","text":"Zweite Nachricht","sender":{"did":"did:plc:bob"},"sentAt":"2026-01-01T00:01:00Z"},{"$type":"chat.bsky.convo.defs#messageView","id":"m1","rev":"r","text":"Erste Nachricht","sender":{"did":"\#(Self.viewerDID)"},"sentAt":"2026-01-01T00:00:00Z"}]}"#.utf8))
        case "app.bsky.feed.searchPosts":
            return (200, Data(#"{"posts":[\#(posts[0])]}"#.utf8))
        case "app.bsky.feed.getPostThread":
            return (200, Data(#"{"thread":{"post":\#(posts[0]),"replies":[{"post":\#(posts[1])}]}}"#.utf8))
        case "app.bsky.actor.getProfile":
            return (200, Data(#"{"did":"did:plc:bob","handle":"bob.test","displayName":"Bob Beispiel","avatar":"https://nowhere.invalid/a.jpg","followersCount":3,"followsCount":2,"postsCount":9}"#.utf8))
        case "app.bsky.graph.getFollowers":
            return (200, Data(#"{"subject":{"did":"d","handle":"h"},"followers":[{"did":"did:plc:f","handle":"f.test"}]}"#.utf8))
        case "app.bsky.actor.getPreferences":
            return (200, Data(#"{"preferences":[]}"#.utf8))
        case "app.bsky.notification.getUnreadCount":
            return (200, Data(#"{"count":2}"#.utf8))
        case "app.bsky.notification.listNotifications":
            return (200, Data(#"{"notifications":[{"uri":"at://did:plc:nina/app.bsky.feed.like/l1","cid":"c","author":{"did":"did:plc:nina","handle":"nina.test","displayName":"Nina"},"reason":"like","reasonSubject":"at://did:plc:alice/app.bsky.feed.post/p1","indexedAt":"2026-01-01T00:00:00Z","isRead":false,"record":{}}]}"#.utf8))
        case "app.bsky.actor.searchActorsTypeahead":
            return (200, Data(#"{"actors":[{"did":"did:plc:alice","handle":"alice.test","displayName":"Alice"}]}"#.utf8))
        default:
            return (200, Data("{}".utf8))
        }
    }
}

/// An inactive window uses a first click only to become active. This one behaves as if already active,
/// which is how the real window behaves in use, without taking the focus from whatever is in front.
final class ActiveLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// The real deck window, in a window nobody can see, driven with real AppKit mouse and key events.
/// It never moves the cursor, takes the focus, touches the clipboard or uses the signed-in account.
/// Menus are not opened, because AppKit would show them on the real screen; their entries are checked directly.
@MainActor
final class DeckHarness {
    let deck = DeckStore()
    let server = FakeBluesky()
    let window: NSWindow
    let hosting: NSView

    /// Positions in the fixed layout of this window, measured from its top left corner.
    enum Layout {
        static let columnLeft: CGFloat = 61
        static let railX: CGFloat = 26
        static let railCompose: CGFloat = 30
        static let railSearch: CGFloat = 72
        static let railAddColumn: CGFloat = 114
        static let railFavorites: CGFloat = 156
    }

    init(size: CGSize = CGSize(width: 1100, height: 760)) {
        server.start()
        let session = Session(
            did: FakeBluesky.viewerDID, handle: "me.test", accessJwt: "a", refreshJwt: "r",
            service: URL(string: "https://\(server.host)")!
        )
        deck.accounts.installForTesting(
            Account(did: session.did, handle: session.handle, displayName: "Ich"),
            client: XRPCClient(service: session.service, session: session, transport: StubProtocol.session())
        )
        let root = DeckWindow().environment(deck).frame(width: size.width, height: size.height)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hosting = hostingView
        window = ActiveLookingWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "BlueSkyship"
        window.contentView = hostingView
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }

    func settle(_ seconds: Double = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Opens one home column and waits for its posts.
    @discardableResult
    func openHome() async -> Column {
        let column = Column(kind: .home, accountDID: FakeBluesky.viewerDID)
        deck.addColumn(column)
        await settle(0.8)
        return column
    }

    private func windowPoint(x: CGFloat, y: CGFloat) -> CGPoint {
        hosting.convert(CGPoint(x: x, y: hosting.isFlipped ? y : hosting.bounds.height - y), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        )!
    }

    /// A real click on whatever is at this position.
    /// A text view runs its own loop inside the press, so the release is queued for it beforehand, and
    /// it gets the press directly: a synthetic press through the window does not arrive there, while the
    /// hit test still proves this is the view a real click would reach.
    func click(x: CGFloat, y: CGFloat, clicks: Int = 1) async {
        let point = windowPoint(x: x, y: y)
        if let text = textView(x: x, y: y) {
            NSApp.postEvent(mouse(.leftMouseUp, at: point, clicks: clicks), atStart: false)
            text.mouseDown(with: mouse(.leftMouseDown, at: point, clicks: clicks))
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        } else {
            window.sendEvent(mouse(.leftMouseDown, at: point, clicks: clicks))
            try? await Task.sleep(for: .milliseconds(60))
            window.sendEvent(mouse(.leftMouseUp, at: point, clicks: clicks))
        }
    }

    /// Presses, moves and releases, the way selecting text with the mouse does.
    func drag(fromX: CGFloat, toX: CGFloat, y: CGFloat) {
        guard let text = textView(x: fromX, y: y) else { return }
        let end = windowPoint(x: toX, y: y)
        NSApp.postEvent(mouse(.leftMouseDragged, at: end), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, at: end), atStart: false)
        text.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(x: fromX, y: y)))
    }

    /// What is under a position, the way a real click would find it.
    func view(x: CGFloat, y: CGFloat) -> NSView? {
        window.contentView?.hitTest(windowPoint(x: x, y: y))
    }

    /// Finds selectable text by what it says, wherever it is on the screen.
    func textView(containing text: String) -> PostTextView? {
        func search(_ view: NSView) -> PostTextView? {
            if let found = view as? PostTextView, found.string.contains(text) { return found }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(hosting)
    }

    func textView(x: CGFloat, y: CGFloat) -> PostTextView? {
        view(x: x, y: y) as? PostTextView
    }

    /// Text typed into whatever has the focus.
    func type(_ text: String) {
        (window.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
        return KeyboardController.handle(event, deck: deck, window: window)
    }

    func screenshot(_ name: String) {
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name).png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    func color(x: CGFloat, y: CGFloat) -> NSColor? {
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        return bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))
    }
}
