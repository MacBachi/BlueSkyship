import AppKit

/// Single-key commands in the main window, and pasting pictures into the composer.
/// A local event monitor is used because SwiftUI shortcuts without modifiers would also fire while typing.
@MainActor
final class KeyboardController {
    static let shared = KeyboardController()
    private var monitor: Any?

    func install(deck: DeckStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak deck] event in
            let isHandled = MainActor.assumeIsolated {
                guard let deck else { return false }
                return Self.handle(event, deck: deck)
            }
            return isHandled ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, deck: DeckStore) -> Bool {
        // Sheets, Settings and Help have their own key window and their own title.
        guard let window = NSApp.keyWindow, window.title == "BlueSkyship" else { return false }
        let isTyping = window.firstResponder is NSText
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])

        if modifiers == .command, event.charactersIgnoringModifiers == "v", isTyping, deck.compose != nil {
            return pasteImage(into: deck)
        }

        guard deck.settings.keyboardShortcuts, !isTyping, deck.media == nil, deck.confirmation == nil,
              let command = KeyCommand.parse(
                characters: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                hasModifiers: !modifiers.isEmpty
              ) else { return false }
        return deck.handle(command)
    }

    /// Only takes over when the clipboard holds a picture and no text, so normal pasting stays as it is.
    private static func pasteImage(into deck: DeckStore) -> Bool {
        let board = NSPasteboard.general
        guard board.string(forType: .string) == nil,
              let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return false }
        deck.pastedImageData = data
        return true
    }
}
