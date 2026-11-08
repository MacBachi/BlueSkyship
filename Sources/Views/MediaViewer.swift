import AVKit
import SwiftUI

/// Full-window viewer for pictures and videos. Esc closes it, the arrow keys page through pictures.
struct MediaViewer: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL
    let media: MediaPresentation

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            switch media {
            case .images(let images, let index):
                imagePage(images, index: index)
            case .video(let video, _):
                VideoStage(video: video, onFinished: close)
                    .padding(48)
            }

            VStack {
                HStack {
                    Spacer()
                    if let url = browserURL {
                        chromeButton(tr("Im Browser öffnen", "Open in Browser"), systemImage: "safari") { openURL(url) }
                    }
                    chromeButton(tr("Schließen", "Close"), systemImage: "xmark", action: close)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var browserURL: URL? {
        switch media {
        case .images(let images, let index):
            return images.indices.contains(index) ? URL(string: images[index].fullsize) : nil
        case .video(_, let webURL):
            return webURL
        }
    }

    private func close() {
        deck.media = nil
    }

    @ViewBuilder
    private func imagePage(_ images: [EmbedImage], index: Int) -> some View {
        if images.indices.contains(index) {
            let image = images[index]
            VStack(spacing: 10) {
                ZStack {
                    // The small version is usually cached and bridges the wait for the large one.
                    RemoteImage(url: URL(string: image.thumb), contentMode: .fit, showsPlaceholder: false)
                    RemoteImage(url: URL(string: image.fullsize), contentMode: .fit, showsPlaceholder: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(image.alt?.isEmpty == false ? image.alt! : tr("Bild", "Picture"))

                if let alt = image.alt, !alt.isEmpty {
                    Text(alt)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .frame(maxWidth: 700)
                }
                if images.count > 1 {
                    Text(tr("\(index + 1) von \(images.count)", "\(index + 1) of \(images.count)"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 48)

            if images.count > 1 {
                HStack {
                    chromeButton(tr("Vorheriges Bild", "Previous picture"), systemImage: "chevron.left") {
                        page(images, to: index - 1)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)
                    Spacer()
                    chromeButton(tr("Nächstes Bild", "Next picture"), systemImage: "chevron.right") {
                        page(images, to: index + 1)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index == images.count - 1)
                }
                .padding(12)
            }
        }
    }

    private func page(_ images: [EmbedImage], to index: Int) {
        guard images.indices.contains(index) else { return }
        deck.media = .images(images, index: index)
    }

    private func chromeButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Bluesky serves video as HLS, which AVPlayer plays natively.
private struct VideoStage: View {
    let video: VideoEmbed
    let onFinished: () -> Void
    @State private var player: AVQueuePlayer?
    /// Kept here, because a queue player may already have let go of an item when it reports its end.
    @State private var item: AVPlayerItem?
    /// Has to stay alive for as long as a clip should keep looping.
    @State private var looper: AVPlayerLooper?

    var body: some View {
        Group {
            if let player {
                PlayerView(player: player, showsControls: !video.isGIF)
                    .aspectRatio(video.aspectRatio?.value ?? 16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(tr("Dieses Video lässt sich nicht abspielen.", "This video cannot be played."))
                    .foregroundStyle(.white)
            }
        }
        .onAppear {
            guard player == nil, let url = URL(string: video.playlist) else { return }
            let item = AVPlayerItem(url: url)
            self.item = item
            let newPlayer = AVQueuePlayer(playerItem: item)
            if video.isGIF {
                newPlayer.isMuted = true
                looper = AVPlayerLooper(player: newPlayer, templateItem: item)
            }
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            looper = nil
        }
        // A silent loop never really ends, so only a normal video closes the viewer.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard !video.isGIF, let ended = note.object as? AVPlayerItem, ended === item else { return }
            onFinished()
        }
    }
}

/// AppKit's player. SwiftUI's own `VideoPlayer` aborts inside the system's _AVKit_SwiftUI as soon as it is shown.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let showsControls: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
