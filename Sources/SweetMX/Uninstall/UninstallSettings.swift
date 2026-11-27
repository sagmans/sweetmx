import Foundation

/// The person's choice to use uninstall at all.
///
/// Off until someone turns it on, because the feature has not been proven in live use on a real Mac
/// and nobody should reach it by accident. The owner turns it on for their own Mac to try it. The
/// launcher model holds one value, so the key handler, the row menu, the footer and the prompt all
/// follow the same answer, and tests inject their own preferences like `HotkeyManager` and
/// `WindowManagerMenu` do.
struct UninstallSettings {
    /// Same naming as `WindowManagerMenu.preferenceKey`; `docs/UNINSTALL.md` quotes it.
    static let preferenceKey = "Uninstall.enabled"

    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    /// Read on each use, never cached, so `defaults write` takes effect without a relaunch. A missing
    /// value reads as off.
    var isEnabled: Bool {
        preferences.bool(forKey: Self.preferenceKey)
    }
}
