import Foundation

/// Which columns lie outside the visible part of the deck.
struct DeckOverflow: Equatable {
    var left: [Column] = []
    var right: [Column] = []

    var isEmpty: Bool { left.isEmpty && right.isEmpty }

    /// A column counts as outside once less than half of it shows, because its title is then no longer readable.
    static func compute(columns: [Column], frames: [UUID: CGRect], viewportWidth: CGFloat) -> DeckOverflow {
        guard viewportWidth > 0 else { return DeckOverflow() }
        var overflow = DeckOverflow()
        for column in columns {
            guard let frame = frames[column.id], frame.width > 0 else { continue }
            let visibleWidth = min(frame.maxX, viewportWidth) - max(frame.minX, 0)
            guard visibleWidth < frame.width / 2 else { continue }
            if frame.midX < viewportWidth / 2 {
                overflow.left.append(column)
            } else {
                overflow.right.append(column)
            }
        }
        return overflow
    }
}

/// True inside the app instance that hosts unit tests, which must not touch the real account or saved deck.
enum RuntimeEnvironment {
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
