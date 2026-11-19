import Foundation

/// A filter with a name, kept once and used by any number of columns.
/// Changing it changes every column that uses it.
struct FilterPreset: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var filter: ColumnFilter
}

extension DeckStore {
    var feedReader: FeedReader {
        FeedReader(transport: feedTransport, feedly: feedly.map { FeedlyClient(connection: $0, transport: feedTransport) })
    }

    func presetFilters(for column: Column) -> [ColumnFilter] {
        (column.presetIDs ?? []).compactMap { id in filterPresets.first { $0.id == id }?.filter }
    }

    func isUsing(_ preset: FilterPreset, in columnID: UUID) -> Bool {
        columns.first { $0.id == columnID }?.presetIDs?.contains(preset.id) == true
    }

    func setPreset(_ preset: FilterPreset, used: Bool, in columnID: UUID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        var ids = columns[index].presetIDs ?? []
        ids.removeAll { $0 == preset.id }
        if used { ids.append(preset.id) }
        columns[index].presetIDs = ids.isEmpty ? nil : ids
        feeds[columnID]?.presets = presetFilters(for: columns[index])
        saveColumns()
    }

    @discardableResult
    func savePreset(name: String, filter: ColumnFilter) -> FilterPreset {
        let preset = FilterPreset(name: name.trimmingCharacters(in: .whitespacesAndNewlines), filter: filter)
        filterPresets.append(preset)
        saveFilterPresets()
        return preset
    }

    func updatePreset(_ preset: FilterPreset) {
        guard let index = filterPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        filterPresets[index] = preset
        saveFilterPresets()
    }

    func deletePreset(_ id: UUID) {
        filterPresets.removeAll { $0.id == id }
        for deck in decks.indices {
            for column in decks[deck].columns.indices {
                guard var ids = decks[deck].columns[column].presetIDs, ids.contains(id) else { continue }
                ids.removeAll { $0 == id }
                decks[deck].columns[column].presetIDs = ids.isEmpty ? nil : ids
            }
        }
        saveColumns()
        saveFilterPresets()
    }

    /// The columns of every deck that use this preset, for "used in 3 columns".
    func columnCount(using preset: FilterPreset) -> Int {
        decks.flatMap(\.columns).filter { $0.presetIDs?.contains(preset.id) == true }.count
    }

    func saveFilterPresets() {
        // Every open column sees the change at once.
        for deck in decks {
            for column in deck.columns { feeds[column.id]?.presets = presetFilters(for: column) }
        }
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        if let data = try? JSONEncoder().encode(filterPresets) {
            UserDefaults.standard.set(data, forKey: Self.filterPresetsKey)
        }
        pushToCloud { $0.filterPresets.push(self.filterPresets) }
    }

    // MARK: Feedly

    func connectFeedly(token: String) async throws {
        let connection = try await FeedlyClient.connect(token: token, transport: feedTransport)
        feedly = connection
        FeedlyKeychain.save(connection)
        refreshGeneration += 1
    }

    func disconnectFeedly() {
        feedly = nil
        FeedlyKeychain.delete()
    }

    // MARK: Feed columns

    /// One column per folder of an OPML file, in a new deck of their own.
    func importOPML(_ folders: [OPMLFolder], deckName: String) {
        let columns = folders.map { folder in
            Column(kind: .rss(feeds: folder.feeds.map(\.url), name: folder.name), accountDID: nil, width: settings.defaultWidth)
        }
        guard !columns.isEmpty else { return }
        let page = DeckPage(name: deckName, columns: columns)
        decks.append(page)
        activeDeckID = page.id
        saveColumns()
    }
}
