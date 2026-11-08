import Foundation

/// The little that synchronization needs from a key-value store, so tests can use their own.
protocol CloudStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudStore {}

/// One list in iCloud with the time of its last change.
/// When two Macs edit while offline, the later change wins for the whole list.
struct SyncEnvelope<Item: Codable>: Codable {
    var modifiedAt: Date
    var items: [Item]
}

enum CloudPushOutcome: Equatable {
    case nothing, pushed, tooLarge
}

@MainActor
final class CloudDocument<Item: Codable & Identifiable> {
    /// The store allows 1 MB per key and in total. Three lists have to fit, and text is small.
    static var maxBytes: Int { 300_000 }

    private let key: String
    private let store: CloudStore
    private let defaults: UserDefaults

    init(key: String, store: CloudStore, defaults: UserDefaults) {
        self.key = key
        self.store = store
        self.defaults = defaults
    }

    private var markKey: String { "cloud.modified.\(key)" }
    private var localMark: Date? { defaults.object(forKey: markKey) as? Date }

    private func envelope() -> SyncEnvelope<Item>? {
        store.data(forKey: key).flatMap { try? JSONDecoder.cloud.decode(SyncEnvelope<Item>.self, from: $0) }
    }

    /// Records a local change and sends it up.
    @discardableResult
    func push(_ items: [Item], at date: Date = Date()) -> CloudPushOutcome {
        let new = SyncEnvelope(modifiedAt: date, items: items)
        guard let data = try? JSONEncoder.cloud.encode(new) else { return .nothing }
        // Saving is also called for changes that stay on this Mac, such as switching the deck on screen.
        if let current = envelope(), let currentData = try? JSONEncoder.cloud.encode(SyncEnvelope(modifiedAt: date, items: current.items)),
           currentData == data {
            return .nothing
        }
        guard data.count <= Self.maxBytes else { return .tooLarge }
        store.set(data, forKey: key)
        defaults.set(date, forKey: markKey)
        store.synchronize()
        return .pushed
    }

    /// Compares with iCloud. Returns the items to use when they differ from what is here, otherwise nil.
    func reconcile(local: [Item], now: Date = Date()) -> [Item]? {
        guard let cloud = envelope() else {
            if !local.isEmpty { push(local, at: localMark ?? now) }
            return nil
        }
        guard let mark = localMark else {
            // The first sync on this Mac: nothing here may be lost, so both sides are combined.
            let cloudIDs = Set(cloud.items.map(\.id))
            let merged = cloud.items + local.filter { !cloudIDs.contains($0.id) }
            push(merged, at: now)
            return merged
        }
        if cloud.modifiedAt > mark {
            defaults.set(cloud.modifiedAt, forKey: markKey)
            return cloud.items
        }
        if mark > cloud.modifiedAt {
            push(local, at: mark)
        }
        return nil
    }
}

extension JSONEncoder {
    static var cloud: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
