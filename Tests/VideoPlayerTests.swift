import AppKit
import AVKit
import SwiftUI
import Testing
@testable import BlueSkyship

/// SwiftUI's `VideoPlayer` once aborted the app the moment any video opened, which no other test could see.
/// So this really shows the viewer. The clip is marked as a silent loop and its address leads nowhere,
/// so it needs no network and makes no sound.
@MainActor
@Suite struct VideoPlayerTests {
    @Test func openingAVideoShowsThePlayerInsteadOfCrashing() async throws {
        let json = #"{"$type":"app.bsky.embed.video#view","playlist":"https://nowhere.invalid/p.m3u8","presentation":"gif"}"#
        let video = try JSONDecoder().decode(VideoEmbed.self, from: Data(json.utf8))
        #expect(video.isGIF)

        let size = CGSize(width: 600, height: 400)
        let view = MediaViewer(media: .video(video, webURL: nil))
            .environment(DeckStore())
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))

        func players(in view: NSView) -> [AVPlayerView] {
            if let player = view as? AVPlayerView { return [player] }
            return view.subviews.flatMap { players(in: $0) }
        }
        let player = try #require(players(in: hosting).first?.player)
        #expect(player.isMuted)
    }
}
