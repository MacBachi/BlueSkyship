import SwiftUI
import Translation

extension DeckStore {
    /// What a right-click on an article offers. Articles cannot be liked or answered, only read and passed on.
    func articleMenuEntries(_ post: PostView, open: @escaping @MainActor () -> Void, openURL: OpenURLAction) -> [PostMenuEntry] {
        guard let article = post.article else { return [] }
        var entries = [PostMenuEntry(title: tr("Artikel lesen", "Read Article"), perform: open)]
        if let url = post.webURL {
            entries.append(PostMenuEntry(title: tr("Im Browser öffnen", "Open in Browser")) { openURL(url) })
            entries.append(PostMenuEntry(title: tr("Link kopieren", "Copy Link")) { [self] in copy(url.absoluteString) })
        }
        entries.append(PostMenuEntry(title: tr("Teilen …", "Share…")) { [self] in shareArticle(post) })
        entries.append(.separator)
        if let feedURL = article.feedURL, let kind = singleFeedKind(feedURL: feedURL, title: article.source) {
            entries.append(PostMenuEntry(title: tr("„\(article.source)“ in neuer Spalte", "“\(article.source)” in new column")) { [self] in
                openColumn(kind: kind, accountDID: nil)
            })
        }
        entries.append(PostMenuEntry(title: tr("Text kopieren", "Copy Text")) { [self] in copy(article.title + "\n\n" + article.body) })
        return entries
    }

    /// Opens the composer with the title and link, on the first account there is.
    func shareArticle(_ post: PostView) {
        guard let article = post.article else { return }
        let link = post.webURL?.absoluteString ?? ""
        startCompose(text: [article.title, link].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// Feedly articles name their feed as Feedly does; plain feed addresses open as RSS.
    private func singleFeedKind(feedURL: String, title: String) -> ColumnKind? {
        guard FeedFetcher.normalize(feedURL) != nil else { return nil }
        return .rss(feeds: [feedURL], name: title)
    }
}

/// One article in a column: where it is from, its title, the start of the text and its picture.
struct ArticleRow: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL
    let post: PostView
    let onOpen: @MainActor () -> Void

    @State private var isTranslating = false

    var body: some View {
        if let article = post.article {
            content(article)
                .modifier(ArticleTranslation(isPresented: $isTranslating, text: post.record.text))
        }
    }

    private var summary: String {
        guard let article = post.article else { return "" }
        return ArticleMapper.summary(of: article.body)
    }

    private func content(_ article: ArticleInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Avatar(url: post.author.avatarURL, size: 16)
                Text(article.source)
                    .lineLimit(1)
                if let author = article.author, !author.isEmpty, author != article.source {
                    Text("· \(author)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Text(ATDate.age(of: post.date))
                    .fixedSize()
                    .help(post.date?.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: Localizer.shared.locale)) ?? "")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(.system(size: deck.settings.textSize.points + 1, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: deck.settings.textSize.points - 1))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if deck.settings.showMedia, let image = article.imageURL.flatMap(URL.init(string:)) {
                    RemoteImage(url: image)
                        .frame(width: 84, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            PostMenuItems(entries: menuEntries)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    private var menuEntries: [PostMenuEntry] {
        var entries = deck.articleMenuEntries(post, open: onOpen, openURL: openURL)
        if #available(macOS 14.4, *) {
            entries.append(PostMenuEntry(title: tr("Übersetzen", "Translate")) { isTranslating = true })
        }
        return entries
    }
}

private struct ArticleTranslation: ViewModifier {
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

/// The whole article inside the column, as plain text with working links. Nothing from the
/// publisher's page is loaded here: no scripts, no trackers, only the text the feed sent.
struct ArticlePanel: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL
    let post: PostView
    let onBack: () -> Void

    @State private var isTranslating = false

    var body: some View {
        VStack(spacing: 0) {
            ColumnPanelBar(title: tr("Artikel", "Article"), onBack: onBack)
            Divider()
            if let article = post.article {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Avatar(url: post.author.avatarURL, size: 18)
                            Text(article.source).lineLimit(1)
                            Spacer(minLength: 4)
                            if let date = post.date {
                                Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Localizer.shared.locale)))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(article.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let author = article.author, !author.isEmpty {
                            Text(author).font(.callout).foregroundStyle(.secondary)
                        }
                        if deck.settings.showMedia, let image = article.imageURL.flatMap(URL.init(string:)) {
                            RemoteImage(url: image, contentMode: .fit, showsPlaceholder: false)
                                .frame(maxWidth: .infinity, maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                        }
                        if !article.body.isEmpty {
                            SelectablePostText(
                                text: RichText.attributed(text: article.body, facets: article.bodyFacets),
                                fontSize: deck.settings.textSize.points,
                                onTap: {},
                                menuEntries: { [] },
                                onOpenLink: { openURL($0) },
                                onMisleadingLink: { deck.confirmation = .openLink($0, shownAs: $1) }
                            )
                        }
                        actions
                            .padding(.top, 6)
                    }
                    .padding(14)
                }
                .modifier(ArticleTranslation(isPresented: $isTranslating, text: article.title + "\n\n" + article.body))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let url = post.webURL {
                Button {
                    openURL(url)
                } label: {
                    Label(tr("Im Browser öffnen", "Open in Browser"), systemImage: "safari")
                }
            }
            Button {
                deck.shareArticle(post)
            } label: {
                Label(tr("Teilen", "Share"), systemImage: "square.and.arrow.up")
            }
            if #available(macOS 14.4, *) {
                Button {
                    isTranslating = true
                } label: {
                    Label(tr("Übersetzen", "Translate"), systemImage: "translate")
                }
            }
        }
        .controlSize(.small)
    }
}
