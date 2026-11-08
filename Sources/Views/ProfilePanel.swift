import AppKit
import SwiftUI

struct ProfilePanel: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL
    @Environment(\.openRoute) private var openRoute

    let actor: String
    let accountDID: String?
    let onBack: () -> Void
    let onOpenThread: (PostView) -> Void

    @State private var profile: ProfileDetail?
    @State private var errorMessage: String?
    @State private var tab: ProfileTab = .posts
    @State private var feed = ColumnFeed()

    /// Prefers an account, because only then does the server say whether you already follow this person.
    private var client: XRPCClient {
        deck.accounts.client(for: accountDID)
            ?? deck.accounts.client(for: deck.accounts.accounts.first?.did)
            ?? deck.accounts.publicClient
    }

    private var tabKind: ColumnKind { .profileTab(actor: actor, tab: tab) }

    var body: some View {
        VStack(spacing: 0) {
            ColumnPanelBar(title: tr("Profil", "Profile"), onBack: onBack)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let profile {
                        header(profile)
                    } else if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary).padding()
                    } else {
                        ProgressView().controlSize(.small).padding()
                    }
                    Picker(tr("Ansicht", "View"), selection: $tab) {
                        ForEach(ProfileTab.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                    posts
                }
            }
        }
        .task(id: "\(actor)#\(deck.moderationGeneration)") { await loadProfile() }
        .task(id: tab) {
            feed.reset()
            await feed.refresh(using: client, kind: tabKind)
        }
    }

    @ViewBuilder
    private var posts: some View {
        ForEach(feed.visibleItems) { item in
            if case .post(let entry) = item {
                PostRow(
                    post: entry.post,
                    repostedBy: entry.reason?.by,
                    replyingTo: entry.reply?.parentAuthor,
                    accountDID: accountDID,
                    onUpdate: { feed.replace(post: $0) },
                    onOpenThread: onOpenThread
                )
                .onAppear {
                    if item.id == feed.visibleItems.last?.id {
                        Task { await feed.loadMore(using: client, kind: tabKind) }
                    }
                }
                Divider()
            }
        }
        if feed.isRefreshing || feed.isLoadingMore {
            ProgressView().controlSize(.small).padding()
        } else if feed.visibleItems.isEmpty {
            Text(feed.errorMessage ?? tr("Keine Einträge", "No items"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(24)
        }
    }

    private func header(_ profile: ProfileDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: profile.bannerURL)
                .frame(height: 90)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Avatar(url: profile.avatarURL, size: 64)
                    .overlay {
                        Circle().strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 2)
                    }
                    .padding(.top, -40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.bestName)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("@\(profile.handle)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if profile.viewer?.muted == true {
                            Text(tr("stummgeschaltet", "muted")).font(.caption2).foregroundStyle(.orange)
                        }
                        if profile.viewer?.blocking != nil {
                            Text(tr("blockiert", "blocked")).font(.caption2).foregroundStyle(.red)
                        }
                        if profile.viewer?.followedBy != nil {
                            Text(tr("folgt dir", "follows you"))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
                        }
                    }
                    .font(.subheadline)
                }
                if let description = profile.description, !description.isEmpty {
                    Text(RichText.linkifiedPlainText(description))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    countButton(profile.followersCount, tr("Follower", "Followers"), list: .followers, actor: profile.did)
                    countButton(profile.followsCount, tr("Folgt", "Following"), list: .following, actor: profile.did)
                    count(profile.postsCount, "Posts")
                }
                actions(profile)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func countButton(_ value: Int?, _ label: String, list: PeopleList, actor: String) -> some View {
        ProfileCountButton {
            openRoute(.people(actor: actor, list: list))
        } label: {
            count(value, label)
        }
    }

    private func count(_ value: Int?, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value ?? 0, format: .number.notation(.compactName)).fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func actions(_ profile: ProfileDetail) -> some View {
        let isOwnProfile = deck.accounts.accounts.contains { $0.did == profile.did }
        let isFollowing = profile.viewer?.following != nil
        return HStack(spacing: 6) {
            if !isOwnProfile {
                Button(isFollowing ? tr("Entfolgen", "Unfollow") : tr("Folgen", "Follow")) {
                    Task {
                        await deck.toggleFollow(profile, accountDID: accountDID) { self.profile = $0 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isFollowing ? Color.secondary : Color.accentColor)
            }
            if !isOwnProfile {
                Button(tr("Nachricht", "Message")) {
                    Task {
                        if let (conversation, did) = await deck.openConversation(with: profile.did, accountDID: accountDID) {
                            openRoute(.conversation(conversation, accountDID: did))
                        }
                    }
                }
                .help(tr("Direktnachricht schreiben", "Write a direct message"))
            }
            Button(tr("Als Spalte", "As Column")) {
                deck.openColumn(kind: .profileTab(actor: profile.handle, tab: .replies), accountDID: accountDID)
            }
            .help(tr("Alle Posts dieser Person als eigene Spalte öffnen", "Open all posts by this person as a column"))
            if !isOwnProfile {
                moderationMenu(profile)
            }
            if let url = profile.webURL {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "safari")
                }
                .help(tr("Im Browser öffnen", "Open in Browser"))
                .accessibilityLabel(tr("Im Browser öffnen", "Open in Browser"))
            }
        }
        .controlSize(.small)
    }

    private func moderationMenu(_ profile: ProfileDetail) -> some View {
        let person = Profile(did: profile.did, handle: profile.handle, displayName: profile.displayName, avatar: profile.avatar)
        return Menu {
            if profile.viewer?.muted == true {
                Button(tr("Stummschaltung aufheben", "Unmute")) {
                    Task { await deck.unmute(profile, accountDID: accountDID) }
                }
            } else {
                Button(tr("Stummschalten …", "Mute…")) {
                    deck.confirmation = .mute(person, accountDID: accountDID)
                }
            }
            if profile.viewer?.blocking != nil {
                Button(tr("Blockierung aufheben", "Unblock")) {
                    Task { await deck.unblock(profile, accountDID: accountDID) }
                }
            } else {
                Button(tr("Blockieren …", "Block…"), role: .destructive) {
                    deck.confirmation = .block(person, accountDID: accountDID)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .fixedSize()
        .accessibilityLabel(tr("Stummschalten oder blockieren", "Mute or block"))
    }

    private func loadProfile() async {
        do {
            profile = try await client.profileDetail(actor: actor)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Looks like plain text at rest, so it shows on hover that it can be clicked.
private struct ProfileCountButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .underline(isHovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            // Opening the list removes this view while the mouse is still over it.
            if isHovering { NSCursor.pop() }
        }
    }
}
