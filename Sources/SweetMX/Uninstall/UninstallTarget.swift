import Foundation

/// The app a person asked to remove, after the resolver accepted it.
///
/// Later steps (finding related files, confirming, moving to the Trash) take this value instead of
/// a raw path, so every one of them works on an app that already passed the refusal rules.
nonisolated struct UninstallTarget: Equatable, Sendable {
    let bundleURL: URL
    let displayName: String
    let bundleID: String
    /// False when the signature does not confirm the bundle ID; all related items are then locked.
    let identityConfirmed: Bool
    /// The parent folder is not writable for this user, so only Finder can move the app.
    let needsFinder: Bool
}

/// Why an app may not be removed. Each case maps to one message for the person, so a refusal is
/// explained instead of silently ignored.
nonisolated enum UninstallRefusal: Error, Equatable, Sendable {
    case systemApp, requiredAppleApp, sweetMXItself, symlinkedApp, unreadableBundleID
}
