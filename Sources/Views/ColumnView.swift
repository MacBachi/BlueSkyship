import SwiftUI

/// The icons are smaller than a comfortable click target, so the clickable area is set explicitly.
private struct HeaderIconTarget: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

struct ColumnView: View {
    @Environment(DeckStore.self) private var deck
    let column: Column
    /// Set when this is the temporary view of a favorite rather than a column in the deck.
    var favoritePreview: Favorite?

    @State private var routes: [ColumnRoute] = []
    @State private var isDropTarget = false
    @State private var isEditingFilter = false
    @State private var isSearchOpen = false
    @FocusState private var isSearchFocused: Bool

    private var feed: ColumnFeed { deck.feed(for: column) }
    private var isMessagesColumn: Bool {
        if case .messages = column.kind { return true }
        return false
    }
    private var account: Account? { deck.accounts.accounts.first { $0.did == column.accountDID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let route = routes.last {
                panel(for: route)
            } else {
                if isSearchOpen {
                    searchBar
                    Divider()
                }
                if column.filter != nil {
                    filterStatus
                    Divider()
                }
                timeline
            }
        }
        .frame(width: column.width.points)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTarget ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isDropTarget ? 2 : 1)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            deck.moveColumn(id, onto: column.id)
            return true
        } isTargeted: { isDropTarget = $0 }
        .environment(\.columnAccountDID, column.accountDID)
        .environment(\.showsPostDetails, column.kind.isOwnPosts)
        .environment(\.openReactions, OpenReactionsAction { routes.append(.reactions($0)) })
        .environment(\.openProfile, OpenProfileAction { routes.append(.profile($0)) })
        .environment(\.openRoute, OpenRouteAction { routes.append($0) })
        .environment(\.openURL, OpenURLAction { url in
            if let did = RichText.mentionedDID(in: url) {
                routes.append(.profile(did))
                return .handled
            }
            return deck.handleInternalLink(url, accountDID: column.accountDID) ? .handled : .systemAction
        })
        .onChange(of: deck.columnSearchRequest) { _, request in
            if request?.columnID == column.id { openSearch() }
        }
        .task(id: feed.searchTerm) {
            // Waits for a typing pause, so not every keystroke fetches more pages.
            guard feed.isSearching else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let client = deck.readClient(for: column) else { return }
            await feed.fillIfNeeded(using: client, kind: column.kind)
        }
        .onChange(of: deck.columnRequest) { _, request in
            guard let request, request.columnID == column.id else { return }
            switch request.action {
            case .push(let route): routes.append(route)
            case .back: if !routes.isEmpty { routes.removeLast() }
            }
        }
        // Restarts on account change and on "refresh all", and stops when the column is removed.
        .task(id: "\(column.accountDID ?? "public")#\(deck.refreshGeneration)#\(deck.settings.refreshSeconds)") {
            await autoRefreshLoop()
        }
        // Waits for a typing pause, so not every keystroke fetches more pages.
        .task(id: column.filter) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let client = deck.readClient(for: column) else { return }
            await feed.fillIfNeeded(using: client, kind: column.kind)
        }
    }

    @ViewBuilder
    private func panel(for route: ColumnRoute) -> some View {
        switch route {
        case .thread(let post):
            ThreadPanel(
                root: post,
                accountDID: column.accountDID,
                onBack: { routes.removeLast() },
                onOpenThread: { routes.append(.thread($0)) }
            )
            .id(route)
        case .reactions(let post):
            ReactionsPanel(
                post: post,
                accountDID: column.accountDID,
                onBack: { routes.removeLast() },
                onOpenThread: { routes.append(.thread($0)) }
            )
            .id(route)
        case .conversation(let conversation, let accountDID):
            ConversationPanel(
                conversation: conversation,
                accountDID: accountDID,
                onBack: { routes.removeLast() }
            )
            .id(route)
        case .people(let actor, let list):
            PeoplePanel(actor: actor, list: list, accountDID: column.accountDID, onBack: { routes.removeLast() })
                .id(route)
        case .profile(let actor):
            ProfilePanel(
                actor: actor,
                accountDID: column.accountDID,
                onBack: { routes.removeLast() },
                onOpenThread: { routes.append(.thread($0)) }
            )
            .id(route)
        }
    }

    private func autoRefreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            // Jitter keeps columns from hitting the API in lockstep.
            let interval = deck.settings.refreshSeconds
            guard interval > 0 else { return }
            let delay = Double(interval) + Double.random(in: 0...10)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        guard let client = deck.readClient(for: column) else { return }
        await feed.refresh(using: client, kind: column.kind)
        await feed.fillIfNeeded(using: client, kind: column.kind)
    }

    private func openSearch() {
        routes = []
        isSearchOpen = true
        isSearchFocused = true
    }

    private func closeSearch() {
        isSearchOpen = false
        feed.searchTerm = ""
    }

    private var searchBar: some View {
        @Bindable var feed = feed
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tr("In dieser Spalte suchen", "Search this column"), text: $feed.searchTerm)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onExitCommand { closeSearch() }
            if feed.isSearching {
                Text(tr("\(feed.visibleItems.count) Treffer", "\(feed.visibleItems.count) found"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if feed.isLoadingMore {
                ProgressView().controlSize(.small)
            }
            Button(action: closeSearch) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(tr("Suche schließen", "Close search"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var filterStatus: some View {
        Button {
            isEditingFilter = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(tr("Filter aktiv: \(feed.hiddenCount) von \(feed.items.count) ausgeblendet", "Filter on: \(feed.hiddenCount) of \(feed.items.count) hidden"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Filter bearbeiten", "Edit Filter"))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Image(systemName: column.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.trailing, 6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(column.kind.title)
                        .font(.headline)
                        .lineLimit(1)
                    if case .notifications = column.kind, let did = column.accountDID,
                       let unread = deck.unreadCounts[did], unread > 0 {
                        Text(unread, format: .number)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                if let account {
                    Text("@\(account.handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if feed.isRefreshing {
                ProgressView().controlSize(.small)
            }
            if !isMessagesColumn {
                Button {
                    if isSearchOpen { closeSearch() } else { openSearch() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .modifier(HeaderIconTarget())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSearchOpen ? Color.accentColor : Color.secondary)
                .help(tr("In dieser Spalte suchen (⌘F)", "Search this column (⌘F)"))
                .accessibilityLabel(tr("In dieser Spalte suchen", "Search this column"))
            }
            if favoritePreview == nil, !isMessagesColumn {
                Button {
                    isEditingFilter.toggle()
                } label: {
                    Image(systemName: column.filter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                        .modifier(HeaderIconTarget())
                }
                .buttonStyle(.plain)
                .foregroundStyle(column.filter == nil ? Color.secondary : Color.accentColor)
                .help(tr("Spalte filtern", "Filter column"))
                .accessibilityLabel(column.filter == nil ? tr("Spalte filtern", "Filter column") : tr("Filter bearbeiten, Filter aktiv", "Edit filter, filter is on"))
                .popover(isPresented: $isEditingFilter, arrowEdge: .bottom) {
                    ColumnFilterEditor(column: column)
                }
            }
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .modifier(HeaderIconTarget())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("Aktualisieren", "Refresh"))
            .accessibilityLabel(tr("Aktualisieren", "Refresh"))
            if let favoritePreview {
                Button {
                    if deck.isFavorite(favoritePreview.kind) {
                        deck.removeFavorite(kind: favoritePreview.kind)
                    } else {
                        deck.addFavorite(
                            kind: favoritePreview.kind, title: favoritePreview.title,
                            avatar: favoritePreview.avatar, accountDID: favoritePreview.accountDID
                        )
                    }
                } label: {
                    Image(systemName: deck.isFavorite(favoritePreview.kind) ? "star.fill" : "star")
                        .modifier(HeaderIconTarget())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("In den Favoriten speichern oder daraus entfernen", "Save to or remove from favorites"))
                .accessibilityLabel(tr("Favorit", "Favorite"))
                Button {
                    deck.pinAsColumn(favoritePreview)
                } label: {
                    Image(systemName: "pin")
                        .modifier(HeaderIconTarget())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("Als Spalte anheften", "Pin as Column"))
                .accessibilityLabel(tr("Als Spalte anheften", "Pin as Column"))
                Button {
                    deck.closeFavoritePreview()
                } label: {
                    Image(systemName: "xmark")
                        .modifier(HeaderIconTarget())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("Schließen", "Close"))
                .accessibilityLabel(tr("Schließen", "Close"))
            } else {
                columnMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .draggable(column.id.uuidString)
        .help(favoritePreview == nil ? tr("Zum Umsortieren ziehen", "Drag to reorder") : "")
    }

    private var columnMenu: some View {
        Menu {
            Picker(tr("Breite", "Width"), selection: Binding(
                get: { column.width },
                set: { deck.setWidth($0, for: column.id) }
            )) {
                ForEach(ColumnWidth.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            if case .notifications = column.kind, let did = column.accountDID {
                Button(tr("Alle als gelesen markieren", "Mark All as Read")) {
                    Task { await deck.markNotificationsRead(accountDID: did) }
                }
                Divider()
            }
            Button(tr("Nach links", "Move Left")) { deck.moveColumn(column.id, by: -1) }
            Button(tr("Nach rechts", "Move Right")) { deck.moveColumn(column.id, by: 1) }
            Divider()
            Button(tr("In Favoriten verschieben", "Move to Favorites")) { deck.moveColumnToFavorites(column) }
            if deck.isFavorite(column.kind) {
                Button(tr("Aus Favoriten entfernen", "Remove from Favorites")) { deck.removeFavorite(kind: column.kind) }
            } else {
                Button(tr("Zu Favoriten hinzufügen", "Add to Favorites")) {
                    deck.addFavorite(kind: column.kind, title: column.kind.title, accountDID: column.accountDID)
                }
            }
            Divider()
            Button(tr("Spalte entfernen", "Remove Column"), role: .destructive) { deck.removeColumn(column.id) }
        } label: {
            Image(systemName: "ellipsis")
                .modifier(HeaderIconTarget())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityLabel(tr("Spaltenmenü", "Column menu"))
    }

    // MARK: Timeline

    @ViewBuilder
    private var timeline: some View {
        @Bindable var feed = feed
        if deck.readClient(for: column) == nil {
            ContentUnavailableView {
                Label(tr("Nicht angemeldet", "Not signed in"), systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(tr("Diese Spalte braucht ein Konto.", "This column needs an account."))
            } actions: {
                Button(tr("Anmelden", "Sign In")) { deck.isLoggingIn = true }
            }
            .frame(maxHeight: .infinity)
        } else if case .messages = column.kind {
            ConversationsPanel(accountDID: column.accountDID ?? "") {
                routes.append(.conversation($0, accountDID: column.accountDID ?? ""))
            }
        } else if feed.visibleItems.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(feed.visibleItems) { item in
                            row(for: item)
                                .background(deck.keyboardFocus == KeyboardFocus(columnID: column.id, itemID: item.id) ? Color.accentColor.opacity(0.12) : Color.clear)
                                .id(item.id)
                                .onAppear {
                                    if item.id == feed.visibleItems.last?.id {
                                        Task {
                                            guard let client = deck.readClient(for: column) else { return }
                                            await feed.loadMore(using: client, kind: column.kind)
                                        }
                                    }
                                }
                            Divider()
                        }
                        if feed.isLoadingMore {
                            ProgressView().controlSize(.small).padding()
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $feed.anchorID, anchor: .top)
                .onChange(of: deck.keyboardFocus) { _, focus in
                    guard let focus, focus.columnID == column.id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(focus.itemID, anchor: .center) }
                }
                .overlay(alignment: .top) {
                    if !feed.visiblePending.isEmpty {
                        Button {
                            let top = feed.showPending()
                            withAnimation { proxy.scrollTo(top, anchor: .top) }
                        } label: {
                            Label(tr("\(feed.visiblePending.count) neu", "\(feed.visiblePending.count) new"), systemImage: "arrow.up")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                        .shadow(radius: 3, y: 1)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let message = feed.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if feed.hiddenCount > 0 {
                ContentUnavailableView {
                    Label(tr("Keine Treffer", "No matches"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(feed.isSearching
                        ? tr("In den \(feed.items.count) geladenen Einträgen kommt das nicht vor.", "Not found in the \(feed.items.count) loaded items.")
                        : tr("Der Filter blendet alle \(feed.hiddenCount) geladenen Einträge aus.", "The filter hides all \(feed.hiddenCount) loaded items."))
                } actions: {
                    if feed.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else if feed.hasMore {
                        Button(tr("Weiter suchen", "Keep Searching")) {
                            Task {
                                guard let client = deck.readClient(for: column) else { return }
                                await feed.loadMore(using: client, kind: column.kind)
                            }
                        }
                    }
                    if !feed.isSearching {
                        Button(tr("Filter bearbeiten", "Edit Filter")) { isEditingFilter = true }
                    }
                }
            } else if let message = feed.errorMessage {
                ContentUnavailableView {
                    Label(tr("Laden fehlgeschlagen", "Loading failed"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(tr("Erneut versuchen", "Try Again")) { Task { await refresh() } }
                }
            } else if feed.isRefreshing {
                ProgressView()
            } else {
                Text(tr("Keine Einträge", "No items")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for item: ColumnItem) -> some View {
        switch item {
        case .post(let entry):
            PostRow(
                post: entry.post,
                repostedBy: entry.reason?.by,
                replyingTo: entry.reply?.parentAuthor,
                accountDID: column.accountDID,
                onUpdate: { feed.replace(post: $0) },
                onOpenThread: { routes.append(.thread($0)) }
            )
        case .notification(let notification):
            NotificationRow(
                item: notification,
                accountDID: column.accountDID,
                onUpdate: { feed.replace(post: $0) },
                onOpenThread: { routes.append(.thread($0)) }
            )
        }
    }
}
