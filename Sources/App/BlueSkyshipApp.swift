import SwiftUI

@main
struct BlueSkyshipApp: App {
    @State private var deck = DeckStore()
    private let localizer = Localizer.shared

    var body: some Scene {
        Window("BlueSkyship", id: "main") {
            DeckWindow()
                .environment(deck)
                .environment(\.locale, localizer.locale)
                // Fixed ideal size: the deck's own, arbitrarily large ideal size must never drive the window.
                .frame(
                    minWidth: 720, idealWidth: 1440, maxWidth: .infinity,
                    minHeight: 480, idealHeight: 900, maxHeight: .infinity
                )
        }
        .defaultSize(width: 1440, height: 900)
        // By default a Window follows its content's size, which would grow it with every column.
        .windowResizability(.contentMinSize)
        .commands { DeckCommands(deck: deck) }

        Window("Help", id: HelpView.windowID) {
            HelpView()
                .environment(deck)
                .environment(\.locale, localizer.locale)
                .frame(minWidth: 640, idealWidth: 860, minHeight: 440, idealHeight: 640)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(deck)
                .environment(\.locale, localizer.locale)
        }
    }
}

private struct DeckCommands: Commands {
    let deck: DeckStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("Neuer Post", "New Post")) { deck.startCompose() }
                .keyboardShortcut("n")
            Button(tr("Spalte hinzufügen …", "Add Column…")) { deck.isAddingColumn = true }
                .keyboardShortcut("t")
            Button(tr("Favoriten ein- oder ausblenden", "Show or Hide Favorites")) {
                deck.isShowingFavorites.toggle()
            }
            .keyboardShortcut("d")
            Divider()
            Button(tr("Alle Spalten aktualisieren", "Refresh All Columns")) { deck.refreshAll() }
                .keyboardShortcut("r")
        }
        CommandMenu("Deck") {
            ForEach(Array(deck.decks.prefix(9).enumerated()), id: \.element.id) { index, page in
                Button(page.name) { deck.switchDeck(page.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
        CommandGroup(replacing: .help) {
            Button(tr("BlueSkyship-Hilfe", "BlueSkyship Help")) { openWindow(id: HelpView.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
