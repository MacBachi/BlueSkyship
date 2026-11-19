import AppKit
import SwiftUI

/// One line in a post's menu. A plain description, so the same menu can appear as a SwiftUI
/// context menu and as the AppKit menu of the selectable text.
struct PostMenuEntry: Identifiable {
    let id = UUID()
    var title = ""
    var isDestructive = false
    var isSeparator = false
    var perform: @MainActor () -> Void = {}

    static var separator: PostMenuEntry { PostMenuEntry(isSeparator: true) }
}

struct PostMenuItems: View {
    let entries: [PostMenuEntry]

    var body: some View {
        ForEach(entries) { entry in
            if entry.isSeparator {
                Divider()
            } else {
                Button(entry.title, role: entry.isDestructive ? .destructive : nil) { entry.perform() }
            }
        }
    }
}

/// Text that can be selected with the mouse without giving up the post's other behavior:
/// a plain click still opens the thread, and a right-click still shows the post's menu.
/// SwiftUI's `.textSelection` takes over both, so this uses AppKit's text view directly.
struct SelectablePostText: NSViewRepresentable {
    @Environment(DeckStore.self) private var deck: DeckStore?
    let text: AttributedString
    var fontSize: CGFloat
    var color: NSColor = .labelColor
    var maxLines = 0
    var onTap: (@MainActor () -> Void)?
    var menuEntries: @MainActor () -> [PostMenuEntry] = { [] }
    var onOpenLink: @MainActor (URL) -> Void
    /// A link whose text names a different site than it goes to. Opens nothing unless this asks first.
    var onMisleadingLink: @MainActor (URL, String) -> Void = { _, _ in }
    /// Marks IOCs such as hashes and IP addresses that are not links yet, and offers lookups for them.
    var findsIOCs = true

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenLink: @MainActor (URL) -> Void = { _ in }
        var onMisleadingLink: @MainActor (URL, String) -> Void = { _, _ in }
        weak var view: PostTextView?

        /// Always returns true: returning false would let the text view open the address by itself.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            view?.didClickLink = true
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return true }
            let shown = Self.shownText(of: textView, at: charIndex)
            MainActor.assumeIsolated {
                if let ioc = IOCDetector.ioc(from: url) {
                    showLookups(for: ioc, in: textView, at: charIndex)
                } else if url.scheme == RichText.internalScheme {
                    onOpenLink(url)
                } else if LinkPolicy.isWebURL(url) {
                    if LinkPolicy.isMisleading(shown: shown, target: url) {
                        onMisleadingLink(url, shown)
                    } else {
                        onOpenLink(url)
                    }
                }
            }
            return true
        }

        /// The services that know more about an IOC, right where it was clicked.
        @MainActor private func showLookups(for ioc: IOC, in textView: NSTextView, at charIndex: Int) {
            let open = onOpenLink
            var entries: [PostMenuEntry] = IOCLookup.services(for: ioc).map { service in
                PostMenuEntry(title: tr("Bei \(service.name) nachsehen", "Look up on \(service.name)")) { open(service.url) }
            }
            entries.append(.separator)
            entries.append(PostMenuEntry(title: tr("Kopieren", "Copy")) { Self.copy(ioc.value) })
            if ioc.kind == .url || ioc.kind == .domain || ioc.kind == .ipv4 || ioc.kind == .email {
                entries.append(PostMenuEntry(title: tr("Entschärft kopieren", "Copy Defanged")) { Self.copy(ioc.defanged) })
            }
            if ioc.mayOpenInBrowser {
                let address = ioc.kind == .url ? ioc.value : "https://\(ioc.value)"
                if let url = LinkPolicy.webURL(address) {
                    entries.append(.separator)
                    entries.append(PostMenuEntry(title: tr("Im Browser öffnen", "Open in Browser")) { open(url) })
                }
            }
            let menu = PostTextView.makeMenu(entries: entries, offersCopy: false)
            let header = NSMenuItem(title: "\(ioc.kind.label): \(ioc.value)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.insertItem(header, at: 0)
            menu.insertItem(.separator(), at: 1)
            let point: NSPoint
            if let event = NSApp.currentEvent, event.window == textView.window {
                point = textView.convert(event.locationInWindow, from: nil)
            } else if let layout = textView.layoutManager, let container = textView.textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
                point = layout.boundingRect(forGlyphRange: glyphs, in: container).origin
            } else {
                point = .zero
            }
            menu.popUp(positioning: nil, at: point, in: textView)
        }

        private static func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        private static func shownText(of textView: NSTextView, at index: Int) -> String {
            guard let storage = textView.textStorage, index >= 0, index < storage.length else { return "" }
            var range = NSRange()
            _ = storage.attribute(.link, at: index, effectiveRange: &range)
            return storage.attributedSubstring(from: range).string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PostTextView {
        let view = PostTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        // Links get their color from the text itself, because IOCs are links with a color of their own.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        context.coordinator.view = view
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: PostTextView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onMisleadingLink = onMisleadingLink
        view.onTap = onTap
        view.menuEntries = menuEntries
        view.onOpenLink = onOpenLink
        view.hover = deck.map { IOCHover(live: $0.settings.liveIOCInfo, intel: $0.iocIntel) }
        view.textContainer?.maximumNumberOfLines = maxLines
        view.textContainer?.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        // Hover cards replace the plain tooltips where they can appear.
        let content = Self.attributed(text, fontSize: fontSize, color: color, findsIOCs: findsIOCs, tooltips: view.hover == nil)
        // Setting the text clears a selection, and a column redraws often.
        if view.textStorage?.isEqual(to: content) != true {
            view.textStorage?.setAttributedString(content)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PostTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width ?? 300
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    static let iocColor = NSColor.systemOrange

    static func attributed(
        _ text: AttributedString, fontSize: CGFloat, color: NSColor, findsIOCs: Bool = false, tooltips: Bool = true
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: whole)
        result.addAttribute(.foregroundColor, value: color, range: whole)
        // Shows where a link really goes before anyone clicks it.
        var linked = IndexSet()
        result.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let url = value as? URL else { return }
            linked.insert(integersIn: range.location..<(range.location + range.length))
            result.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            if LinkPolicy.isWebURL(url) {
                if tooltips { result.addAttribute(.toolTip, value: IOCDetector.tooltip(forLink: url), range: range) }
            } else {
                result.addAttribute(.toolTip, value: tr("In der App öffnen", "Open in the app"), range: range)
            }
        }
        guard findsIOCs else { return result }
        for ioc in IOCDetector.find(in: result.string) {
            let span = ioc.range.location..<(ioc.range.location + ioc.range.length)
            guard !linked.intersects(integersIn: span), let link = IOCDetector.link(for: ioc) else { continue }
            result.addAttributes([
                .link: link,
                .foregroundColor: iocColor,
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 0.5, weight: .regular),
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: iocColor.withAlphaComponent(0.7),
            ], range: ioc.range)
            if tooltips { result.addAttribute(.toolTip, value: IOCDetector.tooltip(for: ioc), range: ioc.range) }
        }
        return result
    }
}

final class PostTextView: NSTextView {
    var onTap: (@MainActor () -> Void)?
    var menuEntries: @MainActor () -> [PostMenuEntry] = { [] }
    var onOpenLink: @MainActor (URL) -> Void = { _ in }
    var didClickLink = false
    /// Set when hover cards can appear; `nil` leaves the plain tooltips.
    var hover: IOCHover?

    private var hoverArea: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var hoveredRange: NSRange?
    private var popover: NSPopover?

    /// How long the mouse rests before a card appears, so that crossing a link shows nothing.
    static let hoverDelay: Duration = .milliseconds(450)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard hover != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let found = link(at: point), let subject = Self.subject(of: found.url) else {
            hoveredRange = nil
            hoverTask?.cancel()
            closeSoon()
            return
        }
        guard found.range != hoveredRange else { return }
        hoveredRange = found.range
        hoverTask?.cancel()
        closeTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled, let self, self.hoveredRange == found.range else { return }
            self.showCard(subject.ioc, link: subject.link, range: found.range)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRange = nil
        hoverTask?.cancel()
        closeSoon()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { closeCard() }
    }

    /// The IOC behind a link, and the web address if it is an ordinary link.
    static func subject(of url: URL) -> (ioc: IOC, link: URL?)? {
        if let ioc = IOCDetector.ioc(from: url) { return (ioc, nil) }
        if let ioc = IOCDetector.subject(forLink: url) { return (ioc, url) }
        return nil
    }

    /// The link under a point, with the whole range it covers.
    func link(at point: NSPoint) -> (url: URL, range: NSRange)? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        let value = storage.attribute(.link, at: index, effectiveRange: &range)
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        return url.map { ($0, range) }
    }

    private func showCard(_ ioc: IOC, link: URL?, range: NSRange) {
        guard let hover, let layout = layoutManager, let container = textContainer, window != nil else { return }
        closeCard()
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var anchor = layout.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: container)
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, stop in
            anchor = rect
            stop.pointee = true
        }
        anchor = anchor.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let open = onOpenLink
        popover.contentViewController = NSHostingController(rootView: IOCHoverCard(
            ioc: ioc, link: link, live: hover.live, intel: hover.intel,
            open: { open($0) },
            close: { [weak self] in self?.closeCard() }
        ))
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    /// Closes the card once the mouse is neither on its link nor on the card itself.
    private func closeSoon() {
        guard popover != nil else { return }
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let popover = self.popover else { return }
                let inCard = popover.contentViewController?.view.window?.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) ?? false
                if !inCard && self.hoveredRange == nil {
                    self.closeCard()
                    return
                }
            }
        }
    }

    func closeCard() {
        closeTask?.cancel()
        popover?.close()
        popover = nil
    }

    /// A click counts as a click on the post only if it did nothing else: it selected no text,
    /// did not just clear a selection, and was not on a link.
    static func isPlainClick(clickCount: Int, selectionLength: Int, hadSelection: Bool, clickedLink: Bool) -> Bool {
        clickCount == 1 && selectionLength == 0 && !hadSelection && !clickedLink
    }

    override func mouseDown(with event: NSEvent) {
        hoverTask?.cancel()
        closeCard()
        didClickLink = false
        let hadSelection = selectedRange().length > 0
        // Runs until the button is released, selecting text if the mouse is dragged.
        super.mouseDown(with: event)
        if Self.isPlainClick(
            clickCount: event.clickCount, selectionLength: selectedRange().length,
            hadSelection: hadSelection, clickedLink: didClickLink
        ) {
            onTap?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        closeCard()
        var entries = menuEntries()
        // On a link or IOC, looking it up comes first.
        if let found = link(at: convert(event.locationInWindow, from: nil)), let subject = Self.subject(of: found.url) {
            let open = onOpenLink
            var lookups = IOCLookup.services(for: subject.ioc).map { service in
                PostMenuEntry(title: tr("Bei \(service.name) nachsehen", "Look up on \(service.name)")) { open(service.url) }
            }
            let copied = subject.link?.absoluteString ?? subject.ioc.value
            lookups.append(PostMenuEntry(title: subject.link == nil ? tr("IOC kopieren", "Copy IOC") : tr("Link kopieren", "Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copied, forType: .string)
            })
            entries = lookups + (entries.isEmpty ? [] : [.separator] + entries)
        }
        return Self.makeMenu(entries: entries, offersCopy: selectedRange().length > 0)
    }

    /// Selected text comes first in the menu, because copying it is why someone right-clicks there.
    static func makeMenu(entries: [PostMenuEntry], offersCopy: Bool) -> NSMenu {
        let menu = NSMenu()
        if offersCopy {
            menu.addItem(withTitle: tr("Kopieren", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
            if !entries.isEmpty { menu.addItem(.separator()) }
        }
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
            } else {
                let item = NSMenuItem(title: entry.title, action: #selector(MenuAction.run), keyEquivalent: "")
                let action = MenuAction(entry.perform)
                item.target = action
                // A menu item does not keep its target alive by itself.
                item.representedObject = action
                menu.addItem(item)
            }
        }
        return menu
    }
}

private final class MenuAction: NSObject {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }

    @MainActor @objc func run() {
        perform()
    }
}
