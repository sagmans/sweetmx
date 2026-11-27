import Foundation
@testable import SweetMX

/// Scriptable FinderTrashProtocol so tests never drive the real Finder.
///
/// `@unchecked Sendable` is safe because every mutable property is read and written under `stateLock`.
final nonisolated class MockFinderTrash: FinderTrashProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var outcomes: [String: FinderTrashOutcome] = [:]
    private var _defaultOutcome: FinderTrashOutcome = .moved
    private var requested: [(url: URL, timeout: TimeInterval)] = []

    /// Outcome for an item that has no scripted outcome.
    var defaultOutcome: FinderTrashOutcome {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _defaultOutcome }
        set { stateLock.lock(); defer { stateLock.unlock() }; _defaultOutcome = newValue }
    }

    func setOutcome(_ outcome: FinderTrashOutcome, for url: URL) {
        stateLock.lock()
        defer { stateLock.unlock() }
        outcomes[url.path] = outcome
    }

    var moveToTrashCalls: [(url: URL, timeout: TimeInterval)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requested
    }

    func moveToTrash(_ url: URL, timeout: TimeInterval) async -> FinderTrashOutcome {
        stateLock.withLock {
            requested.append((url: url, timeout: timeout))
            return outcomes[url.path] ?? _defaultOutcome
        }
    }
}
