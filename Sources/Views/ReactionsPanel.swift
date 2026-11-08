import SwiftUI

/// Who liked, reposted or quoted a post.
struct ReactionsPanel: View {
    private enum Tab: Hashable, CaseIterable {
        case likes, reposts, quotes
    }

    @Environment(DeckStore.self) private var deck
    @Environment(\.openProfile) private var openProfile

    let post: PostView
    let accountDID: String?
    let onBack: () -> Void
    let onOpenThread: (PostView) -> Void

    @State private var tab: Tab = .likes
    @State private var people: [Profile] = []
    @State private var quotes: [PostView] = []
    @State private var cursor: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var client: XRPCClient {
        deck.accounts.client(for: accountDID) ?? deck.accounts.publicClient
    }

    private func label(_ tab: Tab) -> String {
        switch tab {
        case .likes: return "Likes \(post.likeCount ?? 0)"
        case .reposts: return "Reposts \(post.repostCount ?? 0)"
        case .quotes: return tr("Zitate \(post.quoteCount ?? 0)", "Quotes \(post.quoteCount ?? 0)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnPanelBar(title: tr("Reaktionen", "Reactions"), onBack: onBack)
            Divider()
            Text(post.record.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            Picker(tr("Ansicht", "View"), selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if tab == .quotes {
                        ForEach(quotes) { quote in
                            PostRow(
                                post: quote, repostedBy: nil, replyingTo: nil, accountDID: accountDID,
                                onUpdate: { updated in
                                    quotes = quotes.map { $0.uri == updated.uri ? updated : $0 }
                                },
                                onOpenThread: onOpenThread
                            )
                            .onAppear { loadMoreIfLast(quote.uri == quotes.last?.uri) }
                            Divider()
                        }
                    } else {
                        ForEach(people) { person in
                            personRow(person)
                                .onAppear { loadMoreIfLast(person.id == people.last?.id) }
                            Divider()
                        }
                    }
                    footer
                }
            }
        }
        .task(id: tab) {
            people = []
            quotes = []
            cursor = nil
            errorMessage = nil
            await load()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isLoading {
            ProgressView().controlSize(.small).padding()
        } else if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(.secondary).padding()
        } else if people.isEmpty, quotes.isEmpty {
            Text(tr("Noch keine Reaktionen dieser Art.", "No reactions of this kind yet."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(24)
        }
    }

    private func personRow(_ person: Profile) -> some View {
        Button {
            openProfile(person.did)
        } label: {
            HStack(spacing: 10) {
                Avatar(url: person.avatarURL, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(person.bestName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("@\(person.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { PersonMenuItems(person: person) }
    }

    private func loadMoreIfLast(_ isLast: Bool) {
        guard isLast, cursor != nil else { return }
        Task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let requestedTab = tab
        do {
            switch requestedTab {
            case .likes:
                let page = try await client.likers(of: post.uri, cursor: cursor)
                people = (people + page.people).removingDuplicateIDs()
                cursor = page.cursor
            case .reposts:
                let page = try await client.reposters(of: post.uri, cursor: cursor)
                people = (people + page.people).removingDuplicateIDs()
                cursor = page.cursor
            case .quotes:
                let page = try await client.quotes(of: post.uri, cursor: cursor)
                quotes = (quotes + page.posts).removingDuplicateIDs()
                cursor = page.cursor
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
