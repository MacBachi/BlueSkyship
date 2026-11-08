import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private struct ComposerAttachment: Identifiable {
    let id = UUID()
    let preview: NSImage
    let prepared: PreparedImage
    var alt = ""

    var draftImage: DraftImage { DraftImage(prepared: prepared, alt: alt) }
}

private enum ImageSource: Sendable {
    case file(URL)
    case data(Data, name: String)

    var name: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .data(_, let name): return name
        }
    }

    func prepared() throws -> PreparedImage {
        switch self {
        case .data(let data, _):
            return try ImagePreparer.prepare(data)
        case .file(let url):
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            return try ImagePreparer.prepare(try Data(contentsOf: url))
        }
    }
}

/// Every text field is one post. More than one makes a thread.
struct ComposerPanel: View {
    @Environment(DeckStore.self) private var deck
    @FocusState private var focusedSegment: Int?

    @State private var segments: [String]
    /// One list per post, parallel to `segments`.
    @State private var attachments: [[ComposerAttachment]]
    @State private var video: VideoDraft?
    @State private var replyRule: ReplyRule = .everyone
    @State private var isSending = false
    @State private var isPreparingImages = false
    @State private var pickingImagesFor: Int?
    @State private var isPickingVideo = false
    @State private var isDropTarget = false
    @State private var isPlanning = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)

    private let draftID: UUID
    private static let limit = 300
    private static let maxImages = 4
    /// The limit named by the official definition of video embeds.
    private static let maxVideoBytes = 300_000_000

    init(context: ComposeContext) {
        let segments = context.initialSegments.isEmpty ? [""] : context.initialSegments
        _segments = State(initialValue: segments)
        _attachments = State(initialValue: segments.indices.map { index in
            guard context.initialImages.indices.contains(index) else { return [] }
            return context.initialImages[index].compactMap { image in
                NSImage(data: image.prepared.data).map {
                    ComposerAttachment(preview: $0, prepared: image.prepared, alt: image.alt)
                }
            }
        })
        draftID = context.draftID
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isMissingAltText: Bool {
        guard deck.settings.requireAltText else { return false }
        return attachments.joined().contains { isBlank($0.alt) } || (video.map { isBlank($0.alt) } ?? false)
    }

    private var canSend: Bool {
        guard let context = deck.compose, !isSending, !isPreparingImages, !isMissingAltText else { return false }
        guard segments.allSatisfy({ $0.count <= Self.limit }) else { return false }
        // A post needs text unless it carries something else.
        for index in segments.indices.dropFirst() where isBlank(segments[index]) && attachments[index].isEmpty {
            return false
        }
        return !isBlank(segments[0]) || context.effectiveQuote != nil || !attachments[0].isEmpty || video != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                draftsMenu
                Button {
                    deck.compose = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                // Esc in the media viewer must not close the composer.
                .disabled(deck.media != nil)
                .help(tr("Schließen. Dein Text bleibt als Entwurf erhalten.", "Close. Your text stays as a draft."))
                .accessibilityLabel(tr("Schließen", "Close"))
            }

            if deck.accounts.accounts.count > 1 {
                Picker(tr("Konto", "Account"), selection: Binding(
                    get: { deck.compose?.accountDID ?? "" },
                    set: { deck.compose?.accountDID = $0 }
                )) {
                    ForEach(deck.accounts.accounts) { Text("@\($0.handle)").tag($0.did) }
                }
                .labelsHidden()
            } else if let account = deck.accounts.accounts.first {
                Text("@\(account.handle)").font(.caption).foregroundStyle(.secondary)
            }

            target

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(segments.indices, id: \.self) { index in
                        editor(index)
                    }
                    Button {
                        segments.append("")
                        attachments.append([])
                        focusedSegment = segments.count - 1
                    } label: {
                        Label(tr("Weiterer Post im Thread", "Another post in thread"), systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if deck.compose?.effectiveReply == nil {
                Picker(tr("Wer darf antworten", "Who can reply"), selection: $replyRule) {
                    ForEach(ReplyRule.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .font(.caption)
                .help(tr("Gilt für den neuen Thread als Ganzes.", "Applies to the new thread as a whole."))
            }

            if isMissingAltText {
                Text(tr("Bildbeschreibung fehlt. Du hast sie in den Einstellungen verpflichtend gemacht.", "Image description missing. You made it mandatory in Settings."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
        .onAppear { focusedSegment = 0 }
        .onChange(of: segments) { _, new in
            if let context = deck.compose {
                deck.saveDraft(id: draftID, segments: new, context: context)
            }
        }
        .onChange(of: attachments.map { $0.map { "\($0.id)\($0.alt)" } }) { _, _ in
            deck.saveDraftImages(id: draftID, images: attachments.map { $0.map(\.draftImage) })
        }
        .onChange(of: deck.pastedImageData) { _, data in
            guard let data else { return }
            deck.pastedImageData = nil
            addImages(from: [.data(data, name: tr("Eingefügtes Bild", "Pasted picture"))], to: focusedSegment ?? 0)
        }
        .fileImporter(
            isPresented: Binding(get: { pickingImagesFor != nil }, set: { if !$0 { pickingImagesFor = nil } }),
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            let index = pickingImagesFor ?? 0
            switch result {
            case .success(let urls): addImages(from: urls.map(ImageSource.file), to: index)
            case .failure(let error): deck.showToast(error.localizedDescription)
            }
        }
        .fileDialogBrowserOptions([])
        .background {
            // A second importer needs its own view, because one view can only present one.
            Color.clear.fileImporter(isPresented: $isPickingVideo, allowedContentTypes: [.mpeg4Movie]) { result in
                switch result {
                case .success(let url): addVideo(url)
                case .failure(let error): deck.showToast(error.localizedDescription)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addImages(from: urls.map(ImageSource.file), to: focusedSegment ?? 0)
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    @ViewBuilder
    private var target: some View {
        if let post = deck.compose?.replyTo ?? deck.compose?.quote {
            VStack(alignment: .leading, spacing: 2) {
                Text(post.author.bestName).font(.caption.weight(.semibold)).lineLimit(1)
                Text(post.record.text).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } else if let label = deck.compose?.targetLabel {
            Label(label, systemImage: "arrowshape.turn.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func editor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $segments[index])
                .font(.body)
                .focused($focusedSegment, equals: index)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isDropTarget ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isDropTarget ? 2 : 1
                        )
                }
                .frame(height: segments.count == 1 ? 180 : 100)
                .accessibilityLabel(tr("Text des Posts", "Post text"))
            HStack(spacing: 10) {
                Button {
                    pickingImagesFor = index
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(attachments[index].count >= Self.maxImages || isPreparingImages || (index == 0 && video != nil))
                .help(tr("Bild hinzufügen, höchstens \(Self.maxImages). Du kannst Bilder auch hineinziehen oder mit ⌘V einfügen.", "Add a picture, up to \(Self.maxImages). You can also drag pictures in or paste them with ⌘V."))
                .accessibilityLabel(tr("Bild hinzufügen", "Add picture"))
                if index == 0 {
                    Button {
                        isPickingVideo = true
                    } label: {
                        Image(systemName: "video.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(video != nil || !attachments[0].isEmpty)
                    .help(tr("MP4-Video hinzufügen, statt Bildern. Nur im ersten Post.", "Add an MP4 video instead of pictures. First post only."))
                    .accessibilityLabel(tr("Video hinzufügen", "Add video"))
                }
                if segments.count > 1 {
                    Text(tr("Post \(index + 1) von \(segments.count)", "Post \(index + 1) of \(segments.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        segments.remove(at: index)
                        attachments.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(tr("Diesen Post entfernen", "Remove this post"))
                }
                Spacer()
                if isPreparingImages, focusedSegment == index {
                    ProgressView().controlSize(.small)
                }
                Text("\(Self.limit - segments[index].count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(segments[index].count > Self.limit ? Color.red : Color.secondary)
            }
            attachmentList(index)
            if index == 0 {
                videoRow
            }
        }
    }

    @ViewBuilder
    private func attachmentList(_ index: Int) -> some View {
        ForEach($attachments[index]) { $attachment in
            HStack(spacing: 8) {
                Image(nsImage: attachment.preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                TextField(tr("Bildbeschreibung", "Image description"), text: $attachment.alt, prompt: Text(tr("Bildbeschreibung (Alt-Text)", "Image description (alt text)")))
                    .textFieldStyle(.roundedBorder)
                Button {
                    attachments[index].removeAll { $0.id == attachment.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(tr("Bild entfernen", "Remove picture"))
            }
        }
    }

    @ViewBuilder
    private var videoRow: some View {
        if video != nil {
            HStack(spacing: 8) {
                Image(systemName: "video.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                TextField(tr("Videobeschreibung", "Video description"), text: Binding(
                    get: { video?.alt ?? "" },
                    set: { video?.alt = $0 }
                ), prompt: Text(tr("Videobeschreibung (Alt-Text)", "Video description (alt text)")))
                .textFieldStyle(.roundedBorder)
                Button {
                    video = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(tr("Video entfernen", "Remove video"))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if isSending {
                ProgressView().controlSize(.small)
                if video != nil {
                    Text(tr("Video wird verarbeitet …", "Processing video…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(tr("Planen …", "Schedule…")) { isPlanning = true }
                // Videos need a conversion step that should run while someone is watching.
                .disabled(!canSend || video != nil || replyRule != .everyone)
                .popover(isPresented: $isPlanning, arrowEdge: .top) { planner }
            Button(tr("Posten", "Post"), action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .help(tr("Posten (⌘↩)", "Post (⌘↩)"))
        }
    }

    private var planner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Später senden", "Send later")).font(.headline)
            DatePicker(tr("Zeitpunkt", "Time"), selection: $scheduledDate, in: Date()...)
                .labelsHidden()
            Text(tr("Die App muss zu diesem Zeitpunkt laufen und der Mac wach sein. Sonst fragt sie dich beim nächsten Start.", "The app must be running and the Mac awake at that time. Otherwise it asks you at the next start."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Planen", "Schedule"), action: schedule)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private var draftsMenu: some View {
        let others = deck.drafts.filter { $0.id != draftID }
        if !others.isEmpty {
            Menu {
                ForEach(others) { draft in
                    Button(String(draft.preview.prefix(50))) { deck.open(draft) }
                }
                Divider()
                Menu(tr("Entwurf löschen", "Delete Draft")) {
                    ForEach(others) { draft in
                        Button(String(draft.preview.prefix(50)), role: .destructive) { deck.removeDraft(draft.id) }
                    }
                }
            } label: {
                Label(tr("Entwürfe (\(others.count))", "Drafts (\(others.count))"), systemImage: "doc.text")
                    .font(.caption)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
    }

    private var title: String {
        if deck.compose?.replyTo != nil || deck.compose?.savedReply != nil { return tr("Antworten", "Reply") }
        if deck.compose?.quote != nil || deck.compose?.savedQuote != nil { return tr("Zitieren", "Quote") }
        return segments.count > 1 ? tr("Neuer Thread", "New Thread") : tr("Neuer Post", "New Post")
    }

    private func addImages(from sources: [ImageSource], to index: Int) {
        guard attachments.indices.contains(index) else { return }
        guard index != 0 || video == nil else {
            deck.showToast(tr("Ein Post hat entweder ein Video oder Bilder.", "A post has either a video or pictures."))
            return
        }
        let room = Self.maxImages - attachments[index].count
        if sources.count > room {
            deck.showToast(tr("Höchstens \(Self.maxImages) Bilder pro Post.", "At most \(Self.maxImages) pictures per post."))
        }
        let selected = Array(sources.prefix(max(0, room)))
        guard !selected.isEmpty else { return }
        isPreparingImages = true
        Task {
            defer { isPreparingImages = false }
            for source in selected {
                let name = source.name
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try source.prepared()
                    }.value
                    guard let preview = NSImage(data: prepared.data), attachments.indices.contains(index) else { continue }
                    attachments[index].append(ComposerAttachment(preview: preview, prepared: prepared))
                } catch {
                    deck.showToast("\(name): \(error.localizedDescription)")
                }
            }
        }
    }

    private func addVideo(_ url: URL) {
        isPreparingImages = true
        Task {
            defer { isPreparingImages = false }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= Self.maxVideoBytes else {
                    deck.showToast(tr("Das Video ist zu groß, höchstens 300 MB.", "The video is too large, 300 MB at most."))
                    return
                }
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    deck.showToast(tr("Diese Datei enthält kein Video.", "This file contains no video."))
                    return
                }
                // A rotated phone video stores its upright size only through this transform.
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let upright = size.applying(transform)
                video = VideoDraft(data: data, width: Int(abs(upright.width)), height: Int(abs(upright.height)), alt: "")
            } catch {
                deck.showToast(error.localizedDescription)
            }
        }
    }

    private var draftImages: [[DraftImage]] {
        attachments.map { $0.map(\.draftImage) }
    }

    private func schedule() {
        guard canSend, let context = deck.compose else { return }
        deck.schedule(segments: segments, images: draftImages, context: context, date: scheduledDate)
        isPlanning = false
        deck.removeDraft(draftID)
        deck.compose = nil
    }

    private func send() {
        guard canSend, let context = deck.compose else { return }
        isSending = true
        let texts = segments
        Task {
            let result = await deck.publish(
                segments: texts, images: draftImages, video: video, replyRule: replyRule, context: context
            )
            isSending = false
            if result.error == nil {
                deck.removeDraft(draftID)
                deck.compose = nil
                deck.refreshAll()
            } else if result.sent > 0 {
                // What went out stays out. The rest continues from there, so nothing is posted twice.
                segments = Array(texts.dropFirst(result.sent))
                attachments = Array(attachments.dropFirst(result.sent))
                video = nil
                replyRule = .everyone
                deck.compose?.replyTo = nil
                deck.compose?.quote = nil
                deck.compose?.savedQuote = nil
                deck.compose?.savedReply = result.continuation
                deck.refreshAll()
            }
        }
    }
}

/// Everything waiting to be sent, and what should happen with posts that missed their time.
struct ScheduledSheet: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Geplante Posts", "Scheduled Posts")).font(.title2.weight(.semibold))
            Text(tr("Sie werden gesendet, solange die App läuft und der Mac wach ist.", "They are sent while the app is running and the Mac is awake."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if deck.scheduledPosts.isEmpty {
                Text(tr("Nichts geplant.", "Nothing scheduled.")).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(deck.scheduledPosts) { row($0) }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button(tr("Fertig", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row(_ post: ScheduledPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: Localizer.shared.locale)))
                .font(.caption.weight(.semibold))
            if let label = post.targetLabel {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(post.segments.first ?? "").lineLimit(3)
            if post.segments.count > 1 {
                Text(tr("Thread mit \(post.segments.count) Posts", "Thread of \(post.segments.count) posts"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !post.images.isEmpty {
                Label(tr("\(post.images.count) Bilder", "\(post.images.count) pictures"), systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = post.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if post.due() == .overdue {
                Text(tr("Zeitpunkt verpasst. Soll der Post jetzt noch raus?", "Time missed. Should the post still go out now?"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button(tr("Jetzt senden", "Send Now")) {
                    Task { await deck.send(scheduled: post) }
                }
                Button(tr("Löschen", "Delete"), role: .destructive) { deck.removeScheduled(post.id) }
            }
            .controlSize(.small)
            Divider()
        }
    }
}
