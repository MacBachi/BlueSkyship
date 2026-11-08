import SwiftUI

/// What a column shows instead of its timeline when you drill into something.
enum ColumnRoute: Hashable {
    case thread(PostView)
    case profile(String)
    case reactions(PostView)
    case conversation(Conversation, accountDID: String)
    case people(actor: String, list: PeopleList)
}

/// Lets any row deep inside a column open a profile within that column.
struct OpenProfileAction: @unchecked Sendable {
    let handler: @MainActor (String) -> Void

    @MainActor func callAsFunction(_ actor: String) {
        handler(actor)
    }
}

struct OpenReactionsAction: @unchecked Sendable {
    let handler: @MainActor (PostView) -> Void

    @MainActor func callAsFunction(_ post: PostView) {
        handler(post)
    }
}

/// Lets a profile open a chat or a list of people inside its column.
struct OpenRouteAction: @unchecked Sendable {
    let handler: @MainActor (ColumnRoute) -> Void

    @MainActor func callAsFunction(_ route: ColumnRoute) {
        handler(route)
    }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { _ in }
    @Entry var openProfile = OpenProfileAction { _ in }
    @Entry var openReactions = OpenReactionsAction { _ in }
    /// Set in the "My Posts" column: exact dates and a reactions summary instead of the compact look.
    @Entry var showsPostDetails = false
    /// The account a column reads and acts with; `nil` means it reads the public API.
    @Entry var columnAccountDID: String? = nil
}

/// Shared top bar of everything a column drills into.
struct ColumnPanelBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title).font(.subheadline.weight(.semibold))
            HStack {
                Button(action: onBack) {
                    Label(tr("Zurück", "Back"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Replaces the timeline inside the column, the way a deck drills down without leaving its place.
struct ThreadPanel: View {
    @Environment(DeckStore.self) private var deck
    let root: PostView
    let accountDID: String?
    let onBack: () -> Void
    let onOpenThread: (PostView) -> Void

    @State private var thread: ThreadContent?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ColumnPanelBar(title: "Thread", onBack: onBack)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(thread?.parents ?? []) { row($0) }
                    row(thread?.post ?? root)
                        .background(Color.accentColor.opacity(0.06))
                    if thread == nil, errorMessage == nil {
                        ProgressView().controlSize(.small).padding()
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary).padding()
                    }
                    ForEach(thread?.replies ?? []) { row($0) }
                }
            }
        }
        .task(id: root.uri) { await load() }
    }

    private func row(_ post: PostView) -> some View {
        VStack(spacing: 0) {
            PostRow(
                post: post,
                repostedBy: nil,
                replyingTo: nil,
                accountDID: accountDID,
                onUpdate: { thread?.replace($0) },
                onOpenThread: { opened in
                    if opened.uri != root.uri { onOpenThread(opened) }
                }
            )
            Divider()
        }
    }

    private func load() async {
        thread = nil
        errorMessage = nil
        let client = deck.accounts.client(for: accountDID) ?? deck.accounts.publicClient
        do {
            thread = try await client.thread(uri: root.uri)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
