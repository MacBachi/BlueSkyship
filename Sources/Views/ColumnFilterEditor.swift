import SwiftUI

/// The rules of one filter, as text fields and switches. Used for a column's own filter and for saved filters.
struct FilterFields: View {
    @Binding var filter: ColumnFilter

    @State private var includeText = ""
    @State private var excludeText = ""
    @State private var alwaysText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field(
                tr("Immer ausblenden", "Always hide"),
                text: $excludeText,
                prompt: "spoiler, werbung, @name.bsky.social"
            )
            field(
                tr("Immer zeigen", "Always show"),
                text: $alwaysText,
                prompt: "apple, swift",
                note: tr("Schlägt alles andere, auch „Immer ausblenden“.", "Beats everything else, including “Always hide”.")
            )
            field(
                tr("Nur mit diesen Wörtern", "Only with these words"),
                text: $includeText,
                prompt: "swift, apple"
            )
            Text(tr("Mehrere Begriffe mit Komma trennen. Ganze Wörter zählen, Groß- und Kleinschreibung nicht. Mit @name filterst du nach Autor.", "Separate several terms with commas. Whole words count, case does not. Use @name to filter by author."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(tr("Nur Einträge mit Bild oder Video", "Only items with a picture or video"), isOn: $filter.mediaOnly)
                Toggle(tr("Reposts ausblenden", "Hide reposts"), isOn: $filter.hideReposts)
                Toggle(tr("Antworten ausblenden", "Hide replies"), isOn: $filter.hideReplies)
            }
        }
        .onAppear {
            includeText = filter.includeTerms.joined(separator: ", ")
            excludeText = filter.excludeTerms.joined(separator: ", ")
            alwaysText = filter.alwaysShowTerms.joined(separator: ", ")
        }
        .onChange(of: includeText) { _, text in filter.includeTerms = ColumnFilter.parseTerms(text) }
        .onChange(of: excludeText) { _, text in filter.excludeTerms = ColumnFilter.parseTerms(text) }
        .onChange(of: alwaysText) { _, text in filter.alwaysShowTerms = ColumnFilter.parseTerms(text) }
        .onChange(of: filter) { _, new in
            // A reset from outside empties the fields too.
            if !new.isActive {
                includeText = ""
                excludeText = ""
                alwaysText = ""
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Applies every change right away, so the column behind the popover shows the effect while typing.
struct ColumnFilterEditor: View {
    @Environment(DeckStore.self) private var deck
    let column: Column

    @State private var filter: ColumnFilter
    @State private var isNamingPreset = false
    @State private var presetName = ""

    init(column: Column) {
        self.column = column
        _filter = State(initialValue: column.filter ?? ColumnFilter())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Filter für „\(column.kind.title)“", "Filter for “\(column.kind.title)”"))
                .font(.headline)
                .lineLimit(1)

            FilterFields(filter: $filter)

            if !deck.filterPresets.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Gespeicherte Filter", "Saved filters")).font(.callout)
                    ForEach(deck.filterPresets) { preset in
                        Toggle(preset.name, isOn: Binding(
                            get: { deck.isUsing(preset, in: column.id) },
                            set: { deck.setPreset(preset, used: $0, in: column.id) }
                        ))
                    }
                }
            }

            Divider()
            if isNamingPreset {
                HStack {
                    TextField(tr("Name", "Name"), text: $presetName, prompt: Text(tr("z. B. Ohne Sport", "e.g. No sports")))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreset)
                    Button(tr("Sichern", "Save"), action: savePreset)
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack {
                Button(tr("Als Filter speichern …", "Save as Filter…")) {
                    isNamingPreset = true
                }
                .disabled(!filter.isActive || isNamingPreset)
                .help(tr("Speichert diese Regeln unter einem Namen, damit andere Spalten sie mitbenutzen.", "Saves these rules under a name, so other columns can use them too."))
                Spacer()
                Button(tr("Zurücksetzen", "Reset")) { filter = ColumnFilter() }
                    .disabled(!filter.isActive)
            }
            Text(tr("Gilt nur in dieser App.", "Applies in this app only."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
        .onChange(of: filter) { _, filter in
            deck.setFilter(filter, for: column.id)
        }
    }

    /// The rules move into the saved filter, which this column then uses instead of its own copy.
    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = deck.savePreset(name: name, filter: filter)
        deck.setPreset(preset, used: true, in: column.id)
        filter = ColumnFilter()
        presetName = ""
        isNamingPreset = false
    }
}
