import Foundation
import Observation

/// Loading state of one column. New posts never shift what you are reading: while scrolled down
/// they wait in `pending` until you ask for them.
@MainActor
@Observable
final class ColumnFeed {
    /// A filter can hide whole pages; this bounds how much one action may fetch looking for matches.
    private static let maxPagesPerLoad = 5
    /// A filtered column keeps fetching until it shows at least this many items.
    private static let minimumVisibleItems = 10
    private static let maxPending = 500

    private(set) var items: [ColumnItem] = [] {
        didSet { visibleItems = shown(items) }
    }
    private(set) var pending: [ColumnItem] = [] {
        didSet { visiblePending = shown(pending) }
    }
    private(set) var visibleItems: [ColumnItem] = []
    private(set) var visiblePending: [ColumnItem] = []
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private var cursor: String?

    var filter = ColumnFilter() {
        didSet {
            guard filter != oldValue else { return }
            refreshVisible()
            // The item at the old position may be hidden now.
            anchorID = nil
            autoFillBudget = Self.maxPagesPerLoad
        }
    }

    /// Pages that may still be fetched without being asked, per filter. Without this limit, a filter
    /// with no matches would fetch more pages on every auto-refresh, forever.
    private var autoFillBudget = ColumnFeed.maxPagesPerLoad

    /// A search in this column only. Never saved, and gone when the search closes.
    var searchTerm = "" {
        didSet {
            guard searchTerm != oldValue else { return }
            refreshVisible()
            anchorID = nil
            autoFillBudget = Self.maxPagesPerLoad
        }
    }

    var isSearching: Bool { !searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the account has set in Bluesky. Applies on top of the column's own filter.
    var moderation = ModerationPrefs() {
        didSet {
            if moderation != oldValue { refreshVisible() }
        }
    }
    /// One's own posts are never hidden by one's own settings.
    @ObservationIgnored var isOwnPost: (PostView) -> Bool = { _ in false }

    private func shown(_ items: [ColumnItem]) -> [ColumnItem] {
        filter.apply(items).filter { item in
            if isSearching, !item.matchesSearch(searchTerm) { return false }
            guard let post = item.displayedPost else { return true }
            return moderation.decision(for: post, isOwn: isOwnPost(post)) != .hide
        }
    }

    private func refreshVisible() {
        visibleItems = shown(items)
        visiblePending = shown(pending)
    }

    /// The topmost visible item, bound to the column's scroll position.
    var anchorID: String?

    var isAtTop: Bool { anchorID == nil || anchorID == visibleItems.first?.id }
    var hasMore: Bool { cursor != nil }
    var hiddenCount: Int { items.count - visibleItems.count }

    func refresh(using client: XRPCClient, kind: ColumnKind) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let page = try await client.fetchPage(kind: kind, cursor: nil)
            merge(page)
            errorMessage = nil
        } catch is CancellationError {
            // The view went away; not an error worth showing.
        } catch let error as URLError where error.code == .cancelled {
            // Same as above, surfaced by URLSession.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches older items until at least one more becomes visible, or the page limit is reached.
    func loadMore(using client: XRPCClient, kind: ColumnKind) async {
        let target = visibleItems.count + 1
        await fetchPages(until: target, using: client, kind: kind)
    }

    /// Keeps a filtered column from looking empty just because the first page had few matches.
    func fillIfNeeded(using client: XRPCClient, kind: ColumnKind) async {
        guard filter.isActive || isSearching, !items.isEmpty, autoFillBudget > 0 else { return }
        await fetchPages(until: Self.minimumVisibleItems, usesAutoFillBudget: true, using: client, kind: kind)
    }

    private func fetchPages(
        until visibleTarget: Int,
        usesAutoFillBudget: Bool = false,
        using client: XRPCClient,
        kind: ColumnKind
    ) async {
        guard !isLoadingMore, !isRefreshing else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var pagesFetched = 0
        do {
            while visibleItems.count < visibleTarget,
                  let current = cursor,
                  pagesFetched < Self.maxPagesPerLoad,
                  !usesAutoFillBudget || autoFillBudget > 0 {
                let page = try await client.fetchPage(kind: kind, cursor: current)
                items = (items + page.items).removingDuplicateIDs()
                cursor = page.cursor
                pagesFetched += 1
                if usesAutoFillBudget { autoFillBudget -= 1 }
            }
        } catch is CancellationError {
            // The filter changed or the view went away.
        } catch let error as URLError where error.code == .cancelled {
            // Same as above, surfaced by URLSession.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves waiting posts into the list and returns the new top item to scroll to.
    @discardableResult
    func showPending() -> String? {
        items = (pending + items).removingDuplicateIDs()
        pending = []
        anchorID = visibleItems.first?.id
        return anchorID
    }

    func replace(post: PostView) {
        items = items.map { $0.replacingPost(post) }
        pending = pending.map { $0.replacingPost(post) }
    }

    func remove(where shouldRemove: (ColumnItem) -> Bool) {
        items.removeAll(where: shouldRemove)
        pending.removeAll(where: shouldRemove)
    }

    func reset() {
        items = []
        pending = []
        cursor = nil
        anchorID = nil
        errorMessage = nil
    }

    private func merge(_ page: FeedPage) {
        guard !items.isEmpty else {
            items = page.items.removingDuplicateIDs()
            cursor = page.cursor
            return
        }

        let known = Set(items.map(\.id)).union(pending.map(\.id))
        let fresh = page.items.filter { !known.contains($0.id) }

        // Keep counters and like state of already loaded posts current.
        let updates = Dictionary(page.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = items.map { updates[$0.id] ?? $0 }

        // A page with nothing known is typically an algorithmic feed that re-ranked itself.
        // Swapping it in would replace the post being read, so it waits like any other update.
        let isWholesaleChange = !page.items.isEmpty && fresh.count == page.items.count

        if isAtTop, !isWholesaleChange {
            items = (fresh + pending + items).removingDuplicateIDs()
            pending = []
        } else {
            pending = Array((fresh + pending).removingDuplicateIDs().prefix(Self.maxPending))
        }
    }
}
