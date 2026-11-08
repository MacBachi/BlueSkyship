import SwiftUI

/// Applies every change right away, so the column behind the popover shows the effect while typing.
struct ColumnFilterEditor: View {
    @Environment(DeckStore.self) private var deck
    let column: Column

    @State private var includeText: String
    @State private var excludeText: String
    @State private var mediaOnly: Bool
    @State private var hideReposts: Bool
    @State private var hideReplies: Bool

    init(column: Column) {
        self.column = column
        let filter = column.filter ?? ColumnFilter()
        _includeText = State(initialValue: filter.includeTerms.joined(separator: ", "))
        _excludeText = State(initialValue: filter.excludeTerms.joined(separator: ", "))
        _mediaOnly = State(initialValue: filter.mediaOnly)
        _hideReposts = State(initialValue: filter.hideReposts)
        _hideReplies = State(initialValue: filter.hideReplies)
    }

    private var currentFilter: ColumnFilter {
        ColumnFilter(
            includeTerms: ColumnFilter.parseTerms(includeText),
            excludeTerms: ColumnFilter.parseTerms(excludeText),
            mediaOnly: mediaOnly,
            hideReposts: hideReposts,
            hideReplies: hideReplies
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Filter für „\(column.kind.title)“", "Filter for “\(column.kind.title)”"))
                .font(.headline)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Nur mit diesen Wörtern", "Only with these words")).font(.callout)
                TextField(tr("Filterwörter, die vorkommen sollen", "Words that must appear"), text: $includeText, prompt: Text("swift, apple"))
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Ausblenden", "Hide")).font(.callout)
                TextField(tr("Filterwörter, die ausgeblendet werden", "Words to hide"), text: $excludeText, prompt: Text("spoiler, @name.bsky.social"))
                    .textFieldStyle(.roundedBorder)
            }
            Text(tr("Mehrere Begriffe mit Komma trennen. Mit @name.bsky.social filterst du nach Autor.", "Separate several terms with commas. Use @name.bsky.social to filter by author."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(tr("Nur Posts mit Bild oder Video", "Only posts with a picture or video"), isOn: $mediaOnly)
                Toggle(tr("Reposts ausblenden", "Hide reposts"), isOn: $hideReposts)
                Toggle(tr("Antworten ausblenden", "Hide replies"), isOn: $hideReplies)
            }

            HStack {
                Text(tr("Gilt nur in dieser App.", "Applies in this app only."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("Zurücksetzen", "Reset"), action: reset)
                    .disabled(!currentFilter.isActive)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onChange(of: currentFilter) { _, filter in
            deck.setFilter(filter, for: column.id)
        }
    }

    private func reset() {
        includeText = ""
        excludeText = ""
        mediaOnly = false
        hideReposts = false
        hideReplies = false
    }
}
