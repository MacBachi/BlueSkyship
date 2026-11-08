import SwiftUI

struct FavoritesPanel: View {
    @Environment(DeckStore.self) private var deck

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Favoriten", "Favorites")).font(.headline)
                Spacer()
                Button {
                    deck.isShowingFavorites = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(tr("Favoriten schließen", "Close favorites"))
            }

            HStack(spacing: 6) {
                TextField(tr("Favorit hinzufügen", "Add favorite"), text: $input, prompt: Text(tr("@name, #tag oder Begriff", "@name, #tag or term")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                if isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: add) {
                        Image(systemName: "plus")
                    }
                    .disabled(trimmedInput.isEmpty)
                    .accessibilityLabel(tr("Hinzufügen", "Add"))
                }
            }
            if trimmedInput.hasPrefix("@") {
                PersonSuggestions(term: trimmedInput) { person in
                    deck.toggleFavorite(person: person)
                    input = ""
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if deck.favorites.isEmpty {
                emptyHint
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Favorite.Category.allCases, id: \.self) { category in
                            section(category)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Noch keine Favoriten.", "No favorites yet."))
                .font(.callout.weight(.semibold))
            Text(tr("Favoriten liegen hier griffbereit und belegen keine Spalte. Tippe oben etwas ein, klicke eine Person mit der rechten Maustaste an, oder wähle im Spaltenmenü „In Favoriten verschieben“.", "Favorites stay close at hand without taking up a column. Type something above, right-click a person, or choose “Move to Favorites” in the column menu."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func section(_ category: Favorite.Category) -> some View {
        let items = deck.favorites.filter { $0.category == category }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ favorite: Favorite) -> some View {
        let isSelected = deck.previewedFavorite?.id == favorite.id
        return Button {
            deck.togglePreview(favorite)
        } label: {
            HStack(spacing: 8) {
                if favorite.category == .people {
                    Avatar(url: favorite.avatarURL, size: 22)
                } else {
                    Image(systemName: favorite.kind.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(favorite.displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                    if case .profileTab(let actor, _) = favorite.kind {
                        Text("@\(actor)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .draggable(favorite.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            deck.moveFavorite(id, onto: favorite.id)
            return true
        }
        .contextMenu {
            Button(tr("Als Spalte anheften", "Pin as Column")) { deck.pinAsColumn(favorite) }
            Divider()
            Button(tr("Nach oben", "Move Up")) { deck.moveFavorite(favorite, by: -1) }
            Button(tr("Nach unten", "Move Down")) { deck.moveFavorite(favorite, by: 1) }
            Divider()
            Button(tr("Aus Favoriten entfernen", "Remove from Favorites"), role: .destructive) { deck.removeFavorite(favorite) }
        }
    }

    private func add() {
        guard !trimmedInput.isEmpty, !isAdding else { return }
        isAdding = true
        errorMessage = nil
        Task {
            defer { isAdding = false }
            do {
                try await deck.addFavorite(fromInput: trimmedInput)
                input = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
