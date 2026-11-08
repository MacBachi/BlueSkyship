import AppKit
import SwiftUI

/// Tests run inside this app, in the same container as the real one. They bring their own windows,
/// so the real interface stays off: it would open a window, store its position and take the focus.
@main
enum AppEntry {
    @MainActor
    static func main() {
        guard RuntimeEnvironment.isUnitTestHost else {
            BlueSkyshipApp.main()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
