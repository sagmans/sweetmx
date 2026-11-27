import Foundation
@testable import SweetMX

/// Scriptable CodeIdentityProtocol so decision tests never read a real signature.
///
/// `@unchecked Sendable` is safe because every mutable property is read and written under `stateLock`.
final nonisolated class MockCodeIdentity: CodeIdentityProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var identifiers: [String: String] = [:]
    private var requested: [URL] = []

    /// Scripts the signed identifier for a bundle; unscripted bundles read as unsigned (nil).
    func setIdentifier(_ identifier: String?, forBundleAt url: URL) {
        stateLock.lock()
        defer { stateLock.unlock() }
        identifiers[url.path] = identifier
    }

    var signedIdentifierCalls: [URL] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requested
    }

    func signedIdentifier(at bundleURL: URL) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        requested.append(bundleURL)
        return identifiers[bundleURL.path]
    }
}
