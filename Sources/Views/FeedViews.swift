import SwiftUI
import UniformTypeIdentifiers

extension DeckStore {
    /// Finds the feeds behind what someone typed, one address per line, and makes one column of them.
    func rssColumnKind(addresses: String, name: String) async throws -> ColumnKind {
        let lines = addresses
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw URLError(.badURL) }
        let transport = feedTransport
        let found = try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
            for (index, line) in lines.enumerated() {
                group.addTask {
                    do {
                        let result = try await FeedFetcher.discover(line, transport: transport)
                        return (index, result.url, result.feed.title)
                    } catch {
                        throw XRPCError(status: 0, code: nil, message: tr("\(line): \(error.localizedDescription)", "\(line): \(error.localizedDescription)"))
                    }
                }
            }
            var all: [(Int, String, String)] = []
            for try await result in group { all.append(result) }
            return all.sorted { $0.0 < $1.0 }
        }
        var seen = Set<String>()
        let feeds = found.map(\.1).filter { seen.insert($0).inserted }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? (found.first?.2.isEmpty == false ? found[0].2 : "RSS") : typed
        return .rss(feeds: feeds, name: title)
    }

    func updateFeedColumn(_ id: UUID, kind: ColumnKind) {
        for deck in decks.indices {
            guard let index = decks[deck].columns.firstIndex(where: { $0.id == id }) else { continue }
            decks[deck].columns[index].kind = kind
        }
        // The old articles may come from feeds that are gone now.
        feeds[id] = nil
        saveColumns()
    }
}

/// Adding a column from RSS, Feedly or an OPML file, inside the "add column" sheet.
struct FeedSourceForm: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Source: String, CaseIterable, Identifiable {
        case rss, feedly, opml
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rss: return tr("RSS- oder Atom-Feed", "RSS or Atom feed")
            case .feedly: return "Feedly"
            case .opml: return tr("OPML-Datei importieren", "Import OPML file")
            }
        }
    }

    private struct Stream: Hashable, Identifiable {
        let id: String
        let name: String
        let indent: Bool
    }

    @State private var source: Source = .rss
    @State private var addresses = ""
    @State private var name = ""
    @State private var streams: [Stream] = []
    @State private var selectedStream: Stream?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(tr("Quelle", "Source"), selection: $source) {
                ForEach(Source.allCases) { Text($0.label).tag($0) }
            }
            switch source {
            case .rss: rssForm
            case .feedly: feedlyForm
            case .opml: opmlForm
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(tr("Abbrechen", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if source != .opml {
                    Button(tr("Hinzufügen", "Add"), action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !isComplete)
                }
            }
        }
        .onChange(of: source) { _, _ in errorMessage = nil }
        .task(id: "\(source.rawValue)#\(deck.feedly?.userID ?? "")") { await loadStreams() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.xml, UTType(filenameExtension: "opml") ?? .xml]) { result in
            importOPML(result)
        }
    }

    private var rssForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Adressen, eine pro Zeile", "Addresses, one per line")).font(.callout)
            TextEditor(text: $addresses)
                .font(.body.monospaced())
                .frame(height: 80)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)) }
            Text(tr("Die Adresse des Feeds oder einfach der Website: Die App sucht den Feed selbst. Mehrere Feeds landen gemischt in einer Spalte.", "The feed's address, or just the website's: the app finds the feed itself. Several feeds share one column."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(tr("Name der Spalte", "Column name"), text: $name, prompt: Text(tr("Automatisch", "Automatic")))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var feedlyForm: some View {
        if deck.feedly == nil {
            FeedlyConnectForm()
        } else {
            Picker(tr("Inhalt", "Content"), selection: $selectedStream) {
                if streams.isEmpty { Text(tr("Lädt …", "Loading…")).tag(Stream?.none) }
                ForEach(streams) { stream in
                    Text(stream.indent ? "    \(stream.name)" : stream.name).tag(Stream?.some(stream))
                }
            }
        }
    }

    private var opmlForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Jeder Ordner der Datei wird eine Spalte, alle zusammen in einem neuen Deck. Die App liest die Feeds danach selbst, ohne Feedly.", "Every folder in the file becomes a column, all of them in a new deck. Afterwards the app reads the feeds itself, without Feedly."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("Datei wählen …", "Choose File…")) { isImporting = true }
                Button(tr("Bei Feedly exportieren", "Export from Feedly")) { openURL(Feedly.opmlExportURL) }
                    .help(Feedly.opmlExportURL.absoluteString)
            }
        }
    }

    private var isComplete: Bool {
        switch source {
        case .rss: return !addresses.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .feedly: return deck.feedly != nil && selectedStream != nil
        case .opml: return false
        }
    }

    private func loadStreams() async {
        guard source == .feedly, let connection = deck.feedly else { return }
        do {
            let collections = try await FeedlyClient(connection: connection, transport: deck.feedTransport).collections()
            var list = [Stream(id: Feedly.allStreamID(userID: connection.userID), name: tr("Alle Artikel", "All articles"), indent: false)]
            for collection in collections {
                list.append(Stream(id: collection.id, name: collection.label ?? collection.id, indent: false))
                for feed in collection.feeds ?? [] {
                    list.append(Stream(id: feed.id, name: feed.title ?? feed.id, indent: true))
                }
            }
            streams = list
            selectedStream = list.first
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let kind: ColumnKind
                switch source {
                case .rss:
                    kind = try await deck.rssColumnKind(addresses: addresses, name: name)
                case .feedly:
                    guard let selectedStream else { return }
                    kind = .feedly(streamID: selectedStream.id, name: selectedStream.name)
                case .opml:
                    return
                }
                deck.openColumn(kind: kind, accountDID: nil)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importOPML(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let folders = try OPMLParser.parse(data)
            guard !folders.isEmpty else {
                errorMessage = tr("Die Datei enthält keine Feeds.", "The file contains no feeds.")
                return
            }
            deck.importOPML(folders, deckName: url.deletingPathExtension().lastPathComponent)
            let count = folders.reduce(0) { $0 + $1.feeds.count }
            deck.showToast(tr("\(count) Feeds in \(folders.count) Spalten importiert.", "Imported \(count) feeds into \(folders.count) columns."))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The token field for Feedly, in the add-column sheet and in Settings.
struct FeedlyConnectForm: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL

    @State private var token = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Feedly lässt fremde Apps nur mit einem Zugangsschlüssel herein. Den erzeugst du bei Feedly selbst und fügst ihn hier ein. Laut Feedly gibt es ihn nur in bestimmten Abos; ohne Schlüssel geht der OPML-Import immer.", "Feedly only lets other apps in with an access token. You create it at Feedly yourself and paste it here. According to Feedly, only some plans include it; without a token, the OPML import always works."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField(tr("Zugangsschlüssel", "Access token"), text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                Button(tr("Verbinden", "Connect"), action: connect)
                    .disabled(isWorking || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button(tr("Schlüssel bei Feedly holen", "Get a token at Feedly")) { openURL(Feedly.tokenPageURL) }
                    .help(Feedly.tokenPageURL.absoluteString)
                if isWorking { ProgressView().controlSize(.small) }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func connect() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await deck.connectFeedly(token: token)
                token = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Changes which feeds an RSS column reads and what it is called.
struct FeedColumnEditor: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.dismiss) private var dismiss
    let column: Column

    @State private var addresses = ""
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Feeds bearbeiten", "Edit Feeds")).font(.title2.weight(.semibold))
            TextField(tr("Name der Spalte", "Column name"), text: $name)
                .textFieldStyle(.roundedBorder)
            Text(tr("Adressen, eine pro Zeile", "Addresses, one per line")).font(.callout)
            TextEditor(text: $addresses)
                .font(.body.monospaced())
                .frame(height: 160)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)) }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(tr("Abbrechen", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Sichern", "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || addresses.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if case .rss(let feeds, let title) = column.kind {
                addresses = feeds.joined(separator: "\n")
                name = title
            }
        }
    }

    private func save() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let kind = try await deck.rssColumnKind(addresses: addresses, name: name)
                deck.updateFeedColumn(column.id, kind: kind)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Settings → Feeds: Feedly and the saved filters.
struct FeedSettings: View {
    @Environment(DeckStore.self) private var deck
    @State private var editing: FilterPreset?

    var body: some View {
        Form {
            Section("Feedly") {
                if let feedly = deck.feedly {
                    LabeledContent(tr("Verbunden als", "Connected as"), value: feedly.name)
                    Button(tr("Trennen", "Disconnect"), role: .destructive) { deck.disconnectFeedly() }
                } else {
                    FeedlyConnectForm()
                }
            }
            Section(tr("Gespeicherte Filter", "Saved filters")) {
                if deck.filterPresets.isEmpty {
                    Text(tr("Noch keine. Im Filter einer Spalte (Trichter-Symbol) „Als Filter speichern …“ wählen, oder hier einen anlegen.", "None yet. Choose “Save as Filter…” in a column's filter (funnel icon), or create one here."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(deck.filterPresets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(tr("In \(deck.columnCount(using: preset)) Spalten", "In \(deck.columnCount(using: preset)) columns"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("Bearbeiten", "Edit")) { editing = preset }
                        Button(role: .destructive) {
                            deck.deletePreset(preset.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(tr("\(preset.name) löschen", "Delete \(preset.name)"))
                    }
                }
                Button(tr("Neuer Filter …", "New Filter…")) {
                    editing = FilterPreset(name: "", filter: ColumnFilter())
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { preset in
            FilterPresetEditor(preset: preset)
        }
    }
}

struct FilterPresetEditor: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.dismiss) private var dismiss
    @State var preset: FilterPreset

    private var isNew: Bool { !deck.filterPresets.contains { $0.id == preset.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? tr("Neuer Filter", "New Filter") : tr("Filter bearbeiten", "Edit Filter"))
                .font(.title2.weight(.semibold))
            TextField(tr("Name", "Name"), text: $preset.name, prompt: Text(tr("z. B. Ohne Sport", "e.g. No sports")))
                .textFieldStyle(.roundedBorder)
            FilterFields(filter: $preset.filter)
            Text(tr("Änderungen gelten in jeder Spalte, die diesen Filter benutzt.", "Changes apply to every column that uses this filter."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(tr("Abbrechen", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Sichern", "Save")) {
                    if isNew {
                        deck.savePreset(name: preset.name, filter: preset.filter)
                    } else {
                        deck.updatePreset(preset)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
