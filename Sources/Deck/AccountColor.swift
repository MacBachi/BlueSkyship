import SwiftUI

/// Marks which account a post came from. Each account has one; the first ones get different colours.
enum AccountColor: String, Codable, CaseIterable, Sendable {
    case blue, purple, green, orange, pink, teal, yellow, gray

    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .teal: return .teal
        case .yellow: return .yellow
        case .gray: return .gray
        }
    }

    var label: String {
        switch self {
        case .blue: return tr("Blau", "Blue")
        case .purple: return tr("Violett", "Purple")
        case .green: return tr("Grün", "Green")
        case .orange: return tr("Orange", "Orange")
        case .pink: return tr("Rosa", "Pink")
        case .teal: return tr("Türkis", "Teal")
        case .yellow: return tr("Gelb", "Yellow")
        case .gray: return tr("Grau", "Gray")
        }
    }
}

extension AccountStore {
    /// The chosen colour, or else one by position, so two accounts never start out alike.
    func color(for did: String?) -> AccountColor? {
        guard let did, let index = accounts.firstIndex(where: { $0.did == did }) else { return nil }
        if let chosen = accounts[index].color { return chosen }
        let taken = Set(accounts.compactMap(\.color))
        let free = AccountColor.allCases.filter { !taken.contains($0) }
        let automatic = accounts.prefix(index).filter { $0.color == nil }.count
        return free.isEmpty ? AccountColor.allCases[index % AccountColor.allCases.count] : free[automatic % free.count]
    }
}

/// A thin strip at the leading edge that says which account a post came from.
/// Only shown with more than one account, where the origin is worth telling apart.
struct AccountMark: ViewModifier {
    @Environment(DeckStore.self) private var deck
    let accountDID: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if deck.accounts.accounts.count > 1, let color = deck.accounts.color(for: accountDID) {
                Rectangle()
                    .fill(color.color.opacity(0.55))
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A small dot in an account's colour, next to its name.
struct AccountDot: View {
    @Environment(DeckStore.self) private var deck
    let accountDID: String?
    var size: CGFloat = 7

    var body: some View {
        if let color = deck.accounts.color(for: accountDID) {
            Circle().fill(color.color).frame(width: size, height: size)
        }
    }
}
