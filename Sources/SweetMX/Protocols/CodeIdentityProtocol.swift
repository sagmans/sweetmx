import Foundation

/// Reads the code-signing identity of an app bundle, so uninstall can match an app to the data it
/// owns by a value the vendor signed rather than by a name anyone can copy.
///
/// Nonisolated and Sendable because the decision code that uses it runs off the main actor.
public nonisolated protocol CodeIdentityProtocol: Sendable {
    /// The identifier inside a valid signature, or nil when the app is
    /// unsigned or the signature does not validate.
    func signedIdentifier(at bundleURL: URL) -> String?
}
