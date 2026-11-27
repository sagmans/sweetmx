import Foundation
@testable import SweetMX

/// A throwaway preferences domain, so tests set the uninstall switch without touching the real
/// preferences of the app or the Mac. The domain is removed when the owner goes away, which keeps
/// test runs from leaving files behind.
@MainActor
final class IsolatedPreferences {
    let defaults: UserDefaults
    private let suiteName = "SweetMXTests.\(UUID().uuidString)"

    /// `uninstallEnabled` nil leaves the key unset, the state of everyone who never chose.
    init(uninstallEnabled: Bool? = nil) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let uninstallEnabled {
            defaults.set(uninstallEnabled, forKey: UninstallSettings.preferenceKey)
        }
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var uninstallSettings: UninstallSettings {
        UninstallSettings(preferences: defaults)
    }
}
