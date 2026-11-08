import AppKit
import Foundation
import UserNotifications

// MARK: - Posts and people

extension DeckStore {
    func isOwnPost(_ post: PostView) -> Bool {
        accounts.accounts.contains { $0.did == post.author.did }
    }

    func isOwnAccount(did: String) -> Bool {
        accounts.accounts.contains { $0.did == did }
    }

    func perform(_ confirmation: DeckConfirmation) async {
        do {
            switch confirmation {
            case .deletePost(let post):
                guard let client = accounts.client(for: post.author.did) else { return }
                try await client.deleteRecord(uri: post.uri)
                hiddenPostURIs.insert(post.uri)
                for feed in feeds.values {
                    feed.remove { $0.displayedPost?.uri == post.uri }
                }
                showToast(tr("Post gelöscht.", "Post deleted."))
            case .mute(let person, let accountDID):
                guard let actor = actingAccount(for: accountDID) else { return }
                try await actor.client.mute(actor: person.did)
                hideAuthor(person.did)
                showToast(tr("\(person.bestName) ist stummgeschaltet.", "\(person.bestName) is muted."))
            case .block(let person, let accountDID):
                guard let actor = actingAccount(for: accountDID) else { return }
                _ = try await actor.client.block(did: person.did, repo: actor.did)
                hideAuthor(person.did)
                showToast(tr("\(person.bestName) ist blockiert.", "\(person.bestName) is blocked."))
            case .deleteDeck(let page):
                deleteDeck(page.id)
            case .openLink(let url, _):
                if LinkPolicy.isWebURL(url), !RuntimeEnvironment.isUnitTestHost {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            moderationGeneration += 1
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func hideAuthor(_ did: String) {
        hiddenAuthorDIDs.insert(did)
        for feed in feeds.values {
            feed.remove { $0.displayedPost?.author.did == did }
        }
    }

    func unmute(_ profile: ProfileDetail, accountDID: String?) async {
        guard let actor = actingAccount(for: accountDID) else { return }
        do {
            try await actor.client.unmute(actor: profile.did)
            hiddenAuthorDIDs.remove(profile.did)
            moderationGeneration += 1
            refreshAll()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func unblock(_ profile: ProfileDetail, accountDID: String?) async {
        guard let actor = actingAccount(for: accountDID), let uri = profile.viewer?.blocking else { return }
        do {
            try await actor.client.deleteRecord(uri: uri)
            hiddenAuthorDIDs.remove(profile.did)
            moderationGeneration += 1
            refreshAll()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func toggleBookmark(_ post: PostView, accountDID: String?, update: @escaping @MainActor (PostView) -> Void) async {
        guard let actor = actingAccount(for: accountDID) else { return }
        var changed = post
        var viewer = post.viewer ?? PostViewer()
        let wasBookmarked = viewer.bookmarked == true
        viewer.bookmarked = !wasBookmarked
        changed.viewer = viewer
        update(changed)
        do {
            if wasBookmarked {
                try await actor.client.removeBookmark(uri: post.uri)
            } else {
                try await actor.client.addBookmark(post.ref)
            }
            showToast(wasBookmarked
                ? tr("Lesezeichen entfernt.", "Bookmark removed.")
                : tr("Lesezeichen gespeichert.", "Bookmark saved."))
        } catch {
            update(post)
            showToast(error.localizedDescription)
        }
    }
}

// MARK: - Drafts

extension DeckStore {
    /// Called on every change in the composer. An empty draft is not worth keeping.
    func saveDraft(id: UUID, segments: [String], context: ComposeContext) {
        let isEmpty = segments.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !isEmpty else {
            removeDraft(id)
            return
        }
        let draft = SavedDraft(
            id: id, segments: segments, accountDID: context.accountDID,
            reply: context.effectiveReply, quote: context.effectiveQuote,
            targetLabel: context.targetLabel
        )
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
        saveDrafts()
    }

    func removeDraft(_ id: UUID) {
        removeDraftImages(id)
        guard drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        saveDrafts()
    }

    private static func draftImagesURL(_ id: UUID) -> URL {
        URL.applicationSupportDirectory.appending(path: "draft-images-\(id.uuidString).json")
    }

    /// Pictures can be large, so they live in a file on this Mac rather than in the draft list.
    func saveDraftImages(id: UUID, images: [[DraftImage]]) {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        guard images.contains(where: { !$0.isEmpty }) else {
            removeDraftImages(id)
            return
        }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(images) {
            try? data.write(to: Self.draftImagesURL(id), options: .atomic)
        }
    }

    private func loadDraftImages(_ id: UUID) -> [[DraftImage]] {
        guard let data = try? Data(contentsOf: Self.draftImagesURL(id)) else { return [] }
        return (try? JSONDecoder().decode([[DraftImage]].self, from: data)) ?? []
    }

    private func removeDraftImages(_ id: UUID) {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        try? FileManager.default.removeItem(at: Self.draftImagesURL(id))
    }

    /// The pictures of every post after the first, by position.
    static func laterImages(_ images: [[DraftImage]]) -> [Int: [DraftImage]] {
        var result: [Int: [DraftImage]] = [:]
        for (index, pictures) in images.enumerated().dropFirst() where !pictures.isEmpty {
            result[index] = pictures
        }
        return result
    }

    func open(_ draft: SavedDraft) {
        compose = ComposeContext(
            accountDID: draft.accountDID ?? accounts.accounts.first?.did,
            savedReply: draft.reply,
            savedQuote: draft.quote,
            savedTargetLabel: draft.targetLabel,
            initialSegments: draft.segments,
            initialImages: loadDraftImages(draft.id),
            draftID: draft.id
        )
    }

    func saveDraftsLocally() {
        saveDrafts()
    }

    private func saveDrafts() {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        if let data = try? JSONEncoder().encode(drafts) {
            UserDefaults.standard.set(data, forKey: Self.draftsKey)
        }
        pushToCloud { $0.drafts.push(self.drafts) }
    }
}

// MARK: - Scheduled posts

extension DeckStore {
    private static var scheduledFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "scheduled-posts.json")
    }

    func loadScheduledPosts() {
        guard !RuntimeEnvironment.isUnitTestHost,
              let data = try? Data(contentsOf: Self.scheduledFileURL),
              let stored = try? JSONDecoder().decode([ScheduledPost].self, from: data) else { return }
        scheduledPosts = stored
    }

    private func saveScheduledPosts() {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(scheduledPosts) {
            do {
                try data.write(to: Self.scheduledFileURL, options: .atomic)
            } catch {
                // A plan that silently does not survive a restart would be worse than this message.
                showToast(tr("Geplante Posts konnten nicht gespeichert werden.", "Scheduled posts could not be saved."))
            }
        }
    }

    func schedule(segments: [String], images: [[DraftImage]], context: ComposeContext, date: Date) {
        guard let did = context.accountDID else { return }
        scheduledPosts.append(ScheduledPost(
            date: date, segments: segments, images: images.first ?? [],
            laterImages: Self.laterImages(images), accountDID: did,
            reply: context.effectiveReply, quote: context.effectiveQuote,
            langs: settings.effectivePostLanguage.map { [$0] } ?? [],
            targetLabel: context.targetLabel
        ))
        scheduledPosts.sort { $0.date < $1.date }
        saveScheduledPosts()
        showToast(tr("Geplant. Die App muss zu diesem Zeitpunkt laufen.", "Scheduled. The app must be running at that time."))
    }

    func removeScheduled(_ id: UUID) {
        scheduledPosts.removeAll { $0.id == id }
        saveScheduledPosts()
    }

    /// Sends what is due. The post leaves the list before sending, so a second pass cannot send it twice.
    func sendDueScheduledPosts(now: Date = Date()) async {
        for post in scheduledPosts where post.due(now: now) == .send {
            await send(scheduled: post)
        }
    }

    func send(scheduled post: ScheduledPost) async {
        guard let client = accounts.client(for: post.accountDID) else {
            markFailed(post, message: tr("Das Konto ist nicht mehr angemeldet.", "The account is no longer signed in."))
            return
        }
        scheduledPosts.removeAll { $0.id == post.id }
        saveScheduledPosts()
        var first = PostDraft(text: "", langs: post.langs, reply: post.reply, quote: post.quote, images: post.images)
        first.text = post.segments.first ?? ""
        let result = await client.createThread(
            texts: post.segments, first: first, laterImages: post.laterImages ?? [:], repo: post.accountDID
        )
        if let error = result.error {
            // Only what did not go out comes back, attached to what did.
            var rest = post
            rest.segments = Array(post.segments.dropFirst(result.sent))
            if result.sent > 0 {
                rest.images = []
                rest.quote = nil
                rest.reply = result.continuation
                // Positions move up by what already went out, and the new first post gets its own pictures.
                let shifted = (post.laterImages ?? [:]).reduce(into: [Int: [DraftImage]]()) { pictures, entry in
                    pictures[entry.key - result.sent] = entry.value
                }
                rest.images = shifted[0] ?? []
                rest.laterImages = shifted.filter { $0.key > 0 }
            }
            markFailed(rest, message: error.localizedDescription)
        } else {
            showToast(tr("Geplanter Post gesendet.", "Scheduled post sent."))
            refreshAll()
        }
    }

    private func markFailed(_ post: ScheduledPost, message: String) {
        var failed = post
        failed.lastError = message
        scheduledPosts.removeAll { $0.id == post.id }
        scheduledPosts.append(failed)
        scheduledPosts.sort { $0.date < $1.date }
        saveScheduledPosts()
        showToast(tr("Geplanter Post konnte nicht gesendet werden.", "Scheduled post could not be sent."))
    }
}

// MARK: - Background work

extension DeckStore {
    /// Runs while the deck window exists.
    func runBackgroundLoop() async {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        loadScheduledPosts()
        startCloudSync()
        await accounts.refreshDetails()
        var tick = 0
        while !Task.isCancelled {
            await sendDueScheduledPosts()
            if tick % 2 == 0 { await pollNotifications() }
            // Every half hour, so changes made in the Bluesky app arrive without a restart.
            if tick % 60 == 0 { await loadModerationPrefs() }
            tick += 1
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func pollNotifications() async {
        for account in accounts.accounts {
            guard let client = accounts.client(for: account.did) else { continue }
            if let count = try? await client.unreadNotificationCount() {
                unreadCounts[account.did] = count
            }
            if settings.showSystemNotifications {
                await deliverSystemNotifications(account: account, client: client)
            }
        }
        updateDockBadge()
    }

    var totalUnread: Int { unreadCounts.values.reduce(0, +) }

    func updateDockBadge() {
        let total = totalUnread
        NSApp?.dockTile.badgeLabel = settings.showDockBadge && total > 0 ? String(total) : nil
    }

    func markNotificationsRead(accountDID: String) async {
        guard let client = accounts.client(for: accountDID) else { return }
        do {
            try await client.markNotificationsSeen()
            unreadCounts[accountDID] = 0
            updateDockBadge()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func requestSystemNotificationPermission() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        if !granted {
            settings.showSystemNotifications = false
            showToast(tr("macOS erlaubt keine Hinweise. Du kannst das in den Systemeinstellungen ändern.", "macOS does not allow alerts. You can change that in System Settings."))
        }
    }

    private func deliverSystemNotifications(account: Account, client: XRPCClient) async {
        guard let items = try? await client.latestNotifications(limit: 20) else { return }
        let key = "notifications.mark.\(account.did)"
        let result = NotificationDigest.newItems(items, since: UserDefaults.standard.string(forKey: key))
        if let mark = result.mark { UserDefaults.standard.set(mark, forKey: key) }
        for item in result.new.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = item.author.bestName
            content.body = item.summary
            content.sound = .default
            let request = UNNotificationRequest(identifier: "\(item.uri)|\(item.reason)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Keyboard

extension DeckStore {
    /// Returns false for anything that should keep its normal meaning.
    func handle(_ command: KeyCommand) -> Bool {
        switch command {
        case .next: moveFocus(by: 1)
        case .previous: moveFocus(by: -1)
        case .nextColumn: moveFocusColumn(by: 1)
        case .previousColumn: moveFocusColumn(by: -1)
        case .jumpToColumn(let index):
            guard columns.indices.contains(index) else { return true }
            focusColumn(columns[index])
        case .newPost: startCompose()
        case .addColumn: isAddingColumn = true
        case .open:
            guard let (column, post) = focusedPost() else { return false }
            columnRequest = ColumnNavigationRequest(columnID: column.id, action: .push(.thread(post)))
        case .back:
            guard let column = focusedColumn else { return false }
            columnRequest = ColumnNavigationRequest(columnID: column.id, action: .back)
        case .like:
            guard let (column, post) = focusedPost() else { return true }
            let feed = feed(for: column)
            Task { await toggleLike(post, accountDID: column.accountDID) { feed.replace(post: $0) } }
        case .repost:
            guard let (column, post) = focusedPost() else { return true }
            let feed = feed(for: column)
            Task { await toggleRepost(post, accountDID: column.accountDID) { feed.replace(post: $0) } }
        case .reply:
            guard let (column, post) = focusedPost() else { return true }
            startCompose(replyTo: post, accountDID: column.accountDID)
        case .quote:
            guard let (column, post) = focusedPost() else { return true }
            startCompose(quote: post, accountDID: column.accountDID)
        }
        return true
    }

    private var focusedColumn: Column? {
        columns.first { $0.id == keyboardFocus?.columnID }
    }

    private func focusedPost() -> (Column, PostView)? {
        guard let column = focusedColumn,
              let item = feed(for: column).visibleItems.first(where: { $0.id == keyboardFocus?.itemID }),
              let post = item.displayedPost else { return nil }
        return (column, post)
    }

    private func moveFocus(by offset: Int) {
        guard let column = focusedColumn ?? columns.first else { return }
        let items = feed(for: column).visibleItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == keyboardFocus?.itemID }
        let next = current.map { min(max($0 + offset, 0), items.count - 1) } ?? 0
        keyboardFocus = KeyboardFocus(columnID: column.id, itemID: items[next].id)
    }

    private func moveFocusColumn(by offset: Int) {
        guard !columns.isEmpty else { return }
        let current = columns.firstIndex { $0.id == keyboardFocus?.columnID }
        let next = current.map { min(max($0 + offset, 0), columns.count - 1) } ?? 0
        focusColumn(columns[next])
    }

    private func focusColumn(_ column: Column) {
        revealColumnID = column.id
        if let first = feed(for: column).visibleItems.first {
            keyboardFocus = KeyboardFocus(columnID: column.id, itemID: first.id)
        }
    }
}

// MARK: - Decks and favorite order

extension DeckStore {
    func switchDeck(_ id: UUID) {
        guard decks.contains(where: { $0.id == id }) else { return }
        activeDeckID = id
        keyboardFocus = nil
        saveColumns()
    }

    func addDeck(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = DeckPage(name: trimmed.isEmpty ? "Deck \(decks.count + 1)" : trimmed)
        decks.append(page)
        switchDeck(page.id)
    }

    func renameDeck(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = decks.firstIndex(where: { $0.id == id }) else { return }
        decks[index].name = trimmed
        saveColumns()
    }

    /// The last deck stays: the app always needs one to show.
    func deleteDeck(_ id: UUID) {
        guard decks.count > 1, let index = decks.firstIndex(where: { $0.id == id }) else { return }
        for column in decks[index].columns { feeds[column.id] = nil }
        decks.remove(at: index)
        if activeDeckID == id { activeDeckID = decks[0].id }
        saveColumns()
    }

    /// Moves within its group, because that is the only order the list shows.
    /// Drag and drop: places the favorite where the other one is, if both are in the same group.
    func moveFavorite(_ id: UUID, onto targetID: UUID) {
        guard id != targetID,
              let from = favorites.firstIndex(where: { $0.id == id }),
              let to = favorites.firstIndex(where: { $0.id == targetID }),
              favorites[from].category == favorites[to].category else { return }
        let favorite = favorites.remove(at: from)
        favorites.insert(favorite, at: to)
        saveFavorites()
    }

    func moveFavorite(_ favorite: Favorite, by offset: Int) {
        let group = favorites.indices.filter { favorites[$0].category == favorite.category }
        guard let position = group.firstIndex(where: { favorites[$0].id == favorite.id }) else { return }
        let target = position + offset
        guard group.indices.contains(target) else { return }
        favorites.swapAt(group[position], group[target])
        saveFavorites()
    }
}

// MARK: - Moderation

extension DeckStore {
    /// For a column without an account, the first account's settings apply if there is one.
    func moderationPrefs(for accountDID: String?) -> ModerationPrefs {
        (accountDID ?? accounts.accounts.first?.did).flatMap { moderationByAccount[$0] } ?? ModerationPrefs()
    }

    func moderationDecision(for post: PostView, accountDID: String?) -> ModerationPrefs.Decision {
        moderationPrefs(for: accountDID).decision(for: post, isOwn: isOwnPost(post))
    }

    func loadModerationPrefs() async {
        for account in accounts.accounts {
            guard let client = accounts.client(for: account.did),
                  let prefs = try? await client.moderationPrefs() else { continue }
            moderationByAccount[account.did] = prefs
        }
        for page in decks {
            for column in page.columns {
                feeds[column.id]?.moderation = moderationPrefs(for: column.accountDID)
            }
        }
    }

    /// Opens a chat from a profile. Errors usually mean the app password lacks the chat permission.
    func openConversation(with did: String, accountDID: String?) async -> (Conversation, String)? {
        guard let actor = actingAccount(for: accountDID) else { return nil }
        do {
            return (try await actor.client.conversation(with: did), actor.did)
        } catch {
            showToast(tr("Unterhaltung nicht möglich: \(error.localizedDescription)", "Conversation not possible: \(error.localizedDescription)"))
            return nil
        }
    }
}

// MARK: - iCloud

/// The lists that travel between Macs. Sign-ins and pictures deliberately do not.
@MainActor
struct CloudDocuments {
    let favorites: CloudDocument<Favorite>
    let decks: CloudDocument<DeckPage>
    let drafts: CloudDocument<SavedDraft>

    init(store: CloudStore, defaults: UserDefaults) {
        favorites = CloudDocument(key: "favorites", store: store, defaults: defaults)
        decks = CloudDocument(key: "decks", store: store, defaults: defaults)
        drafts = CloudDocument(key: "drafts", store: store, defaults: defaults)
    }
}

extension DeckStore {
    func startCloudSync() {
        guard !RuntimeEnvironment.isUnitTestHost, cloudDocuments == nil else { return }
        let store = NSUbiquitousKeyValueStore.default
        cloudDocuments = CloudDocuments(store: store, defaults: .standard)
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithCloud() }
        }
        store.synchronize()
        syncWithCloud()
    }

    func pushToCloud(_ push: (CloudDocuments) -> CloudPushOutcome) {
        guard settings.iCloudSync, !isApplyingCloudChange, let cloudDocuments else { return }
        if push(cloudDocuments) == .tooLarge {
            showToast(tr("Zu viele Daten für iCloud. Diese Änderung bleibt auf diesem Mac.", "Too much data for iCloud. This change stays on this Mac."))
        }
    }

    /// Takes over what is newer in iCloud and sends up what is newer here.
    func syncWithCloud() {
        guard settings.iCloudSync, let cloudDocuments else { return }
        apply(cloud: cloudDocuments)
    }

    /// Separate from the store setup, so tests can run it against their own store.
    func apply(cloud documents: CloudDocuments) {
        isApplyingCloudChange = true
        defer { isApplyingCloudChange = false }
        if let items = documents.favorites.reconcile(local: favorites) {
            favorites = items
            if let previewed = previewedFavorite, !items.contains(where: { $0.id == previewed.id }) {
                closeFavoritePreview()
            }
            saveFavorites()
        }
        if let pages = documents.drafts.reconcile(local: drafts) {
            drafts = pages
            saveDraftsLocally()
        }
        if let pages = documents.decks.reconcile(local: decks), !pages.isEmpty {
            decks = pages
            // Which deck is on screen stays a choice of this Mac, as long as that deck still exists.
            if !pages.contains(where: { $0.id == activeDeckID }) { activeDeckID = pages[0].id }
            saveColumns()
        }
    }
}
