import AppKit
import AVFoundation
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

    /// A real, very short video without a sound track, so playing it makes no noise.
    private func makeShortVideo() async throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try #require(buffer)
        for index in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 20))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func show(_ url: URL, presentation: String, allowsLocalVideo: Bool = true) async throws -> (DeckStore, NSWindow) {
        let json = #"{"$type":"app.bsky.embed.video#view","playlist":"\#(url.absoluteString)","presentation":"\#(presentation)"}"#
        let video = try JSONDecoder().decode(VideoEmbed.self, from: Data(json.utf8))
        let deck = DeckStore()
        deck.media = .video(video, webURL: nil)
        let size = CGSize(width: 300, height: 300)
        let hosting = NSHostingView(rootView: MediaViewer(media: .video(video, webURL: nil), allowsLocalVideo: allowsLocalVideo)
            .environment(deck).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        return (deck, window)
    }

    /// The same clip that plays in the test below. If this played, the viewer would close when it ended.
    @Test func aPostCannotPlayALocalFile() async throws {
        let url = try await makeShortVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let (deck, window) = try await show(url, presentation: "default", allowsLocalVideo: false)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(4))
        #expect(deck.media != nil, "a file address must not start playing")
    }

    @Test func aFinishedVideoClosesTheViewerButALoopingClipKeepsPlaying() async throws {
        let url = try await makeShortVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        let (normal, normalWindow) = try await show(url, presentation: "default")
        defer { normalWindow.orderOut(nil) }
        var waited = 0
        while normal.media != nil, waited < 100 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        #expect(normal.media == nil, "the viewer should close when the video ends")

        let (clip, clipWindow) = try await show(url, presentation: "gif")
        defer { clipWindow.orderOut(nil) }
        try await Task.sleep(for: .seconds(3))
        #expect(clip.media != nil, "a looping clip never closes by itself")
    }
}
