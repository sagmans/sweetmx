import AppKit

/// The on and off switch for the window manager in the status menu.
///
/// Its own type, like `LoginItemMenu`, so the controller that later starts and stops tiling reads
/// one owner of the choice. Today the switch only records the choice: nothing reads it yet, so
/// app search and the clipboard history cannot change with it.
final class WindowManagerMenu: NSObject {
    private enum Title {
        static let toggle = "Window Manager"
        /// Says plainly that the switch has no effect, so a checkmark is not taken for tiling.
        static let help = "Not available yet. SweetMX keeps this choice for a later version."
    }

    /// A missing value reads as off, so the window manager is off for everyone who never chose.
    static let preferenceKey = "WindowManager.enabled"

    private let preferences: UserDefaults
    let item = NSMenuItem(title: Title.toggle, action: #selector(toggleEnabled), keyEquivalent: "")

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
        item.target = self
        item.toolTip = Title.help
        refresh()
    }

    var isEnabled: Bool {
        preferences.bool(forKey: Self.preferenceKey)
    }

    @objc private func toggleEnabled() {
        preferences.set(!isEnabled, forKey: Self.preferenceKey)
        refresh()
    }

    private func refresh() {
        item.state = isEnabled ? .on : .off
    }
}
