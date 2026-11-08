import Foundation

/// A named set of columns to switch between, such as "Work" and "Private".
struct DeckPage: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var columns: [Column] = []
}

/// Text from the composer, kept while writing so closing it or a crash loses nothing. Pictures are not kept.
struct SavedDraft: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var segments: [String]
    var accountDID: String?
    var reply: ReplyRef?
    var quote: StrongRef?
    var targetLabel: String?
    var updatedAt = Date()

    var preview: String {
        segments.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}

/// A post waiting for its time. Sent by this app, so only while it runs and the Mac is awake.
struct ScheduledPost: Codable, Identifiable, Sendable {
    enum Due: Equatable {
        case wait, send
        /// The app was not running at the planned time. Sending much later could be wrong, so it asks.
        case overdue
    }

    /// How late a post may still go out without asking.
    static let graceInterval: TimeInterval = 15 * 60

    var id = UUID()
    var date: Date
    var segments: [String]
    var images: [DraftImage] = []
    /// Pictures of the following posts of a thread, by position.
    var laterImages: [Int: [DraftImage]]?
    var accountDID: String
    var reply: ReplyRef?
    var quote: StrongRef?
    var langs: [String] = []
    var targetLabel: String?
    var lastError: String?

    func due(now: Date = Date()) -> Due {
        if lastError != nil { return .overdue }
        if date > now { return .wait }
        return now.timeIntervalSince(date) <= Self.graceInterval ? .send : .overdue
    }
}

/// Things that need a yes first, because they change the account and are public or hard to undo.
enum DeckConfirmation: Identifiable, Hashable {
    case deletePost(PostView)
    case mute(Profile, accountDID: String?)
    case block(Profile, accountDID: String?)
    case deleteDeck(DeckPage)
    case openLink(URL, shownAs: String)

    var id: Self { self }

    var title: String {
        switch self {
        case .deletePost: return tr("Post löschen?", "Delete post?")
        case .mute(let person, _): return tr("\(person.bestName) stummschalten?", "Mute \(person.bestName)?")
        case .block(let person, _): return tr("\(person.bestName) blockieren?", "Block \(person.bestName)?")
        case .deleteDeck(let page): return tr("Deck „\(page.name)“ löschen?", "Delete deck “\(page.name)”?")
        case .openLink: return tr("Dieser Link führt woanders hin", "This link goes somewhere else")
        }
    }

    var message: String {
        switch self {
        case .deletePost:
            return tr("Der Post wird von Bluesky entfernt. Das lässt sich nicht rückgängig machen.", "The post is removed from Bluesky. This cannot be undone.")
        case .mute:
            return tr("Du siehst die Posts dieser Person nicht mehr. Sie erfährt nichts davon. Rückgängig machst du es im Profil.", "You no longer see this person's posts. They are not told. Undo it on their profile.")
        case .block:
            return tr("Ihr könnt einander nicht mehr sehen oder miteinander interagieren. Blockieren ist öffentlich einsehbar. Rückgängig machst du es im Profil.", "You can no longer see or interact with each other. Blocks are publicly visible. Undo it on their profile.")
        case .openLink(let url, let shown):
            let target = String(url.absoluteString.prefix(200))
            return tr(
                "Im Post steht: \(String(shown.prefix(100)))\nDas Ziel ist: \(target)\n\nÖffne ihn nur, wenn du dem Ziel vertraust, und gib dort keine Passwörter ein.",
                "The post says: \(String(shown.prefix(100)))\nIt goes to: \(target)\n\nOnly open it if you trust the destination, and do not enter passwords there."
            )
        case .deleteDeck:
            return tr("Seine Spalten werden entfernt. Deine Favoriten und dein Bluesky-Konto bleiben unberührt.", "Its columns are removed. Your favorites and Bluesky account are not affected.")
        }
    }

    var actionLabel: String {
        switch self {
        case .deletePost, .deleteDeck: return tr("Löschen", "Delete")
        case .openLink: return tr("Trotzdem öffnen", "Open Anyway")
        case .mute: return tr("Stummschalten", "Mute")
        case .block: return tr("Blockieren", "Block")
        }
    }
}

/// Which item the keyboard is on.
struct KeyboardFocus: Equatable {
    let columnID: UUID
    let itemID: String
}

/// A request for one column to navigate, for actions that come from outside the column.
struct ColumnNavigationRequest: Equatable {
    enum Action: Equatable {
        case push(ColumnRoute)
        case back
    }

    let id = UUID()
    let columnID: UUID
    let action: Action
}

enum KeyCommand: Equatable {
    case next, previous, nextColumn, previousColumn
    case open, back
    case like, repost, reply, quote
    case newPost, addColumn
    case jumpToColumn(Int)

    /// Single keys without modifiers, in the style of TweetDeck.
    static func parse(characters: String, keyCode: UInt16, hasModifiers: Bool) -> KeyCommand? {
        guard !hasModifiers else { return nil }
        switch keyCode {
        case 123: return .previousColumn
        case 124: return .nextColumn
        case 36: return .open
        case 53: return .back
        default: break
        }
        switch characters {
        case "j": return .next
        case "k": return .previous
        case "l": return .like
        case "t": return .repost
        case "r": return .reply
        case "q": return .quote
        case "n": return .newPost
        case "a": return .addColumn
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return Int(characters).map { .jumpToColumn($0 - 1) }
        default: return nil
        }
    }
}

enum NotificationDigest {
    /// What is new since the last alert. The first run only sets the mark, so old items never flood in.
    static func newItems(_ items: [RawNotification], since mark: String?) -> (new: [RawNotification], mark: String?) {
        let newest = items.map(\.indexedAt).max { (ATDate.parse($0) ?? .distantPast) < (ATDate.parse($1) ?? .distantPast) }
        guard let mark, let markDate = ATDate.parse(mark) else { return ([], newest ?? mark) }
        let fresh = items.filter { (ATDate.parse($0.indexedAt) ?? .distantPast) > markDate }
        return (fresh, newest ?? mark)
    }
}

extension RawNotification {
    /// One line such as "liked your post", shown after the person's name.
    var summary: String {
        switch reason {
        case "like": return tr("gefällt dein Post", "liked your post")
        case "repost": return tr("hat deinen Post repostet", "reposted your post")
        case "follow": return tr("folgt dir jetzt", "followed you")
        case "reply": return tr("hat dir geantwortet", "replied to you")
        case "mention": return tr("hat dich erwähnt", "mentioned you")
        case "quote": return tr("hat dich zitiert", "quoted you")
        case "starterpack-joined": return tr("ist über dein Starter Pack beigetreten", "joined through your starter pack")
        default: return tr("hat mit dir interagiert", "interacted with you")
        }
    }
}
