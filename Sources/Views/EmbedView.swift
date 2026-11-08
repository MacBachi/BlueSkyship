import AppKit
import SwiftUI

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        guard let data = await LimitedDownload.data(from: url),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }
}

/// Fetches a picture without letting a huge or unexpected answer fill the memory.
final class LimitedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let limit = 30 * 1024 * 1024

    private let maximum: Int
    private let finish: @Sendable (Data?) -> Void
    private var received = Data()
    private var isDone = false

    private init(maximum: Int, finish: @escaping @Sendable (Data?) -> Void) {
        self.maximum = maximum
        self.finish = finish
    }

    static func data(from url: URL, session: URLSession = .shared, limit: Int = LimitedDownload.limit) async -> Data? {
        guard LinkPolicy.isSecureMedia(url) else { return nil }
        let task = session.dataTask(with: url)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                task.delegate = LimitedDownload(maximum: limit) { continuation.resume(returning: $0) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let isOK = ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) }) ?? false
        completionHandler(isOK && response.expectedContentLength <= Int64(maximum) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
        if received.count > maximum {
            complete(nil)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(error == nil ? received : nil)
    }

    private func complete(_ data: Data?) {
        guard !isDone else { return }
        isDone = true
        finish(data)
    }
}

/// `AsyncImage` reloads whenever a lazy row reappears, which flickers while scrolling; this keeps images in memory.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var showsPlaceholder = true

    @State private var image: NSImage?

    var body: some View {
        // The color decides the size; an image in an overlay can never push the layout wider or taller.
        (showsPlaceholder ? Color(nsColor: .quaternaryLabelColor) : Color.clear)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return }
                image = ImageCache.shared.cached(url)
                if image == nil { image = await ImageCache.shared.load(url) }
            }
    }
}

struct Avatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

struct EmbedView: View {
    @Environment(DeckStore.self) private var deck
    let embed: Embed
    let parent: PostView

    private func collapsedMedia(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        switch embed {
        case .images(let images):
            if deck.settings.showMedia {
                ImageGrid(images: images)
            } else {
                collapsedMedia(images.count == 1 ? tr("Bild anzeigen", "Show picture") : tr("\(images.count) Bilder anzeigen", "Show \(images.count) pictures"), systemImage: "photo") {
                    deck.media = .images(images, index: 0)
                }
            }
        case .external(let link):
            ExternalCard(link: link)
        case .video(let video) where !deck.settings.showMedia:
            collapsedMedia(tr("Video abspielen", "Play video"), systemImage: "play.circle") {
                deck.media = .video(video, webURL: parent.webURL)
            }
        case .video(let video):
            Button {
                deck.media = .video(video, webURL: parent.webURL)
            } label: {
                RemoteImage(url: video.thumbnail.flatMap(URL.init(string:)))
                    // Portrait media is cropped so one post cannot fill a whole column.
                    .aspectRatio(max(video.aspectRatio?.value ?? 16.0 / 9.0, 1), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
            }
            .buttonStyle(.plain)
            .help(tr("Video abspielen", "Play video"))
            .accessibilityLabel(video.alt ?? tr("Video abspielen", "Play video"))
        case .quote(let quoted):
            QuoteCard(quoted: quoted)
        case .quoteWithMedia(let quoted, let media):
            VStack(alignment: .leading, spacing: 6) {
                EmbedView(embed: media, parent: parent)
                QuoteCard(quoted: quoted)
            }
        case .recordCard(let card):
            RecordCardView(card: card)
        case .unknown:
            EmptyView()
        }
    }
}

private struct ImageGrid: View {
    @Environment(DeckStore.self) private var deck
    let images: [EmbedImage]

    var body: some View {
        if images.count == 1, let image = images.first {
            tile(image, index: 0)
                .aspectRatio(max(image.aspectRatio?.value ?? 4.0 / 3.0, 1), contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    tile(image, index: index).frame(height: 120)
                }
            }
        }
    }

    private func tile(_ image: EmbedImage, index: Int) -> some View {
        Button {
            deck.media = .images(images, index: index)
        } label: {
            RemoteImage(url: URL(string: image.thumb))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image.alt?.isEmpty == false ? image.alt! : tr("Bild", "Picture"))
    }
}

private struct ExternalCard: View {
    @Environment(\.openURL) private var openURL
    let link: ExternalLink

    var body: some View {
        Button {
            if let url = LinkPolicy.webURL(link.uri) { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let thumb = link.thumb.flatMap(URL.init(string:)) {
                    RemoteImage(url: thumb)
                        .frame(height: 130)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = link.title, !title.isEmpty {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    }
                    if let description = link.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(URL(string: link.uri)?.host ?? link.uri)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(LinkPolicy.webURL(link.uri) == nil)
        .help(link.uri)
    }
}

private struct RecordCardView: View {
    @Environment(\.openURL) private var openURL
    let card: RecordCard

    private var kindLabel: String {
        switch card.kind {
        case .feed: return tr("Feed", "Feed")
        case .list: return tr("Liste", "List")
        case .starterPack: return "Starter Pack"
        }
    }

    private var icon: String {
        switch card.kind {
        case .feed: return "number"
        case .list: return "list.bullet"
        case .starterPack: return "person.3"
        }
    }

    var body: some View {
        Button {
            if let url = card.webURL { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(kindLabel) · @\(card.creatorHandle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let description = card.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Im Browser öffnen", "Open in Browser"))
    }
}

private struct QuoteCard: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL
    @Environment(\.openProfile) private var openProfile
    @Environment(\.postTap) private var postTap
    @Environment(\.columnAccountDID) private var accountDID
    let quoted: QuotedPost?

    var body: some View {
        Group {
            if let quoted {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Avatar(url: quoted.author.avatarURL, size: 16)
                        Text(quoted.author.bestName).font(.caption.weight(.semibold)).lineLimit(1)
                        Text("@\(quoted.author.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contextMenu { PersonMenuItems(person: quoted.author) }
                    if !quoted.value.text.isEmpty {
                        SelectablePostText(
                            text: RichText.attributed(text: quoted.value.text, facets: quoted.value.facets),
                            fontSize: 11,
                            maxLines: 8,
                            onTap: { postTap() },
                            menuEntries: { deck.personMenuEntries(person: quoted.author, accountDID: accountDID, openProfile: openProfile) },
                            onOpenLink: { openURL($0) },
                            onMisleadingLink: { deck.confirmation = .openLink($0, shownAs: $1) }
                        )
                    }
                    if quoted.embeds?.isEmpty == false {
                        Label(tr("Enthält Medien", "Contains media"), systemImage: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Also covers embedded starter packs, feeds and lists, which exist but are not posts.
                Text(tr("Dieser eingebettete Inhalt kann hier nicht angezeigt werden.", "This embedded content cannot be shown here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}
