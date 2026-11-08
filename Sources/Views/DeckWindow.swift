import SwiftUI

struct DeckWindow: View {
    @Environment(DeckStore.self) private var deck

    var body: some View {
        @Bindable var deck = deck
        HStack(spacing: 0) {
            NavigationRail()
            Divider()
            if let context = deck.compose {
                ComposerPanel(context: context)
                    .id(context.sessionID)
                    .frame(width: 320)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            if deck.isShowingGlobalSearch {
                GlobalSearchPanel()
                    .frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            if deck.isShowingFavorites {
                FavoritesPanel()
                    .frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            if let column = deck.previewColumn, let favorite = deck.previewedFavorite {
                ColumnView(column: column, favoritePreview: favorite)
                    .id(favorite.id)
                    .padding(8)
                Divider()
            }
            DeckColumns()
        }
        .animation(.snappy(duration: 0.2), value: deck.compose != nil)
        .animation(.snappy(duration: 0.2), value: deck.isShowingFavorites)
        .animation(.snappy(duration: 0.2), value: deck.isShowingGlobalSearch)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            if let toast = deck.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: deck.toast)
        .overlay {
            if let media = deck.media {
                MediaViewer(media: media)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: deck.media != nil)
        .sheet(isPresented: $deck.isAddingColumn) { AddColumnSheet() }
        .sheet(isPresented: $deck.isLoggingIn) { LoginSheet() }
        .sheet(isPresented: $deck.isShowingScheduled) { ScheduledSheet() }
        .confirmationDialog(
            deck.confirmation?.title ?? "",
            isPresented: Binding(get: { deck.confirmation != nil }, set: { if !$0 { deck.confirmation = nil } }),
            titleVisibility: .visible,
            presenting: deck.confirmation
        ) { confirmation in
            Button(confirmation.actionLabel, role: .destructive) {
                Task { await deck.perform(confirmation) }
            }
            Button(tr("Abbrechen", "Cancel"), role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .onAppear { KeyboardController.shared.install(deck: deck) }
        .task { await deck.runBackgroundLoop() }
    }
}

private let deckViewportSpace = "deckViewport"

private struct DeckColumns: View {
    @Environment(DeckStore.self) private var deck

    /// Column positions change on every scroll tick. Kept outside view state so scrolling
    /// only redraws when the set of hidden columns really changes.
    private final class Layout {
        var frames: [UUID: CGRect] = [:]
        var viewportWidth: CGFloat = 0
    }

    @State private var layout = Layout()
    @State private var overflow = DeckOverflow()


    var body: some View {
        if deck.columns.isEmpty {
            ContentUnavailableView {
                Label(tr("Noch keine Spalten", "No columns yet"), systemImage: "rectangle.split.3x1")
            } actions: {
                Button(tr("Spalte hinzufügen", "Add Column")) { deck.isAddingColumn = true }
            }
            // Without this the window centers its content and shows empty areas at both sides.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(deck.columns) { column in
                                ColumnView(column: column)
                                    .id(column.id)
                                    .onGeometryChange(for: CGRect.self) {
                                        $0.frame(in: .named(deckViewportSpace))
                                    } action: { frame in
                                        layout.frames[column.id] = frame
                                        updateOverflow()
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .coordinateSpace(.named(deckViewportSpace))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        layout.viewportWidth = width
                        updateOverflow()
                    }

                    if !overflow.isEmpty {
                        Divider()
                        OverflowBar(overflow: overflow) { column, anchor in
                            withAnimation { proxy.scrollTo(column.id, anchor: anchor) }
                        }
                    }
                }
                .onChange(of: deck.revealColumnID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .trailing) }
                    deck.revealColumnID = nil
                }
                .onChange(of: deck.columns) { _, columns in
                    let ids = Set(columns.map(\.id))
                    layout.frames = layout.frames.filter { ids.contains($0.key) }
                    updateOverflow()
                }
            }
        }
    }

    private func updateOverflow() {
        let updated = DeckOverflow.compute(
            columns: deck.columns, frames: layout.frames, viewportWidth: layout.viewportWidth
        )
        if updated != overflow { overflow = updated }
    }
}

/// Appears only when columns are out of view: how many on each side, what they are called, and a click to go there.
private struct OverflowBar: View {
    let overflow: DeckOverflow
    let reveal: (Column, UnitPoint) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if !overflow.left.isEmpty {
                sideLabel(tr("\(overflow.left.count) links", "\(overflow.left.count) left"), systemImage: "chevron.left")
                chips(overflow.left, anchor: .leading)
            }
            Spacer(minLength: 0)
            if !overflow.right.isEmpty {
                chips(overflow.right, anchor: .trailing)
                sideLabel(tr("\(overflow.right.count) rechts", "\(overflow.right.count) right"), systemImage: "chevron.right", iconTrailing: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func sideLabel(_ text: String, systemImage: String, iconTrailing: Bool = false) -> some View {
        HStack(spacing: 3) {
            if !iconTrailing { Image(systemName: systemImage) }
            Text(text)
            if iconTrailing { Image(systemName: systemImage) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// Uses only the room it needs, and scrolls by itself when the names do not fit.
    private func chips(_ columns: [Column], anchor: UnitPoint) -> some View {
        ViewThatFits(in: .horizontal) {
            chipRow(columns, anchor: anchor)
            ScrollView(.horizontal, showsIndicators: false) {
                chipRow(columns, anchor: anchor)
            }
        }
    }

    private func chipRow(_ columns: [Column], anchor: UnitPoint) -> some View {
        HStack(spacing: 4) {
            ForEach(columns) { column in
                Button {
                    reveal(column, anchor)
                } label: {
                    Label(column.kind.title, systemImage: column.kind.systemImage)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 170)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tr("Zu „\(column.kind.title)“ springen", "Jump to “\(column.kind.title)”"))
            }
        }
    }
}

private struct NavigationRail: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 6) {
            railButton(tr("Neuer Post (⌘N)", "New post (⌘N)"), systemImage: "square.and.pencil") {
                if deck.compose != nil {
                    deck.compose = nil
                } else {
                    deck.startCompose()
                }
            }
            railButton(tr("Bluesky durchsuchen (⌘⇧F)", "Search Bluesky (⌘⇧F)"), systemImage: "magnifyingglass") {
                if deck.isShowingGlobalSearch {
                    deck.closeGlobalSearch()
                } else {
                    deck.isShowingGlobalSearch = true
                }
            }
            railButton(tr("Spalte hinzufügen (⌘T)", "Add column (⌘T)"), systemImage: "plus.rectangle.on.rectangle") {
                deck.isAddingColumn = true
            }
            railButton(tr("Favoriten (⌘D)", "Favorites (⌘D)"), systemImage: deck.isShowingFavorites ? "star.fill" : "star") {
                deck.isShowingFavorites.toggle()
            }
            railButton(tr("Alle aktualisieren (⌘R)", "Refresh all (⌘R)"), systemImage: "arrow.clockwise") {
                deck.refreshAll()
            }
            DeckSwitcher()
            if !deck.scheduledPosts.isEmpty {
                railButton(tr("Geplante Posts (\(deck.scheduledPosts.count))", "Scheduled posts (\(deck.scheduledPosts.count))"), systemImage: "calendar.badge.clock") {
                    deck.isShowingScheduled = true
                }
            }
            Spacer()
            ForEach(deck.accounts.accounts) { account in
                Menu {
                    Text("@\(account.handle)")
                    Button(tr("Meine Posts anzeigen", "Show My Posts")) {
                        deck.openColumn(kind: .ownPosts(actor: account.did), accountDID: account.did)
                    }
                    Button(tr("Meine Likes anzeigen", "Show My Likes")) {
                        deck.openColumn(kind: .likes(actor: account.did), accountDID: account.did)
                    }
                    Button(tr("Lesezeichen anzeigen", "Show Bookmarks")) {
                        deck.openColumn(kind: .bookmarks, accountDID: account.did)
                    }
                    Button(tr("Direktnachrichten anzeigen", "Show Direct Messages")) {
                        deck.openColumn(kind: .messages, accountDID: account.did)
                    }
                    Button(tr("Neuer Post mit diesem Konto", "New Post with This Account")) { deck.startCompose(accountDID: account.did) }
                    Divider()
                    Button(tr("Abmelden", "Sign Out"), role: .destructive) {
                        Task { await deck.logout(did: account.did) }
                    }
                } label: {
                    Avatar(url: account.avatarURL, size: 32)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("@\(account.handle)")
            }
            railButton(tr("Konto hinzufügen", "Add account"), systemImage: "person.crop.circle.badge.plus") {
                deck.isLoggingIn = true
            }
            railButton(tr("Hilfe (⌘?)", "Help (⌘?)"), systemImage: "questionmark.circle") {
                openWindow(id: HelpView.windowID)
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("Einstellungen (⌘,)", "Settings (⌘,)"))
            .accessibilityLabel(tr("Einstellungen", "Settings"))
        }
        .padding(.vertical, 12)
        .frame(width: 52)
    }

    private func railButton(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Switches between named sets of columns.
private struct DeckSwitcher: View {
    @Environment(DeckStore.self) private var deck

    private enum NameRequest {
        case new, rename
    }

    @State private var nameRequest: NameRequest?
    @State private var name = ""

    var body: some View {
        Menu {
            ForEach(deck.decks) { page in
                Toggle(page.name, isOn: Binding(
                    get: { page.id == deck.activeDeckID },
                    set: { if $0 { deck.switchDeck(page.id) } }
                ))
            }
            Divider()
            Button(tr("Neues Deck …", "New Deck…")) {
                name = ""
                nameRequest = .new
            }
            Button(tr("Deck umbenennen …", "Rename Deck…")) {
                name = deck.activeDeck?.name ?? ""
                nameRequest = .rename
            }
            if deck.decks.count > 1, let active = deck.activeDeck {
                Button(tr("Deck löschen …", "Delete Deck…"), role: .destructive) {
                    deck.confirmation = .deleteDeck(active)
                }
            }
        } label: {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .help(tr("Deck: \(deck.activeDeck?.name ?? "")", "Deck: \(deck.activeDeck?.name ?? "")"))
        .accessibilityLabel(tr("Deck wechseln", "Switch deck"))
        .alert(
            nameRequest == .rename ? tr("Deck umbenennen", "Rename Deck") : tr("Neues Deck", "New Deck"),
            isPresented: Binding(get: { nameRequest != nil }, set: { if !$0 { nameRequest = nil } })
        ) {
            TextField(tr("Name", "Name"), text: $name)
            Button(tr("Abbrechen", "Cancel"), role: .cancel) {}
            Button(tr("Sichern", "Save")) {
                if nameRequest == .rename {
                    deck.renameDeck(deck.activeDeckID, to: name)
                } else {
                    deck.addDeck(name: name)
                }
            }
        }
    }
}
