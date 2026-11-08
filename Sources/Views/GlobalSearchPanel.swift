import SwiftUI

/// Search across all of Bluesky. The result shows next to the deck, like a favorite, and only stays if asked to.
struct GlobalSearchPanel: View {
    @Environment(DeckStore.self) private var deck
    @FocusState private var isFocused: Bool
    @State private var input = ""

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Bluesky durchsuchen", "Search Bluesky")).font(.headline)
                Spacer()
                Button {
                    deck.closeGlobalSearch()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(tr("Suche schließen", "Close search"))
            }
            TextField(tr("Suchbegriff", "Search term"), text: $input, prompt: Text(tr("Begriff, #tag oder @name", "Term, #tag or @name")))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { deck.searchBluesky(for: trimmed) }
                .onExitCommand { deck.closeGlobalSearch() }
            Text(tr("↩ sucht in Posts. Personen erscheinen beim Tippen.", "↩ searches posts. People appear as you type."))
                .font(.caption)
                .foregroundStyle(.secondary)
            PersonSuggestions(term: trimmed) { person in
                deck.showResult(
                    kind: .profileTab(actor: person.handle, tab: .replies),
                    title: person.bestName,
                    avatar: person.avatar
                )
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
        .onAppear { isFocused = true }
    }
}
