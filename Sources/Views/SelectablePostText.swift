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
    let text: AttributedString
    var fontSize: CGFloat
    var color: NSColor = .labelColor
    var maxLines = 0
    var onTap: (@MainActor () -> Void)?
    var menuEntries: @MainActor () -> [PostMenuEntry] = { [] }
    var onOpenLink: @MainActor (URL) -> Void
    /// A link whose text names a different site than it goes to. Opens nothing unless this asks first.
    var onMisleadingLink: @MainActor (URL, String) -> Void = { _, _ in }

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
                if url.scheme == RichText.internalScheme {
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
        // Same look as links elsewhere in the app: colored, without the default underline.
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
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
        view.textContainer?.maximumNumberOfLines = maxLines
        view.textContainer?.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        let content = Self.attributed(text, fontSize: fontSize, color: color)
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

    static func attributed(_ text: AttributedString, fontSize: CGFloat, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: whole)
        result.addAttribute(.foregroundColor, value: color, range: whole)
        // Shows where a link really goes before anyone clicks it.
        result.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let url = value as? URL else { return }
            if LinkPolicy.isWebURL(url) {
                result.addAttribute(.toolTip, value: url.absoluteString, range: range)
            } else {
                result.addAttribute(.toolTip, value: tr("In der App öffnen", "Open in the app"), range: range)
            }
        }
        return result
    }
}

final class PostTextView: NSTextView {
    var onTap: (@MainActor () -> Void)?
    var menuEntries: @MainActor () -> [PostMenuEntry] = { [] }
    var didClickLink = false

    /// A click counts as a click on the post only if it did nothing else: it selected no text,
    /// did not just clear a selection, and was not on a link.
    static func isPlainClick(clickCount: Int, selectionLength: Int, hadSelection: Bool, clickedLink: Bool) -> Bool {
        clickCount == 1 && selectionLength == 0 && !hadSelection && !clickedLink
    }

    override func mouseDown(with event: NSEvent) {
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
        Self.makeMenu(entries: menuEntries(), offersCopy: selectedRange().length > 0)
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
