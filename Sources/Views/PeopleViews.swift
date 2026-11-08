import SwiftUI

enum PeopleList: Hashable {
    case followers, following

    var title: String {
        switch self {
        case .followers: return tr("Follower", "Followers")
        case .following: return tr("Folgt", "Following")
        }
    }
}

/// One person in a list, with the usual right-click menu.
struct PersonRow: View {
    @Environment(\.openProfile) private var openProfile
    let person: Profile

    var body: some View {
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
}

struct PeoplePanel: View {
    @Environment(DeckStore.self) private var deck
    let actor: String
    let list: PeopleList
    let accountDID: String?
    let onBack: () -> Void

    @State private var people: [Profile] = []
    @State private var cursor: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var client: XRPCClient {
        deck.accounts.client(for: accountDID) ?? deck.accounts.publicClient
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnPanelBar(title: list.title, onBack: onBack)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(people) { person in
                        PersonRow(person: person)
                            .onAppear {
                                if person.id == people.last?.id, cursor != nil {
                                    Task { await load() }
                                }
                            }
                        Divider()
                    }
                    if isLoading {
                        ProgressView().controlSize(.small).padding()
                    } else if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary).padding()
                    } else if people.isEmpty {
                        Text(tr("Keine Einträge", "No items")).font(.callout).foregroundStyle(.secondary).padding(24)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = list == .followers
                ? try await client.followers(of: actor, cursor: cursor)
                : try await client.follows(of: actor, cursor: cursor)
            people = (people + page.people).removingDuplicateIDs()
            cursor = page.cursor
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Suggestions while typing a name. Waits for a typing pause, and shows nothing until there is something to show.
struct PersonSuggestions: View {
    @Environment(DeckStore.self) private var deck
    let term: String
    /// Someone who makes no sense as a result here, such as the signed-in account when writing a message.
    var excluding: String?
    let onPick: (Profile) -> Void

    @State private var people: [Profile] = []

    private var query: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(people.filter { $0.did != excluding }) { person in
                Button {
                    onPick(person)
                } label: {
                    HStack(spacing: 8) {
                        Avatar(url: person.avatarURL, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(person.bestName).font(.callout).lineLimit(1)
                            Text("@\(person.handle)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: query) {
            guard query.count >= 2 else {
                people = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let client = deck.accounts.client(for: deck.accounts.accounts.first?.did) ?? deck.accounts.publicClient
            if let found = try? await client.suggestPeople(matching: query), !Task.isCancelled {
                people = found
            }
        }
    }
}
