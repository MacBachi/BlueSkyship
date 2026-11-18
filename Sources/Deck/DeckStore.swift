import AppKit
import Foundation
import Observation

/// What the full-window media viewer is showing.
enum MediaPresentation: Equatable {
    case images([EmbedImage], index: Int)
    case video(VideoEmbed, webURL: URL?)
}

/// What the composer panel is currently writing.
struct ComposeContext: Equatable {
    var replyTo: PostView?
    var quote: PostView?
    var accountDID: String?
    /// From a saved draft, which keeps only the references rather than the whole post.
    var savedReply: ReplyRef?
    var savedQuote: StrongRef?
    var savedTargetLabel: String?
    var initialSegments = [""]
    /// Pictures per post, from a saved draft.
    var initialImages: [[DraftImage]] = []
    /// Visibility and content warning, used when the account is on Mastodon.
    var mastodonOptions = MastodonPostOptions()
    var draftID = UUID()
    /// A new one for every start, so the panel begins fresh.
    var sessionID = UUID()

    var effectiveReply: ReplyRef? {
        if let parent = replyTo {
            return ReplyRef(root: parent.record.reply?.root ?? parent.ref, parent: parent.ref)
        }
        return savedReply
    }

    var effectiveQuote: StrongRef? { quote?.ref ?? savedQuote }

    /// Says what this refers to, wherever the post itself is not at hand.
    var targetLabel: String? {
        if let replyTo { return tr("Antwort an \(replyTo.author.bestName)", "Reply to \(replyTo.author.bestName)") }
        if let quote { return tr("Zitat von \(quote.author.bestName)", "Quote of \(quote.author.bestName)") }
        return savedTargetLabel
    }
}

@MainActor
@Observable
final class DeckStore {
    private static let columnsKey = "deck.columns.v1"
    private static let favoritesKey = "deck.favorites.v1"
    private static let decksKey = "deck.pages.v1"
    private static let activeDeckKey = "deck.activePage.v1"
    static let draftsKey = "deck.drafts.v1"
    /// Seen by everyone on first launch, so the deck is useful before signing in.
    private static let discoverFeed = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot"

    let accounts = AccountStore()
    // Tests run in the same container as the real app, and must not change its settings.
    let settings = AppSettings(defaults: RuntimeEnvironment.isUnitTestHost
        ? (UserDefaults(suiteName: "bluesky-ship-tests") ?? .standard)
        : .standard)

    var decks: [DeckPage]
    var activeDeckID: UUID

    /// The columns of the deck on screen.
    var columns: [Column] {
        get { decks.first { $0.id == activeDeckID }?.columns ?? [] }
        set {
            guard let index = decks.firstIndex(where: { $0.id == activeDeckID }) else { return }
            decks[index].columns = newValue
        }
    }

    var activeDeck: DeckPage? { decks.first { $0.id == activeDeckID } }

    var favorites: [Favorite] = []
    var drafts: [SavedDraft] = []
    var scheduledPosts: [ScheduledPost] = []
    var unreadCounts: [String: Int] = [:]
    /// Deleted posts and muted or blocked people vanish everywhere at once, including threads and profiles.
    var hiddenPostURIs: Set<String> = []
    var hiddenAuthorDIDs: Set<String> = []
    /// Bumped after a mute or block, so an open profile shows the new state.
    var moderationGeneration = 0
    var confirmation: DeckConfirmation?
    var keyboardFocus: KeyboardFocus?
    var columnRequest: ColumnNavigationRequest?
    var isShowingScheduled = false
    var isShowingGlobalSearch = false
    /// Which column should open its search; each request is new, so the same column can be asked again.
    var columnSearchRequest: ColumnNavigationRequest?
    /// A picture pasted with ⌘V, waiting for the composer to pick it up.
    var pastedImageData: Data?
    /// What each account has set in Bluesky: muted words and labeled content.
    var moderationByAccount: [String: ModerationPrefs] = [:]
    /// Set only in the real app. Tests never touch iCloud through this.
    var cloudDocuments: CloudDocuments?
    /// While iCloud changes arrive, saving must not send them straight back.
    var isApplyingCloudChange = false
    private(set) var previewedFavorite: Favorite?
    var isShowingFavorites = false {
        didSet { if !isShowingFavorites { closeFavoritePreview() } }
    }
    var feeds: [UUID: ColumnFeed] = [:]
    private var toastTask: Task<Void, Never>?
    private var didAutoOpenAppPasswords = false

    var compose: ComposeContext?
    var media: MediaPresentation?
    var isAddingColumn = false
    var isLoggingIn = false
    var toast: String?
    /// Lets the deck scroll to a column that was just added.
    var revealColumnID: UUID?
    /// Bumped to make every column reload.
    var refreshGeneration = 0

    init() {
        let firstPage = DeckPage(name: "Deck 1")
        decks = [firstPage]
        activeDeckID = firstPage.id
        if RuntimeEnvironment.isUnitTestHost { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.favoritesKey),
           let stored = try? JSONDecoder().decode([Favorite].self, from: data) {
            favorites = stored
        }
        if let data = defaults.data(forKey: Self.draftsKey),
           let stored = try? JSONDecoder().decode([SavedDraft].self, from: data) {
            drafts = stored
        }
        if let data = defaults.data(forKey: Self.decksKey),
           let stored = try? JSONDecoder().decode([DeckPage].self, from: data), !stored.isEmpty {
            decks = stored
            activeDeckID = defaults.string(forKey: Self.activeDeckKey)
                .flatMap(UUID.init(uuidString:))
                .flatMap { id in stored.contains { $0.id == id } ? id : nil } ?? stored[0].id
        } else if let data = defaults.data(forKey: Self.columnsKey),
                  let stored = try? JSONDecoder().decode([Column].self, from: data) {
            // From before there were several decks.
            columns = stored
        } else {
            columns = [
                Column(kind: .feed(uri: Self.discoverFeed, name: "Discover")),
                Column(kind: .author(actor: "bsky.app")),
            ]
        }
    }

    // MARK: Columns

    func feed(for column: Column) -> ColumnFeed {
        if let feed = feeds[column.id] { return feed }
        let feed = ColumnFeed()
        feed.filter = column.filter ?? ColumnFilter()
        feed.moderation = moderationPrefs(for: column.accountDID)
        feed.isOwnPost = { [weak self] in self?.isOwnPost($0) ?? false }
        feeds[column.id] = feed
        return feed
    }

    func setFilter(_ filter: ColumnFilter, for id: UUID) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].filter = filter.isActive ? filter : nil
        feeds[id]?.filter = filter
        saveColumns()
    }

    func readClient(for column: Column) -> (any SocialReader)? {
        if let did = column.accountDID {
            return accounts.reader(for: did)
        }
        return column.kind.requiresAccount ? nil : accounts.publicClient
    }

    /// Reads for an account, or else through the first Bluesky account, or else Bluesky's public service.
    func reader(for accountDID: String?) -> any SocialReader {
        accounts.reader(for: accountDID)
            ?? accounts.client(for: accounts.firstBluesky?.did)
            ?? accounts.publicClient
    }

    /// The account a view without its own account reads with. Mastodon people and Mastodon-only views
    /// need a Mastodon account; Bluesky feeds and lists need Bluesky.
    func defaultAccountDID(for kind: ColumnKind, preferred: String? = nil) -> String? {
        if let preferred, accounts.reader(for: preferred) != nil { return preferred }
        switch kind {
        case .author(let actor), .profileTab(let actor, _), .ownPosts(let actor), .likes(let actor):
            if MastodonID.isActor(actor) { return accounts.mastodonAccount(forActor: actor)?.did }
            return accounts.firstBluesky?.did
        case .localTimeline, .federatedTimeline:
            return accounts.firstMastodon?.did
        case .feed, .list:
            return accounts.firstBluesky?.did
        default:
            return accounts.accounts.first?.did
        }
    }

    func addColumn(_ column: Column) {
        columns.append(column)
        revealColumnID = column.id
        saveColumns()
    }

    /// Opens a column for this kind, or scrolls to it when one already exists.
    func openColumn(kind: ColumnKind, accountDID: String?) {
        if let existing = columns.first(where: { $0.kind == kind && $0.accountDID == accountDID }) {
            revealColumnID = existing.id
        } else {
            addColumn(Column(kind: kind, accountDID: accountDID, width: settings.defaultWidth))
        }
    }

    func removeColumn(_ id: UUID) {
        columns.removeAll { $0.id == id }
        feeds[id] = nil
        saveColumns()
    }

    func moveColumn(_ id: UUID, by offset: Int) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard columns.indices.contains(target) else { return }
        columns.swapAt(index, target)
        saveColumns()
    }

    /// Drag and drop: places the dragged column where the target column is.
    func moveColumn(_ id: UUID, onto targetID: UUID) {
        guard id != targetID,
              let from = columns.firstIndex(where: { $0.id == id }),
              let to = columns.firstIndex(where: { $0.id == targetID }) else { return }
        let column = columns.remove(at: from)
        columns.insert(column, at: to)
        saveColumns()
    }

    func setWidth(_ width: ColumnWidth, for id: UUID) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].width = width
        saveColumns()
    }

    func refreshAll() {
        refreshGeneration += 1
    }

    func saveColumns() {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        if let data = try? JSONEncoder().encode(decks) {
            UserDefaults.standard.set(data, forKey: Self.decksKey)
        }
        UserDefaults.standard.set(activeDeckID.uuidString, forKey: Self.activeDeckKey)
        pushToCloud { $0.decks.push(self.decks) }
    }

    // MARK: Favorites

    func isFavorite(_ kind: ColumnKind) -> Bool {
        let normalized = Favorite.normalized(kind)
        return favorites.contains { Favorite.normalized($0.kind) == normalized }
    }

    func addFavorite(
        kind: ColumnKind, title: String, avatar: String? = nil, accountDID: String? = nil,
        filter: ColumnFilter? = nil, width: ColumnWidth? = nil
    ) {
        guard !isFavorite(kind) else { return }
        favorites.append(Favorite(
            kind: kind,
            title: title,
            avatar: avatar,
            // Mastodon views only work through an account on Mastodon, so they keep theirs.
            accountDID: Favorite.isTiedToAccount(kind) || accounts.network(of: accountDID) == .mastodon ? accountDID : nil,
            filter: filter,
            width: width
        ))
        saveFavorites()
    }

    func removeFavorite(kind: ColumnKind) {
        let normalized = Favorite.normalized(kind)
        if let favorite = favorites.first(where: { Favorite.normalized($0.kind) == normalized }) {
            removeFavorite(favorite)
        }
    }

    func removeFavorite(_ favorite: Favorite) {
        if previewedFavorite?.id == favorite.id { closeFavoritePreview() }
        favorites.removeAll { $0.id == favorite.id }
        saveFavorites()
    }

    func toggleFavorite(person: Profile, accountDID: String? = nil) {
        let kind = ColumnKind.profileTab(actor: person.handle, tab: .replies)
        if isFavorite(kind) {
            removeFavorite(kind: kind)
        } else {
            addFavorite(kind: kind, title: person.bestName, avatar: person.avatar, accountDID: accountDID)
        }
    }

    /// Frees up the deck: the column goes away and stays reachable from the favorites list.
    func moveColumnToFavorites(_ column: Column) {
        addFavorite(
            kind: column.kind, title: column.kind.title, accountDID: column.accountDID,
            filter: column.filter, width: column.width
        )
        removeColumn(column.id)
        isShowingFavorites = true
        Task { await fillInPersonDetails(for: column.kind) }
    }

    /// A column only knows the handle. A person belongs in the list with name and picture.
    private func fillInPersonDetails(for kind: ColumnKind) async {
        let actor: String
        switch kind {
        case .author(let name), .profileTab(let name, _): actor = name
        default: return
        }
        let client = reader(for: defaultAccountDID(for: kind))
        guard let profile = try? await client.profile(actor: actor),
              let index = favorites.firstIndex(where: { $0.kind == kind }) else { return }
        favorites[index].title = profile.bestName
        favorites[index].avatar = profile.avatar
        saveFavorites()
    }

    /// Understands `@name`, `#tag`, a search term, or a bsky.app link to a profile, feed or list.
    func addFavorite(fromInput input: String) async throws {
        let client = accounts.client(for: accounts.firstBluesky?.did) ?? accounts.publicClient
        switch FavoriteInput.parse(input) {
        case .invalid:
            throw XRPCError(status: 0, code: nil, message: tr("Bitte @name, #tag, einen Suchbegriff oder einen Bluesky-Link eingeben.", "Please enter @name, #tag, a search term or a Bluesky link."))
        case .search(let query):
            addFavorite(kind: .search(query: query), title: query)
        case .person(let actor) where MastodonID.isActor(actor):
            guard let account = accounts.mastodonAccount(forActor: actor) else {
                throw XRPCError(status: 0, code: nil, message: tr("Für Mastodon-Profile musst du mit einem Mastodon-Konto angemeldet sein.", "Mastodon profiles need a signed-in Mastodon account."))
            }
            let profile = try await reader(for: account.did).profile(actor: actor)
            addFavorite(
                kind: .profileTab(actor: profile.handle, tab: .replies), title: profile.bestName,
                avatar: profile.avatar, accountDID: account.did
            )
        case .person(let actor):
            let profile = try await client.profile(actor: actor)
            toggleOn(profile)
        case .personOrSearch(let text):
            if let profile = try? await client.profile(actor: text) {
                toggleOn(profile)
            } else {
                addFavorite(kind: .search(query: text), title: text)
            }
        case .feedLink(var link):
            if let authority = link.authority, !authority.hasPrefix("did:") {
                link = link.replacingAuthority(with: try await client.resolveHandle(authority))
            }
            switch link {
            case .feed(let uri):
                let name = try await client.feedName(uri: uri)
                addFavorite(kind: .feed(uri: uri, name: name), title: name)
            case .list(let uri):
                let name = try await client.listName(uri: uri)
                addFavorite(kind: .list(uri: uri, name: name), title: name)
            }
        }
    }

    private func toggleOn(_ profile: Profile) {
        addFavorite(
            kind: .profileTab(actor: profile.handle, tab: .replies),
            title: profile.bestName,
            avatar: profile.avatar
        )
    }

    /// Shows a favorite next to the list, or hides it when it is already showing.
    func togglePreview(_ favorite: Favorite) {
        let wasShowing = previewedFavorite?.id == favorite.id
        closeFavoritePreview()
        if !wasShowing { previewedFavorite = favorite }
    }

    /// Shows something temporary next to the deck, without adding it to the favorites.
    func showResult(kind: ColumnKind, title: String, avatar: String? = nil) {
        closeFavoritePreview()
        previewedFavorite = Favorite(kind: kind, title: title, avatar: avatar)
    }

    func searchBluesky(for term: String) {
        guard !term.isEmpty else { return }
        if term.hasPrefix("@"), !term.contains(" ") {
            showResult(kind: .profileTab(actor: String(term.dropFirst()), tab: .replies), title: term)
        } else if actingAccount(for: nil) != nil {
            // The public service refuses searches, so this needs an account.
            showResult(kind: .search(query: term), title: term)
        }
    }

    func closeGlobalSearch() {
        isShowingGlobalSearch = false
        closeFavoritePreview()
    }

    /// The column the keyboard is on, otherwise the first one.
    func startColumnSearch() {
        guard let column = columns.first(where: { $0.id == keyboardFocus?.columnID }) ?? columns.first else { return }
        revealColumnID = column.id
        columnSearchRequest = ColumnNavigationRequest(columnID: column.id, action: .back)
    }

    func closeFavoritePreview() {
        if let id = previewedFavorite?.id { feeds[id] = nil }
        previewedFavorite = nil
    }

    /// The temporary column for the favorite being previewed. Never part of the saved deck.
    var previewColumn: Column? {
        previewedFavorite.map { favorite in
            Column(
                id: favorite.id,
                kind: favorite.kind,
                accountDID: defaultAccountDID(for: favorite.kind, preferred: favorite.accountDID),
                filter: favorite.filter
            )
        }
    }

    func pinAsColumn(_ favorite: Favorite) {
        closeFavoritePreview()
        let accountDID = defaultAccountDID(for: favorite.kind, preferred: favorite.accountDID)
        if columns.contains(where: { $0.kind == favorite.kind && $0.accountDID == accountDID }) {
            openColumn(kind: favorite.kind, accountDID: accountDID)
        } else {
            addColumn(Column(
                kind: favorite.kind, accountDID: accountDID,
                width: favorite.width ?? settings.defaultWidth, filter: favorite.filter
            ))
        }
    }

    func saveFavorites() {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: Self.favoritesKey)
        }
        pushToCloud { $0.favorites.push(self.favorites) }
    }

    // MARK: Accounts

    /// Where people create the app password that sign-in asks for.
    static let appPasswordsURL = URL(string: "https://bsky.app/settings/app-passwords")!

    /// True once per launch, and only while no account is signed in, so existing users get no surprise browser tabs.
    func claimAutomaticAppPasswordsOpen() -> Bool {
        guard accounts.accounts.isEmpty, !didAutoOpenAppPasswords else { return false }
        didAutoOpenAppPasswords = true
        return true
    }

    func logout(did: String) async {
        let wasMastodon = accounts.network(of: did) == .mastodon
        await accounts.logout(did: did)
        // Columns of that account fall back to public reading, or go away if they need an account.
        for index in decks.indices {
            decks[index].columns = decks[index].columns.compactMap { column in
                guard column.accountDID == did else { return column }
                // Bluesky's public service cannot read anything from Mastodon.
                if column.kind.requiresAccount || wasMastodon {
                    feeds[column.id] = nil
                    return nil
                }
                var updated = column
                updated.accountDID = nil
                return updated
            }
        }
        unreadCounts[did] = nil
        updateDockBadge()
        if compose?.accountDID == did { compose = nil }
        saveColumns()
        // Views that belong to this account, such as its notifications, no longer work.
        for favorite in favorites where favorite.accountDID == did {
            removeFavorite(favorite)
        }
    }

    /// The first account of a network puts the columns people expect in front of the deck.
    func didLogin(_ account: Account, isFirstAccount: Bool) {
        if isFirstAccount {
            for kind in [ColumnKind.notifications, .home].reversed() {
                let column = Column(kind: kind, accountDID: account.did)
                columns.insert(column, at: 0)
            }
            saveColumns()
        }
    }

    // MARK: Interactions

    /// The account that acts for a column: its own, or the first one when reading anonymously.
    func actingAccount(for accountDID: String?) -> (did: String, client: XRPCClient)? {
        let did = accountDID ?? accounts.firstBluesky?.did
        guard let did, let client = accounts.client(for: did) else {
            showToast(tr("Dafür musst du angemeldet sein.", "You need to be signed in for that."))
            isLoggingIn = true
            return nil
        }
        return (did, client)
    }

    func toggleLike(_ post: PostView, accountDID: String?, update: @escaping @MainActor (PostView) -> Void) async {
        if post.isMastodon {
            await toggleMastodon(post, accountDID: accountDID, keyPath: \.like, count: \.likeCount, update: update) {
                try await $0.setFavourite(post.uri, $1)
            }
            return
        }
        guard let actor = actingAccount(for: accountDID) else { return }
        var changed = post
        let existing = post.viewer?.like
        var viewer = post.viewer ?? PostViewer()
        viewer.like = existing == nil ? "pending" : nil
        changed.viewer = viewer
        changed.likeCount = max(0, (post.likeCount ?? 0) + (existing == nil ? 1 : -1))
        update(changed)
        do {
            if let existing {
                try await actor.client.deleteRecord(uri: existing)
            } else {
                viewer.like = try await actor.client.createInteraction(
                    collection: "app.bsky.feed.like", subject: post.ref, repo: actor.did
                )
                changed.viewer = viewer
                update(changed)
            }
        } catch {
            update(post)
            showToast(error.localizedDescription)
        }
    }

    func toggleRepost(_ post: PostView, accountDID: String?, update: @escaping @MainActor (PostView) -> Void) async {
        if post.isMastodon {
            await toggleMastodon(post, accountDID: accountDID, keyPath: \.repost, count: \.repostCount, update: update) {
                try await $0.setReblog(post.uri, $1)
            }
            return
        }
        guard let actor = actingAccount(for: accountDID) else { return }
        var changed = post
        let existing = post.viewer?.repost
        var viewer = post.viewer ?? PostViewer()
        viewer.repost = existing == nil ? "pending" : nil
        changed.viewer = viewer
        changed.repostCount = max(0, (post.repostCount ?? 0) + (existing == nil ? 1 : -1))
        update(changed)
        do {
            if let existing {
                try await actor.client.deleteRecord(uri: existing)
            } else {
                viewer.repost = try await actor.client.createInteraction(
                    collection: "app.bsky.feed.repost", subject: post.ref, repo: actor.did
                )
                changed.viewer = viewer
                update(changed)
            }
        } catch {
            update(post)
            showToast(error.localizedDescription)
        }
    }

    /// The Mastodon account that acts in a column. Mastodon posts and people can only be reached from there.
    func mastodonActor(for accountDID: String?) -> MastodonClient? {
        guard let client = accounts.mastodon(for: accountDID) else {
            showToast(tr("Dafür musst du mit einem Mastodon-Konto angemeldet sein.", "You need a signed-in Mastodon account for that."))
            return nil
        }
        return client
    }

    /// Favourite and boost: shown at once, and put back if the server says no.
    private func toggleMastodon(
        _ post: PostView, accountDID: String?,
        keyPath: WritableKeyPath<PostViewer, String?>, count: WritableKeyPath<PostView, Int?>,
        update: @escaping @MainActor (PostView) -> Void,
        perform: (MastodonClient, Bool) async throws -> Void
    ) async {
        guard let client = mastodonActor(for: accountDID) else { return }
        let turnOn = post.viewer?[keyPath: keyPath] == nil
        var changed = post
        var viewer = post.viewer ?? PostViewer()
        viewer[keyPath: keyPath] = turnOn ? "set" : nil
        changed.viewer = viewer
        changed[keyPath: count] = max(0, (post[keyPath: count] ?? 0) + (turnOn ? 1 : -1))
        update(changed)
        do {
            try await perform(client, turnOn)
        } catch {
            update(post)
            showToast(error.localizedDescription)
        }
    }

    func toggleFollow(
        _ profile: ProfileDetail, accountDID: String?, update: @escaping @MainActor (ProfileDetail) -> Void
    ) async {
        if MastodonID.isActor(profile.did) {
            guard let client = mastodonActor(for: accountDID) else { return }
            let isFollowing = profile.viewer?.following != nil
            var changed = profile
            var viewer = profile.viewer ?? ProfileViewerState()
            viewer.following = isFollowing ? nil : "pending"
            changed.viewer = viewer
            update(changed)
            do {
                let relationship = try await client.accountAction(profile.did, isFollowing ? "unfollow" : "follow")
                viewer.following = relationship.following == true ? "following" : (relationship.requested == true ? "requested" : nil)
                changed.viewer = viewer
                if relationship.following == true, !isFollowing {
                    changed.followersCount = (profile.followersCount ?? 0) + 1
                } else if isFollowing {
                    changed.followersCount = max(0, (profile.followersCount ?? 0) - 1)
                }
                update(changed)
                if relationship.requested == true {
                    showToast(tr("Anfrage gesendet. Diese Person bestätigt Follower selbst.", "Request sent. This person approves followers."))
                }
            } catch {
                update(profile)
                showToast(error.localizedDescription)
            }
            return
        }
        guard let actor = actingAccount(for: accountDID) else { return }
        var changed = profile
        var viewer = profile.viewer ?? ProfileViewerState()
        let existing = viewer.following
        viewer.following = existing == nil ? "pending" : nil
        changed.viewer = viewer
        changed.followersCount = max(0, (profile.followersCount ?? 0) + (existing == nil ? 1 : -1))
        update(changed)
        do {
            if let existing {
                try await actor.client.deleteRecord(uri: existing)
            } else {
                viewer.following = try await actor.client.follow(did: profile.did, repo: actor.did)
                changed.viewer = viewer
                update(changed)
            }
        } catch {
            update(profile)
            showToast(error.localizedDescription)
        }
    }

    func startCompose(
        replyTo: PostView? = nil, quote: PostView? = nil, accountDID: String? = nil, text: String = "",
        visibility: MastodonVisibility? = nil
    ) {
        // A reply or quote goes out on the network of the post it answers.
        let target = replyTo ?? quote
        let fallback = target.map { $0.isMastodon ? accounts.firstMastodon?.did : accounts.firstBluesky?.did }
            ?? accounts.accounts.first?.did
        guard let did = accountDID ?? fallback else {
            showToast(tr("Zum Posten musst du angemeldet sein.", "You need to be signed in to post."))
            isLoggingIn = true
            return
        }
        var context = ComposeContext(replyTo: replyTo, quote: quote, accountDID: did, initialSegments: [text])
        if let replyTo, let parent = replyTo.mastodon?.visibility.flatMap(MastodonVisibility.init(rawValue:)) {
            context.mastodonOptions.visibility = settings.mastodonVisibility.narrowed(to: parent)
            // Answering a content warning keeps it, as Mastodon's own apps do.
            context.mastodonOptions.spoilerText = replyTo.mastodon?.spoilerText ?? ""
        } else {
            context.mastodonOptions.visibility = visibility ?? settings.mastodonVisibility
        }
        compose = context
    }

    /// Sends one post or a whole thread. On failure the result tells how far it got.
    func publish(
        segments: [String], images: [[DraftImage]], video: VideoDraft?, replyRule: ReplyRule, context: ComposeContext
    ) async -> ThreadResult {
        if let mastodon = accounts.mastodon(for: context.accountDID) {
            var first = PostDraft(text: segments.first ?? "", images: images.first ?? [], video: video)
            first.langs = settings.effectivePostLanguage.map { [$0] } ?? []
            first.reply = context.effectiveReply
            first.quote = context.effectiveQuote
            let result = await mastodon.createThread(
                texts: segments, first: first, laterImages: Self.laterImages(images), options: context.mastodonOptions
            )
            reportPublish(result, count: segments.count)
            return result
        }
        guard let did = context.accountDID, let client = accounts.client(for: did) else {
            return ThreadResult(error: XRPCError(status: 401, code: "AuthenticationRequired", message: nil))
        }
        var first = PostDraft(text: segments.first ?? "", images: images.first ?? [], video: video)
        if let language = settings.effectivePostLanguage {
            first.langs = [language]
        }
        first.reply = context.effectiveReply
        first.quote = context.effectiveQuote
        let result = await client.createThread(
            texts: segments, first: first, laterImages: Self.laterImages(images),
            replyRule: replyRule, repo: did
        )
        reportPublish(result, count: segments.count)
        return result
    }

    private func reportPublish(_ result: ThreadResult, count: Int) {
        let segments = Array(repeating: "", count: count)
        if let error = result.error {
            showToast(result.sent > 0
                ? tr("\(result.sent) von \(segments.count) gesendet: \(error.localizedDescription)", "\(result.sent) of \(segments.count) sent: \(error.localizedDescription)")
                : error.localizedDescription)
        } else {
            showToast(result.replyRuleFailed
                ? tr("Gepostet, aber die Antwort-Einschränkung konnte nicht gesetzt werden. Alle können antworten.", "Posted, but the reply limit could not be set. Everyone can reply.")
                : tr("Gepostet.", "Posted."))
        }
    }

    // MARK: Links

    /// Hashtags in post text open as search columns. Mentions are handled by the column, which shows the profile.
    func handleInternalLink(_ url: URL, accountDID: String?) -> Bool {
        guard url.scheme == RichText.internalScheme, url.host == "tag",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value else { return false }
        if accounts.network(of: accountDID) == .mastodon {
            openColumn(kind: .search(query: "#\(value)"), accountDID: accountDID)
            return true
        }
        guard let actor = actingAccount(for: accountDID) else { return true }
        openColumn(kind: .search(query: "#\(value)"), accountDID: actor.did)
        return true
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
