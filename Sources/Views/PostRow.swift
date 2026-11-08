import SwiftUI
import Translation

extension DeckStore {
    /// What a right-click on a person offers, wherever that person appears.
    func personMenuEntries(person: Profile, accountDID: String?, openProfile: OpenProfileAction) -> [PostMenuEntry] {
        let favoriteKind = ColumnKind.profileTab(actor: person.handle, tab: .replies)
        var entries = [
            PostMenuEntry(title: tr("Alle Posts von \(person.bestName) in neuer Spalte", "All posts by \(person.bestName) in new column")) { [self] in
                openColumn(kind: favoriteKind, accountDID: accountDID)
            },
            PostMenuEntry(title: tr("Profil von \(person.bestName) anzeigen", "Show profile of \(person.bestName)")) {
                openProfile(person.did)
            },
            PostMenuEntry(title: isFavorite(favoriteKind)
                ? tr("\(person.bestName) aus Favoriten entfernen", "Remove \(person.bestName) from Favorites")
                : tr("\(person.bestName) zu Favoriten hinzufügen", "Add \(person.bestName) to Favorites")) { [self] in
                toggleFavorite(person: person)
            },
        ]
        if !isOwnAccount(did: person.did) {
            entries += [
                .separator,
                PostMenuEntry(title: tr("\(person.bestName) stummschalten …", "Mute \(person.bestName)…")) { [self] in
                    confirmation = .mute(person, accountDID: accountDID)
                },
                PostMenuEntry(title: tr("\(person.bestName) blockieren …", "Block \(person.bestName)…"), isDestructive: true) { [self] in
                    confirmation = .block(person, accountDID: accountDID)
                },
            ]
        }
        return entries
    }
}

/// The person menu as SwiftUI context menu content.
struct PersonMenuItems: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openProfile) private var openProfile
    @Environment(\.columnAccountDID) private var accountDID
    let person: Profile

    var body: some View {
        PostMenuItems(entries: deck.personMenuEntries(person: person, accountDID: accountDID, openProfile: openProfile))
    }
}

/// Apple's own translation popover, which runs on the device.
private struct TranslationPopover: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        if #available(macOS 14.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
    }
}

struct PostRow: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL
    @Environment(\.openProfile) private var openProfile
    @Environment(\.openReactions) private var openReactions
    @Environment(\.showsPostDetails) private var showsPostDetails

    let post: PostView
    let repostedBy: Profile?
    let replyingTo: Profile?
    let accountDID: String?
    let onUpdate: @MainActor (PostView) -> Void
    let onOpenThread: (PostView) -> Void

    @State private var isTranslating = false
    @State private var showsCoveredMedia = false

    private var moderation: ModerationPrefs.Decision {
        deck.moderationDecision(for: post, accountDID: accountDID)
    }

    var body: some View {
        // Deleted posts and muted or blocked people vanish from every view at once.
        if !deck.hiddenPostURIs.contains(post.uri), !deck.hiddenAuthorDIDs.contains(post.author.did), moderation != .hide {
            content
                .modifier(TranslationPopover(isPresented: $isTranslating, text: post.record.text))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let repostedBy {
                Label(tr("\(repostedBy.bestName) hat repostet", "\(repostedBy.bestName) reposted"), systemImage: "arrow.2.squarepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 46)
                    .lineLimit(1)
                    .contextMenu { PersonMenuItems(person: repostedBy) }
            }
            HStack(alignment: .top, spacing: 10) {
                Button {
                    openProfile(post.author.did)
                } label: {
                    Avatar(url: post.author.avatarURL, size: 36)
                }
                .buttonStyle(.plain)
                .help(tr("Profil anzeigen. Rechtsklick für alle Posts in neuer Spalte.", "Show profile. Right-click for all posts in a new column."))
                .accessibilityLabel(tr("Profil von \(post.author.bestName) öffnen", "Open profile of \(post.author.bestName)"))
                .contextMenu { PersonMenuItems(person: post.author) }

                VStack(alignment: .leading, spacing: 4) {
                    authorLine
                    if let replyingTo {
                        Label(tr("Antwort an \(replyingTo.bestName)", "Reply to \(replyingTo.bestName)"), systemImage: "arrowshape.turn.up.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contextMenu { PersonMenuItems(person: replyingTo) }
                    }
                    if !post.record.text.isEmpty {
                        SelectablePostText(
                            text: RichText.attributed(text: post.record.text, facets: post.record.facets),
                            fontSize: deck.settings.textSize.points,
                            onTap: { onOpenThread(post) },
                            menuEntries: { menuEntries },
                            onOpenLink: { openURL($0) },
                            onMisleadingLink: { deck.confirmation = .openLink($0, shownAs: $1) }
                        )
                    }
                    if let embed = post.embed {
                        if case .warn(let label) = moderation, !showsCoveredMedia {
                            Button {
                                showsCoveredMedia = true
                            } label: {
                                Label(tr("Inhaltswarnung (\(label)). Anzeigen", "Content warning (\(label)). Show"), systemImage: "eye.slash")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        } else {
                                EmbedView(embed: embed, parent: post)
                                .padding(.top, 2)
                                .environment(\.postTap, PostTapAction { onOpenThread(post) })
                        }
                    }
                    actionBar
                    if showsPostDetails {
                        reactionsSummary
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { onOpenThread(post) }
        .contextMenu { contextItems }
    }

    private var authorLine: some View {
        HStack(spacing: 4) {
            Text(post.author.bestName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("@\(post.author.handle)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !showsPostDetails {
                Text(ATDate.age(of: post.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(fullDate)
            }
        }
    }

    private var fullDate: String {
        post.date?.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: Localizer.shared.locale)) ?? ""
    }

    /// The exact date and everyone who reacted, for looking back at your own posts.
    private var reactionsSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fullDate)
            Button {
                openReactions(post)
            } label: {
                HStack(spacing: 3) {
                    Text(tr("\(post.likeCount ?? 0) Likes · \(post.repostCount ?? 0) Reposts · \(post.quoteCount ?? 0) Zitate · \(post.replyCount ?? 0) Antworten", "\(post.likeCount ?? 0) likes · \(post.repostCount ?? 0) reposts · \(post.quoteCount ?? 0) quotes · \(post.replyCount ?? 0) replies"))
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Zeigt, wer reagiert hat", "Shows who reacted"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            action(
                "bubble.left", count: post.replyCount, label: tr("Antworten", "Reply"), tint: nil
            ) {
                deck.startCompose(replyTo: post, accountDID: accountDID)
            }
            Spacer()
            Menu {
                Button(post.viewer?.repost == nil ? tr("Reposten", "Repost") : tr("Repost zurücknehmen", "Undo Repost")) {
                    Task { await deck.toggleRepost(post, accountDID: accountDID, update: onUpdate) }
                }
                Button(tr("Zitieren", "Quote")) {
                    deck.startCompose(quote: post, accountDID: accountDID)
                }
            } label: {
                actionLabel(
                    "arrow.2.squarepath",
                    count: post.repostCount,
                    tint: post.viewer?.repost != nil ? .green : nil
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(tr("Reposten oder zitieren", "Repost or quote"))
            Spacer()
            action(
                post.viewer?.like != nil ? "heart.fill" : "heart",
                count: post.likeCount,
                label: post.viewer?.like != nil ? tr("Like entfernen", "Remove like") : tr("Liken", "Like"),
                tint: post.viewer?.like != nil ? .pink : nil
            ) {
                Task { await deck.toggleLike(post, accountDID: accountDID, update: onUpdate) }
            }
            Spacer()
            Menu {
                contextItems
            } label: {
                actionLabel("ellipsis", count: nil, tint: nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(tr("Weitere Aktionen", "More actions"))
        }
        .padding(.top, 2)
    }

    private var contextItems: some View {
        PostMenuItems(entries: menuEntries)
    }

    /// One list for both menus: the one on the post and the one on its selectable text.
    private var menuEntries: [PostMenuEntry] {
        let post = post
        let accountDID = accountDID
        let deck = deck
        let update = onUpdate
        var entries = deck.personMenuEntries(person: post.author, accountDID: accountDID, openProfile: openProfile)
        entries.append(.separator)
        entries.append(PostMenuEntry(title: tr("Thread öffnen", "Open Thread")) { onOpenThread(post) })
        entries.append(PostMenuEntry(title: tr("Reaktionen anzeigen", "Show Reactions")) { openReactions(post) })
        if let url = post.webURL {
            entries.append(PostMenuEntry(title: tr("Im Browser öffnen", "Open in Browser")) { openURL(url) })
            entries.append(PostMenuEntry(title: tr("Link kopieren", "Copy Link")) { deck.copy(url.absoluteString) })
        }
        entries.append(PostMenuEntry(title: tr("Text kopieren", "Copy Text")) { deck.copy(post.record.text) })
        if #available(macOS 14.4, *), !post.record.text.isEmpty {
            entries.append(PostMenuEntry(title: tr("Übersetzen", "Translate")) { isTranslating = true })
        }
        entries.append(PostMenuEntry(title: post.viewer?.bookmarked == true ? tr("Lesezeichen entfernen", "Remove Bookmark") : tr("Als Lesezeichen speichern", "Save as Bookmark")) {
            Task { await deck.toggleBookmark(post, accountDID: accountDID, update: update) }
        })
        for tag in hashtags {
            let kind = ColumnKind.search(query: "#\(tag)")
            let isFavorite = deck.isFavorite(kind)
            entries.append(PostMenuEntry(title: isFavorite
                ? tr("#\(tag) aus Favoriten entfernen", "Remove #\(tag) from Favorites")
                : tr("#\(tag) zu Favoriten hinzufügen", "Add #\(tag) to Favorites")) {
                if isFavorite {
                    deck.removeFavorite(kind: kind)
                } else {
                    deck.addFavorite(kind: kind, title: "#\(tag)")
                }
            })
        }
        if deck.isOwnPost(post) {
            entries.append(.separator)
            entries.append(PostMenuEntry(title: tr("Post löschen …", "Delete Post…"), isDestructive: true) {
                deck.confirmation = .deletePost(post)
            })
        }
        return entries
    }

    /// The hashtags in this post, each once, without letting a long list swamp the menu.
    private var hashtags: [String] {
        var seen = Set<String>()
        let tags = (post.record.facets ?? []).flatMap(\.features).compactMap { feature -> String? in
            if case .tag(let tag) = feature { return tag }
            return nil
        }
        return Array(tags.filter { seen.insert($0).inserted }.prefix(5))
    }

    private func action(
        _ systemImage: String, count: Int?, label: String, tint: Color?, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            actionLabel(systemImage, count: count, tint: tint)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func actionLabel(_ systemImage: String, count: Int?, tint: Color?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            if let count, count > 0 {
                Text(count, format: .number.notation(.compactName))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(tint ?? .secondary)
        .frame(minWidth: 36, minHeight: 24, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct NotificationRow: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openProfile) private var openProfile
    let item: NotificationItem
    let accountDID: String?
    let onUpdate: @MainActor (PostView) -> Void
    let onOpenThread: (PostView) -> Void

    private var reason: String { item.raw.reason }
    private var showsFullPost: Bool { ["reply", "mention", "quote"].contains(reason) }

    var body: some View {
        if showsFullPost, let post = item.post {
            PostRow(
                post: post, repostedBy: nil, replyingTo: nil, accountDID: accountDID,
                onUpdate: onUpdate, onOpenThread: onOpenThread
            )
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 36)
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 4) {
                    Avatar(url: item.raw.author.avatarURL, size: 28)
                    (Text(item.raw.author.bestName).fontWeight(.semibold) + Text(" \(item.raw.summary)"))
                        .font(.subheadline)
                    if let post = item.post {
                        SelectablePostText(
                            text: AttributedString(post.record.text),
                            fontSize: 11,
                            color: .secondaryLabelColor,
                            maxLines: 3,
                            onTap: { onOpenThread(post) },
                            menuEntries: { deck.personMenuEntries(person: item.raw.author, accountDID: accountDID, openProfile: openProfile) },
                            onOpenLink: { _ in }
                        )
                    }
                }
                Spacer(minLength: 0)
                Text(ATDate.age(of: ATDate.parse(item.raw.indexedAt)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                if let post = item.post {
                    onOpenThread(post)
                } else {
                    openProfile(item.raw.author.did)
                }
            }
            .contextMenu { PersonMenuItems(person: item.raw.author) }
        }
    }

    private var icon: String {
        switch reason {
        case "like": return "heart.fill"
        case "repost": return "arrow.2.squarepath"
        case "follow": return "person.badge.plus"
        default: return "bell"
        }
    }

    private var tint: Color {
        switch reason {
        case "like": return .pink
        case "repost": return .green
        case "follow": return .blue
        default: return .secondary
        }
    }

}
